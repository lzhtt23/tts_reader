import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/structured_document.dart';
import '../features/pdf_reading/pdf_read_session.dart';
import '../services/speech_diagnostics.dart';
import '../services/auto_sleep.dart';
import '../services/crash_log.dart';
import '../services/document_service.dart';
import '../services/keep_alive.dart';
import '../services/storage_service.dart';
import '../services/text_processor.dart';
import 'cloud_tts_engine.dart';
import 'media_interruption.dart';
import 'system_tts_engine.dart';
import 'audio_session_source.dart';
import 'tts_audio_handler.dart';
import 'tts_engine.dart';

/// 插件等待被上层主动取消（用户按了停止 / 换了位置），按普通失败处理
class _WaitCancelled implements Exception {
  const _WaitCancelled();

  @override
  String toString() => '朗读已取消';
}

/// 朗读调度中心（ChangeNotifier 单例）
///
/// 负责：引擎注册与切换、朗读游标 (章, 段, 句)、朗读粒度、
/// 打断令牌 _generation、云端失败降级，以及设置持久化。
class TtsManager extends ChangeNotifier implements AudioSessionSource {
  TtsManager._() {
    _register(SystemTtsEngine());
  }

  /// 全局单例
  static final TtsManager instance = TtsManager._();

  static const String _systemId = 'system';
  static const String _cloudId = 'cloud';

  final Map<String, TtsEngine> _engines = <String, TtsEngine>{};

  // ---- 设置项（持久化到 SharedPreferences）----
  String _activeId = _systemId;
  double _rate = 1.0;
  double _pitch = 1.0;
  String _voiceId = '';
  String _cloudBaseUrl = '';
  String _cloudApiKey = '';

  // ---- 朗读状态 ----
  StructuredDocument? _doc;
  ReadGranularity _granularity = ReadGranularity.sentence;
  int _ch = 0;
  int _p = 0;
  int _s = 0;

  /// **意图游标**：已经发起、但还没被 `_runBody` 真正写进 `_ch/_p/_s` 的目标位置
  ///
  /// 见 [cursor] 与 [speakFrom] 的说明（§4.102）。落地后立刻清 `null`。
  (int, int, int)? _pendingCursor;
  bool _speaking = false;
  bool _paused = false;
  bool _oneShot = false;

  /// 用户是否刚刚**主动结束**了朗读（[stop] 置真，播放/重新载入文档清掉）
  ///
  /// 为什么需要它：`stop()` 之后 `_endSession()` 故意保留 `_doc`（记进度用），
  /// 于是 `hasSession` 仍为 true —— 只按 `hasSession` 判断显示的话，
  /// 阅读页按下方块键结束朗读后，文档库那条迷你条会一直挂着不消失。
  bool _endedByStop = false;
  bool get endedByStop => _endedByStop;

  /// 纯文本队列（网页朗读等场景），与结构化文档游标互不影响
  List<String> _lines = const <String>[];
  int _lineIndex = 0;

  /// 当前是否处于纯文本队列模式（决定通知栏进度与续读行为）
  bool _plainMode = false;

  /// 当前文档标题（通知栏）
  String _docTitle = '';

  /// 当前文档在文档库里的 id（见 [loadDocument]）
  String? _documentId;

  bool _fallback = false;
  bool _wakelockOn = false;

  /// 「保持屏幕常亮」当前是否生效（与熄屏保活分开记账）
  bool _screenLockOn = false;
  int _generation = 0;
  String? _error;
  List<TtsVoice> _voices = const <TtsVoice>[];
  bool _initialized = false;

  /// 上一次**已经成功下发**的引擎设置指纹：`引擎id|语速|音调|音色`
  ///
  /// 用途：多句连读时跳过重复的平台调用（见 [_applyRate] / [_applyVoice] 的说明）。
  /// 指纹没变就说明"引擎那边的设置已经是我要的"，再下发一次纯属浪费一次平台通道
  /// 往返 —— 真机日志实测（v1.21.36+87）：每句读完到下一句出声之间白花
  /// **406~521ms**，而这几项设置与上一句完全相同。
  String _appliedSetupKey = '';

  /// **哪个引擎已经成功 initialize 过**（与上面那条一起决定能否跳过重复下发）
  ///
  /// ⚠️ 不能用 [_initialized]：那个是**进程级**标记（[loadSettings] 里置真），
  /// 它只说明"设置读过了"，不说明"当前这个引擎初始化过"。
  /// 拿它当判据会让**第一次朗读就跳过 initialize** → 直接 speak 到未初始化的引擎。
  String _initedEngineId = '';

  String _setupKeyOf(TtsEngine engine) =>
      '${engine.id}|$_rate|$_pitch|$_voiceId';

  // ---------------- 只读状态 ----------------

  List<TtsEngine> get engines => List<TtsEngine>.unmodifiable(_engines.values);
  List<TtsVoice> get voices => _voices;
  String get activeEngineId => _activeId;
  bool get cloudConfigured => _cloudBaseUrl.isNotEmpty && _cloudApiKey.isNotEmpty;
  String get cloudBaseUrl => _cloudBaseUrl;
  String get cloudApiKey => _cloudApiKey;
  @override
  double get rate => _rate;
  double get pitch => _pitch;
  String get voiceId => _voiceId;
  ReadGranularity get granularity => _granularity;
  bool get speaking => _speaking;
  @override
  bool get paused => _paused;
  @override
  bool get playing => _speaking && !_paused;
  String? get error => _error;

  /// 纯文本队列朗读的当前条下标与总条数
  int get plainIndex => _lineIndex;
  int get plainTotal => _lines.length;

  /// 是否正在做纯文本队列朗读（网页朗读）
  bool get readingPlain => _oneShot && _speaking && _lines.isNotEmpty;

  /// 当前引擎展示名（降级中会标注）
  String get activeEngineName {
    final engine = _engines[_activeId];
    final name = engine == null
        ? '系统 TTS'
        : (engine == _engines[_systemId] && _localEnginePackage.isNotEmpty
              ? '本地 TTS · $localEngineLabel'
              : engine.displayName);
    return _fallback ? '$name → 系统 TTS' : name;
  }

  /// 游标：章、段、句（均在对应粒度下解释）
  ///
  /// ⚠️ **优先返回「意图游标」**（§4.102）：点句 / 快进发起后，真实游标
  /// `_ch/_p/_s` 要等 `_runBody` 里 `await 停引擎` 之后才写（实测 5–78ms）。
  /// 这个窗口里如果读到的是还没更新的旧游标，「短时间内点击切换相邻句子」
  /// 就会**反复从同一个旧位置起算** —— 于是每次都算成同一句、最后只有
  /// 最后一次生效且目标还是错的（用户报的「滚到随机位置、从错误位置开始读」）。
  ///
  /// 意图游标在 [speakFrom] 里**同步**写入，落地时清空，所以这个窗口里
  /// 「读游标」拿到的是用户最后一次点的位置。
  (int, int, int) get cursor => _pendingCursor ?? (_ch, _p, _s);

  /// 内部取「当前有效位置」：优先意图游标，无意图时才用真实游标
  ///
  /// ⚠️ 管理层**自己**算下一句 / 夹取位置时也必须走它（§4.102）——
  /// `skipSentence` 原来直接读 `(_ch,_p,_s)`，绕过了 [cursor]，
  /// 于是快进连点仍然基于旧游标算，一路退化成「永远第 1 句」。
  (int, int, int) get _effectiveCursor => _pendingCursor ?? (_ch, _p, _s);

  /// **仅供测试**：真实游标（不读意图游标）
  ///
  /// §4.102 之后 [cursor] 会优先返回「还没落地的意图」，于是它**不再适合**
  /// 当「异步落位完成了没」的轮询信号 —— 旧用例 `until(tts, expected)` 就是
  /// 轮询 `cursor`，语义变了以后会立刻返回、等不到真实落位。
  /// 想等真实落位请用这个。
  @visibleForTesting
  (int, int, int) get settledCursor => (_ch, _p, _s);

  /// 高亮游标：仅在朗读会话进行中返回，否则返回 null（界面据此关闭高亮）
  (int, int, int)? get highlightCursor =>
      _speaking && !_oneShot && _doc != null ? cursor : null;

  TtsEngine get _activeEngine => _engines[_activeId] ?? _engines[_systemId]!;

  void _notify() {
    _updateWakelock();
    _updateAutoSleep();
    if (!hasListeners) return;
    try {
      notifyListeners();
    } catch (_) {
      // 界面监听器抛出的异常绝不能顺着调用栈打断朗读循环
    }
  }

  /// 把「是否正在出声」告诉自动休眠：暂停期间不计入空闲时间
  void _updateAutoSleep() =>
      AutoSleepController.instance.setPlaying(_speaking && !_paused);

  /// 朗读期间保持 CPU 唤醒，后台朗读不被系统休眠中断
  ///
  /// 两件事分开：
  /// - **熄屏保活**（默认行为）：持 `PARTIAL_WAKE_LOCK`，屏幕可以关、CPU 继续跑，
  ///   这是「熄屏之后还能继续听」的关键；暂停 / 停止立刻释放，避免待机耗电。
  /// - **保持屏幕常亮**（可选，默认关）：`wakelock_plus` 加的是 `FLAG_KEEP_SCREEN_ON`，
  ///   适合「盯着屏幕跟读」，但很费电，而且与熄屏保活正好相反，所以做成开关。
  void _updateWakelock() {
    final playing = _speaking && !_paused;
    if (playing != _wakelockOn) {
      _wakelockOn = playing;
      unawaited(playing ? KeepAliveService.instance.acquire() : KeepAliveService.instance.release());
    }
    final wantScreenOn = playing && StorageService.instance.keepScreenOn;
    if (wantScreenOn != _screenLockOn) {
      _screenLockOn = wantScreenOn;
      unawaited(
        (wantScreenOn ? WakelockPlus.enable() : WakelockPlus.disable()).catchError((Object _) {}),
      );
    }
  }

  /// 「朗读时保持屏幕常亮」开关（设置页用）
  Future<void> setKeepScreenOn(bool value) async {
    await StorageService.instance.setKeepScreenOn(value);
    _updateWakelock();
    _notify();
  }

  // ---------------- 初始化与设置 ----------------

  /// 启动时载入设置并注册云端引擎
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    final settings = await StorageService.instance.loadTtsSettings();
    _rate = _clampDouble(_asDouble(settings['rate'], 1.0), 0.5, 2.0);
    _pitch = _clampDouble(_asDouble(settings['pitch'], 1.0), 0.5, 2.0);
    _voiceId = settings['voiceId'] as String? ?? '';
    _cloudBaseUrl = settings['cloudBaseUrl'] as String? ?? '';
    _cloudApiKey = settings['cloudApiKey'] as String? ?? '';
    _localEnginePackage = settings['localEngine'] as String? ?? '';

    if (cloudConfigured) {
      _register(CloudTtsEngine(baseUrl: _cloudBaseUrl, apiKey: _cloudApiKey));
    }
    // 用户选过本地引擎：重建系统引擎并带上包名（构造时就带上，
    // 避免 initialize 之后再切导致已注册的完成回调被重置）
    if (_localEnginePackage.isNotEmpty) {
      _engines.remove(_systemId);
      _register(SystemTtsEngine(enginePackage: _localEnginePackage));
    }
    final saved = settings['activeId'] as String? ?? _systemId;
    _activeId = _engines.containsKey(saved) ? saved : _systemId;

    // 系统引擎初始化也套超时：引擎缺失或系统 TTS 服务无响应时不能卡住启动
    final ready = await _awt(
      () => _engines[_systemId]!.initialize(),
      initTimeout,
      lock: 'init-$_systemId',
    );
    if (!ready) _error = '系统 TTS 初始化失败或超时，可在设置里检查系统语音引擎';
    // 文本预处理规则（T2S 的 Text Process Rules）：只影响送去合成的字符串
    await TextProcessor.instance.init();
    // 自动休眠（T2S 的 tts.autosleep.settings）：空闲暂停 + 定时停止
    final autoSleep = AutoSleepController.instance;
    await autoSleep.init();
    autoSleep.onIdleTimeout = pause;
    autoSleep.onStopTimeout = stop;
    unawaited(refreshVoices());
    // 本地引擎列表：选择栏与设置页都要用，启动时先拉一次
    unawaited(refreshLocalEngines());
    _notify();
  }

  void _register(TtsEngine engine) {
    engine.setCompletionHandler(_handleEngineCompletion);
    _engines[engine.id] = engine;
    // ⚠️ 换了引擎对象 = 之前下发过的设置不再可信（新对象内部是干净的），
    // 必须作废记账，否则 [_ensureReady] 会跳过 initialize 直接 speak
    // （表现为"切了引擎却不生效 / 没声音"）。
    _appliedSetupKey = '';
    if (_initedEngineId == engine.id) _initedEngineId = '';
  }

  // ---------------- 「朗读被打断」标记（§4.107） ----------------
  //
  // 为什么需要它：`flutter_tts` 的**取消**与**自然读完**都会让 `speak()` 的 Future
  // 完成，而且只给一条完成回调、没有参数区分。原来的实现于是把"被 stop 掐掉"
  // 也当成了"读完了" —— 真机实测 54% 的"读完"只有 0~48ms（真朗读 1~6 秒），
  // 上层据此推进位置，就是「点句之后多跑 5~10 句」。

  /// 跳动检测用：当前会话代次（只读，不改变任何行为）。
  ///
  /// PDF 侧的推进由 `PdfReadSession` 自己记账，但判定器要拿它和朗读事件的
  /// 代次对比（R2），所以这里把代次暴露出来。
  int get diagGeneration => _generation;

  // ---------------- 本地 TTS 引擎 ----------------

  /// 设备上可选的本地 TTS 引擎（系统引擎才有）
  List<LocalTtsEngine> get localEngines => List<LocalTtsEngine>.unmodifiable(_localEngines);
  List<LocalTtsEngine> _localEngines = const <LocalTtsEngine>[];

  /// 当前本地引擎包名（跟随系统默认时为空）
  String get localEnginePackage => _localEnginePackage;
  String _localEnginePackage = '';

  LocalEngineHost? get _localHost {
    // 声明成 Object? 再判断：Dart 的类型提升只在「被测类型是声明类型的子类型」时成立，
    // 而 TtsEngine 与 LocalEngineHost 是互不相关的两个接口（只是碰巧由同一个类实现）
    final Object? engine = _engines[_systemId];
    if (engine is LocalEngineHost) return engine;
    return null;
  }

  /// 当前本地引擎的显示名（没得选时就是「系统 TTS」）
  String get localEngineLabel {
    final package = _localEnginePackage;
    if (package.isEmpty) {
      final fallback = _localEngines.where((engine) => engine.isCurrent).toList();
      return fallback.isEmpty ? _systemDisplayName : fallback.first.label;
    }
    return LocalTtsEngine.labelOf(package);
  }

  /// 重新枚举本地引擎（设置页与选择栏共用）
  Future<void> refreshLocalEngines() async {
    final host = _localHost;
    if (host == null) {
      _localEngines = const <LocalTtsEngine>[];
      _notify();
      return;
    }
    try {
      final engines = await _bounded(host.listLocalEngines(), voiceTimeout);
      _localEngines = engines;
    } catch (_) {
      // 枚举失败不影响朗读，保持上一次的结果
    }
    _notify();
  }

  /// 切换本地 TTS 引擎：停掉当前朗读 → 换引擎 → 重新套用语言 / 语速 / 音色
  Future<void> setLocalEngine(String package) async {
    final host = _localHost;
    if (host == null) return;
    final target = package.trim();
    if (target == _localEnginePackage) return;
    await stop();
    try {
      await _bounded(host.useLocalEngine(target), voiceTimeout);
      _localEnginePackage = target;
    } catch (e) {
      _error = '切换本地引擎失败：$e';
      CrashLog.mark('切换本地引擎失败：$target（$e）');
    }
    await _persist();
    // 换了引擎，音色列表也整套变了
    _voices = const <TtsVoice>[];
    _voiceId = '';
    await refreshLocalEngines();
    unawaited(refreshVoices());
    _notify();
  }

  /// 系统引擎的兜底显示名（枚举不到引擎时用）
  String get _systemDisplayName => _engines[_systemId]?.displayName ?? '系统 TTS';

  /// 仅供测试：清掉本地引擎选择与错误状态
  ///
  /// TtsManager 是单例，跨用例会串状态（上一个用例选过的引擎会留在下一个用例里）。
  @visibleForTesting
  void resetLocalEngineForTest() {
    _localEnginePackage = '';
    _localEngines = const <LocalTtsEngine>[];
    _voices = const <TtsVoice>[];
    _error = null;
  }

  /// 注册 / 替换一个朗读引擎。
  ///
  /// 生产代码由 [init] 与 [configureCloud] 调用；对外暴露是为了让测试注入
  /// 假引擎（测试环境没有 flutter_tts 原生实现，真引擎永远不回复，
  /// 只有假引擎才能把「整篇朗读」这条流程真正跑完）。
  ///
  /// [makeActive] 为真时立刻切到该引擎（等价于先 stop 再切换）。
  Future<void> registerEngine(TtsEngine engine, {bool makeActive = false}) async {
    _register(engine);
    if (makeActive) {
      await stop();
      _activeId = engine.id;
      _voices = const <TtsVoice>[];
      _notify();
    }
  }

  /// 引擎侧「这一段读完了」的回调
  ///
  /// 真实系统引擎在每段话语结束时既唤醒 `speak()` 的 Future，也会调这个回调
  /// （见 `SystemTtsEngine._handleFinished`）。所以**不能**在这里决定多单元朗读的收尾：
  /// 会话什么时候结束由主循环推进决定，这里只兜底「队列里确实没有下一条」的情况。
  ///
  /// 踩过的坑：原来判据是 `_oneShot`，但纯文本队列（网页朗读 / 复制即朗读 / 打字朗读）
  /// 为了 `resume()` 也把 `_oneShot` 置真，于是每读完第一段就被这里收尾 ——
  /// 表现是**多段朗读只读第一段就停**，而且单元测试发现不了（假引擎没接这个回调）。
  void _handleEngineCompletion() {
    if (!_speaking) return;
    // 文档朗读（按句 / 按段 / 按章）：游标推进与收尾都归主循环管
    if (!_plainMode) return;
    // 纯文本队列后面还有条目：交给循环继续推进
    if (_lineIndex < _lines.length - 1) return;
    _oneShot = false;
    _speaking = false;
    _notify();
  }

  /// 动态注册 / 更新云端引擎；地址或 Key 为空时移除云端引擎
  Future<void> configureCloud(String baseUrl, String apiKey) async {
    _cloudBaseUrl = baseUrl.trim();
    _cloudApiKey = apiKey.trim();
    final existing = _engines[_cloudId];
    if (!cloudConfigured) {
      _engines.remove(_cloudId);
      if (_activeId == _cloudId) await setActiveEngine(_systemId);
    } else if (existing is CloudTtsEngine) {
      existing.updateConfig(baseUrl: _cloudBaseUrl, apiKey: _cloudApiKey);
    } else {
      _register(CloudTtsEngine(baseUrl: _cloudBaseUrl, apiKey: _cloudApiKey));
    }
    await _persist();
    _notify();
  }

  /// 切换引擎：先 stop 再切换
  Future<void> setActiveEngine(String id) async {
    if (id == _activeId || !_engines.containsKey(id)) return;
    await stop();
    // 切引擎：作废设置记账（新引擎内部状态是干净的，必须重新下发）
    _appliedSetupKey = '';
    _activeId = id;    _voiceId = ''; // 音色列表随引擎变化
    _voices = const <TtsVoice>[];
    await _persist();
    _notify();
    unawaited(refreshVoices());
  }

  /// 拉取当前引擎的语音列表（枚举可能很慢，超时按空列表处理）
  Future<List<TtsVoice>> refreshVoices() async {
    List<TtsVoice> result;
    try {
      result = await _awtValue(_activeEngine.getVoices, voiceTimeout, const <TtsVoice>[]);
    } catch (_) {
      result = const <TtsVoice>[];
    }
    _voices = result;
    _notify();
    return _voices;
  }

  Future<void> setVoice(String voiceId) async {
    _voiceId = voiceId;
    if (voiceId.isNotEmpty) {
      try {
        await _activeEngine.setVoice(voiceId);
      } catch (_) {
        // 平台拒绝该音色时忽略，仍保留用户选择
      }
    }
    await _persist();
    _notify();
  }

  Future<void> setRate(double value) async {
    _rate = _clampDouble(value, 0.5, 2.0);
    try {
      await _activeEngine.setRate(_rate);
    } catch (_) {
      // 忽略
    }
    await _persist();
    _notify();
  }

  Future<void> setPitch(double value) async {
    _pitch = _clampDouble(value, 0.5, 2.0);
    try {
      await _activeEngine.setPitch(_pitch);
    } catch (_) {
      // 忽略
    }
    await _persist();
    _notify();
  }

  Future<void> _persist() => StorageService.instance.saveTtsSettings(<String, dynamic>{
    'activeId': _activeId,
    'rate': _rate,
    'pitch': _pitch,
    'voiceId': _voiceId,
    'cloudBaseUrl': _cloudBaseUrl,
    'cloudApiKey': _cloudApiKey,
    'localEngine': _localEnginePackage,
  });

  // ---------------- 文档与游标 ----------------

  /// 绑定待朗读文档，游标默认从 (0,0,0) 开始；[title] 用于通知栏显示
  ///
  /// [documentId] 是文档库里的 id：底部迷你控制栏的「返回朗读页」要靠它找到
  /// 对应的 Document 再跳回阅读页。
  void loadDocument(
    StructuredDocument document, {
    (int, int, int)? at,
    String? title,
    String? documentId,
  }) {
    // ⚠️ §4.100 任务 E：**换书必须先终止上一本**（音乐播放器换歌语义）。
    // 这一步要在覆盖 `_doc` / 游标**之前**做 —— 它会先让页面把旧文档的位置
    // 写盘（那时 _doc 还是旧的），再打断旧推进循环。顺序反了就是
    // 「A 的播放推进 B 的游标」的数据损坏（任务 E 诊断根因③）。
    // 同 id 重进（`documentId` 与当前一致）不会被它打断（§4.60）。
    terminateForDocumentSwitch(nextDocumentId: documentId);
    _doc = document;
    _plainMode = false;
    // 换书/重新载入 = 新的一场朗读，清掉「刚结束」标记
    _endedByStop = false;
    // ★v1.21.63：**绑定文档时必须清掉"借声残留"**。
    //
    // 真机（2026-10-17 15:50，决定性证据）：
    // ```
    // 15:50:24  从 PDF 暂停后进入 EPUB（同一本，loadDocument 走「同 id」早返回
    //           → terminateForDocumentSwitch 整条 return，什么都没清）
    // 15:50:25  按耳机播放 →
    //           恢复[playFromCursor] speaking=true paused=true plainMode=false
    //                               **lines=1** docTitle=一八七一年巴黎公社史
    //           → 念出来的却是 **PDF 的那 1 条文字**
    // ```
    // PDF 是**借** `TtsManager` 发声的，它把文字塞进了 `_lines`
    // （`_borrowedQueue` 记账）。切回 EPUB 时 `_lines` 没清，
    // 于是「当前书是 EPUB，念的却是 PDF」—— 正是用户报的那条。
    //
    // 判据不用「是不是换了文档」：**只要重新绑定文档，借来的队列就不算数**。
    // 同一本书重进也清（重进之后本来就要从 `_doc` 的游标重新开口）。
    _lines = const <String>[];
    _lineIndex = 0;
    _borrowedQueue = false;
    _speakForOther = false;
    // ⚠️ **不要清 `_oneShot`**（v1.21.63 试过，会让"单句播放"语义丢掉）。
    // 它表达的是「用户这次只想放一段」，不是"借声记账"。
    // 只要 `_lines` 清空了，`resume()` 里 `_oneShot && _lines.isNotEmpty`
    // 自然为假，会正常回落到 `_restart(_doc 的游标)`。
    _documentId = documentId ?? _documentId;
    if (title != null && title.trim().isNotEmpty) _docTitle = title.trim();
    // 记一份「最近绑定的文档」：`endSessionAndClear()` 会把 `_doc` 清掉
    // （那是控制栏收起的依据），但用户紧接着还要能重新朗读 ——
    // 靠这份记录自动绑回去，见 [_rebindIfCleared]。
    _lastDoc = document;
    _lastDocTitle = _docTitle;
    _lastDocId = documentId ?? _lastDocId;
    final start = at ?? (0, 0, 0);
    // 位置记忆埋点 D（载入文档）：`at == null` 会把游标重置成 (0,0,0)，
    // 调用方必须在这之前把内存游标读走（见 reader_page._resolveStart 的说明）。
    CrashLog.mark('位置[载入文档] docId=${documentId ?? _documentId} '
        'at=$at 起点=$start 章数=${document.chapters.length}');
    // 绑定新文档 = 显式指定位置：旧意图作废，否则 cursor 会返回上一本的意图（§4.102）
    _pendingCursor = null;
    _ch = start.$1;
    _p = start.$2;
    _s = start.$3;
    _clampCursor();
    _error = null;
    _notify();
  }

  /// 最近一次绑定过的文档（**会话被清掉之后**用它自动绑回）
  StructuredDocument? _lastDoc;
  String _lastDocTitle = '';
  String? _lastDocId;

  /// 会话被 `endSessionAndClear()` 清掉后，把文档自动绑回去
  ///
  /// ## 为什么必须有这一步
  ///
  /// `endSessionAndClear()` 会清 `_doc`（控制栏「收起」就是看 `hasSession`），
  /// 而所有朗读入口（`_runBody`）第一句都是 `if (doc == null) return`。
  /// 于是「方块键结束朗读」之后再点目录 / 章标题 / 播放键都会**毫无反应**。
  ///
  /// 一开始是在阅读页各处手动补 `_ensureDocumentBound`，但入口太多
  /// （点句、点行、章标题、目录、播放键……），漏一个就出一次「点了没反应」。
  /// 所以改成**在这里统一兜住**：任何朗读入口先调它一次。
  ///
  /// 只动「被清空」这一种情况：文档还在时什么都不做，避免打断正常朗读。
  void _rebindIfCleared() {
    if (_doc != null) return;
    final document = _lastDoc;
    if (document == null || document.chapters.isEmpty) return;
    _doc = document;
    _documentId = _lastDocId;
    if (_lastDocTitle.isNotEmpty) _docTitle = _lastDocTitle;
  }

  /// 换文档之前，请**页面**把「旧文档的位置」写回文档库（§4.100 任务 E）
  ///
  /// 为什么由页面写而不是管理器写：位置不只有朗读游标，还有「用户视图停在哪」
  /// （`_lastSpot` / 自动排版后的坐标系映射），只有页面算得准 —— 而且
  /// `ReaderPage._persistProgress()` 已经在做这件事，这里只是给它一个**时机**。
  ///
  /// 调用时机：`loadDocument(别的文档)` / `PdfReadSession.open(别的文档)` 之前，
  /// 此刻 `_documentId` / `_doc` **还是旧文档**的，页面据此写的是旧文档的位置。
  /// 注册方式仿 `AutoSleepController.onStopTimeout`（页面 initState 注册、
  /// dispose 注销），避免管理器反向依赖页面类型。
  VoidCallback? onBeforeDocumentSwitch;

  /// **跨文档切换时终止上一本**（§4.100 任务 E 的触发点）
  ///
  /// 语义对齐「音乐播放器换歌」：上一首停止 + 记住进度 + 换新的。
  ///
  /// ### 为什么不用 [stop] / [endSessionAndClear]
  ///   · [stop] 是 `async`：`loadDocument` 要同步完成状态切换，中间插一个
  ///     await 会让「旧文档已终止」与「新文档已就绪」之间出现半态窗口；
  ///   · [endSessionAndClear] 会 `_clearContent()` 清 `_doc`，而它同时被
  ///     「注册引擎」「同一本书重进」等路径调用 —— 顺手清内容会把正在读的书
  ///     清掉（见它的注释）。而且本方法**必须保留 `_documentId`**：
  ///     文档库控制栏的「返回朗读页」还要靠它找到那本书。
  ///
  /// 所以这里用与 [stop] 同一套**同步**打断手段：`_generation++` 让旧推进
  /// 循环立刻失效（旧循环在每个 await 之后都会核对 token 再决定要不要进位，
  /// 见 `_runBody` / `_speakLoop`），`_cancelWaitsBelow` 松开挂在插件上的等待。
  ///
  /// ⚠️ **顺序是硬要求**：先 `onBeforeDocumentSwitch()` 写盘（此刻 `_doc`
  /// 仍是旧文档），再打断，最后才清 `_doc`。顺序反了会让旧文档的播放循环
  /// 拿**新文档**的 `_doc` 去 clamp 与进位 —— 那就是「A 的播放推进 B 的游标」
  /// 这个数据损坏（任务 E 诊断根因③）。
  ///
  /// 同 id 重进（`nextDocumentId` 与当前一致）**什么都不做**：§4.60「退出阅读页
  /// 不打断朗读」依赖这条，别在这里打断自己。
  void terminateForDocumentSwitch({String? nextDocumentId}) {
    // 「真的换了文档」= 新 id 存在，且与当前持有的 id 不同。
    //
    // ⚠️ 这里**不能**写成 `_documentId != null && _documentId != nextDocumentId`：
    // 当本管理器从没 `loadDocument` 过（`_documentId == null`）、而 PDF 那边
    // 正在读时，那个写法会整条短路 —— 于是「PDF 朗读中打开 TXT」这一反向
    // 永远不终止 PDF（设备实测踩到：`pdfPlaying=true` 一直为真）。
    final switching = nextDocumentId != null && _documentId != nextDocumentId;

    // ★v1.21.55 修的**真根因**（用户报：书A暂停 → 打开书B → 恢复却读书A）
    //
    // 真机日志（2026-10-17 11:54）给出的形态：
    // ```
    // 11:54:40  位置[进入阅读页] docId=…264 type=epub     ← 用户打开了 EPUB(B)
    // 11:54:55  媒体控制[play source=pdf-session title=苏联国内战争史…
    //            ttsDoc=…264 pdfDoc=…395 pdfPlayback=true identicalSourcePdf=true]
    // 11:54:55  位置[PDF起读] docId=…395 ref=20/8          ← 读的是旧 PDF(A)
    // ```
    // 即：**用户在看 EPUB(B)，通知栏/耳机的播放键却仍然派给旧 PDF(A)**。
    //
    // 为什么会这样：`loadDocument(B)` 进来时 `_documentId` **已经是 B**
    // （用户先前打开过 B），于是 `switching == false` → 本方法**整条 return**，
    // 「先终止另一条朗读路径」那一步一起被跳过 —— PDF 会话始终没被停、
    // 也始终占着 `TtsAudioHandler` 的当前来源。
    //
    // §4.60 那条守卫的本意是「同一本书重进不许打断**自己**」，
    // 它不该顺带放过**另一个会话**。所以这两件事必须分开判断：
    final bool otherWasSource =
        identical(audioHandler?.activeSource, PdfReadSession.instance);
    final bool otherHoldsAudio =
        otherWasSource || PdfReadSession.instance.isPlaybackActive;

    if (!switching) {
      // 同一本书重进：**不打断自己**（§4.60），但别的路径占着音频要收回来。
      // 只做「终止对方 + 抢回来源」，不碰本管理器的朗读状态。
      if (!otherHoldsAudio) return;
      _terminateOtherReadSession();
      audioHandler?.activate(this);
      _notify();
      return;
    }

    // 0) 另一条朗读路径（PDF）也要终止 —— 两套会话互相独立，必须双向处理
    _terminateOtherReadSession();
    // 0.5) v1.21.17：**换书这一刻就把通知栏归属抢回来**，不能等新会话真的开口。
    //
    // 为什么不能指望 `_restart` 里那次 `_claimAudioIfNotDelegated()`：
    //   · 旧会话若只是"暂停"，`_terminateOtherReadSession` 过去不会终止它；
    //   · 若 `_speakForOther` 还挂着（旧 PDF 的 speak 没收尾），那次 claim 会被
    //     `if (_speakForOther) return;` 直接跳过。
    // 两条都会让来源停在旧的 `pdf-session` 上（真机日志实证）。这里只在
    // **旧 PDF 确实占着通知栏**时才抢，避免多余的换源与状态闪烁。
    if (otherWasSource) audioHandler?.activate(this);
    // 1) 先让页面把**旧文档**的位置写回（此刻 _doc/_documentId 还是旧的）
    try {
      onBeforeDocumentSwitch?.call();
    } catch (_) {
      // 写盘失败不影响终止
    }
    // 2) 打断旧推进循环 + 松开插件等待（与 stop 同一套同步手段）
    _generation++;
    _cancelWaitsBelow(++_waitSeq);
    _speaking = false;
    _paused = false;
    _oneShot = false;
    _fallback = false;
    _speakForOther = false; // v1.21.25：换书也是终止路径，借声标记不能留着
    _pendingCursor = null; // 换书：意图不跨文档残留（§4.102）
    _fireControl(_activeEngine.stop());
    _endSession(); // 强制收尾：所有在等的都放行
    unawaited(MediaInterruptionController.instance.releaseFocus());
    // 3) 旧文档的位置已经落盘，现在才允许清掉它
    _doc = null;
    _plainMode = false;
    _borrowedQueue = false; // 换书：借声记账不跨文档残留（v1.21.40）
    _lines = const <String>[];
    _lineIndex = 0;
    _ch = 0;
    _p = 0;
    _s = 0;
    _pendingCursor = null; // 意图不跨文档残留（§4.102）
    _notify();
  }

  /// 换文档时**把另一条朗读路径也终止掉**（§4.100 任务 E：全局只有一个「当前播放」）
  ///
  /// 两套会话是彼此独立的对象（TXT 走本类，PDF 走 [PdfReadSession]），
  /// 「新会话建立时终止旧的」必须**两个方向都做**，否则就是单向的：
  ///   · PDF 侧已在 `PdfReadSession.open()` 里调 [terminateForDocumentSwitch]；
  ///   · TXT 侧（本类 [loadDocument]）也得把正在读的 PDF 停掉。
  ///
  /// ⚠️ 设备实测（§4.100 任务 E 复验）：「PDF 朗读中加载 TXT」这一反向
  /// 单靠 `TtsAudioHandler.activate()` 的跨源短路**不会**停掉 PDF ——
  /// TXT 走的是 `_claimAudioIfNotDelegated`，同源（tts-manager）直接 return；
  /// 而且 PDF 的推进循环本身不看通知栏归属。所以必须在这里显式停。
  ///
  /// 用 `stopSound()`（停声 + **保留位置**），不是 `clear()`：
  /// 换歌语义是「上一首停止 + 记住进度」，用户回到那本 PDF 还要能接着读。
  void _terminateOtherReadSession() {
    final session = PdfReadSession.instance;
    if (!session.isActive) return;
    // ⚠️ v1.21.17：**暂停态也要终止**（原来写的是 `if (!session.isPlaying) return;`）。
    //
    // 真机日志（v1.21.16）实证的后果：用户在 PDF 里按了暂停（playing=false、
    // paused=true），再打开一本 EPUB —— PDF 会话不会被终止，它**仍然是
    // `TtsAudioHandler` 的当前来源**：
    // ```
    // 21:29:06 媒体控制[play] source=pdf-session playing=false paused=true
    // 21:30:34 开始朗读：国家与革命.epub 起于 4/4/0
    // 21:30:39 媒体控制[play] source=pdf-session playing=false paused=false  ← 还是它
    // ```
    // 表现：通知栏卡片显示**已经停掉的那本 PDF**，耳机键与通知栏指令全发给错的会话。
    //
    // 判据用 `isPlaybackActive`（= 会话在 **且** 在播或暂停，§4.103 的口径）：
    // 「暂停但还占着通知栏」正是被漏掉的那个状态。
    if (!session.isPlaybackActive) return;
    unawaited(session.stopSound());
  }

  /// 当前文档标题（通知栏）
  @override
  String get documentTitle => _docTitle;

  /// 当前文档在文档库里的 id（纯文本队列朗读时为 null）
  String? get activeDocumentId => _documentId;

  /// 这个文档是否**正在被本管理器持有**（打开过、且没被别的文档顶掉）
  ///
  /// 与 [activeDocumentId] 的区别：那个只是「上次 loadDocument 传进来的 id」，
  /// 中途停止朗读、甚至同一个 id 被重新打开，它都不会变。
  /// 判断「内存里的游标还算不算数」必须用这个 —— 否则同一本书第二次带着
  /// 新位置打开时，会被上一轮遗留的游标覆盖（表现为「回不到退出时的位置」）。
  bool holdsDocument(String documentId) =>
      _doc != null && _documentId == documentId;


  /// 当前章标题（迷你控制栏的副标题）；没有文档时为空
  String get currentChapterTitle {
    final doc = _doc;
    if (doc == null || doc.chapters.isEmpty) return '';
    final index = _ch < 0
        ? 0
        : (_ch >= doc.chapters.length ? doc.chapters.length - 1 : _ch);
    return doc.chapters[index].title;
  }

  /// 是否有正在读（或暂停中）的内容：结构化文档或纯文本队列
  ///
  /// 迷你控制栏据此决定显不显示 —— 什么都没读的时候，那四个按钮没有意义。
  ///
  /// ## ⚠️ 「替别人发声」期间不算自己的会话（v1.21.4 修）
  ///
  /// PDF 会话是**借** `TtsManager` 发声的（§4.94 的 `speakForOther`）：
  /// `speakText` 会把 `_plainMode=true` + `_lines=[当前句]` 写进来。
  /// 于是 PDF 会话结束、`clear()` 清掉之后，这里仍然因为
  /// 「有 plain 队列」返回 true —— 控制栏碟片**走了又回来**，
  /// 显示成一个 `doc=null`、`activeDocumentId=null` 的"TTS 会话"，
  /// 用户按方块键怎么都关不掉（这就是「控制栏不消失」的真因）。
  ///
  /// 判据改成：被借走发声期间，这份队列是**别人的**，不算自己的会话。
  @override
  bool get hasSession {
    // 有 doc 就是有独立会话 —— 无论 PDF 有没有在借声。
    //
    // 真机（§4.100 任务 E 遗漏，v1.21.25）：PDF 借声把 `_plainMode` 置真，
    // 而 EPUB 自己的 `_doc` 仍在 —— 此时 hasSession 必须为 true，
    // 否则文档库控制栏不出现、通知栏卡片被收掉（用户报的两条症状）。
    if (_doc != null && _doc!.chapters.isNotEmpty) return true;
    // 借声期间，「plain 队列」是借来的，不算自己的。
    if (_speakForOther) return false;
    return _plainMode && _lines.isNotEmpty;
  }

  /// 仅供测试：清掉当前会话（文档、标题、纯文本队列）
  ///
  /// TtsManager 是单例，上一个用例加载过的文档会留到下一个用例里
  /// （表现为「纯文本队列」用例里还能读到上一个文档的章标题）。
  @visibleForTesting
  void resetSessionForTest() {
    _doc = null;
    _docTitle = '';
    _documentId = null;
    _lines = const <String>[];
    _plainMode = false;
    _borrowedQueue = false; // 单例跨用例不能留借声记账（v1.21.40）
    _lineIndex = 0;
    _ch = 0;
    _p = 0;
    _s = 0;
    _pendingCursor = null; // 单例跨用例不能留意图（§4.102）
    _speaking = false;
    _paused = false;
    _error = null;
    _speakTimeouts = 0; // 单例跨用例不能留「引擎不回应」的记账
  }

  /// 当前朗读位置描述（通知栏副标题）
  @override
  String get positionLabel {
    final doc = _doc;
    if (doc == null) return '';
    if (doc.chapterIsPage) return '第 ${_ch + 1}/${doc.chapters.length} 页';
    final perPage = _perPage();
    return '第 ${_ch + 1} 章 · 第 ${doc.pageOf(_ch, _p, perPage)}/${doc.pageCountOf(_ch, perPage)} 页';
  }

  /// 朗读进度 0~1（通知栏进度条）
  double get progress {
    final total = progressTotal;
    if (total <= 0) return 0;
    final value = progressIndex / total;
    return value < 0 ? 0 : (value > 1 ? 1 : value);
  }

  /// 进度单元总数（结构化文档按句计，纯文本队列按条计）
  @override
  int get progressTotal =>
      _plainMode ? _lines.length : (_doc?.sentenceCount ?? 0);

  // ---------------- AudioSessionSource 实现（通知栏接口化，v1.21.1）----------------
  //
  // 这一层只是把原有成员「对上接口」，**行为一个字节都不改** ——
  // 通知栏的进度条 / 上下一章 / seek 拖动有设备用例守着（HANDOFF §4.6）。

  @override
  String get sourceId => 'tts-manager';

  @override
  void onStop() {
    // 被别的来源顶替：停掉自己的声音，别再往通知栏推
    unawaited(stop());
  }

  /// TXT / EPUB 会话**保持可以拖进度条**（原有行为，别改成 false）
  @override
  bool get canSeek => true;

  /// 当前进度单元下标
  @override
  int get progressIndex =>
      _plainMode ? _lineIndex : (_doc?.indexOfCursor((_ch, _p, _s)) ?? 0);

  /// 仅供测试：模拟「PDF 借声留下残留队列」（真机 `lines=1` 那个形态）
  ///
  /// 真机日志（2026-10-17 15:50）里 `恢复[playFromCursor] … lines=1` 就是这个状态：
  /// PDF 借 `TtsManager` 发声时把文字塞进了 `_lines`，切回 EPUB 后没清。
  @visibleForTesting
  void debugInjectBorrowedResidue(String text) {
    _lines = <String>[text];
    _lineIndex = 0;
    _borrowedQueue = true;
    // 真机上这条残留会被 `resume()` 里的 `_oneShot` 分支直接念出来
    // 注入时保留 _oneShot 原值
  }

  /// 通知栏 / 外部触发的播放：暂停中接着读，否则从当前游标开始
  @override
  void playFromCursor() {
    // ★v1.21.62 诊断（用户反馈「进入另一本书后按耳机，恢复的是上一本书」）：
    // 这里三个分支对"读哪本书"有完全不同的含义，必须留下证据才能定位 ——
    //   · 分支 1 `resume()` 内部会 `_rebindIfCleared()`，把 `_lastDoc` **绑回来**；
    //     若 `_lastDoc` 还是上一本，就是"恢复上本书"。
    //   · 分支 3 直接用 `_doc`，这是正常的当前书。
    CrashLog.mark('恢复[playFromCursor] '
        'speaking=$_speaking paused=$_paused '
        'plainMode=$_plainMode lines=${_lines.length} '
        'hasDoc=${_doc != null} docIsLast=${identical(_doc, _lastDoc)} '
        'docTitle=$_docTitle lastTitle=$_lastDocTitle '
        'cursor=($_ch,$_p,$_s)');
    if (_speaking && _paused) {
      resume();
      return;
    }
    // 用户又开始读了：清掉「刚结束朗读」标记，迷你条重新出现
    _endedByStop = false;
    if (_plainMode && _lines.isNotEmpty) {
      speakLines(_lines, start: _lineIndex);
      return;
    }
    if (_doc != null) {
      speakFrom(_ch, _p, _s);
    }
  }

  /// 跳到指定进度（通知栏拖动进度条）
  @override
  void seekToProgress(double fraction) {
    if (_plainMode && _lines.isNotEmpty) {
      final total = _lines.length;
      // v1.21.20：与 `StructuredDocument.cursorAt` 同一个浮点坑 ——
      // 通知栏显示的位置就是 `index/total`，用户拖回同一处时会乘回
      // `index - 1e-14`，`floor()` 一取就退一行。加 epsilon 抵消。
      var index = (fraction * total + 1e-9).floor();
      if (index < 0) index = 0;
      if (index > total - 1) index = total - 1;
      speakLines(_lines, start: index);
      return;
    }
    final doc = _doc;
    if (doc == null || doc.chapters.isEmpty) return;
    final cursor = doc.cursorAt(fraction);
    speakFrom(cursor.$1, cursor.$2, cursor.$3);
  }

  /// 上一章 / 下一章（通知栏按钮）
  @override
  void skipChapter(int delta) {
    final doc = _doc;
    if (doc == null || doc.chapters.isEmpty) return;
    var target = _ch + delta;
    if (target < 0) target = 0;
    if (target > doc.chapters.length - 1) target = doc.chapters.length - 1;
    speakFrom(target, 0, 0);
  }

  /// 快进 / 快退一页（底部控制栏按钮）
  ///
  /// - PDF / 一章即一页：直接跳到上/下一个有内容的章（页）；
  /// - TXT / EPUB：「页」= 目录里设定的每页段数，步长按**页边界**计算：
  ///   当前段先归位到所在页的起始（末页可能停在半页位置），再整页进退；
  /// - 已到首尾时不越界，但也不停住不动（末页再快进落到末段）。
  ///
  /// 走 speakFrom 而不是直接改游标：它会打断旧的朗读循环并从新位置继续，
  /// 因此朗读中按快进也能干净地接上，不会出现两段声音叠加。
  void skipPage(int delta) {
    final doc = _doc;
    if (doc == null || doc.chapters.isEmpty || delta == 0) return;
    _clampCursor();
    if (doc.chapterIsPage) {
      var target = _ch + delta;
      if (target < 0) target = 0;
      if (target > doc.chapters.length - 1) target = doc.chapters.length - 1;
      speakFrom(target, 0, 0);
      return;
    }
    final perPage = _perPage();
    final step = perPage < 1 ? 1 : perPage;

    if (delta < 0) {
      // 当前页起始：末页可能停在半页，必须先归位再退整页
      final pageStart = (_p ~/ step) * step;
      var target = pageStart - step;
      var chapter = _ch;
      while (target < 0 && chapter > 0) {
        chapter--;
        final previous = doc.chapters[chapter].paragraphs;
        if (previous.isEmpty) {
          target = 0;
          continue;
        }
        target = ((previous.length - 1) ~/ step) * step; // 上一章的最后一页起点
      }
      if (target < 0) target = 0;
      speakFrom(chapter, target, 0);
      return;
    }

    final target = ((_p ~/ step) + 1) * step; // 下一页起点
    final paragraphs = doc.chapters[_ch].paragraphs;
    if (target < paragraphs.length) {
      speakFrom(_ch, target, 0);
      return;
    }
    // 本章读完：进下一章
    if (_ch + 1 < doc.chapters.length) {
      speakFrom(_ch + 1, 0, 0);
      return;
    }
    // 已经是最后一章最后一页：退到本章最后一段（不越界），
    // 但绝不停在原地不动——否则按钮看起来像坏了
    final last = paragraphs.isEmpty ? 0 : paragraphs.length - 1;
    speakFrom(_ch, last > _p ? last : _p, 0);
  }

  /// 快进一页
  @override
  void skipPageForward() => skipPage(1);

  /// 快退一页
  @override
  void skipPageBackward() => skipPage(-1);

  /// 上一句 / 下一句（底部控制栏按钮）
  ///
  /// 按**全篇句序号**进退：跨段、跨章都只走一句，首尾夹取不越界。
  /// 走 speakFrom 而不是直接改游标，朗读中按它能打断旧循环并从新位置接着读。
  void skipSentence(int delta) {
    if (delta == 0) return;
    if (_plainMode) {
      // 纯文本队列（网页 / 即读页）：按条目进退
      if (_lines.isEmpty) return;
      final target = (_lineIndex + delta).clamp(0, _lines.length - 1);
      speakLines(_lines, start: target);
      return;
    }
    final doc = _doc;
    if (doc == null || doc.chapters.isEmpty || doc.sentenceCount == 0) {
      return;
    }
    _clampCursor();
    // ⚠️ 必须用 _effectiveCursor（含意图游标）：短时间连点「下一句」时，
    // 真实游标可能还没落地，直接读 (_ch,_p,_s) 会让每次都算成同一句（§4.102）。
    //
    // v1.21.21：基准从「游标」改成「**出声位置**」——
    // 主循环是「读完一句才进位」，所以上一句读完的瞬间游标已经指向下一句，
    // 而那句的音频还没出来（引擎起播有延迟）。用户此刻按「下一句」，
    // 心里"当前"还是刚听完的那句，期望听到的是**没听到的那句**；
    // 用游标当基准就会再 +1，把它跳过（真机反馈："跳过该去的那句"）。
    final base = _pendingCursor ?? _audibleCursor ?? _effectiveCursor;
    final index = doc.indexOfCursor(base) + delta;
    final cursor = doc.cursorAtIndex(index);
    speakFrom(cursor.$1, cursor.$2, cursor.$3);
  }

  /// 正在出声的那一句（已交给引擎、还没读完）
  (int, int, int)? _speakingRef;

  /// 它是什么时候交给引擎的（区分「已经响了」和「刚交出去还没出声」）
  DateTime? _speakingIssuedAt;

  /// 最后一句**确实读完**的
  (int, int, int)? _lastSpokenRef;

  /// 引擎起播的宽限期：超过它就算"这一句已经出声了"
  ///
  /// 与 [_minRealSpeakMs]（100ms，判"提交即返回"的假完成）同源但更大：
  /// 这里要判的是「用户耳朵里有没有听到」，系统引擎起播通常 100~500ms。
  static const int _audibleGraceMs = 300;

  /// **出声位置** = 用户实际听到哪一句（[skipSentence] 的基准）
  ///
  /// - 正在读的那句已经响了（发出超过 [_audibleGraceMs]）→ 它就是"当前句"；
  /// - 刚交出去还没出声 → 以**上一句读完的**为基准（那句还没进耳朵）；
  /// - 谁都没有（会话刚开始）→ 返回 null，调用方退回游标。
  (int, int, int)? get _audibleCursor {
    final ref = _speakingRef;
    if (ref == null) return _lastSpokenRef;
    final issuedAt = _speakingIssuedAt;
    final bool hasRung = issuedAt != null &&
        DateTime.now().difference(issuedAt).inMilliseconds >= _audibleGraceMs;
    return hasRung ? ref : (_lastSpokenRef ?? ref);
  }

  /// 下一句
  @override
  void skipSentenceForward() => skipSentence(1);

  /// 上一句
  @override
  void skipSentenceBackward() => skipSentence(-1);

  /// 目录分页的每页段数
  int _perPage() => StorageService.instance.paragraphsPerPage;

  /// 切换朗读粒度；朗读中则从当前单元按新粒度继续
  Future<void> setGranularity(ReadGranularity value) async {
    if (value == _granularity) return;
    _granularity = value;
    if (_speaking && !_oneShot) {
      _restart((_ch, _p, _s));
    } else {
      _notify();
    }
  }

  // ---------------- 朗读控制 ----------------

  /// 是否正在「替别人发声」：为真时朗读入口**不抢通知栏**
  ///
  /// ## 为什么需要它（v1.21.1 实测踩到）
  ///
  /// PDF 会话没有自己的合成引擎 —— 它复用 [TtsManager.speakText] 说话。
  /// 而 `speakText` 是「本管理器发起的朗读」，会调
  /// `audioHandler.activate(this)` 把通知栏改成 TXT 那一套。于是**每读一句
  /// PDF，通知栏就被抢回去一次**：实测通知栏显示的是上一本 TXT 的书名与页码。
  ///
  /// 真实调用栈：
  /// ```
  /// PdfReadSession._readLoop → TtsManager.speakText → speakLines
  ///   → TtsAudioHandler.activate(tts-manager)   ← 通知栏被抢走
  /// ```
  bool _speakForOther = false;

  /// 当前这份纯文本队列是不是**「借来发声」时建立的**（v1.21.40）
  ///
  /// 为什么需要单独记：`speakForOther` 的 `finally` 里那道清理（见下）带
  /// `!_speaking` 判据 —— 而 PDF 每读完一句、`body()` 返回时**声音还在响**
  /// （`_speaking` 仍为 true），所以那份清理**几乎从来不执行**。
  /// 原来的注释写「等那一次借完自己清」，但**代码里没有任何地方**安排这次清理。
  ///
  /// 后果（真机日志满屏）：`借声[退出] speaking=true hasSession=true doc=null`
  /// 长期存在 —— 文档库控制栏留着一个假会话，点播放什么都不读。
  ///
  /// 所以改成：**谁建的谁认领**，并挂到 [_endSession] 这个唯一共同收尾点上清
  /// （`_runLines` / `_run` 的 `finally` 都会走到它，覆盖"读完 / 被 stop / 失败"）。
  bool _borrowedQueue = false;

  /// 在「借 [TtsManager] 发声但不抢通知栏」的期间执行 [body]
  ///
  /// 只给 `PdfReadSession` 用：它自己会 `activate`，不需要被代言。
  ///
  /// ## ⚠️ 收尾要把借来的「纯文本队列」清掉（v1.21.4 修）
  ///
  /// PDF 是**借** `speakText` 发声的，每读一句都会把
  /// `_plainMode = true` + `_lines = [这一句]` 写进本管理器。
  /// 这些 leftovers 留在身上会有一个很显眼的后遗症：
  /// **PDF 会话结束、`clear()` 清掉之后，[hasSession] 仍然是 true**
  /// （它判的是「有 doc 或 有 plain 队列」）→ 文档库的碟片**走了又回来**，
  /// 显示成一个 `doc=null` 的假 TTS 会话，用户按方块键怎么都关不掉。
  ///
  /// 实测就是这样：`方块键 → PDF session.clear()` 之后
  /// `pdfActive=false` 但 `ttsActive=true(doc=null)`，碟片还在。
  ///
  /// 所以「借完」要把借来的痕迹擦干净 —— 只在两者**都是**自己设的才清，
  /// 避免误伤用户真正的「打字朗读 / 复制即朗读」队列。
  Future<T> speakForOther<T>(Future<T> Function() body) async {
    final previous = _speakForOther;
    final hadSessionBefore = hasSession;
    _speakForOther = true;
    // 借声埋点（v1.21.25）：下次真机定位"谁在借、借的时候有没有自己的会话"
    CrashLog.mark('借声[进入] previous=$previous speaking=$_speaking '
        'doc=$_documentId hasSession=$hadSessionBefore');
    try {
      return await body();
    } finally {
      _speakForOther = previous;
      if (!previous) {
        // 借之前本来就没有会话 → 现在这份队列一定是借来发声时产生的 → 清掉
        //
        // ⚠️ 只在**确实没人在借**时才动引擎。
        //
        // 这里的坑（v1.21.4 实测踩到）：两个会话会短暂并存 ——
        // 用户点新句子时，旧链刚读完一句、新链已经开始 `speakText`。
        // 那时若调 `stop()` / `engine.stop()`，它会去抢 `TtsManager._awt`
        // 的 `run-stop` 锁，而新链的 `_runLinesBody` 正持有那把锁，
        // 于是新链那次朗读**被静默取消**：日志上「读完」，但引擎从没收到。
        // 表现就是「点了新句子，那一句永远读不出来」。
        //
        // 判据用 `_speaking`：它由 `speakLines` **同步**置真，
        // 所以「还有人在借」时一定为真，跳过清理；等那一次借完自己清。
        //
        // ⚠️ v1.21.40：这里**不再是唯一的清理点**（`!_speaking` 时几乎从不成立），
        // 真正的兜底在 [_endSession] → [_clearBorrowedQueueIfMine]。
        if (!hadSessionBefore && !_speaking) {
          _plainMode = false;
          _lines = const <String>[];
          _lineIndex = 0;
          _borrowedQueue = false;
        }
        // ⚠️ v1.21.25：**无条件通知**。
        // 从「借声」回到「自己」时 `hasSession` 会翻转（false → true），
        // 而修前只在 `!_speaking` 分支里 notify —— 文本正在播时正好不通知，
        // 于是控制栏/通知栏一直停在旧状态（用户报的症状）。
        notifyListeners();
        CrashLog.mark('借声[退出] previous=$previous speaking=$_speaking '
            'hasSession=$hasSession doc=$_documentId');
      }
    }
  }

  /// 是否正被别的会话借去发声（PDF 借 TtsManager）
  ///
  /// 通知栏用它判断「这次 notify 能不能推状态」：借声期间 `hasSession` 是
  /// 别人的语义，推 idle 会把还在播的卡片收掉（v1.21.25）。
  bool get isBorrowedForOther => _speakForOther;

  /// 一次朗读会话的收尾信号，**按朗读代次分开存**。
  ///
  /// 每发起一次朗读都会换一个新的 Completer，并在该轮循环结束（读完 / 失败 /
  /// 被新的朗读打断）时完成。测试用它来确定地等待「整篇读完」，
  /// 而不是靠轮询 [speaking]（轮询会漏掉刚开始就结束的会话）。
  ///
  /// ## 为什么按代次存（v1.21.1 修的竞态）
  ///
  /// 原来只有一个 `_sessionDone` 字段 + 一个 `_sessionOwner` 归属检查。
  /// 归属检查**挡不住**这种时序：旧循环被顶掉后是「稍后才退出」的，
  /// 它退出时 `_beginSession` 可能**已经**把 `_sessionOwner` 改成新代次了 ——
  /// 于是这次「过期的收尾」会把**新会话**的 Completer 完成掉。
  ///
  /// 实测（PDF 自动连读）：循环按「先订阅、再 speak」严格串行推进时必然踩中：
  ///
  /// ```
  /// speak "第一页甲。"      ← 第 1 句发出
  /// done  "第一页甲。" 4ms  ← 立刻「读完」了，可引擎根本还没出声
  /// ```
  ///
  /// 表现就是**只读最后一句**（前面每一句都在出声之前被顶掉）。
  /// 改成按代次存之后，「过期的收尾」只会完成它自己那一代的 Completer，
  /// 碰不到新会话。
  final Map<int, Completer<void>> _sessionCompleters = <int, Completer<void>>{};

  /// 还没有任何会话时的收尾信号（已完成）
  final Completer<void> _noSession = Completer<void>()..complete();

  void _beginSession(int token) {
    // 上一代的 Completer 若还在（它已经被顶掉了），替它收尾 ——
    // 等它的那一方（例如「整篇读完」的测试）不该永远挂住
    for (final key in _sessionCompleters.keys.toList()) {
      final old = _sessionCompleters.remove(key);
      if (old != null && !old.isCompleted) old.complete();
    }
    _sessionCompleters[token] = Completer<void>();
    AutoSleepController.instance.beginSession();
  }

  /// 收尾。带 [token] 时**只收尾该代次**；不带 token 表示强制收尾（stop）。
  void _endSession([int? token]) {
    if (token != null) {
      final mine = _sessionCompleters.remove(token);
      if (mine != null && !mine.isCompleted) mine.complete();
      AutoSleepController.instance.endSession();
      // 借声残留的队列在这里清（见 [_clearBorrowedQueueIfMine] 的说明）
      // （已实测：注释掉这一行，两条用例会红在 `hasSession` 仍为 true）
      _clearBorrowedQueueIfMine(token);
      return;
    }
    // 强制收尾（stop / 换书）：所有在等的都放行
    for (final key in _sessionCompleters.keys.toList()) {
      final completer = _sessionCompleters.remove(key);
      if (completer != null && !completer.isCompleted) completer.complete();
    }
    AutoSleepController.instance.endSession();
    _clearBorrowedQueueIfMine(null);
  }

  /// 清掉**借声**残留的纯文本队列（v1.21.40）
  ///
  /// ## 为什么必须挂在 [_endSession] 上
  ///
  /// `speakForOther` 的 `finally` 里那道清理带 `!_speaking` 判据，而 PDF 借声
  /// **每读完一句 `body()` 就返回、那会儿声音还在响** → 判据不成立 → 从不清。
  /// 于是 `_plainMode=true` + `_lines=[那一句]` 就长期留在管理器上，
  /// `hasSession` 一直是 true —— 文档库控制栏显示一个 `doc=null` 的假会话，
  /// 点播放什么都不读（真机日志满屏 `借声[退出] … doc=null`）。
  ///
  /// `_endSession` 是**唯一共同收尾点**：`_runLines` / `_run` 的 `finally` 都调它，
  /// 覆盖「正常读完 / 被 stop / 失败 / 换书」全部路径；而 `_runLinesBody` 的收尾
  /// 只覆盖"正常读完队列"。
  ///
  /// ## 只在「确实是自己建的」时才清
  ///
  /// `_borrowedQueue` 只在 `claimAudio == false`（借声入口）时置真 ——
  /// 这样不会误伤用户真正的「打字朗读 / 复制即朗读」队列。
  /// [token] 非空时还要校验代次：过期的那一次收尾不许清掉新会话的队列。
  void _clearBorrowedQueueIfMine(int? token) {
    if (!_borrowedQueue) return;
    if (token != null && token != _generation) return;
    _borrowedQueue = false;
    _plainMode = false;
    _lines = const <String>[];
    _lineIndex = 0;
    // 队列没了 → 会话也跟着没了，通知栏/控制栏要重算一遍
    notifyListeners();
  }

  /// 等待**当前这一次**朗读会话结束（读完 / 失败 / 被新会话打断都算结束）
  ///
  /// 取用时若已经开了新会话，拿到的是新会话的信号 ——
  /// 所以用法必须是「先调用它、紧接着发起朗读」，顺序反了会等到上一轮的信号。
  Future<void> whenSessionFinished() {
    if (_sessionCompleters.isEmpty) {
      return _noSession.future;
    }
    // 取最近开的那一代（正常情况下只有一个）
    final key = _sessionCompleters.keys.reduce((a, b) => a > b ? a : b);
    return _sessionCompleters[key]!.future;
  }

  /// 从指定坐标开始朗读（章、段、句）
  void speakFrom(int chapter, int paragraph, int sentence) {
    // 又要开始读了：清掉「刚被用户结束」标记（迷你条据此决定显示与否）
    _endedByStop = false;
    // 跳动检测：这是一次用户显式「点句」，随之而来的推进不算异常跳跃
    SpeechDiagnostics.instance.markUserAction('点句');
    // ⚠️ **同步**记下意图（§4.102）：`_restart` 只是发起，真实游标要等
    // `_runBody` 里 await 停引擎之后才写。中间这个窗口里若有人读 `cursor`
    // （点句 / 快进都是「读游标 → 算相邻句」），必须读到**本次意图**而不是旧值。
    _pendingCursor = (chapter, paragraph, sentence);
    _restart((chapter, paragraph, sentence));
  }

  /// 从头开始
  void restartFromStart() {
    // 跳动检测：用户显式跳转（快进/回到开头）
    SpeechDiagnostics.instance.markUserAction('快进');
    _restart((0, 0, 0));
  }

  /// 暂停：通过打断令牌终止旧循环，游标停在当前单元
  @override
  Future<void> pause() async {
    if (_paused) return;
    // ⚠️ 判据**不能**用 `_speaking`（v1.21.27 修，真机实测）。
    //
    // `_speaking` 是 `_runLinesBody` 里**异步**置真的（它前面还有
    // `await _awt(..., lock: 'run-stop')` 排队）。在「上一句刚收尾、下一句已排队
    // 但还没开口」这个窗口里，`_speaking` 仍是 false —— 用 `!_speaking` 做短路
    // 会让这一次 pause **整个失效**：
    //   · `_generation` 不递增 → 排队的 `_runLinesBody` 不会被作废；
    //   · `_paused` 不置真 → `_speakLoop` 里的 `if (... || _paused) return;` 不生效；
    // 紧接着 `_runLinesBody` 走到 `_speaking = true` 并开始 speak → 用户看到的
    // 就是「按了暂停但本句照读、要等本句读完才停」。
    //
    // 正确判据：「有没有未收尾的会话」——`_beginSession` 在 `speakLines` 里
    // **同步**调用，所以 `_sessionCompleters` 一旦非空就说明"有东西要读（或正在读）"。
    if (_sessionCompleters.isEmpty) return;
    AutoSleepController.instance.notifyUserActivity();
    _generation++;
    // 跳动检测（埋点 4）：记录这次打断，以及打断时正飞着的是哪一代
    SpeechDiagnostics.instance.recordInterrupt(
      epoch: _generation,
      paused: true,
      speaking: _speaking,
    );
    _cancelWaitsBelow(++_waitSeq); // 旧循环别再挂在插件上了
    _wakeLockWaiters(); // 排队等插件的旧循环立刻退出排队
    _paused = true;
    _notify();
    _fireControl(_activeEngine.pause());
    // ⚠️ v1.21.15：暂停**不再释放音频焦点**。
    //
    // 原来这里 `releaseFocus()`（= `setActive(false)`）。实测（ColorOS / Android 13+）：
    // 交出焦点后系统可能不再把**耳机/通知栏的媒体键**路由给本应用 ——
    // 表现就是「暂停之后再按播放键毫无反应」（skip 也一样没反应）。
    // 焦点改由 [stop] / 会话结束释放（那边保留 releaseFocus）。
    // 代价：暂停期间仍占着焦点，别的应用会继续被压低。
  }

  /// 继续：从当前单元（或纯文本队列的当前条）重新朗读
  void resume() {
    if (!_speaking || !_paused) return;
    AutoSleepController.instance.notifyUserActivity();
    _paused = false;
    // 会话被清掉过就先绑回来（同 [_restart] 的理由）
    _rebindIfCleared();
    if (_oneShot && _lines.isNotEmpty) {
      speakLines(_lines, start: _lineIndex);
      return;
    }
    _restart((_ch, _p, _s));
    // ⚠️ v1.21.43（真机手测 ②，与 PdfReadSession.resume 对称）：**恢复后补推一次**。
    //
    // `_restart` 里的 `activate()` 按 `sourceId` 判等 —— 没换书时它**直接 return、
    // 不推状态**。若 `notifyListeners → _sync()` 那条路也被闸门挡下
    // （`_sync` 开头有 `isBorrowedForOther` 与"当前来源不是 TtsManager"两道 return），
    // 通知栏就收不到 playing=true，图标停在"暂停"样式。
    // 无条件补推一次是幂等的，最坏只多发一次 playbackState。
    _notify();
  }

  /// 只移动「读到哪」的位置，**不发声、不改朗读状态**
  ///
  /// 用途：目录跳转时用户要求「跳过去并暂停」，但我们仍要把游标放到目标位置 ——
  /// 否则点播放键会从上一次读的那一句接着读，而不是从跳过去的位置读。
  ///
  /// 与 [speakFrom] 的区别：那个会起一轮新的朗读；这个纯粹挪位置。
  /// 暂停中调用它，之后 [resume] 就从新位置接着读。
  void moveCursorTo(int chapter, int paragraph, int sentence) {
    // 跳动检测：目录/书签跳转属于用户显式操作
    SpeechDiagnostics.instance.markUserAction('目录');
    _rebindIfCleared();
    final doc = _doc;
    if (doc == null || doc.chapters.isEmpty) return;
    // 正在出声（未暂停）时不动游标：挪了会让正在跑的那一轮循环与它不一致。
    // 暂停状态是允许的 —— `pause()` 已经作废了当前令牌，循环不会再改游标。
    if (_speaking && !_paused) return;
    _ch = chapter;
    _p = paragraph;
    _s = sentence;
    _clampCursor();
    _notify();
  }

  /// 停止朗读（游标保持在当前位置）
  ///
  /// ⚠️ **不要在这里置 `_endedByStop`**：`stop()` 会被「换书 / 注册引擎 / 起读」
  /// 等内部路径调用，置标记会让文档库迷你条在正常朗读时也不显示
  /// （用户报的「第一次打开文档开始朗读、退回文档库迷你条不显示，第二次才显示」）。
  /// 只有用户**明确按下方块键**时才走 [stopByUser]。
  Future<void> stop() async {
    AutoSleepController.instance.notifyUserActivity();
    _generation++;
    // 跳动检测（埋点 4）：记录这次打断，以及打断时正飞着的是哪一代
    SpeechDiagnostics.instance.recordInterrupt(
      epoch: _generation,
      paused: false,
      speaking: _speaking,
    );
    _cancelWaitsBelow(++_waitSeq); // 立刻松开旧循环，别等插件
    _wakeLockWaiters();
    _speaking = false;
    _paused = false;
    _oneShot = false;
    _fallback = false;
    // v1.21.25：终止路径必须复位借声标记，否则会泄漏到下一次朗读
    // （表现：之后起读文本时 hasSession 一直是 false）
    _speakForOther = false;
    // v1.21.21：停声 = 会话结束，出声位置一并作废
    _speakingRef = null;
    _speakingIssuedAt = null;
    _lastSpokenRef = null;
    _notify();
    _endSession(); // 停止是强制收尾：不管当前会话属于谁
    _fireControl(_activeEngine.stop());
    // 停止 / 结束朗读就交还音频焦点
    unawaited(MediaInterruptionController.instance.releaseFocus());
  }

  /// **用户主动结束朗读**（阅读页/文档库的方块键走这里）
  ///
  /// 与 [stop] 的唯一区别：多置一个 [endedByStop] 标记，让文档库那条迷你条
  /// 整条消失 —— `_endSession()` 故意保留 `_doc`（记进度用），`hasSession`
  /// 停完仍为真，只看它的话迷你条会一直挂着。
  ///
  /// 标记在「又点播放 / 点句 / 重新载入文档」时清掉。
  Future<void> stopByUser() async {
    _endedByStop = true;
    await stop();
    _endedByStop = true; // stop() 内部会 _notify，这里再补一次让界面收到新状态
    _notify();
  }

  /// 结束整场朗读**并放掉当前内容**：控制栏随之整个收起
  ///
  /// 需求：「文档库导航栏的方块键 = 终止朗读**并关闭导航栏**，
  /// 效果就是刚打开软件时的样子」。控制栏的显隐看 `hasSession`（取决于 `_doc`），
  /// 只调 [stop] 是不会收起来的。
  ///
  /// ⚠️ 这件事**不能塞进 [stop] 里**：`registerEngine(makeActive: true)`、
  /// 「加载另一本书」等路径内部都会调 `stop()`，顺手清内容会把正在读的书清掉
  /// （表现为「注册引擎之后就读不了了」）。所以单独给一个入口，只让方块键用。
  Future<void> endSessionAndClear() async {
    await stop();
    _clearContent();
    _notify();
  }

  /// 放掉当前内容（结构化文档 / 纯文本队列）：停止朗读后回到「什么都没读」的状态
  ///
  /// 注意**不能**清 `_documentId`：文档库控制栏的「返回朗读页」要靠它找到是哪本书，
  /// 用户点「停止」之后仍然可能想按那个按钮回到刚才那本书接着看。
  void _clearContent() {
    _doc = null;
    _plainMode = false;
    _borrowedQueue = false; // 内容都放掉了，借声记账一并作废（v1.21.40）
    _lines = <String>[];
    _lineIndex = 0;
    _ch = 0;
    _p = 0;
    _s = 0;
    _pendingCursor = null; // 内容都放掉了，意图也不再算数（§4.102）
    _error = null;
  }

  /// 下发「暂停 / 停止」这类控制指令，不等插件回复。
  ///
  /// 这类指令幂等，重复下发无害（系统 TTS 的 stop 会把当前话语直接掐掉），
  /// 所以没必要等回复：一旦插件不响应，等待只会让按钮、返回键和退出阅读页一起卡住。
  /// 这里也不挂超时定时器——停止路径上留一个 5 秒定时器，在退出页面时还会拖住收尾。
  void _fireControl(Future<void> operation) {
    operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
  }

  /// 一次性朗读纯文本：不涉及结构化文档与游标（等价于单条队列）
  ///
  /// 这是**借声入口**（PDF 借 TtsManager 读一句）：借声期间不抢通知栏
  /// —— 那条通知栏此刻归 PDF 会话（v1.21.25）。
  void speakText(String text) {
    if (text.trim().isEmpty) return;
    _speakLinesInternal(<String>[text], claimAudio: !_speakForOther);
  }

  /// 纯文本队列朗读：逐条朗读，供网页朗读等无结构化文档的场景使用
  ///
  /// ⚠️ 这是**用户入口**（网页朗读 / 即读页 / 复制即朗读）：无条件抢回通知栏。
  /// v1.21.25 之前它和借声共用一条路，借声期间会把用户入口也短路掉。
  void speakLines(List<String> lines, {int start = 0}) =>
      _speakLinesInternal(lines, start: start, claimAudio: true);

  void _speakLinesInternal(
    List<String> lines, {
    int start = 0,
    required bool claimAudio,
  }) {
    // 开始新一轮朗读：清掉「刚被用户结束」标记
    _endedByStop = false;
    AutoSleepController.instance.notifyUserActivity();
    final items = <String>[];
    for (final line in lines) {
      if (line.trim().isNotEmpty) items.add(line);
    }
    if (items.isEmpty) return;
    // 通知栏切回本来源：用户入口无条件抢；借声入口不抢（那时通知栏归 PDF）
    if (claimAudio) audioHandler?.activate(this);
    // ⚠️ v1.21.43 **已回退**：不要在这里补 `requestFocus()`。
    //
    // 曾经加过一行（想让 PDF 借声也申请音频焦点，治「只有 PDF 朗读时媒体
    // 无法打断」），结果真机反馈**耳机控制整体失效**（暂停/恢复都没反应）——
    // 而且这个方法是**每句都调**的（PDF 逐句朗读走 `speakText`），
    // 于是 `AudioSession.setActive(true)` 被高频重复调用，
    // 把媒体会话/媒体键路由搞坏了。
    //
    // 证据（快照对比）：`requestFocus` 调用数 1→2 正好发生在引入它的那个快照，
    // 而引入前的 TEST2 耳机正常、引入后的 TEST3 失效。
    //
    // 音频焦点只在 `_restart()` 里申请（那是 EPUB/TXT 的入口）；
    // PDF 借声那条路的打断问题**另有根因**，不要用这种方式补。
    // ⚠️ v1.21.40：**同步**记下这份队列的来源（借来的还是用户自己的）。
    // 用同步记账而不是在 `speakForOther` 的 finally 里判断 —— 那个 finally 执行时
    // 状态可能已经变了（新会话已经开始了）。收尾清理见 [_clearBorrowedQueueIfMine]。
    _borrowedQueue = !claimAudio;
    _lines = items;
    _plainMode = true;
    _lineIndex = start < 0 ? 0 : (start >= items.length ? items.length - 1 : start);
    _generation++;
    _cancelWaitsBelow(++_waitSeq);
    _wakeLockWaiters();
    _beginSession(_generation);
    unawaited(_runLines(_generation));
  }

  Future<void> _runLines(int token) async {
    try {
      await _runLinesBody(token);
    } finally {
      _endSession(token); // 无论读完 / 失败 / 被打断，会话都算结束
    }
  }

  Future<void> _runLinesBody(int token) async {
    await _awt(() => _activeEngine.stop(), controlTimeout, lock: 'run-stop', token: token);
    if (token != _generation) return;
    // 注入时保留 _oneShot 原值
    _speaking = true;
    _paused = false;
    _fallback = false;
    _error = null;
    _notify();
    try {
      await _ensureReady(_activeEngine, token);
    } catch (e) {
      if (token != _generation) return;
      _error = '$e';
    }
    if (token != _generation) return;

    while (true) {
      if (token != _generation || !_speaking || _paused) return;
      if (_lineIndex < 0 || _lineIndex >= _lines.length) break;
      // 预处理后为空的条目不能送去合成（空串会被引擎当成朗读失败），直接跳下一条
      final text = _speakable(_lines[_lineIndex]);
      if (text == null) {
        if (_lineIndex >= _lines.length - 1) break;
        // 跳动检测（埋点 2）：跳过空条目也记一次推进（delta=1）
        SpeechDiagnostics.instance.recordAdvance(
          before: 'line:$_lineIndex',
          after: 'line:${_lineIndex + 1}',
          delta: 1,
          epoch: token,
        );
        _lineIndex++;
        continue;
      }
      _notify(); // 刷新当前条高亮
      final engine = _activeEngine;
      try {
        await _applyRate(engine, token);
        await _speakUnit(token, engine, text);
        if (_fallback) _fallback = false;
      } catch (e) {
        if (token != _generation || !_speaking || _paused) return;
        if (!await _fallbackSpeak(text, engine, token)) {
          _fail(e);
          return;
        }
      }
      if (token != _generation || !_speaking || _paused) return;
      // 已读完最后一条：把下标停在末条（界面高亮留得住），然后收尾
      if (_lineIndex >= _lines.length - 1) break;
      // 跳动检测（埋点 2）：本条读完 → 推进到下一条
      SpeechDiagnostics.instance.recordAdvance(
        before: 'line:$_lineIndex',
        after: 'line:${_lineIndex + 1}',
        delta: 1,
        epoch: token,
      );
      _lineIndex++;
    }

    if (token != _generation) return;
    _oneShot = false;
    _speaking = false;
    _notify();
  }

  void _restart((int, int, int) at) {
    _plainMode = false;
    // 通知栏切回本来源：PDF 会话在放时用户点了 TXT 的句子 → 通知栏要跟着换。
    // ⚠️ 只在这两个朗读入口调，**绝不能放进 stop()** ——
    // `registerEngine(makeActive: true)` 与换书路径内部都会 stop()，
    // 那会变成「注册引擎就换了源」（HANDOFF §4.65 踩过）。
    //
    // v1.21.25：用户入口**无条件**抢（不再走 `_claimAudioIfNotDelegated`）——
    // 那个闸门在 PDF 借声期间直接 return，用户起读 EPUB 时抢不回通知栏。
    audioHandler?.activate(this);
    // 会话若被 `endSessionAndClear()` 清掉（方块键 / 换书），先绑回来 ——
    // 否则这一句下面的 `_runBody` 会因为 `doc == null` 直接返回，
    // 表现就是「点了没反应」（目录、章标题、播放键都会这样）。
    _rebindIfCleared();
    AutoSleepController.instance.notifyUserActivity(); // 用户主动发起的操作：空闲计时重来
    // ★v1.21.49：**开始朗读 = 用户没有处于"主动暂停"状态**，清掉那个粘性标志。
    //
    // 为什么必须在这里清：`MediaInterruptionController._userPaused` 只有
    // **通知栏 / 耳机的播放键**会清（`TtsAudioHandler.play` → `notifyUserResumed`）。
    // 用户在**应用内**点播放走的是本方法，不经过那条路 —— 于是"很久以前按过一次
    // 暂停"会一直留成 true，把**短打断 / 提示音自动接回**那条路也一起堵死
    // （真机日志 2026-10-14 23:05 里 `userPaused=true` 而用户正在听，就是它）。
    //
    // `_restart` 是所有"开始朗读"路径的唯一漏斗（点句 / 快进 / 恢复 / 播放键），
    // 放在这里一处即可覆盖全部。
    MediaInterruptionController.instance.notifyUserResumed();
    // 开始朗读就申请音频焦点：别的应用出声时我们能被打断 / 被压低，
    // 来电能中断我们（受「允许其它媒体打断」开关控制）。
    unawaited(MediaInterruptionController.instance.requestFocus());
    _generation++; // 打断令牌：旧循环立即失效
    // v1.21.21：旧循环手上那句作废（"正在出声"的判定不能跨会话残留）。
    // `_lastSpokenRef` 保留 —— 它表示"刚读完的那句"，仍可作为快进基准。
    _speakingRef = null;
    _speakingIssuedAt = null;
    _cancelWaitsBelow(++_waitSeq); // 旧循环的插件等待一并取消
    _wakeLockWaiters(); // 正在排队等插件的旧循环立刻退出排队
    _beginSession(_generation);
    unawaited(_run(at, _generation));
  }

  Future<void> _run((int, int, int) at, int token) async {
    try {
      await _runBody(at, token);
    } finally {
      _endSession(token); // 无论读完 / 失败 / 被打断，会话都算结束
    }
  }

  Future<void> _runBody((int, int, int) at, int token) async {
    final doc = _doc;
    if (doc == null || doc.chapters.isEmpty) return;
    // ⚠️ **已知未修（v1.21.62 记录，别在这里乱试）**：
    //
    // 这一步是「停掉上一段声音，避免叠加」。真机上它可能卡住很久：
    // ```
    // 15:23:16  从 PDF 切回 EPUB（PDF 借 TTS 引擎发声，它那句 speak 的收尾
    //           还挂在引擎上 → 引擎 stop 迟迟不返回）
    // 15:23:17  按耳机播放 → playing 变 true，但**没有「开始朗读」**
    // 15:23:20  按暂停 → 代次被顶掉，这一次朗读彻底作废
    // ```
    // 用户听到的就是「按了播放、图标变了，但一直没声音」。
    //
    // ## 已经试过、都不行的三种改法（不要再走一遍）
    //
    // 1. **把超时从 5 秒改小** → 无效。`_awt` 在 `lock != null` 时走
    //    `_serial('run-stop', …)`，新调用要**排在上一次那个卡住的 stop 后面**，
    //    上限是 5 秒还是 700 毫秒都一样被无限期挡住（实测用例仍红）。
    // 2. **去掉 `lock`、只留 800ms 超时** → 仍红（`stop-block` 用例收到 0 条）。
    // 3. **改成 `unawaited(引擎.stop())` 完全不等待** → 这条通了，
    //    但**打乱了「停完再开口」的顺序**：`reader_control_bar_stop_test`
    //    那条既有用例变红（控制栏根本没渲染出来）。
    //
    // 结论：这不是能靠调超时/加不加锁解决的，得重新设计「换源之后引擎收尾」
    // 的时序（很可能要动 `PdfReadSession` 借声结束时的收尾）。
    // **在此之前保持原样**：宁可偶尔「按一次没声音、再按一次就好」，
    // 也不要破坏「停止 / 换书」那条更常走的路径。
    await _awt(
      () => _activeEngine.stop(),
      controlTimeout,
      lock: 'run-stop',
      token: token,
    ); // 停掉上一段声音，避免叠加
    if (token != _generation) return;
    _ch = at.$1;
    _p = at.$2;
    _s = at.$3;
    _clampCursor();
    // 意图已经落地 → 清掉，之后 cursor 回归真实游标（§4.102）。
    //
    // ⚠️ **只清「本次这一份」意图**：`_pendingCursor` 是共享字段，可能已经被
    // 更晚的一次 `speakFrom` 覆盖成**新目标**。无条件清会把那次新意图抹掉
    // —— 实测后果：`skipPageForward()` 连点两次时，第 1 次（被顶掉的）
    // `_runBody` 落地后清掉了第 2 次的意图，于是第 2 次快进直接失效
    // （`reader_features_test` 的页步进用例变红，而 baseline 是全绿的）。
    // 判据用「意图是否仍等于本次目标」，不能用 `token != _generation`
    // —— 那样区分不了「被更晚的调用顶掉」和「自己这一代还活着」。
    if (_pendingCursor == at) _pendingCursor = null;
    _speaking = true;
    _paused = false;
    _oneShot = false;
    _fallback = false;
    _error = null;
    _notify();
    CrashLog.mark('开始朗读：${_activeEngine.displayName} 粒度=${_granularity.label} '
        '起于 ${at.$1}/${at.$2}/${at.$3} 共 ${doc.chapters.length} 章');
    try {
      await _ensureReady(_activeEngine, token);
    } catch (e) {
      if (token != _generation) return;
      _error = '$e';
      CrashLog.mark('引擎准备失败：$e');
    }
    if (token != _generation) return;
    await _speakLoop(token);
  }

  /// 朗读主循环：取文本 -> 预处理 -> 朗读 -> 进位 -> 再校验令牌
  Future<void> _speakLoop(int token) async {
    while (true) {
      if (token != _generation || !_speaking || _paused) {
        return;
      }
      final raw = _currentText();
      // 原文不存在（空章节/游标越界）或预处理后什么都不剩：都按「跳过该单元」处理
      final text = raw == null ? null : _speakable(raw);
      if (text == null) {
        if (!_advance()) return;
        _notify();
        continue;
      }
      _notify(); // 刷新高亮
      final engine = _activeEngine;
      // v1.21.21：记下"这一句正在出声"（供 skipSentence 判基准，见 _audibleCursor）
      _speakingRef = cursor;
      _speakingIssuedAt = DateTime.now();
      try {
        // 只需套用一次语速/音调：每次朗读都调 initialize() 会白白多几百毫秒延迟
        await _applyRate(engine, token);
        await _speakUnit(token, engine, text);
        if (_fallback) {
          _fallback = false; // 云端恢复，取消降级标记
        }
      } catch (e) {
        if (token != _generation || !_speaking || _paused) return;
        if (!await _fallbackSpeak(text, engine, token)) {
          _fail(e);
          return;
        }
      }
      if (token != _generation || !_speaking || _paused) {
        return;
      }
      // 这一句确实读完了 → 它成为"刚读完的那句"，下一句交给引擎时再更新
      _lastSpokenRef = _speakingRef;
      _speakingRef = null;
      _speakingIssuedAt = null;
      if (!_advance()) return; // 越界：_stopAtEnd 已在内部收尾
    }
  }
  /// 系统 TTS 单条输入有长度上限，超长单元（整页 / 整章）需要切片
  /// 单次交给引擎的文本上限（字）
  ///
  /// ★v1.22.25：300 → **80**。
  ///
  /// 真机（手机 PKG110，2026-10-19 列宁文集）：一句 195 字，MultiTTS 的 **hd**
  /// 音色念得比普通音色慢，整句预算按"8s + 0.4s/字"算到 86 秒**仍然读完**，
  /// 于是被误判成「引擎无响应」并弹「朗读超时」。
  ///
  /// 切到 80 字后每块预算约 40 秒、实际念 20~25 秒，长句不再撞上限；
  /// 顺带让暂停 / 切句更快响应（不用等整句念完）。切分仍走
  /// [DocumentService.readChunks]，**优先在标点处断**，不会把词切断。
  static const int _maxUtterance = 80;

  // ---------------- 插件调用兜底超时 ----------------
  //
  // flutter_tts / just_audio 走 platform channel，插件侧不回复（TTS 引擎未装、
  // 被系统杀、蓝牙断开……）时 Future 永远不会完成。此前 initialize()/speak()/
  // getVoices() 都是裸 await，任何一次不回复都会把朗读循环永久挂住——
  // 表现就是「点朗读之后卡死、界面无响应」，进而被系统判为 ANR 闪退。
  // 这里统一套上超时：超时按失败处理（走已有的降级 / 报错分支），绝不无限等待。

  /// 单次朗读的上限（正常一句话 1~5 秒，30 秒说明插件已经不响应了）
  static const Duration defaultSpeakTimeout = Duration(seconds: 30);

  /// 引擎初始化 / 语速音调设置的上限
  static const Duration defaultInitTimeout = Duration(seconds: 8);

  /// 枚举语音列表较慢（Android 上要遍历引擎的全部音色），给宽一点
  static const Duration defaultVoiceTimeout = Duration(seconds: 10);

  /// 暂停 / 停止这类控制指令：只要能让插件收到就行，不该等太久
  static const Duration defaultControlTimeout = Duration(seconds: 5);

  /// 上面四个超时的实际取值。留成可写字段只为测试能缩短等待
  /// （测试环境没有真实的 TTS 插件，所有调用都必然走到超时分支）；
  /// 生产代码不要改它们。
  Duration speakTimeout = defaultSpeakTimeout;
  Duration initTimeout = defaultInitTimeout;
  Duration voiceTimeout = defaultVoiceTimeout;
  Duration controlTimeout = defaultControlTimeout;

  /// 恢复默认超时（测试收尾用）
  void resetTimeouts() {
    speakTimeout = defaultSpeakTimeout;
    initTimeout = defaultInitTimeout;
    voiceTimeout = defaultVoiceTimeout;
    controlTimeout = defaultControlTimeout;
    _speakTimeouts = 0;
  }

  /// 连续「单句朗读超时」的次数（引擎健康度）。见 [_onSpeakTimeout]。
  ///
  /// 只在**真的超时**时 +1，任何一次朗读成功就清零。
  int _speakTimeouts = 0;

  /// 只给测试看：当前连续超时了几次
  @visibleForTesting
  int get speakTimeoutStreak => _speakTimeouts;

  /// 单句朗读的等待上限：**按字数给，不是固定 30 秒**。
  ///
  /// 真机截图（2026-10-18）：`Bad state: 本地 TTS · multitts 朗读超时（30 秒无响应）`
  /// —— 但同一本书的日志里有 **21 秒**才读完的句子（15:40:59→15:41:20），
  /// 而这类长句（100 字上下）正常要 35~40 秒才念得完。固定 30 秒的判据
  /// 必然把它误判成「引擎不回应」，用户看到的就是朗读被硬生生掐断。
  ///
  /// 口径：8 秒起步 + 每字 400ms，夹在 15~90 秒之间。
  /// （正常语速约 3.5~4 字/秒，400ms/字 留了约 1.5 倍余量。）
  ///
  /// ⚠️ 测试里显式改过 [speakTimeout] 时**以覆盖值为准**：那 1000+ 条用例
  /// 靠把上限压到几百毫秒才能在毫秒级时间内跑完，这里不能把它们拖成十几秒。
  Duration _speakBudgetFor(String text) {
    if (speakTimeout != defaultSpeakTimeout) return speakTimeout;
    final int chars = text.trim().length;
    final int ms = 8000 + chars * 400;
    return Duration(milliseconds: ms.clamp(15000, 90000));
  }

  /// 只给测试看：给定文本的朗读等待上限
  @visibleForTesting
  Duration debugSpeakBudgetFor(String text) => _speakBudgetFor(text);

  // ---------------- 插件调用串行锁 ----------------
  //
  // 同一个 key 上的插件调用**排队执行**，而不是「重入即失败」。
  //
  // 为什么不能重入即失败（v1.5 在模拟器上用真引擎复现的真实缺陷）：
  // 朗读中换位置（点某一段、按上一页、通知栏拖动进度）会打断旧循环，
  // 但旧循环可能刚好已经把 speak 交给了插件——而插件要等这一句**读完**才回复，
  // 于是旧调用会长时间占着锁。此时新循环的 speak 被锁挡下、立刻返回失败，
  // 被 `_speakChunk` 当成「朗读超时」→ `_fail()` → 界面上弹出错误并且不读了。
  // 真机表现就是「正在朗读时点另一段，报朗读超时、没声音」。
  //
  // 排队 + 打断令牌（token）：旧循环在排队期间令牌就会失效，直接退出、不再抢插件；
  // 新循环排队等到旧调用收尾（打断会把旧等待立刻取消，锁随之释放）后照常朗读。

  final Map<String, Completer<void>> _lockHolders = <String, Completer<void>>{};
  final Map<String, List<Completer<void>>> _lockWaiters = <String, List<Completer<void>>>{};

  /// 在 [key] 上排队执行 [action]。
  ///
  /// 返回 null 表示「排队期间令牌失效」——旧循环已被新的朗读打断，本次调用没有执行，
  /// 调用方按「已打断」处理即可（不要当成朗读失败）。
  Future<T?> _serial<T>(String key, int? token, Future<T> Function() action) async {
    while (_lockHolders.containsKey(key)) {
      if (token != null && token != _generation) {
        return null; // 旧循环：别再抢插件
      }
      final waiter = Completer<void>();
      (_lockWaiters[key] ??= <Completer<void>>[]).add(waiter);
      await waiter.future;
    }
    if (token != null && token != _generation) return null;
    _lockHolders[key] = Completer<void>();
    try {
      return await action();
    } finally {
      _lockHolders.remove(key);
      _wakeLockWaiters(key);
    }
  }

  /// 唤醒等待 [key] 的循环（key 为空时全部唤醒）。
  ///
  /// 等待者被唤醒后会重新检查令牌：失效的直接退出，仍然有效的重新排队。
  void _wakeLockWaiters([String? key]) {
    final keys = key == null ? _lockWaiters.keys.toList() : <String>[key];
    for (final item in keys) {
      final waiters = _lockWaiters.remove(item);
      if (waiters == null) continue;
      for (final waiter in waiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
    }
  }

  /// 单调递增的「操作序号」，每发起一次朗读 / 暂停 / 停止就 +1。
  ///
  /// 正在等待插件的调用按发起时的序号登记在 [_pendingWaits]；序号更新的操作
  /// （用户按了停止、点了新位置、开始新的一遍朗读）会把所有**更旧**的等待取消。
  ///
  /// 注意不能用 [_generation] 当代次来登记：`_generation` 表示「游标当前所在的
  /// 朗读代次」，会在朗读推进、`_stopAtEnd()`、`_fail()` 里变化。用它当登记键会
  /// 出现「刚发起的等待被下一次操作当成旧的取消掉」，表现就是**点朗读没有任何反应**。
  int _waitSeq = 0;

  final Map<int, Completer<void>> _pendingWaits = <int, Completer<void>>{};

  /// 取消所有序号小于 [seq] 的插件等待（更旧的操作），返回是否取消了任何等待。
  void _cancelWaitsBelow(int seq) {
    if (_pendingWaits.isEmpty) return;
    final victims = _pendingWaits.keys.where((key) => key < seq).toList();
    for (final key in victims) {
      final completer = _pendingWaits.remove(key);
      if (completer != null && !completer.isCompleted) completer.complete();
    }
  }

  /// 给 future 套超时：超时抛 [TimeoutException]，且**不留悬挂定时器**。
  ///
  /// 不用 `future.timeout()`：它内部注册的定时器在「操作永不完成」时不会被取消，
  /// 会一直挂到进程结束（测试里表现为 "A Timer is still pending"）。
  /// 这里等「操作完成 / 超时 / 被取消」三者先到者，另外两条路都会撤掉定时器。
  Future<T> _bounded<T>(Future<T> operation, Duration timeout) {
    final completer = Completer<T>();
    final cancel = Completer<void>();
    // 登记用的序号在本函数内固定，不受后续操作影响
    final seq = ++_waitSeq;
    _pendingWaits[seq] = cancel;
    var settled = false;
    final timer = Timer(timeout, () {
      if (settled) return;
      settled = true;
      if (identical(_pendingWaits[seq], cancel)) _pendingWaits.remove(seq);
      completer.completeError(
        TimeoutException('插件调用超过 ${timeout.inMilliseconds} 毫秒未响应'),
      );
    });

    void finish(void Function() action) {
      if (settled) return;
      settled = true;
      timer.cancel();
      if (identical(_pendingWaits[seq], cancel)) _pendingWaits.remove(seq);
      action();
    }

    cancel.future.then<void>(
      (_) => finish(() => completer.completeError(const _WaitCancelled())),
    );
    operation.then<void>(
      (T value) => finish(() => completer.complete(value)),
      onError: (Object error, StackTrace stack) =>
          finish(() => completer.completeError(error, stack)),
    );
    return completer.future;
  }

  /// 给一次插件调用套上「排队 + 超时」。
  ///
  /// [operation] 是**工厂**而不是 Future：必须等排到锁之后再真正发起调用，
  /// 否则调用会绕过排队（两个 speak 同时压给插件）。
  /// [token] 是本次朗读的打断令牌，排队期间失效就直接放弃（返回 false）。
  Future<bool> _awt(
    Future<void> Function() operation,
    Duration timeout, {
    String? lock,
    int? token,
  }) async {
    Future<bool> run() async {
      try {
        await _bounded(operation(), timeout);
        return true;
      } catch (_) {
        return false;
      }
    }

    if (lock == null) return run();
    final result = await _serial<bool>(lock, token, run);
    return result ?? false;
  }

  /// 给一次带返回值的插件调用套上超时（失败返回兜底值，交由调用方处理）
  Future<T> _awtValue<T>(
    Future<T> Function() operation,
    Duration timeout,
    T fallback, {
    int? token,
  }) async {
    Future<T> run() async {
      try {
        return await _bounded(operation(), timeout);
      } catch (_) {
        return fallback;
      }
    }

    final result = await _serial<T>('voices', token, run);
    return result ?? fallback;
  }

  /// 层 2 防御判据：一个汉字最短也要 ~80ms 才发得完。
  ///
  /// 文本超过 5 个字却在 100ms 内「读完」，只可能是引擎**提交即返回**
  /// （真机根因见 `system_tts_engine.dart` 的 `speak()` 注释：flutter_tts 的
  /// `speak` Future 在「上一句未收尾」或「刚 stop 过」时会立刻回 0）。
  /// 判据与 PDF 侧 §4.106 的 `_minRealSpeakMs` 同口径，只是提到了共享层。
  static const int _minRealSpeakMs = 100;
  static const int _minRealSpeakChars = 5;

  /// 朗读一个单元：超长文本按句切片依次朗读，仍算作一个单元
  Future<void> _speakUnit(int token, TtsEngine engine, String text) async {
    // 跳动检测（埋点 1a）：只记录，不改判定逻辑
    SpeechDiagnostics.instance.recordSpeakIssued(
      epoch: token,
      text: text,
      cursor: _diagCursorKey(),
    );
    if (text.length <= _maxUtterance) {
      final int startedAtMs = DateTime.now().millisecondsSinceEpoch;
      await _speakChunk(engine, text, token);
      _rejectSubmitOnly(engine, text, startedAtMs);
      return;
    }
    for (final chunk in DocumentService.readChunks(text, maxLength: _maxUtterance)) {
      if (token != _generation || !_speaking || _paused) return;
      final int startedAtMs = DateTime.now().millisecondsSinceEpoch;
      await _speakChunk(engine, chunk, token);
      _rejectSubmitOnly(engine, chunk, startedAtMs);
    }
  }

  /// 层 2 防御：`speak` 返回得过快 → 判为假完成，抛错交给上层（**不推进位置**）。
  ///
  /// 只做「过快」这一件事：正常的读完、被打断、超时都由既有链路处理。
  ///
  /// **判据本身对所有引擎生效**；只有显式声明了合成语义的测试替身
  /// （`with SyntheticTtsEngine`）跳过 —— 让测试装置表达自己的语义，
  /// 而不是让实现为了测试放宽判据。
  void _rejectSubmitOnly(TtsEngine engine, String text, int startedAtMs) {
    if (engine is SyntheticTtsEngine) return;
    if (text.trim().length <= _minRealSpeakChars) return;
    final int elapsed = DateTime.now().millisecondsSinceEpoch - startedAtMs;
    if (elapsed >= _minRealSpeakMs) return;
    throw StateError(
      '${engine.displayName} 提交即返回（${elapsed}ms < ${_minRealSpeakMs}ms）：'
      '判为假完成，本次不推进',
    );
  }

  /// 朗读一个片段：插件不回复时按超时失败处理；被新的朗读打断时安静退出
  Future<void> _speakChunk(TtsEngine engine, String chunk, int token) async {
    // 上限按**这一句的字数**给：固定 30 秒会把长句误判成「引擎不回应」
    // （见 [_speakBudgetFor]）。重试不再额外缩短——长度判据本身就是准确的，
    // 真正 wedge 的引擎交给 [_onSpeakTimeout] 的重置链路处理。
    final Duration budget = _speakBudgetFor(chunk);
    final ok = await _awt(
      () async {
        try {
          await _bounded(engine.speak(chunk), budget);
        } on TimeoutException {
          CrashLog.mark('朗读失败：${engine.displayName} 超时（${budget.inMilliseconds}ms）');
          rethrow;
        }
      },
      budget,
      lock: 'speak',
      token: token,
    );
    // 跳动检测（埋点 1b）：记录引擎结论与耗时，不改判定逻辑
    SpeechDiagnostics.instance.recordSpeakDone(
      epoch: token,
      ok: ok,
      cursorAfter: _diagCursorKey(),
    );
    if (ok) {
      _speakTimeouts = 0; // 引擎恢复回应：下次照常等 speakTimeout
      return;
    }
    // 没排上队 / 被取消：令牌失效说明是旧循环，交给上层的令牌检查收尾；
    // 令牌仍然有效却失败，说明确实超时且没有抛出（例如等待被取消）
    if (token != _generation) throw const _WaitCancelled();
    _onSpeakTimeout(engine);
    throw StateError('${engine.displayName} 朗读超时（${budget.inSeconds} 秒无响应）');
  }

  /// 单句朗读超时 = 插件已经不回应了，**必须当成「引擎坏了」处理**。
  ///
  /// 真机（2026-10-17）：「本地 TTS · multitts 朗读超时（30000ms）」之后，
  /// 同一位置再按播放**又卡满 30 秒**。
  ///
  /// 原因是 [_fail] 只清播放状态，而 [_ensureReady] 的就绪记账
  /// （[_initedEngineId] / [_appliedSetupKey]）没变 —— 下一次直接**跳过
  /// initialize**，把同一句又压给同一个卡死的 `FlutterTts` 实例；
  /// 它 `speaking` / `speakResult` 还挂着，完成回调永远不会再来。
  void _onSpeakTimeout(TtsEngine engine) {
    _speakTimeouts++;
    CrashLog.mark('引擎无响应：${engine.displayName}（连续第 $_speakTimeouts 次）'
        '→ 作废就绪记账并清系统队列');
    // ① 作废就绪记账：下一次必须重新 initialize，不能对着可能已死的插件直接 speak
    if (_initedEngineId == engine.id) _initedEngineId = '';
    _appliedSetupKey = '';
    // ② 清系统侧队列：不 stop 的话上一句的 speakResult 会把下一句整个吞掉。
    //    **不 await**：这个 stop 本身也可能卡住，等它等于把下一次朗读一起挡死。
    unawaited(_awt(() => engine.stop(), controlTimeout, lock: 'recover-${engine.id}'));
    // ③ 连续第二次仍不回应 → 这个实例不可信，强制重绑本地 TTS 引擎
    if (_speakTimeouts >= 2 && engine is SystemTtsEngine) {
      unawaited(_rebindSystemEngine(engine));
    }
    _notify();
  }

  /// 连续超时后强制重绑系统 TTS。
  ///
  /// Android 侧 `setEngineByPackageName` 会重建 `TextToSpeech` 实例，
  /// 卡死的合成线程随之丢弃 —— 这是 Dart 层唯一能做的一次「真重置」。
  /// 重绑也失败才换新对象（新对象至少把 Dart 侧的回调与等待全部作废）。
  Future<void> _rebindSystemEngine(SystemTtsEngine engine) async {
    final ok = await _awt(
      () => engine.reset(),
      initTimeout,
      lock: 'reset-${engine.id}',
    );
    if (ok) {
      CrashLog.mark('引擎重绑成功：${engine.displayName}');
      return;
    }
    CrashLog.mark('引擎重绑失败：${engine.displayName} → 换新实例');
    if (!identical(_engines[_systemId], engine)) return;
    _register(SystemTtsEngine(enginePackage: _localEnginePackage));
    unawaited(engine.dispose());
    _notify();
  }

  /// 引擎准备：初始化 + 套用当前语速 / 音调 / 音色
  ///
  /// ⚠️ v1.21.37：**设置没变就一条通道调用都不发**（见 [_applyRate] / [_applyVoice]）。
  /// 多句连读时每一句都会走这里，而这些设置与上一句完全相同 ——
  /// 真机日志实测每句之间因此白等 406~521ms（用户感受就是"句末要卡一下"）。
  Future<void> _ensureReady(TtsEngine engine, int token) async {
    final key = _setupKeyOf(engine);
    if (_initedEngineId == engine.id && _appliedSetupKey == key) {
      // 这个引擎已初始化、且语速/音调/音色与上次下发的一致：
      // 整段跳过（initialize + setRate + setPitch + getVoices + setVoice）
      return;
    }
    final ok = await _awt(
      () => engine.initialize(),
      initTimeout,
      lock: 'init-${engine.id}',
      token: token,
    );
    if (token != _generation) throw const _WaitCancelled();
    if (!ok) throw StateError('${engine.displayName} 初始化超时或失败');
    _initedEngineId = engine.id;
    await _applyRate(engine, token);
    await _applyVoice(engine, token);
    // 全部下发成功才记账：下次同样的设置直接跳过
    _appliedSetupKey = key;
  }

  /// 套用语速与音调（设置失败不影响朗读）
  ///
  /// ⚠️ v1.21.37：**值没变就跳过**（一次平台通道往返 ≈ 几十到几百毫秒）。
  /// 判据落在 [_appliedSetupKey] 上，由 [_ensureReady] 在全部下发成功后记账。
  Future<void> _applyRate(TtsEngine engine, [int? token]) async {
    if (_appliedSetupKey == _setupKeyOf(engine)) return;
    await _awt(() => engine.setRate(_rate), initTimeout, lock: 'rate-${engine.id}', token: token);
    await _awt(() => engine.setPitch(_pitch), initTimeout, lock: 'pitch-${engine.id}', token: token);
  }

  /// 套用音色（Android 上要枚举音色列表，较慢，失败静默）
  ///
  /// ⚠️ v1.21.37：`getVoices()` 在 Android 上要枚举整张音色表，是最贵的一次调用
  /// —— 设置没变时必须跳过。
  Future<void> _applyVoice(TtsEngine engine, [int? token]) async {
    if (_voiceId.isEmpty) return;
    if (_appliedSetupKey == _setupKeyOf(engine)) return;
    final voices = await _awtValue(
      () => engine.getVoices(),
      voiceTimeout,
      const <TtsVoice>[],
      token: token,
    );
    if (!voices.any((v) => v.id == _voiceId)) return;
    await _awt(() => engine.setVoice(_voiceId), initTimeout, lock: 'voice-${engine.id}', token: token);
  }

  /// 云端等引擎异常时降级到系统引擎朗读同一段
  Future<bool> _fallbackSpeak(String text, TtsEngine failed, int token) async {
    final system = _engines[_systemId];
    if (failed.id == _systemId || system == null) return false;
    _fallback = true;
    _error = '${failed.displayName} 朗读失败，已降级为系统引擎';
    _notify();
    try {
      final ready = await _awt(
        () => system.initialize(),
        initTimeout,
        lock: 'init-$_systemId',
        token: token,
      );
      if (!ready) return false;
      await _applyRate(system, token);
      // 同样需要切片，避免整页 / 整章文本超出系统 TTS 上限被截断
      final chunks = text.length <= _maxUtterance
          ? <String>[text]
          : DocumentService.readChunks(text, maxLength: _maxUtterance);
      for (final chunk in chunks) {
        await _speakChunk(system, chunk, token);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  void _fail(Object error) {
    CrashLog.mark('朗读失败：$error');
    _error = '朗读失败：$error';
    _generation++;
    _wakeLockWaiters();
    _speaking = false;
    _paused = false;
    _oneShot = false;
    _fallback = false;
    _pendingCursor = null; // 失败了，意图作废（§4.102）
    _notify();
  }

  // ---------------- 单元定位与进位 ----------------

  /// 送去合成前套一遍文本预处理规则；处理后为空则返回 null（该单元没有可读内容）
  ///
  /// 只改送进引擎的字符串：阅读页高亮跟着游标走，显示的仍是原文。
  ///
  /// ⚠️ v1.21.38：**"没有实义字符"也当空单元跳过**（不只是"处理后为空串"）。
  ///
  /// 为什么：PDF 抽取常见"右引号单独占一行"，分句规则又会把收尾引号归到下一句
  /// 开头 —— 于是 `”` 这种**纯标点**成了 1 字符的独立句被送进引擎。
  /// 真机实测（v1.21.37 日志）这条 `text="”"` **从不回调完成**，
  /// 硬生生卡满 `speakTimeout` = **30 秒**才继续（用户感受就是"卡死了"）。
  ///
  /// 判据用「有没有字母/数字」而不是"长度"：`3` 这种单字符数字**照常读**
  /// （日志里 `text="3"` 正常完成 554ms），只把纯标点/纯符号挡掉。
  static final RegExp _hasMeaningfulChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

  String? _speakable(String raw) {
    if (raw.trim().isEmpty) return null;
    // 没有预处理规则时也要过这一关：纯标点单元直接跳过
    if (!TextProcessor.instance.hasActiveRules) {
      return _hasMeaningfulChar.hasMatch(raw) ? raw : null;
    }
    final processed = TextProcessor.instance.apply(raw);
    final trimmed = processed.trim();
    if (trimmed.isEmpty) return null;
    return _hasMeaningfulChar.hasMatch(trimmed) ? processed : null;
  }

  /// 当前游标对应的文本：句 -> 单句，章 -> 整章拼接，页 -> 本页拼接
  String? _currentText() {
    final doc = _doc;
    if (doc == null || doc.chapters.isEmpty) return null;
    if (_ch < 0 || _ch >= doc.chapters.length) return null;
    final chapter = doc.chapters[_ch];
    return switch (_granularity) {
      ReadGranularity.sentence => _sentenceText(chapter),
      ReadGranularity.chapter => chapter.text,
      ReadGranularity.page => _pageText(chapter),
    };
  }

  String? _paragraphText(Chapter chapter) =>
      _p >= 0 && _p < chapter.paragraphs.length ? chapter.paragraphs[_p].text : null;

  String? _sentenceText(Chapter chapter) {
    final paragraph = _paragraphText(chapter);
    if (paragraph == null) return null;
    final sentences = chapter.paragraphs[_p].sentences;
    return _s >= 0 && _s < sentences.length ? sentences[_s].text : null;
  }

  /// 当前页文本（页 = 章节内的每 N 段，PDF 时一章即一页）
  String? _pageText(Chapter chapter) {
    final doc = _doc;
    if (doc == null) return null;
    final ranges = doc.pageRanges(_ch, _perPage());
    if (ranges.isEmpty) return null;
    var index = doc.pageOf(_ch, _p, _perPage()) - 1;
    if (index < 0) index = 0;
    if (index >= ranges.length) index = ranges.length - 1;
    final (start, end) = ranges[index];
    final buffer = StringBuffer();
    for (var p = start; p < end && p < chapter.paragraphs.length; p++) {
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(chapter.paragraphs[p].text);
    }
    final text = buffer.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// 跳动检测用：把当前游标写成 "ch:p:s"
  String _diagCursorKey() => '$_ch:$_p:$_s';

  /// 按粒度进位（句 → 段 → 章逐级进位）；越界时收尾并返回 false
  bool _advance() {
    final doc = _doc;
    if (doc == null || doc.chapters.isEmpty) return _stopAtEnd();
    if (_ch < 0 || _ch >= doc.chapters.length) return _stopAtEnd();
    final chapter = doc.chapters[_ch];
    // 跳动检测（埋点 2）：只记录推进前后的游标与当时的代次，不参与进位判断。
    // 这里记的是**推进那一刻**的 `_generation`：若它已经与发起朗读时的代次
    // 不一致，判定器会命中 R2（不该推进却推进了）。
    final String before = _diagCursorKey();
    final bool moved = switch (_granularity) {
      ReadGranularity.sentence => _advanceSentence(chapter),
      ReadGranularity.chapter => _advanceChapter(),
      ReadGranularity.page => _advancePage(chapter),
    };
    if (moved) {
      SpeechDiagnostics.instance.recordAdvance(
        before: before,
        after: _diagCursorKey(),
        delta: 1,
        epoch: _generation,
      );
    }
    return moved;
  }

  /// 句粒度：句 → 段 → 章逐级进位
  bool _advanceSentence(Chapter chapter) {
    final paragraphs = chapter.paragraphs;
    // 空章（PDF 空白页等）跳到下一章，而不是直接结束
    if (paragraphs.isEmpty) return _moveToNextChapter();
    final current = _p >= 0 && _p < paragraphs.length ? _p : 0;
    if (_s + 1 < paragraphs[current].sentences.length) {
      _p = current;
      _s++;
      return true;
    }
    if (current + 1 < paragraphs.length) {
      _p = current + 1;
      _s = 0;
      return true;
    }
    return _moveToNextChapter();
  }

  /// 页粒度：页 → 章（PDF 一章即一页）
  bool _advancePage(Chapter chapter) {
    final doc = _doc;
    if (doc == null) return _stopAtEnd();
    if (doc.chapterIsPage) return _moveToNextChapter();
    final ranges = doc.pageRanges(_ch, _perPage());
    if (ranges.isEmpty) return _moveToNextChapter();
    final current = doc.pageOf(_ch, _p, _perPage()) - 1;
    if (current + 1 < ranges.length) {
      _p = ranges[current + 1].$1;
      _s = 0;
      return true;
    }
    return _moveToNextChapter();
  }

  /// 章粒度：章 → 章
  bool _advanceChapter() => _moveToNextChapter();

  bool _moveToNextChapter() {
    final next = _nextChapterWithContent(_ch + 1);
    if (next < 0) return _stopAtEnd();
    _ch = next;
    _p = 0;
    _s = 0;
    return true;
  }

  /// 找到 from 之后第一个有内容的章节，找不到返回 -1
  int _nextChapterWithContent(int from) {
    final doc = _doc;
    if (doc == null) return -1;
    for (var i = from; i < doc.chapters.length; i++) {
      if (doc.chapters[i].paragraphs.isNotEmpty) return i;
    }
    return -1;
  }

  /// 越界收尾：把游标停在最后一有效单元并结束朗读
  bool _stopAtEnd() {
    final doc = _doc;
    // 读完了：意图不再有意义，先清掉再算末尾位置，免得 cursor 返回旧意图（§4.102）
    _pendingCursor = null;
    if (doc != null) {
      for (var c = doc.chapters.length - 1; c >= 0; c--) {
        final paragraphs = doc.chapters[c].paragraphs;
        if (paragraphs.isEmpty) continue;
        _ch = c;
        _p = paragraphs.length - 1;
        final sentences = paragraphs.last.sentences;
        _s = sentences.isEmpty ? 0 : sentences.length - 1;
        break;
      }
    }
    _generation++;
    _wakeLockWaiters();
    _speaking = false;
    _paused = false;
    _oneShot = false;
    _fallback = false;
    _notify();
    return false;
  }

  /// 游标安全化：保证 (章, 段, 句) 落在有效单元内
  ///
  /// ⚠️ §4.102：夹取对象是「有效位置」（有意图游标时夹意图，别去动真实游标），
  /// 否则快进/点句会在意图窗口里夹错对象。
  void _clampCursor() {
    final doc = _doc;
    final pending = _pendingCursor;
    var ch = pending?.$1 ?? _ch;
    var p = pending?.$2 ?? _p;
    var s = pending?.$3 ?? _s;
    if (doc == null || doc.chapters.isEmpty) {
      ch = 0;
      p = 0;
      s = 0;
    } else {
      ch = _clampInt(ch, 0, doc.chapters.length - 1);
      final paragraphs = doc.chapters[ch].paragraphs;
      if (paragraphs.isEmpty) {
        p = 0;
        s = 0;
      } else {
        p = _clampInt(p, 0, paragraphs.length - 1);
        final sentences = paragraphs[p].sentences;
        s = sentences.isEmpty ? 0 : _clampInt(s, 0, sentences.length - 1);
      }
    }
    if (pending != null) {
      _pendingCursor = (ch, p, s);
    } else {
      _ch = ch;
      _p = p;
      _s = s;
    }
  }

  static double _clampDouble(double value, double min, double max) =>
      value < min ? min : (value > max ? max : value);

  static int _clampInt(int value, int min, int max) =>
      value < min ? min : (value > max ? max : value);

  static double _asDouble(Object? value, double fallback) =>
      value is num ? value.toDouble() : fallback;
}

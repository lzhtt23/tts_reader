import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

import '../services/crash_log.dart';
import 'tts_engine.dart';

/// 系统 TTS 引擎（flutter_tts）
///
/// 额外实现 [LocalEngineHost]：设备上装了多个本地 TTS 引擎时可以枚举并切换。
class SystemTtsEngine implements TtsEngine, LocalEngineHost {
  SystemTtsEngine({String enginePackage = ''}) : _enginePackage = enginePackage.trim();

  final FlutterTts _tts = FlutterTts();

  /// 等待当前 speak 结束的凭据
  Completer<void>? _pending;
  void Function()? _onComplete;

  bool _initialized = false;
  bool _disposed = false;

  /// 当前使用的本地引擎包名（空表示跟随系统默认）
  String _enginePackage;

  @override
  String get id => 'system';

  @override
  String get displayName => _enginePackage.isEmpty
      ? '系统 TTS'
      : '本地 TTS · ${LocalTtsEngine.labelOf(_enginePackage)}';

  @override
  String? get enginePackage => _enginePackage.isEmpty ? null : _enginePackage;

  /// 列出设备上安装的本地 TTS 引擎
  ///
  /// 桌面 / 测试环境没有原生实现，`getEngines` 会抛异常或返回空 —— 一律当「没有可选项」处理。
  @override
  Future<List<LocalTtsEngine>> listLocalEngines() async {
    if (_disposed) return const <LocalTtsEngine>[];
    try {
      final raw = await _tts.getEngines;
      final defaultEngine = await _tts.getDefaultEngine;
      final packages = <String>[];
      if (raw is List) {
        for (final item in raw) {
          final name = '$item'.trim();
          if (name.isNotEmpty && name != 'null') packages.add(name);
        }
      } else if (raw is String && raw.trim().isNotEmpty) {
        packages.add(raw.trim());
      }
      final defaultName = defaultEngine is String ? defaultEngine.trim() : '';
      // 当前包名为空时，实际生效的是系统默认引擎
      final current = _enginePackage.isEmpty ? defaultName : _enginePackage;
      return <LocalTtsEngine>[
        for (final package in packages)
          LocalTtsEngine(
            package: package,
            label: LocalTtsEngine.labelOf(package),
            isDefault: package == defaultName,
            isCurrent: package == current,
          ),
      ];
    } catch (_) {
      return const <LocalTtsEngine>[];
    }
  }

  /// 切换本地引擎：切换后必须重新走一遍 initialize（语言 / 语速 / 音色都要重设）
  @override
  Future<void> useLocalEngine(String package) async {
    final target = package.trim();
    if (target.isEmpty || target == _enginePackage) return;
    try {
      await _tts.stop();
    } catch (_) {
      // 停不掉也要继续切
    }
    await _tts.setEngine(target);
    _enginePackage = target;
    _initialized = false; // 让 _ensureReady 重新套用语言 / 语速 / 音色
    await initialize();
  }

  @override
  bool get isAvailable => !_disposed;

  @override
  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    // 用户选过本地引擎就先切过去（切换要在 awaitSpeakCompletion 之前，
    // 否则个别 ROM 上切引擎会把已注册的回调一起重置掉）
    if (_enginePackage.isNotEmpty) {
      try {
        await _tts.setEngine(_enginePackage);
      } catch (_) {
        // 引擎被卸载 / 包名失效：退回系统默认，不影响朗读
        _enginePackage = '';
      }
    }
    // 让 speak() 的 Future 在整段朗读结束后才完成，朗读循环据此顺序推进
    await _tts.awaitSpeakCompletion(true);
    _tts.setCompletionHandler(_handleFinished);
    _tts.setCancelHandler(_handleFinished);
    _tts.setErrorHandler((dynamic message) {
      // 出错也要唤醒等待中的 speak()，否则朗读循环会一直挂起
      _completePending();
      _onComplete?.call();
    });
    _initialized = true;
  }

  /// 完成 / 取消回调：唤醒等待者并通知上层。
  ///
  /// **时长判据（路径 B）**：本回调由引擎侧触发（完成 / 取消 / 出错都会走到这里）。
  /// 若它距本次提交不到 [_minRealSpeakMs]，那它**不是**这一句读完 ——
  /// 真机实测这种「假完成」只有 238 微秒（上一句的迟到回调，或引擎谎报），
  /// 旧实现直接放行，于是主循环把没读的句子当成读完、位置被推飞。
  /// 这里丢弃它、继续等真实回调；连续丢弃到 [_maxFakeCompleteDrops] 才放行（不卡死）。
  ///
  /// 打断路径不受影响：`pause()` / `stop()` 自己调 `_completePending()`（此时
  /// `_pending` 已为 null），所以「被打断要尽快放行」的语义原样保留。
  void _handleFinished() {
    final DateTime? issuedAt = _speakIssuedAt;
    if (issuedAt != null &&
        _pending != null &&
        _fakeCompleteDrops < _maxFakeCompleteDrops) {
      final int elapsed = DateTime.now().difference(issuedAt).inMilliseconds;
      if (elapsed < _minRealSpeakMs) {
        _fakeCompleteDrops++;
        return; // 假完成：不放行、也不通知上层，继续等
      }
    }
    _completePending();
    _onComplete?.call();
  }

  void _completePending() {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  @override
  Future<List<TtsVoice>> getVoices() async {
    await initialize();
    final raw = await _tts.getVoices;
    if (raw is! List) return const <TtsVoice>[];
    final voices = <TtsVoice>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final name = '${item['name'] ?? ''}'.trim();
      if (name.isEmpty || name == 'null') continue;
      voices.add(TtsVoice(id: name, name: name, locale: '${item['locale'] ?? ''}'.trim()));
    }
    return voices;
  }

  @override
  Future<void> setVoice(String voiceId) async {
    if (voiceId.isEmpty || _disposed) return;
    await initialize();
    for (final voice in await getVoices()) {
      if (voice.id != voiceId) continue;
      await _tts.setVoice(<String, String>{'name': voice.name, 'locale': voice.locale});
      return;
    }
  }

  @override
  Future<void> setRate(double rate) async {
    // 按需求把语速 ×0.5 交给 flutter_tts（其有效区间 0.0~1.0，1.0 最快）
    await _tts.setSpeechRate(rate * 0.5);
  }

  @override
  Future<void> setPitch(double pitch) => _tts.setPitch(pitch);

  // ⚠️ v1.22.62：这里曾实现过「首次发声音量渐起」来消外放爆音，
  // **已撤掉** —— 用户实测反馈「启动时句子声音太小，影响使用」。
  //
  // 教训：靠降低首句音量换消音是不可接受的取舍。首句必须**正常音量**开口。
  // 若要再处理爆音，只能走"不改变用户听到的音量"的路子（例如引擎侧预热），
  // 不要再来动用户会听到的音量。

  // ─────────── 引擎音频预热（v1.22.62 · 用户批准后实现） ───────────
  //
  // ## 治什么
  // 真机（平板，2026-10-26）：「冷启动开始朗读时有点爆音」。
  // 已确认系统不给淡入（`get fade type, but return null`）、
  // 也不做爆音优化（`pop_optimize mIsPopOptimizeSupport:0`），
  // 所以音频设备**第一次被唤醒**时的瞬态冲击只能由我们规避。
  //
  // ## 思路
  // 在用户按下播放**之前**（打开文档时）就用**零音量**让引擎把音频轨道建好，
  // 等真正朗读时该设备已经是热的 —— 爆音被提前到"静音、没人注意"的时刻。
  //
  // ## ⚠️ 两条保险，防止重演"首句声音变小"
  // 1. 预热期间音量恒为 0，**从来没有把它当正常音量用过**；
  // 2. `speak()` 在提交真正的句子前，如果发现预热还在进行，
  //    会先 `stop()` + 把音量强制拉回 1.0 —— 首句永远是满音量。
  //
  // 只要有一条成立，用户就听不到"声音小"；两条一起上是为了万无一失。
  bool _warmUpInFlight = false;

  /// **是否做引擎音频预热**（v1.22.62 A/B 实验开关）
  ///
  /// `true`  = 打开文档时用零音量说一句，预热引擎音频通路（会创建一条音轨）
  /// `false` = 完全不预热（本次实验值）
  ///
  /// ⚠️ 这个预热从未证明有效（加了之后爆音照旧），却会多创建一条音轨。
  /// 实验结束后按结论固定成最终值，不要长期留成开关。
  static const bool _kWarmUpAudioPath = false;

  /// 预热是否已完成（同一引擎实例只做一次）
  bool _warmedUp = false;

  /// 用**零音量**跑一句，只为让引擎建立音频轨道
  ///
  /// 失败一律吞掉：预热只是优化，绝不能影响朗读。
  Future<void> warmUpAudioPath() async {
    // ★ v1.22.62 实验：**关闭 TTS 引擎预热**。
    //
    // 预热本身会创建一条引擎音轨（在 `org.nobody.multitts` 进程里），
    // 而用户反馈「打开文档时爆音提前触发」—— 那次瞬态很可能就是它，
    // 而不是静音轨（静音轨当时已挪到应用启动）。
    //
    // 而且这个预热**从没证明过有效**：加它之后爆音照旧。
    // 所以本次 A/B 实验把**两条自建音轨（静音轨 + 引擎预热）全部关掉**，
    // 才能确认"啪"到底来自哪一条、以及关掉后耳机是否仍可用。
    if (!_kWarmUpAudioPath) {
      CrashLog.mark('预热[已禁用] 不再为消爆音创建引擎音轨');
      return;
    }
    if (_disposed || _warmedUp || _warmUpInFlight) {
      CrashLog.mark('预热[跳过] disposed=$_disposed warmed=$_warmedUp '
          'inFlight=$_warmUpInFlight');
      return;
    }
    _warmUpInFlight = true;
    try {
      CrashLog.mark('预热[开始]');
      await initialize();
      if (_disposed) return;
      await _tts.setVolume(0.0);
      // 极短的一句：目的是触发引擎建 AudioTrack
      final r = await _tts.speak('嗯');
      CrashLog.mark('预热[speak返回] result=$r');
      // 给引擎足够时间把轨道真正 start()，并让"嗯"自然说完
      await Future<void>.delayed(const Duration(milliseconds: 900));
    } catch (_) {
      // 预热失败无所谓，忽略
    } finally {
      _warmUpInFlight = false;
      _warmedUp = true;
      if (!_disposed) {
        // ★★ v1.22.62 修正：**这里绝对不能调 `stop()`**
        //
        // 真机日志（2026-10-26 23:32，平板）：
        // ```
        // 23:32:29.194  预热[speak返回] result=1
        // 23:32:29.547  预热[结束]        ← 旧代码在这里 stop() 了
        // 23:32:29.949  真正播放          ← 400ms 后，又变成冷启动
        // ```
        // `stop()` 会让引擎**释放音频轨道**，于是 400ms 后真正发声时
        // 音频设备又回到冷的 —— 预热等于白做。
        //
        // 现在改成：让"嗯"以零音量**自然说完**（不 stop），
        // 引擎的轨道保持存活到真正朗读，才是真正"热"的。
        // 音量在"嗯"说完之后再恢复，用户不会听到它。
        try {
          await _tts.setVolume(1.0);
        } catch (_) {}
      }
      CrashLog.mark('预热[结束] 未 stop（保持轨道存活）');
    }
  }

  /// 若预热还在跑：立刻停掉它并把音量拉回 1.0（`speak()` 提交前调用）
  Future<void> _abortWarmUpIfNeeded() async {
    if (!_warmUpInFlight) return;
    _warmUpInFlight = false;
    _warmedUp = true;
    try {
      await _tts.stop();
    } catch (_) {}
    try {
      await _tts.setVolume(1.0);
    } catch (_) {}
  }


  /// 等引擎完成回调的上限。
  ///
  /// 比 `TtsManager.speakTimeout`（30 秒）略长：让上层先给出**可见**的
  /// 「朗读超时」失败，这里只兜「连上层都收不到」的极端情况。
  static const Duration _completionTimeout = Duration(seconds: 35);

  /// 提交被插件丢弃（返回 0）时的重投次数与间隔。
  ///
  /// 真机上「打断后紧接着的新一句」经常撞上这个丢弃（插件的 `speaking` 还没被
  /// 框架的 onStop 清掉）；重投是**重新提交并听插件的回答**，不是读状态量。
  static const int _submitAttempts = 8;
  static const Duration _submitRetryDelay = Duration(milliseconds: 150);

  /// 时长判据（路径 B）：完成回调距本次提交的合理下限。
  ///
  /// 一个汉字最短也要 ~80ms 才发得完；提交成功后几毫秒就回来的「完成」
  /// 只可能是**上一句的迟到回调**或**引擎谎报**（真机实测 238 微秒）。
  /// 口径与 PDF 侧 §4.106 的 `_minRealSpeakMs` 一致。
  static const int _minRealSpeakMs = 100;

  /// 连续丢弃假完成的次数上限：引擎若始终不回真实完成，也不能把主循环卡死。
  static const int _maxFakeCompleteDrops = 3;

  /// 本次 speak 的提交时刻（时长判据用；null = 当前没有在飞的 speak）
  DateTime? _speakIssuedAt;

  /// **作废令牌**：`stop()` / `pause()` / 新一轮 `speak()` 各自 +1。
  ///
  /// ## 为什么必须有它（v1.21.54 修的真实缺陷）
  ///
  /// [speak] 里的重投机制会在提交被丢弃时**每 150ms 重投一次、最多 8 次**
  /// （合计约 1.2 秒）。原来这个重投**不检查"这次朗读是否已经作废"** ——
  /// 于是下面这条时序会把**旧书的正文**念出来：
  ///
  /// ```
  /// t=0    书A 最后一句进入重投（提交被丢弃）
  /// t=50   用户切到书B → stop()  → _completePending() + _tts.stop()
  /// t=150  重投到点，把【A 的文本】再次交给系统 → 念出来的仍是书A
  /// ```
  ///
  /// 这正是用户报的「书A暂停 → 打开书B → 恢复却读书A」：与在哪一页、
  /// 点哪个按钮、哪本书都无关 —— 因为是**引擎自己把旧文本又送了一遍**。
  ///
  /// 修法：每次 speak 记下当时的 [_generation]，重投前比对；
  /// 不一致就**放弃本次重投并让它安静结束**（不报错、不推进游标）。
  int _generation = 0;

  /// 本次 speak 已经丢弃掉几个「假完成」
  int _fakeCompleteDrops = 0;

  @override
  Future<void> speak(String text) async {
    if (_disposed || text.trim().isEmpty) return;
    await initialize();

    // ★v1.22.62 保险①：真正开口前，若预热还在跑 → 停掉它、音量拉满。
    // 保证**首句永远是满音量**（用户明确要求，不能再出现"声音小"）。
    await _abortWarmUpIfNeeded();

    final done = Completer<void>();
    _pending = done;
    _fakeCompleteDrops = 0;
    // 本次朗读的代次：之后的 stop() / pause() / 新 speak() 都会让它失效
    final int myGeneration = ++_generation;
    int attempts = 0;

    // ① 提交：**不 await、也不把它的完成当成「读完」**。
    //
    // 为什么（真机实测根因，flutter_tts 4.0.2 android 侧）：
    //   FlutterTtsPlugin.kt `speak` 分支：
    //     if (speaking) { if (queueMode == QUEUE_FLUSH) { result.success(0); return } }
    //   FlutterTtsPlugin.kt `stop` 分支：
    //     if (speakResult != null) { speakResult!!.success(0); speakResult = null }
    //   —— 即「上一句还没收尾」或「我们自己刚 stop 过」时，这个 Future 会
    //   **立刻**以 0 返回（表示本次提交被丢弃），并不是读完。
    //   旧实现 `Future.any([done.future, _tts.speak(text)])` 与它竞速，
    //   于是把「提交即返回」当成「读完」→ 主循环疯狂推进
    //   （真机诊断：R5 = 192、R4 = 195、R2 = 0，speak 全是 ms=0 ok=true）。
    void submit() {
      // ★代次校验：这次朗读已经被 stop() / pause() / 新 speak() 作废了，
      // 就**不再提交**（否则旧书的文本会在切书之后被念出来，见 [_generation]）。
      if (myGeneration != _generation || _disposed) {
        // 安静结束：不报错（用户已完成切书，这不是失败），也不推进游标
        if (!done.isCompleted) done.complete();
        return;
      }
      attempts++;
      _speakIssuedAt = DateTime.now();
      unawaited(
        _tts.speak(text).then<void>(
          (dynamic value) {
            if (done.isCompleted) return; // 已经被 stop/pause 或完成回调放行
            if (value == 0 || value == false) {
              // 被丢弃：本次没有排上队，**不会有任何完成回调**。
              // 等一小会儿重投；重投用尽才判失败 —— 绝不把它当「读完」。
              if (attempts >= _submitAttempts) {
                done.completeError(
                  StateError('系统 TTS 未接收本次朗读（提交返回 $value，'
                      '已重投 $attempts 次）'),
                );
                return;
              }
              Future<void>.delayed(_submitRetryDelay, submit);
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!done.isCompleted) done.completeError(error, stack);
          },
        ),
      );
    }

    submit();

    // ② 完成信号**只有一个来源**：引擎的完成 / 取消 / 出错回调
    //    （`_handleFinished` → `_completePending`）。
    //    `pause()` / `stop()` 里的 `_completePending()` 也走同一条路 ——
    //    被打断时按要求「尽快完成」，不在这里区分原因（那是 TtsManager 的事）。
    try {
      await done.future.timeout(_completionTimeout);
    } on TimeoutException {
      // 兜底：引擎始终没回完成回调。放开等待者后把超时抛给上层判失败，
      // 不在这里把「超时」伪装成「读完」。
      _completePending();
      rethrow;
    } finally {
      if (identical(_pending, done)) _pending = null;
      if (!done.isCompleted) done.complete();
      _speakIssuedAt = null; // 这一拍结束了，时长判据不再适用
    }
  }

  @override
  Future<void> pause() async {
    _generation++; // 作废在飞的重投：暂停之后不该再有旧文本被提交
    _completePending(); // 唤醒上层循环，游标保持在当前单元
    try {
      await _tts.pause();
    } catch (_) {
      // 个别平台不支持暂停，忽略
    }
  }

  @override
  Future<void> stop() async {
    // ★作废在飞的重投（v1.21.54）：切书 / 停止之后，任何**旧的**文本
    // 都不能再被提交给系统 —— 否则用户会听到"读回上一本书"。
    // 只递增代次是不够的，还要让 `_tts.stop()` 把系统侧队列也清掉。
    _generation++;
    _completePending();
    try {
      await _tts.stop();
    } catch (_) {
      // 忽略停止异常
    }
  }

  @override
  void setCompletionHandler(void Function()? handler) => _onComplete = handler;

  /// 强制重绑系统 TTS（**真重置**）。
  ///
  /// 为什么需要：`speak()` 超时只说明「插件没回完成回调」，插件内部的
  /// `speaking` / `speakResult` 仍然挂着。此时无论再 speak 多少次都只是
  /// 把文本丢进一个不会回调的队列 —— 真机表现就是**同一位置重复卡满 30 秒**。
  ///
  /// `setEngine` 会让 Android 侧重走 `setEngineByPackageName`，重建
  /// `TextToSpeech` 实例，卡死的合成线程随之丢弃。这是 Dart 层唯一能做到的
  /// 「真重置」（新建 `FlutterTts()` 对象没用：原生插件是单例，状态还在）。
  ///
  /// 只在【连续两次 speak 都不回应】时由 `TtsManager` 调用，平时不要用。
  Future<void> reset() async {
    if (_disposed) throw StateError('引擎已释放');
    _generation++; // 作废在飞的重投：重置之后不该再有旧文本被提交
    _completePending();
    _pending = null;
    _fakeCompleteDrops = 0;
    _speakIssuedAt = null;
    _initialized = false;
    try {
      await _tts.stop(); // 先清系统侧队列与 speakResult
    } catch (_) {
      // 停不掉也要继续重绑
    }
    // 重绑需要一个**具体的包名**：空串交给 `setEngineByPackageName("")` 在
    // 部分 ROM 上会直接 onInit 失败（引擎从此彻底没声）。用户没选过引擎时
    // 先问一次系统默认包名，拿不到就跳过重绑（只做 stop + 重新 initialize）。
    String target = _enginePackage;
    if (target.isEmpty) {
      try {
        final dynamic def = await _tts.getDefaultEngine;
        if (def is String) target = def.trim();
      } catch (_) {
        // 拿不到默认引擎名：跳过重绑
      }
    }
    if (target.isNotEmpty) await _tts.setEngine(target);
    await initialize(); // 重新注册完成 / 取消 / 出错回调
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _onComplete = null;
    await stop();
  }
}

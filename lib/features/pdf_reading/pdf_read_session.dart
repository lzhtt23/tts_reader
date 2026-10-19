import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../services/crash_log.dart';
import '../../services/speech_diagnostics.dart';
import '../../services/storage_service.dart';
import '../../tts/audio_session_source.dart';
import '../../tts/media_interruption.dart';
import '../../tts/tts_audio_handler.dart';
import '../../tts/tts_manager.dart';
import 'pdf_page_layer.dart';
import 'pdf_text_layer.dart';

/// 「同一本 PDF 重进时，要不要终止当前朗读」
///
/// 单独抽出来是为了能离线单测 —— 这是真机 bug 的唯一边界条件
/// （用户 2026-10-19：PDF 正在朗读，点文档卡片回到 PDF 页，朗读被打断）。
///
/// 判据：
/// * 没在播 → 不用终止
/// * 正在**借声给我**（PDF 就是这么读的）→ 更不能终止，那是自己的声音
/// * 在播的**就是这本** → 不用终止
/// * 其余（在播别的书）→ 终止（换歌语义）
bool shouldTerminateOnReopen({
  required bool playing,
  required bool borrowed,
  required String? activeDocumentId,
  required String documentId,
}) {
  if (!playing) return false;
  if (borrowed) return false;
  if (activeDocumentId == documentId) return false;
  return true;
}

/// PDF 朗读的 UI 监听者（阅读页实现它）。
///
/// 会话只通过这几个回调通知界面，**不持有任何 Widget**。
/// 界面 dispose 后 [PdfReadSession.detach] 会把它摘掉，回调自然不再发出 ——
/// 所以不会去动已经销毁的 PageController。
abstract class PdfReadSessionListener {
  /// 朗读位置换到某一句了 → 更新高亮
  void onSentenceChanged(PdfSentenceRef ref);

  /// 该把页面翻到某一页了（0 起）
  void onPageShouldTurn(int pageIndex);

  /// 整篇读完了（或没有下一句了）→ 收起控制栏
  void onFinished();

  /// 播放状态变了（播放 / 暂停 / 停止）→ 刷新控制栏按钮
  void onPlaybackStateChanged();
}

/// 通知栏动作的出口：生产实现直接转给 `TtsAudioHandler`，测试实现只记录。
///
/// 之所以要有这层，是因为 `audioHandler` 是全局可空变量、且 `TtsAudioHandler`
/// 依赖 audio_service —— 纯 Dart 单测里两个都拿不到。有了它，
/// 「PDF 在放时打开 TXT → PDF 停」这条**换书终止**就能在单测里钉死。
class PdfSessionAudioBridge {
  const PdfSessionAudioBridge();

  factory PdfSessionAudioBridge.real() => const PdfSessionAudioBridge();

  /// 把自己设为通知栏当前来源
  void claim(PdfReadSession session) => audioHandler?.activate(session);

  /// 释放来源（换书 / 通知栏关闭）
  void release(PdfReadSession session) => audioHandler?.release(session);

  /// 如果自己就是当前来源，推一次状态
  void notifyIfActive(PdfReadSession session) {
    final handler = audioHandler;
    if (handler == null) return;
    if (identical(handler.activeSource, session)) handler.notifyFromSource();
  }
}

/// 仅供测试：记录调用的假桥
@visibleForTesting
class RecordingAudioBridge extends PdfSessionAudioBridge {
  RecordingAudioBridge();

  final List<String> calls = <String>[];
  bool isActive = false;

  @override
  void claim(PdfReadSession session) {
    calls.add('claim');
    isActive = true;
  }

  @override
  void release(PdfReadSession session) {
    calls.add('release');
    isActive = false;
  }

  @override
  void notifyIfActive(PdfReadSession session) {
    if (!isActive) return;
    calls.add('notify');
  }
}

///
/// ## 为什么不能放在 Widget State 里
///
/// 需求：「退出阅读页后朗读继续」。推进循环如果住在阅读页的 State 里，
/// 页面一 dispose（`mounted == false`）递归就断了，读一句就停。
/// 所以循环住在**单例**里，页面只是「挂上去看」。
///
/// ## 为什么另起一个单例而不是塞进 TtsManager
///
/// 两者是**平行**的会话，不是从属关系：
///
/// | | TtsManager | PdfReadSession |
/// | --- | --- | --- |
/// | 位置 | 结构化文档游标 `(ch, p, s)` | `PdfSentenceRef` + 文本层 |
/// | 数据源 | `StructuredDocument` | `PdfPageTextLayer`（逐字符盒） |
/// | 通知栏进度 | 按**句** | 按**页** |
/// | 能不能拖进度条 | 能 | 不能（`canSeek = false`） |
///
/// 塞在一起会让 TtsManager 同时长两套坐标系，正是要避免的。
/// 两者靠 [AudioSessionSource] 接口在通知栏那一层汇合。
///
/// ## 状态尽量少
///
/// 只持有：documentId / documentTitle / docRef / 文本层缓存 / current /
/// token / playing / listener。**不读 `TtsManager.cursor`**，也不碰 UI 状态。
class PdfReadSession extends ChangeNotifier implements AudioSessionSource {
  PdfReadSession._();

  static final PdfReadSession instance = PdfReadSession._();

  /// 文本层缓存上限：319 页的书全缓存会有几十 MB。
  /// 只留最近用到的若干页；跨页合并最多看下一页，所以不用留太多。
  static const int _maxCachedLayers = 8;

  /// 「最短合理朗读时长」判据的阈值（§4.106）。
  ///
  /// 一个汉字最短也要 ~80ms 才发得完，取 100ms 留安全余量。
  /// 收到比这更短的"读完"信号一律视为**假完成**（真机实测最短 0ms），
  /// 丢弃、不推进。见 `_readLoop` 里那段说明。
  static const int _minRealSpeakMs = 100;

  /// 丢弃假完成后重新等待前的让出时长（避免紧凑自旋）。
  static const Duration _fakeDoneGrace = Duration(milliseconds: 80);

  /// 假完成最多丢弃几次。
  ///
  /// **必须有上限**：真机上假完成可能连着来（实测 18 处），但一旦没有上限，
  /// 「会话已结束 → 立刻返回 → 总时长不够」就会变成无限丢弃，朗读再也推不动。
  /// 重试用尽后放行 —— 宁可偶发多推一句，也不能把朗读卡死。
  static const int _maxFakeDoneRetries = 3;

  // ---------------- 会话状态 ----------------

  String? _documentId;
  String _documentTitle = '';

  /// 打开的 PDF（用于按页抽文本层）
  PdfDocumentRef? _docRef;

  /// 页数（PDF 一章即一页，HANDOFF §4.28）
  int _pageCount = 0;

  /// 按页抽文本层的方式：默认从 [_docRef] 打开文档再抽。
  ///
  /// **可替换**是为了让推进循环能在单测里跑起来：真实 PDF 引擎跑不进
  /// 纯 Dart 测试，而「自动连读 / 跨页推进 / 点句打断」这些逻辑又必须
  /// 被钉死（它们正是最容易错的部分）。测试里换成一个返回构造好的
  /// 文本层的假实现即可（见 `test/pdf_read_session_test.dart`）。
  Future<PdfPageTextLayer?> Function(int pageIndex)? _layerLoader;

  /// 文本层缓存：页下标(0 起) → 文本层
  final Map<int, PdfPageTextLayer> _layers = <int, PdfPageTextLayer>{};

  /// 最近访问顺序（配合 [_maxCachedLayers] 做淘汰）
  final List<int> _layerOrder = <int>[];

  /// 正在加载的页：页下标 → 这一次加载的 Future
  ///
  /// 存 Future 而不是存个标记，是为了让**同一页的并发请求共享同一次加载**
  /// （原来用 Set<int> + 「正在加载就返回 null」，会让后到的调用方误判成
  /// 「这页没有文字」）。
  final Map<int, Future<PdfPageTextLayer?>> _loading =
      <int, Future<PdfPageTextLayer?>>{};

  /// 没有文字的页（扫描件）——别再反复试
  final Set<int> _emptyPages = <int>{};

  /// 当前朗读位置（**自持**，唯一真相）
  PdfSentenceRef? _current;

  /// 所有 `_current` 赋值的**唯一入口**：改值 + 记下落盘目标。
  ///
  /// ⚠️ §4.100 任务 D：落盘必须是独立记录，**不能**靠「让 current 活过
  /// clear()」实现 —— `clear()` 是换书终止 / 方块键的语义（§4.89），
  /// 保留 current 会把「换一本读时上一本还在读」的终止逻辑带坏。
  /// 所以位置记在 StorageService（按 documentId），与生命周期解耦。
  ///
  /// 写频：自动推进每句都换游标，逐句同步写 SharedPreferences 太浪费 ——
  /// 显式动作（点句 / 目录跳转）立即写，推进循环走防抖（停 1.5 秒再写），
  /// 停声 / 结束 / 清空前再强制刷新一次，保证「结束朗读后重进」拿到的是
  /// 最后位置而不是过期快照。
  void _setCurrent(PdfSentenceRef? next, {bool immediate = false}) {
    _current = next;
    // 位置一变，「跨页句终点」就作废：它只对刚读的那一句有效。
    // （写入方是 `_readLoop` 算出 `whole` 之后的 [_noteSpanEnd]。）
    if (_currentSpanEnd != null &&
        (next == null ||
            _currentSpanEnd!.pageIndex != next.pageIndex ||
            _currentSpanEnd!.sentenceIndex != next.sentenceIndex)) {
      _currentSpanEnd = null;
    }
    if (next == null) {
      // 位置被清空：防抖窗口里的待写值已经作废，必须撤掉，
      // 否则定时器稍后会把「上一个位置」写给一个已经不属于本会话的文档
      _flushSpotTimer?.cancel();
      _flushSpotTimer = null;
      _pendingSpot = null;
      return;
    }
    if (immediate) {
      _flushSpotTimer?.cancel();
      _flushSpotTimer = null;
      _pendingSpot = next;
      _enqueueSpotWrite();
      return;
    }
    _pendingSpot = next;
    _flushSpotTimer?.cancel();
    _flushSpotTimer = Timer(const Duration(milliseconds: 1500), () {
      _flushSpotTimer = null;
      _enqueueSpotWrite();
    });
  }

  PdfSentenceRef? _pendingSpot;
  Timer? _flushSpotTimer;

  /// 位置写盘的**拍号**（v1.21.43 · P0-1）
  ///
  /// ⚠️ **在"发起写"的那一刻分配**（[_enqueueSpotWrite]），不是在真正落盘时取。
  /// 原因（本用例当场抓到）：两次并发写如果都在 `_writeSpotNow()` 里取号，
  /// 而 `_writeSpotNow` 是**排队后**才执行的 —— 两次会读到**同一个号**（28 → 28），
  /// 拍号完全失去意义。分配必须在同步路径上完成。
  ///
  /// 落盘时才检查「我这个号还是不是最新」：不是就说明期间又有更新的写，
  /// 本次结果作废并如实记日志。
  int _spotSeq = 0;

  /// 已经落盘的最大拍号 —— 旧拍（号更小）永远不许再改写盘上的值
  int _lastWrittenSeq = 0;

  /// 写盘**串行泵**（v1.21.43 · P0-1）
  ///
  /// ## ⚠️ 为什么不是 `Future.then` 链（踩过的坑，别改回去）
  ///
  /// 第一版写成 `_chain = _chain.then((_) => _write())`。在真机上没问题，
  /// 但**在 `flutter_test` 的假异步环境里整个会挂死**：链式续延是微任务，
  /// 而 `testWidgets` 里那些微任务不会自己推进，于是 `await _chain` 永远不返回
  /// —— 实测 `control_bar_dispatch_diag_test` 直接冻结（最小复现：
  /// `resetForTest → open → ensureLayer(0)` 就卡死）。旧写法（直接 await）9ms 就过。
  ///
  /// 所以改成**命令式泵**：一个普通循环，只要"下一次写请求的号 > 已落盘号就不停"。
  /// 顺序保证不变（每次从 `_pendingSpot` 取当前值），且完全不依赖微任务调度。
  int _spotPumped = 0;

  /// 泵是否正在跑（防重入）。**刻意不用 `Future` 串联** —— 见 [_pumpSpotWrites] 的说明。
  bool _spotPumping = false;

  /// 把一次「写待写位置」排进串行泵
  ///
  /// 只负责**发号**（发起即分配，见 [_spotSeq] 的说明）并**启动泵**；
  /// 调用方要强保证时用 [_flushSpot]。
  ///
  /// ⚠️ 必须在这里就启动泵，不能只发号：`_setCurrent(immediate: true)` 的语义是
  /// 「**立刻**落盘」（点句 / 目录跳转 / 起读都靠它），只发号不跑就等于把这次写
  /// 拖到"下一次 flush"—— 实测会让「点句后位置已在盘上」的既有用例全部变红。
  void _enqueueSpotWrite() {
    _spotSeq++;
    _startSpotPump();
  }

  /// 顺序把"已发号但还没落盘"的写做完
  ///
  /// ## ⚠️ 为什么是「布尔防重入 + while」而不是 `Future.then` 链
  ///
  /// 第一版写成 `_pump = _pump.then((_) => 循环())`，然后 `await _pump`。
  /// 真机没问题，但**在 `flutter_test` 的假异步环境里会整个挂死**：
  /// 链式续延是微任务，`testWidgets` 里那些微任务不自推进，`await` 永不返回。
  /// 实测症状：`control_bar_dispatch_diag_test` 冻结、最小复现
  /// （`resetForTest → open → ensureLayer(0)`）直接卡死；而"直接 await 落盘"
  /// 的旧写法 9ms 就过。
  ///
  /// 现在：并发时**只有一个泵在跑**，它按 `_spotPumped < _spotSeq` 一口气把
  /// 该写的都写完（包括它启动之后新发号的）。落盘顺序由**取号顺序**保证，
  /// [_writeSpotNow] 里的 `seq < _lastWrittenSeq` 再挡一道过期写。
  ///
  /// 返回值只表示"这一轮泵跑完了"；并发调用者在最坏情况下早一点返回，
  /// 位置最终一致（下一次 flush 会把剩下的写完）。
  Future<void> _pumpSpotWrites() async {
    if (_spotPumping) return; // 已经有人在泵：它会把新发号的也做完
    _spotPumping = true;
    try {
      while (_spotPumped < _spotSeq) {
        final seq = ++_spotPumped;
        await _writeSpotNow(seq);
      }
    } finally {
      _spotPumping = false;
    }
  }

  /// 后台启动一次泵（不 await；`_flushSpot` 才需要等）
  void _startSpotPump() {
    unawaited(_pumpSpotWrites());
  }

  /// 把待写位置真正落盘（失败不影响朗读）
  ///
  /// [seq] 是发起时分配的拍号。⚠️ 本方法**只应经 [_enqueueSpotWrite] 调用**，
  /// 不要直接 `unawaited` —— 那会绕过拍号与串行链，重新引入乱序写。
  Future<void> _writeSpotNow(int seq) async {
    final ref = _pendingSpot;
    final doc = _documentId;
    _pendingSpot = null;
    if (ref == null || doc == null) return;
    // 排到我时已经有更新的写落过盘 → 我这份是过期数据，直接丢弃
    if (seq < _lastWrittenSeq) {
      CrashLog.mark('位置[PDF写盘] 丢弃过期写 seq=$seq 现=$_lastWrittenSeq');
      return;
    }
    try {
      await StorageService.instance.setPdfReadingSpot(
        doc,
        pageIndex: ref.pageIndex,
        sentenceIndex: ref.sentenceIndex,
      );
      // 位置记忆埋点 F（PDF 写盘）：真正落盘的位置
      // v1.21.19 补 `当前=$_current`：用来抓「写的是不是过期 ref」
      // （真机日志里出现过 10/13 之后又被 10/4 覆盖）
      CrashLog.mark('位置[PDF写盘] seq=$seq docId=$doc '
          'page=${ref.pageIndex} sentence=${ref.sentenceIndex} '
          '当前=${_current?.pageIndex}/${_current?.sentenceIndex}');
      // 这一拍成功落盘 → 记下来，让更早的拍号（若有）不再改写它
      if (seq > _lastWrittenSeq) _lastWrittenSeq = seq;
    } catch (_) {
      // 落盘失败：下次动作还会再写，不影响朗读
    }
  }

  /// 立即刷新待写位置（停声 / 暂停 / 结束 / 退出前调用）
  ///
  /// ⚠️ 也走 [_enqueueSpotWrite]：与定时器/即时写共用同一条串行链，
  /// 否则「flush 与即时写」又会互相乱序。
  Future<void> _flushSpot() async {
    _flushSpotTimer?.cancel();
    _flushSpotTimer = null;
    _enqueueSpotWrite();
    await _pumpSpotWrites(); // 等这一批顺序做完（调用方要「已经落盘」的强保证）
  }

  /// 打断令牌：新的一次 startAt / 换书 会让旧推进循环立刻失效
  int _token = 0;

  bool _playing = false;
  bool _paused = false;

  PdfReadSessionListener? _listener;

  /// 一次会话是否已经跑完（用于 onFinished 只报一次）
  bool _finished = false;

  // ---------------- 对外只读状态 ----------------

  /// 当前朗读位置
  PdfSentenceRef? get current => _current;

  /// **当前句若跨页，它在下一页的终点**（v1.21.43 · 模型 A 风险②）
  ///
  /// ## 为什么需要它
  ///
  /// 一句从第 7 页末延到第 8 页头时，会话只把**起点**（第 7 页那一句）记进
  /// [_current]；而 UI 侧的高亮是"按 `ref` 判页 + 取该页那句的 rect"——
  /// 于是**只有起始页会画高亮**（真机反馈：「跨页句只框在上一页」）。
  ///
  /// 跨页信息在 `_readLoop` 里由 `buildCrossPageSentence` 算出
  /// （`whole.endPage` / `whole.endSentence`），原来**只用于 `_advancePast`
  /// 的"从终点之后继续"**，没有传给 UI。这里把它留下来，
  /// 让页面侧能给**结束页**也画上高亮。
  ///
  /// 生命周期：由 [_noteSpanEnd] 写入，[_setCurrent] 在"当前句变了"时清空，
  /// `clear()` / 换书时随 `_current = null` 一起清。
  PdfSentenceRef? get currentSpanEnd => _currentSpanEnd;

  PdfSentenceRef? _currentSpanEnd;

  /// 记下"刚读的这一句跨到了下一页的哪一句"（`_readLoop` 专用）
  void _noteSpanEnd(int startPageIndex, CrossPageSentence whole) {
    if (!whole.spansPages) {
      _currentSpanEnd = null;
      return;
    }
    _currentSpanEnd = PdfSentenceRef(
      pageIndex: whole.endPage - 1, // endPage 是 1 起，内部统一 0 起
      sentenceIndex: whole.endSentence,
      text: '',
    );
  }

  String? get documentId => _documentId;

  /// 会话键（v1.21.43 · P0-1 埋点用）
  ///
  /// `pdf:<文档id>#<令牌>` —— 换书 / 重新起读都会让它变化。
  /// 用途：AF 日志里一眼看出「这条记录说的是哪本书、哪一拍」。
  /// （P1-1 会给它派上真正的用场：通知栏命令的过期校验。）
  String get sessionKey => 'pdf:${_documentId ?? '-'}#$_token';

  /// 打断令牌（埋点用，只读）
  int get tokenForDiag => _token;

  /// 位置写盘拍号（埋点用，只读）
  int get spotSeqForDiag => _spotSeq;

  @override
  String get documentTitle => _documentTitle;
  int get pageCount => _pageCount;

  /// 是否有活跃的 PDF 会话（控制栏显隐、通知栏用）
  bool get isActive => _documentId != null && _pageCount > 0;

  /// **真的有播放在进行**（在播或暂停）—— 控制栏挑「谁是当前活跃源」要用这个
  ///
  /// ⚠️ §4.103：**不要**拿 [isActive] 当「活跃会话」的判据。`isActive` 只看
  /// 「会话存在」（`_documentId != null && _pageCount > 0`），而 `stopSound()`
  /// 为了「换歌要记住进度」**故意保留会话** —— 于是「PDF 被 TXT 顶掉而停播」
  /// 之后 `isActive` 仍然为真，控制栏就会一直显示、并且按钮绑在**已经停掉的**
  /// 那本 PDF 上（用户报的「控制栏绑错文档」）。
  ///
  /// 判据拆开之后语义才自洽：
  ///   · 控制栏**显示**看「是不是在播」（本 getter）；
  ///   · 方块键**清理**看「会话在不在」（[isActive]，用户按方块=彻底终止）。
  bool get isPlaybackActive => isActive && (_playing || _paused);

  /// 正在出声
  bool get isPlaying => _playing;

  bool get isPaused => _paused;

  /// 整篇是否已读完（到末句了）
  bool get isFinished => _finished;

  PdfReadSessionListener? get listener => _listener;

  // ---------------- 文本层 ----------------

  /// 取某页的文本层（缓存里没有返回 null；不会触发加载）
  PdfPageTextLayer? layerOf(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= _pageCount) return null;
    return _layers[pageIndex];
  }

  /// 取某页的文本层，没有就现加载。
  ///
  /// **并发安全**：同一页**已经在加载中**时，后来者会**等这一次的结果**，
  /// 而不是拿到 null。
  ///
  /// > ⚠️ v1.21.2 修的真实缺陷：原来这里写的是「正在加载就 return null」。
  /// > 调用方有两类 —— 列表项**预取**（每建出一页就 `unawaited(ensureLayer)`）
  /// > 和**用户点句**（命中测试要先拿到层）。两者撞在一起时，点句那一路会
  /// > 拿到 null → 判定「这页没有文字」→ **点了没反应**（实测在真实 PDF 的
  /// > 正文页上复现：图层已建出来、`textLayer` 却还是 null）。
  /// > 「正在加载」不是「没有」，这两种情况必须分开表达。
  Future<PdfPageTextLayer?> ensureLayer(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= _pageCount) {
      return Future<PdfPageTextLayer?>.value();
    }
    final cached = _layers[pageIndex];
    if (cached != null) return Future<PdfPageTextLayer?>.value(cached);
    if (_emptyPages.contains(pageIndex)) {
      return Future<PdfPageTextLayer?>.value();
    }
    // 已经在加载：等那一次，别给调用方一个假的「没有」
    final inFlight = _loading[pageIndex];
    if (inFlight != null) return inFlight;

    final future = _loadLayer(pageIndex);
    _loading[pageIndex] = future;
    return future.whenComplete(() => _loading.remove(pageIndex));
  }

  Future<PdfPageTextLayer?> _loadLayer(int pageIndex) async {
    final token = _documentId;
    try {
      final layer = await _loadLayerRaw(pageIndex);
      // 加载期间可能换书了：换书后页数对不上就别塞进缓存
      if (_documentId == null || _documentId != token) return null;
      if (layer == null || layer.isEmpty) {
        _markPageEmpty(pageIndex);
        return null;
      }
      _cacheLayer(pageIndex, layer);
      return layer;
    } catch (e) {
      CrashLog.mark('PDF 会话抽层失败（第 ${pageIndex + 1} 页）：$e');
      _markPageEmpty(pageIndex);
      return null;
    }
  }

  /// 真正去取文本层：测试可换掉 [_layerLoader]
  Future<PdfPageTextLayer?> _loadLayerRaw(int pageIndex) async {
    final custom = _layerLoader;
    if (custom != null) return custom(pageIndex);
    final ref = _docRef;
    if (ref == null) return null;
    // `resolveListenable().document` 是 pdfrx 的共享实例：
    // 直接 `loadDocument()` 每次都会重新加载整份文件、内存翻倍。
    final doc = ref.resolveListenable().document;
    if (doc == null) return null;
    if (pageIndex >= doc.pages.length) return null;
    return loadTextLayer(doc.pages[pageIndex]);
  }

  void _cacheLayer(int pageIndex, PdfPageTextLayer layer) {
    _layers[pageIndex] = layer;
    _layerOrder.remove(pageIndex);
    _layerOrder.add(pageIndex);
    // 淘汰最久没用的（当前页与下一页一定要留着）
    while (_layerOrder.length > _maxCachedLayers) {
      final victim = _layerOrder.firstWhere(
        (p) => p != _current?.pageIndex && p != (_current?.pageIndex ?? 0) + 1,
        orElse: () => _layerOrder.first,
      );
      _layerOrder.remove(victim);
      _layers.remove(victim);
    }
    // ⚠️ 必须通知：文本层是异步抽出来的，界面靠这个信号才知道「这一页现在能点了」。
    // 少了它，凡是「首次 build 时层还没进缓存」的页会**永远显示成没有文字层**，
    // 于是点句没反应（实测：缓存里已有 [0,1,2] 三层，组件那侧还是「无层」）。
    notifyListeners();
  }

  /// 某页是否是「没有文字」（扫描件）
  bool isPageEmpty(int pageIndex) => _emptyPages.contains(pageIndex);

  /// 判定某页没有文字（扫描件）→ 也要通知，界面好把提示挂出来
  void _markPageEmpty(int pageIndex) {
    if (_emptyPages.add(pageIndex)) notifyListeners();
  }

  // ---------------- 会话生命周期 ----------------

  /// **切断"仍属于旧文档"的异步尾巴**（v1.21.43 · P0-3）
  ///
  /// ## 要解决的污染（两本书的位置互相写坏）
  ///
  /// 换书时 `_pendingSpot` 可能**还带着旧书的 ref**（防抖窗口里、或刚 flush 完
  /// 又被 `_setCurrent` 塞进来）。若它在新 `_documentId` 下被写出去，旧书的位置
  /// 就被记进了**新书的记录**里 —— 用户表现是「切过去那本书位置莫名其妙」。
  ///
  /// 所以换书顺序必须是：**先撤掉旧书的待写值 + 让在飞的写全部作废**，
  /// 再覆盖 `_documentId`。
  ///
  /// ## ⚠️ 诚实说明：这是**防御性不变量**，不是可复现 bug 的修复
  ///
  /// 实测（v1.21.43）：把本方法从 [open] 里去掉，3 条 P0-3 用例**仍然全绿**。
  /// 原因是 [open] 里原有的 `await _flushSpot()` 已经把待写值排空并让它以
  /// **旧** id 落盘了 —— 那条路本来就没漏。
  ///
  /// 那为什么还留着：它把"换书必须让旧书的在飞写全部作废"变成**显式保证**，
  /// 而不是依赖"flush 恰好先跑到"。挡住两类真会发生、但没被测试稳定复现的情形：
  /// · 定时器在 `_flushSpot()` 的 await **之后**才醒（此刻 `_pendingSpot` 可能
  ///   已被 `_setCurrent` 重新塞入）；
  /// · `_setCurrent` 与"排入队列的写"之间插进了换书。
  ///
  /// 另外 `_writeSpotNow` **在入队那一刻就快照 `_documentId`**，所以队列里的写
  /// 不会用错 id —— 两条合起来才是完整的保证。
  ///
  /// ⚠️ 这个方法**刻意不落盘**：换书前该落的位置由 [stopSound] / [clear] /
  /// 显式 `_flushSpot()` 负责，这里只做"切断"。也**不清 `_current`**（那是 [clear] 的语义）。
  void _cancelOldDocumentWrites() {
    // ① 撤掉防抖定时器：它醒来时会拿 `_documentId`（已是新书）去写旧 ref
    _flushSpotTimer?.cancel();
    _flushSpotTimer = null;
    // ② 待写值作废：它属于旧书，且已经没机会以旧书的 id 写出去了
    _pendingSpot = null;
    // ③ 让**已经在飞的**写全部作废：发号跳到新高度，任何比它小的写落盘时
    //    都会被 [_writeSpotNow] 的 `seq < _lastWrittenSeq` 挡掉
    _lastWrittenSeq = ++_spotSeq;
    // ④ 泵的游标也跟上：否则下一次泵会从旧的 _spotPumped 开始补做早已作废的写
    _spotPumped = _spotSeq;
  }

  /// 打开一本书（进入 PDF 阅读页时调用）
  ///
  /// **同一本书重进时保留位置**：`documentId` 一样就不清 `_current`，
  /// 这样「退出阅读页 → 再进来」能接着读（需求：退出后朗读继续）。
  Future<void> open({
    required String documentId,
    required String title,
    PdfDocumentRef? docRef,
    required int pageCount,
    Future<PdfPageTextLayer?> Function(int pageIndex)? layerLoader,
  }) async {
    _layerLoader = layerLoader;
    if (docRef != null) _docRef = docRef;
    if (_documentId == documentId && _pageCount == pageCount) {
      // 同一本书重进：**保留 _current**，这样「退出阅读页 → 再进来」能接着读。
      // 判据只用 id + 页数 —— 不要把 docRef 也算进去：测试里只给 layerLoader 时
      // docRef 是 null，算进去会让幂等判断失效（位置被清掉）。
      //
      // ⚠️ v1.21.55 回退过一次，v1.21.58 重新加回（条件更窄），原因见下。
      //
      // 用户反馈（2026-10-17）：
      // > 「从上一本书，换到 pdf 时，用耳机控制启停控制的还是上一本书」
      //
      // 场景：EPUB 暂停着（有会话）→ 用户切到 PDF 阅读页（同一本，走本早返回）
      // → `TtsAudioHandler` 的来源**仍是 tts-manager**（它还有会话，只是暂停）
      // → 按耳机 → `playFromCursor()` 继续读 **EPUB**。
      //
      // 所以「用户打开这本 PDF 页」这一拍必须把来源收回来。
      //
      // ## 为什么这次不会重演 v1.21.55 的事故
      //
      // ⚠️ v1.21.59：**这里不再抢音频来源**（[_claimAudioFromTtsIfIdle] 已停用）。
      //
      // 前几版在这里（以及换书路径的末尾）抢来源，与新加的「按前台文档派发」
      // 形成**两套并存机制**：一边靠改 source 表达"用户在看哪本"，
      // 一边靠 `isForeground` 派发。两者会互相打架 ——
      // 抢了来源，另一本文档会被 onStop 打断；不抢，又怕按播放派错。
      //
      // 现在只保留一套：**打开页面绝不改来源**，派发一律在
      // `TtsAudioHandler.play()` 里按 [isForeground] 决定。
      //
      // ## ★v1.21.64：但「终止上一本的朗读」不能省
      //
      // 真机（2026-10-17 16:16）：
      // ```
      // 16:16:39  开始朗读：起于 21/48/3        ← EPUB 在读
      // 16:16:42  前台[PDF]=true                 ← 用户切到了 PDF
      //           （没有任何终止日志）            ← EPUB **还在读**
      // 16:16:47  用户只好手动按暂停才停住
      // ```
      // 用户要求：「进入别的文档时当前朗读停止（记住位置），
      // 且当前文档的控制不受上一个影响」—— 这正是 §4.100 任务 E 的换歌语义。
      //
      // ⚠️ 「终止朗读」和「改来源」是两回事：
      //   · `terminateForDocumentSwitch` 会停上一本、把它位置写回盘（换歌语义）；
      //   · 来源（通知栏派发给谁）仍由前台派发决定，这里**不主动抢**。
      // 之前把两者一起删掉，才导致"切过去了但还在念上一本"。
      // ⚠️ v1.22.16：**只终止"别人的"朗读**
      //
      // 真机（用户 2026-10-19）：PDF 正在文档库里朗读，点文档卡片回到 PDF 页，
      // 朗读被打断。原因就是下面这句 `if (TtsManager.instance.playing)`：
      // PDF 是**借 TtsManager 的声音**读的，此时 `playing == true`，
      // 于是重进自己的页面反而把自己终止了。
      //
      // 判据换成：正在播 **且** 不是"借声给我" **且** 播的不是这本 —— 才终止。
      if (shouldTerminateOnReopen(
        playing: TtsManager.instance.playing,
        borrowed: TtsManager.instance.isBorrowedForOther,
        activeDocumentId: TtsManager.instance.activeDocumentId,
        documentId: documentId,
      )) {
        TtsManager.instance.terminateForDocumentSwitch(
          nextDocumentId: documentId,
        );
      }
      return;
    }
    // 换书：彻底清（旧的推进循环靠 token 失效）
    // ⚠️ 顺序要紧：**先把旧书还挂在防抖窗口里的位置刷盘**，再覆盖 _documentId。
    // 反过来写会让旧书的待写值写到新书的 id 上（两本书的位置互相污染）。
    await _flushSpot();
    // ⚠️ v1.21.43（P0-3）：flush 之后**还要切断旧书的异步尾巴** ——
    // flush 只处理"此刻挂着的待写值"，不处理"定时器稍后再来"与"已在飞的写"。
    _cancelOldDocumentWrites();
    // ⚠️ §4.100 任务 E：开新 PDF 会话 = 跨文档切换的触发点，必须**终止上一本**。
    // 这里要处理的是「上一个是 TXT/EPUB」那一半 —— 单靠 `TtsAudioHandler.activate()`
    // 的跨源短路**不够**：
    //   · 它只在 `audioHandler != null` 时才走到（App 启动后才是），
    //   · 而且它按 `sourceId` 判等，TXT→TXT 换书根本不会触发 `onStop()`。
    // 所以跨文档终止要在「新会话被创建」这一处显式做，别寄望于 activate()。
    // 传 nextDocumentId 是为了让 TtsManager 自己判断「是不是真的换了书」——
    // 同一本书重进时它什么都不做（§4.60），不会打断自己。
    // 注意传的是**本会话自己的** documentId：对 TtsManager 而言，
    // 「新文档」就是当前这个 PDF，两边不是同一个 id 才需要终止。
    TtsManager.instance.terminateForDocumentSwitch(nextDocumentId: documentId);
    _token++;
    _documentId = documentId;
    _documentTitle = title;
    _pageCount = pageCount;
    _layers.clear();
    _layerOrder.clear();
    _emptyPages.clear();
    _current = null; // 换书：会话位置归零（旧书的位置已按 documentId 落盘）
    _playing = false;
    _paused = false;
    _finished = false;
    // ⚠️ §4.100 任务 D 症状③：「结束朗读（clear）后重进要回到上次位置」——
    // 位置不能靠让 current 活过 clear()（会带坏换书终止，§4.89），
    // 而是从按 documentId 落盘的独立记录里恢复。恢复只填 current，
    // 不自动开播（用户要的是「定位」而不是「重播」）。
    //
    // ⚠️ 句下标必须**校验后再用**：分句规则会变（§4.100 任务 B 改了分行，
    // 同页句子数量与顺序都会变），旧的 sentenceIndex 直接拿来用可能指错句
    // 甚至越界。等这一页的层抽出来后用 sentenceRefAt 校验，取不到就退回
    // 该页第 0 句 —— 定位到页永远比定位到错的句子好。
    final spot = StorageService.instance.pdfReadingSpot(documentId);
    if (spot != null && spot.pageIndex < pageCount) {
      final layer = await ensureLayer(spot.pageIndex);
      final restored = sentenceRefAt(
        spot.pageIndex,
        layer != null && spot.sentenceIndex < layer.sentences.length
            ? spot.sentenceIndex
            : 0,
        layer,
      );
      _current = restored ??
          PdfSentenceRef(pageIndex: spot.pageIndex, sentenceIndex: 0, text: '');
    }
    // 位置记忆埋点 E（PDF 恢复）：落盘记录 + 实际落定的句
    CrashLog.mark('位置[PDF恢复] docId=$documentId '
        '记录=$spot 落定=${_current?.pageIndex}/${_current?.sentenceIndex} '
        '页数=$pageCount');

    // ⚠️ v1.21.57 记录：这里**不要**主动 `_claimAudio()`。
    //
    // 曾想用它修「打开 PDF 后按播放没反应」（来源停在已被终止、
    // `hasSession=false` 的 tts-manager 上）。实测证明**在 open() 里抢来源
    // 会引发连锁副作用**：`activate()` 会给旧来源发 `onStop()`，
    // 而 `PdfReadSession.onStop()` 内部会 `await TtsManager.stop()`；
    // 等来源随后再切回 TTS 时，那次 stop 恰好把刚启动的朗读停掉
    // （用例 `★重开同一本 PDF 不得抢走 EPUB 正在读的音频` 因此变红）。
    //
    // v1.21.59：**不再在这里抢音频来源**（v1.21.55 / v1.21.57 / v1.21.58
    // 反复在这里栽跟头：抢了就把另一本文档的朗读搞坏）。
    //
    // 现在的做法：`open()` 只登记「PDF 阅读页是前台的」，真正的派发在
    // `TtsAudioHandler.play()` 里按**前台文档**决定 —— 详见 [setForeground]。
    // 「打开一个页面」不再产生任何音频副作用。
    notifyListeners();
  }

  /// PDF 阅读页是不是**当前前台**（用户正在看这一本）
  ///
  /// ## 为什么引入这个概念（v1.21.59）
  ///
  /// 「切书后按耳机控制错了书」这一类问题反复出现，根因是过去一直靠
  /// **抢音频来源**来表达"用户在看哪本"：
  ///   · 在 `open()` 里抢 → 页面重建就抢，把正在读的书停掉（v1.21.55 事故）；
  ///   · 不抢 → 来源留在上一本书上，按耳机还在读旧书（用户 2026-10-17 反馈）。
  /// 两头都不对，因为「用户在看哪本」和「音频来源停在哪」本来就不是一回事。
  ///
  /// 现在把它显式化：阅读页在 `initState` 里标前台、在 `dispose` 里清掉；
  /// `TtsAudioHandler.play()` 按这个标记派发。**不依赖、也不改动当前的来源**。
  bool get isForeground => _foreground;
  bool _foreground = false;

  /// 标记本会话的阅读页是否处于前台（由 `PdfReadingPage` 的 init/dispose 调用）
  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    CrashLog.mark('前台[PDF]=$value');
  }

  /// 用户打开了这本 PDF 的阅读页 → 把媒体来源从"空闲的 TTS"收回来。
  ///
  /// ## 为什么需要
  ///
  /// `TtsAudioHandler` 的来源可能还停在 `tts-manager` 上（上一本书只是**暂停**，
  /// 会话仍在）。此时按耳机 / 通知栏的播放，会继续读**上一本书**
  /// （用户 2026-10-17 反馈：「从上一本书，换到 pdf 时，用耳机控制启停控制的
  /// 还是上一本书」）。
  ///
  /// ## 两道闸门（防止重演 v1.21.55 的「耳机控制失效」）
  ///
  /// 1. **TTS 正在朗读时绝不接管**（`playing` 为真就整个跳过）——
  ///    正在听的朗读不能被"打开一个页面"打断。
  /// 2. 接管前**先 `terminateForDocumentSwitch`** 清掉 TTS 会话。
  ///    这样之后本会话被切走时，`stopSound()` 里那句无条件的
  ///    `TtsManager.stop()` 打在**空会话**上，不会误伤新启动的朗读。
  ///
  /// ⚠️ v1.21.59 起这个函数**已不再被调用**。它代表"抢来源"那条老路，
  /// 已由 [isForeground] + `TtsAudioHandler.play()` 按前台派发取代。
  /// 保留代码只为让后来的人看到当时的两难，别再重新启用。
  // ignore: unused_element
  void _claimAudioFromTtsIfIdle(String documentId) {
    if (!isActive) return;
    final handler = audioHandler;
    CrashLog.mark('接管[求值] pdfActive=$isActive '
        'ttsSpeaking=${TtsManager.instance.speaking} '
        'ttsPaused=${TtsManager.instance.paused} '
        'ttsPlaying=${TtsManager.instance.playing} '
        'ttsHasSession=${TtsManager.instance.hasSession} '
        'source=${handler?.activeSource.sourceId}');
    if (TtsManager.instance.playing) return; // 闸门 1：正在读 → 不动
    if (handler == null) return;
    if (identical(handler.activeSource, this)) return; // 已经是自己
    // ⚠️ 这里**不要**调 `terminateForDocumentSwitch`。
    //
    // 它会把 TTS 的 `_doc` / `_lines` / `_speaking` 一起清掉 —— 那是「换书」
    // 的力度。而这里只想要「让出音频来源」，会话内容该留着：用户切回那本书
    // 时还要能接着读。真机日志里试过：清太狠之后回 EPUB 按播放，
    // 连「开始朗读」都没打印、进度停在 `index=0/1`（读不起来）。
    //
    // 只 `_claimAudio()`：`activate()` 会通知 tts-manager `onStop()`
    // （它只停声、保留 `_doc`），足够把来源换过来。
    _claimAudio();
    CrashLog.mark('接管[完成] → pdf-session');
  }

  /// 挂上界面（阅读页 initState）
  void attach(PdfReadSessionListener listener) {
    _listener = listener;
    // 页面进来了 → 成为前台（v1.21.59，见 [setForeground]）
    setForeground(true);
    final ref = _current;
    if (ref != null) listener.onSentenceChanged(ref);
  }

  /// 摘下界面（阅读页 dispose）—— **只摘不停止朗读**
  ///
  /// 摘掉之后推进循环照常跑，只是不再回调界面（所以不会去动已销毁的
  /// PageController）。这是「退出阅读页继续读」的实现点。
  void detach(PdfReadSessionListener listener) {
    if (identical(_listener, listener)) {
      _listener = null;
      // 页面离开了 → 不再是前台（v1.21.59，见 [setForeground]）
      setForeground(false);
    }
  }

  /// 只停声音，**保留** current / documentId / 文本层缓存
  ///
  /// 方块键与「暂停」都走这条：之后 [resume] 能从当前句接着读。
  Future<void> stopSound() async {
    // ★v1.21.64：**先停声，再写盘**。
    //
    // 真机（2026-10-17 16:37，用户反馈「从 PDF 切到 EPUB 停止没立即生效，
    // 等了一两秒才停」）：
    // ```
    // 16:37:48.402  位置[进入阅读页] EPUB      ← 用户已经切过去了
    // 16:37:48.504  activate（换源）tts-manager playing=true   ← 还在响
    // 16:37:51.278  pushState playing=false                   ← 2.7 秒后才停
    // ```
    // 原因：原来先 `await stopSoundLocalOnly()`（里面 `await _flushSpot()`
    // 要写盘，慢），**之后**才 `await TtsManager.stop()` 停声。
    // 用户感知就是「切过去了，声音还在响一两秒」。
    //
    // 现在把停声提到最前面并且**不等**：`stop()` 发出去引擎就会掐掉当前话语，
    // 写盘可以慢慢来。
    if (TtsManager.instance.isBorrowedForOther) {
      unawaited(TtsManager.instance.stop());
    }
    await stopSoundLocalOnly();
    // ★v1.21.59（用户要求核对「所有方块键按下后是否都放开媒体焦点」）：
    // PDF 页的方块键走的正是这个方法（`PdfReadingPage._stopAndCollapse`），
    // 而这里原来**没有**释放焦点 —— 文字档那边 `TtsManager.stop()` 会释放，
    // PDF 这边就漏了。后果：停掉 PDF 朗读之后我们仍压着音频焦点，
    // 别的应用（音乐 / 视频）一直出不了声，或媒体键路由异常。
    //
    // 只在这个"用户显式停声"的入口释放；被顶替（[onStop]）走的是
    // [stopSoundLocalOnly]，那条**不能**释放 —— 焦点已经交给接管方了。
    unawaited(MediaInterruptionController.instance.releaseFocus());
  }

  /// [stopSound] 的"只清自己"版本：**碰都不碰 TtsManager**
  ///
  /// 给 [onStop] 用 —— 那一刻音频来源已经不是本会话了，
  /// 去停 TTS 会顶掉接管方刚领的朗读代次（见 [onStop] 的注释）。
  Future<void> stopSoundLocalOnly() async {
    _token++; // 旧推进循环立刻失效
    _playing = false;
    _paused = false;
    await _flushSpot(); // 停声 = 用户要「记住读到哪」，防抖窗口不能再等
    _listener?.onPlaybackStateChanged();
    notifyListeners();
    _notifyAudio();
  }

  /// 彻底清空（换书、通知栏关闭）
  Future<void> clear() async {
    _token++;
    // ⚠️ 必须在清 _documentId / _current **之前**刷盘：
    // 「结束朗读后重新进入要定位到上次位置」（任务 D 症状③）依赖这条落盘记录。
    await _flushSpot();
    // ⚠️ v1.21.43（P0-3）：刷盘之后**切断异步尾巴** —— 否则清掉 _documentId 之后，
    // 定时器还会把最后一个位置写到一个"已经不属于本会话"的 id 上。
    _cancelOldDocumentWrites();
    await TtsManager.instance.stop();
    _documentId = null;
    _documentTitle = '';
    _docRef = null;
    _pageCount = 0;
    _layers.clear();
    _layerOrder.clear();
    _emptyPages.clear();
    _current = null; // clear 是显式终止，不碰落盘记录
    _playing = false;
    _paused = false;
    _finished = false;
    audioBridge.release(this);
    _listener?.onPlaybackStateChanged();
    notifyListeners();
  }

  /// 仅供测试：清到初始状态（单例会串状态，HANDOFF §9.31）
  @visibleForTesting
  void resetForTest() {
    _token++;
    // 撤掉未落盘的防抖：否则上一个用例的定时器会在新用例里写库
    _flushSpotTimer?.cancel();
    _flushSpotTimer = null;
    _pendingSpot = null;
    _documentId = null;
    _documentTitle = '';
    _docRef = null;
    _pageCount = 0;
    _layers.clear();
    _layerOrder.clear();
    _loading.clear();
    _emptyPages.clear();
    _current = null;
    _playing = false;
    _paused = false;
    _finished = false;
    _listener = null;
  }

  // ---------------- 朗读推进 ----------------

  /// 从 [ref] 开始读，并**自动一句接一句读下去**
  ///
  /// 用法（阅读页点句）：`session.startAt(ref)`。
  ///
  /// ⚠️ **发起即返回** —— 内部是常驻的推进循环，`await startAt(...)` 会等到
  /// 整条链读完（几十句），调用方不该等它。这也保证了「点新句子」能**立刻**
  /// 打断旧链：旧链靠 [_token] 失效，不需要等它跑完。
  void startAt(PdfSentenceRef ref, {String? diagSource}) {
    if (!isActive) return;

    // 跳动检测：这是一次用户显式「点句」
    SpeechDiagnostics.instance.markUserAction(diagSource ?? '点句');
    final token = ++_token;
    _setCurrent(ref, immediate: true);
    // ⚠️ 先把播放状态置真，**再**去抢通知栏。
    // 反过来的话 `_claimAudio()` 会立刻推一次状态，而那一刻 `_playing`
    // 还是 false —— 通知栏显示成「已暂停 / 没有动作」，可声音马上就要响
    // （实测：通知栏 playing=false、systemActions 为空）。
    _playing = true;
    _paused = false;
    _finished = false;
    // 位置记忆埋点 H（PDF 起读）：**谁**带着**哪个 ref** 起了这一轮
    // （真机日志里出现过"起读用的 ref 比会话当前值更旧"，这条能直接看出来）
    CrashLog.mark('位置[PDF起读] docId=$_documentId '
        'ref=${ref.pageIndex}/${ref.sentenceIndex} '
        '起读前当前=${_current?.pageIndex}/${_current?.sentenceIndex}');
    // AF 埋点（v1.21.43 · P0-1）：起读是"位置归谁"的关键拍，带上会话键与拍号。
    // 页面侧还会打一条字段更全的（含闸门状态），见 `pdf_reading_page._af`。
    CrashLog.mark('AF[起读] doc=${_documentId ?? '-'} src=pdf-session '
        'key=$sessionKey token=$_token '
        'ref=${ref.pageIndex}/${ref.sentenceIndex} '
        'cur=${_current?.pageIndex}/${_current?.sentenceIndex} '
        'playing=$_playing paused=$_paused hasSession=$hasSession '
        'speaking=${TtsManager.instance.speaking} '
        'borrowed=${TtsManager.instance.isBorrowedForOther} seq=$_spotSeq');
    // 通知栏切到本来源（第三处调用点，见 AudioSessionSource 的说明）
    _claimAudio();
    _listener?.onSentenceChanged(ref);
    _listener?.onPlaybackStateChanged();
    notifyListeners();
    unawaited(_readLoop(token));
  }

  /// 继续：从当前句接着读（通知栏播放键 / 迷你条播放键）
  ///
  /// 实现说明：用 `_restart((_ch,_p,_s))` 的语义是「从当前单元句首重读」，
  /// 这里等价于「从 current 这一句的开头重读」——**不是半句续播**。
  /// 半句续播要保留活着的循环，与打断令牌模型冲突，不值得（见汇报第 3 点）。
  void resume() {
    final ref = _current;
    if (ref == null || !isActive) return;
    startAt(ref);
    // ⚠️ v1.21.43（真机手测 ②）：**恢复播放后强制再推一次通知栏状态**。
    //
    // 为什么需要：`startAt` 里那次 `_claimAudio()` 走 `activate()`，而
    // `activate()` 按 `sourceId` 判等 —— **没换书时 sourceId 不变**，
    // 它会**直接 return、不推状态**。于是"应用内恢复"这条路只剩
    // `notifyIfActive` 一道门：它要求 `identical(handler.activeSource, this)`，
    // 一旦归属判定有偏差（或被 `isBorrowedForOther` 之类的闸门挡下），
    // 通知栏就**收不到 playing=true**，图标停在"暂停"样式 ——
    // 用户手测原话：「应用内恢复，通知栏却没从暂停图标改回播放」。
    //
    // 这里无条件补推一次：幂等，最坏只是多发一次 playbackState。
    _notifyAudio();
  }

  @override
  Future<void> pause() async {
    if (!_playing || _paused) return;
    _token++; // 让推进循环停下
    _paused = true;
    _playing = false;
    await _flushSpot(); // 暂停 = 「记在这里」，不能让防抖窗口把最后位置漏掉
    await TtsManager.instance.pause();
    _listener?.onPlaybackStateChanged();
    notifyListeners();
    _notifyAudio();
  }

  /// 跳到某一页的第一句并从那里读（目录跳转 / 通知栏上下一句）
  ///
  /// ⚠️ 术语：PDF 朗读**没有"滚动"**这个概念（见 `sentence_centering.dart`
  /// 顶部术语表）。这里是"**让画面滑动到那一页**"+把朗读位置移过去。
  Future<void> jumpToPage(int pageIndex, {bool autoPlay = true}) async {
    if (!isActive) return;
    final layer = await ensureLayer(pageIndex);
    final ref = firstSentenceOnPage(pageIndex, layer);
    if (ref == null) {
      // 该页没有文字（扫描件）：**只把画面滑过去**，不读
      _listener?.onPageShouldTurn(pageIndex);
      return;
    }
    if (autoPlay) {
      startAt(ref);
    } else {
      _token++;
      _setCurrent(ref, immediate: true);
      _listener?.onSentenceChanged(ref);
      _listener?.onPageShouldTurn(pageIndex);
    }
  }

  /// 判据：文本里**有没有实义字符**（字母 / 数字）
  ///
  /// 用来挡掉「纯标点」的假句子（`”` / `。` / `--` …）—— 见 [_readLoop] 里的说明。
  /// 用 Unicode 属性而不是"长度"：单字符数字照读，只挡符号。
  static final RegExp _hasMeaningfulChar =
      RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// 核心推进循环
  ///
  /// **严格串行**：`await done` 等到这一句读完才发下一句 —— 这一步是关键，
  /// 第 0 步的时序验证证明了「连发会让前一句在到达引擎前就被顶掉」。
  /// 每一轮都查 token：点新句子 / 换书 / 停止后，旧链立刻退出。
  Future<void> _readLoop(int token) async {
    while (true) {
      if (token != _token) {
        return; // 被打断（点新句 / 停止 / 换书）
      }
      final ref = _current;
      if (ref == null) {
        return;
      }


      // 跨页句子：本页最后一句没写完时把下一页开头接上再读。
      //
      // v1.21.14 任务①：这里**必须留下整个 CrossPageSentence**（含 endPage/endSentence）。
      // 合并句已经把"下一页首句"一起读掉了，推进时必须从它的终点之后开始 ——
      // 原来只取 `.text`、把终点丢掉，于是 `_advance` 又把那一句读了一遍
      // （用户报的「翻到下一页重复页首句」）。
      final layer = await ensureLayer(ref.pageIndex);
      if (token != _token) return;
      final nextLayer = await ensureLayer(ref.pageIndex + 1);
      if (token != _token) return;
      final CrossPageSentence whole = layer == null
          ? CrossPageSentence(
              text: ref.text,
              startPage: ref.pageIndex + 1,
              startSentence: ref.sentenceIndex,
              endPage: ref.pageIndex + 1,
              endSentence: ref.sentenceIndex,
            )
          : buildCrossPageSentence(layer, ref.sentenceIndex, nextLayer);
      final text = whole.text.trim();
      // ★模型 A 风险②：把「跨页句在下一页的终点」留给 UI（高亮要画两页）
      _noteSpanEnd(ref.pageIndex, whole);
      if (text.isEmpty) {
        // 空白句：直接跳下一句，别卡住
        if (!await _advance(token)) return;
        continue;
      }
      // ⚠️ v1.21.38：**纯标点/纯符号的"句子"也当空单元跳过**，不能送去合成。
      //
      // 为什么（真机 v1.21.37 日志）：PDF 抽取常见"右引号单独占一行"，
      // 而分句规则又把收尾引号归到下一句开头 —— 于是 `”` 成了 1 字符的独立句。
      // 这条送进引擎后**从不回调完成**，硬卡满 `speakTimeout` = **30 秒**
      // （日志原文：`speak text="”" ms=30001 ok=false`），用户感受是"卡死了"。
      //
      // 判据用「有没有字母/数字」而不是长度：单字符数字 `3` 照常读
      // （日志里 `text="3"` 正常完成 554ms），只挡纯标点/符号。
      if (!_hasMeaningfulChar.hasMatch(text)) {
        if (!await _advance(token)) return;
        continue;
      }

      // 让页面先到位再读（需求：跟着朗读自动跟随滚动）
      _listener?.onPageShouldTurn(ref.pageIndex);

      // ⚠️⚠️ 顺序必须是「**先 speak、再订阅**」，不能反过来！
      //
      // `whenSessionFinished()` 返回的是「当前那一代」的信号。`speakText` 是
      // **同步**的（内部 `_beginSession` 立刻换上新 Completer），所以：
      //
      // - 「先订阅、再 speak」= 拿到**上一句**已经完成的 Completer
      //   → `await` 立刻返回 → 五句在几毫秒内全被发出、互相顶掉，
      //   **听起来只读了最后一句**（实测就是这个问题，排查了很久）；
      // - 「先 speak、再订阅」= 拿到这一句的 Completer，await 才真的等到读完。
      //
      // 任务书里写的是前者；实测证明必须反过来（见 HANDOFF §4.94）。
      //
      // 另外：整段朗读要用 `speakForOther` 包住 —— PDF 是**借**
      // `TtsManager` 发声，不能让 `speakText` 顺手把通知栏抢回 TXT 那边
      // （否则每读一句通知栏书名就变一次，实测踩到）。
      await TtsManager.instance.speakForOther(() async {
        final speakIssuedAt = DateTime.now();
        TtsManager.instance.speakText(text);
        var done = TtsManager.instance.whenSessionFinished();
        await done;
        // ⚠️ 判据用「**距 speakText 发起**的总时长」，不是"这一次等了多少"。
        //
        // 原因：会话一旦结束，`whenSessionFinished()` 会立刻返回已经完成的
        // Completer —— 那一拍的 waited ≈ 0ms。若拿它去比阈值，就会**永远**
        // 判成假完成、无限丢弃（实测把既有 19 项 PDF 用例全弄红）。
        // 总时长是单调累加的，才会随真实朗读时长一起长上去。
        var waited = DateTime.now().difference(speakIssuedAt).inMilliseconds;

        // ────────────────────────────────────────────────────────────────
        // 丢弃**假完成**：两道判据叠加
        //
        // **第一道（§4.107 治根，可靠）**：`TtsManager.lastSpeakInterrupted`
        // 明确告诉我们「这一拍是被 stop/pause **打断**的」—— 与朗读时长无关。
        // 被打断 = 没读完 = 绝不能推进位置。
        //
        // **第二道（§4.106 兜底）**：真机实测（`pdf_done.log`，112 条）
        // `PDF_DONE` 有 54% 落在 ≤200ms、最短 0ms，而真读完一句要 1~6 秒。
        // 一个汉字最短也要 ~80ms 才发得完，取 100ms 留余量。
        //
        // 命中任一条就丢弃本次信号、让出一小段再看一眼；
        // 带重试上限（[_maxFakeDoneRetries]），**绝不无限丢**（那会把朗读卡死）。
        // ────────────────────────────────────────────────────────────────
        // 判据只剩「时长」这一道：v1.21.12 的第一道（lastSpeakInterrupted）已随 §4.107
      // 的净减法撤掉 —— 真机证明它从未触发，路径 B 的时长判据覆盖了真实场景。
      var fakeRetries = 0;
        while (waited < _minRealSpeakMs &&
            token == _token &&
            fakeRetries < _maxFakeDoneRetries) {
          fakeRetries++;
          await Future<void>.delayed(_fakeDoneGrace);
          if (token != _token) break;
          done = TtsManager.instance.whenSessionFinished();
          await done;
          waited = DateTime.now().difference(speakIssuedAt).inMilliseconds;
        }
      });
      if (token != _token) {
        return;
      }

      // ⚠️ v1.21.40：**引擎失败时不能推进**。
      //
      // `TtsManager._fail()`（超时 / 报错）也会让 `whenSessionFinished()` 完成 ——
      // 于是上面那个 `await done` 正常返回，代码就照常往下走 `_advancePast`。
      // **失败信号被当成了读完信号**，结果是：用户一句都没听到，位置却往前跳。
      //
      // 真机日志（v1.21.39）：
      // ```
      // 13:48:46.343  朗读失败：本地 TTS · multitts 超时（30000ms）
      // 13:48:47.859  位置[PDF写盘] page=17 sentence=32   ← 用户没听到，位置却前进
      // 13:48:51.931  位置[PDF写盘] page=17 sentence=34
      // 13:48:57.341  位置[PDF写盘] page=17 sentence=35
      // 13:48:58.927  位置[PDF写盘] page=17 sentence=36   ← 连跳 5 句
      // 13:49:01.395  之后 6 分钟静默，直到用户手动起读
      // ```
      //
      // 收尾方式与"真正读完"区分开：**只停会话、不报读完、不动位置**。
      // `TtsManager._error` 会在下一次 `_runLinesBody` 开头重置，
      // 所以用户按播放重读不会撞上这个旧错误。
      final String? engineError = TtsManager.instance.error;
      // （已实测：把这里的条件改成 false，用例会红在"位置从 0:0 跳到 0:3"）
      if (engineError != null) {
        CrashLog.mark('PDF 朗读中止：引擎报错 $engineError '
            '（停在第 ${ref.pageIndex}/${ref.sentenceIndex} 句，位置不推进）');
        _playing = false;
        _paused = false;
        _listener?.onPlaybackStateChanged();
        notifyListeners();
        _notifyAudio();
        return;
      }

      // 这一句读完了 → 下一句。
      // 跨页合并句的终点在下一页 → 从它的**下一句**继续（不能从 ref 前进，那是重复）。
      if (!await _advancePast(whole, token)) return;
    }
  }

  /// 从 [ref] 往后找下一句（会同页前进、跳过空白页）。
  ///
  /// ## 为什么不能直接用 [nextPdfSentence]
  ///
  /// 那个纯函数靠 `layerOf` 看后面若干页，而 `layerOf` 是**有上限的 LRU 缓存**
  /// （[`_maxCachedLayers`] = 8）。跳空白页要往后看好几页，一边抽一边淘汰，
  /// 结果扫描时那些页**已经被挤出去了** —— 函数拿到 null，判定「推不动」，
  /// 用户表现就是「书读到一半突然说读完了」。
  ///
  /// 实测（真实 319 页《共产主义ABC》）：第 9 页是空白，第 10~16 页被
  /// 逐页抽出来又被淘汰（`缓存有层页数=8`），于是 `next((7,24))` 返回 null。
  ///
  /// 所以这里**分块往前推**：每块抽完立刻就地检查，找到就走，不再回头依赖缓存。
  Future<PdfSentenceRef?> _nextSentenceAcrossPages(
    PdfSentenceRef ref,
    int token,
  ) async {
    const chunk = 4;
    var scanned = 0;
    var page = ref.pageIndex;
    while (page < _pageCount && scanned <= maxBlankPagesToSkip + chunk) {
      final layer = await ensureLayer(page);
      if (token != _token) return null;
      if (layer != null && layer.sentences.isNotEmpty) {
        // 就在这一页：同页取下一句，跨页取第 0 句
        final nextIndex = page == ref.pageIndex ? ref.sentenceIndex + 1 : 0;
        if (nextIndex < layer.sentences.length) {
          return PdfSentenceRef(
            pageIndex: page,
            sentenceIndex: nextIndex,
            text: layer.sentences[nextIndex].text,
          );
        }
        // 本页读完了，继续往后
      } else if (!isPageEmpty(page)) {
        // 还没抽出来 / 抽失败：不是「读到头」，交给调用方停在这儿等重试
        return null;
      }
      // 这一页没有可读内容（空白页 / 本页已读完）→ 往后推一块
      page++;
      scanned++;
      if (scanned % chunk == 0) {
        await Future<void>.delayed(Duration.zero);
        if (token != _token) return null;
      }
    }
    return null;
  }


  /// 前进到下一句；读到头返回 false 并报 onFinished
  Future<bool> _advance(int token) async {
    final ref = _current;
    if (ref == null) return false;
    await ensureLayer(ref.pageIndex);
    if (token != _token) {
      return false;
    }
    return _advanceAfter(ref, token);
  }

  /// 跨页合并句读完之后的推进（v1.21.14 任务①）
  ///
  /// `whole.spansPages` 为真 = 「下一页第 0 句」已经被合并进来读掉了 →
  /// 必须从 `endSentence` **之后**继续，否则那一句会被读第二遍。
  Future<bool> _advancePast(CrossPageSentence whole, int token) async {
    if (!whole.spansPages) return _advance(token);
    final int endPageIndex = whole.endPage - 1; // endPage 是 1 起，内部统一 0 起
    if (endPageIndex < 0) return _advance(token);
    await ensureLayer(endPageIndex);
    if (token != _token) return false;
    return _advanceAfter(
      PdfSentenceRef(
        pageIndex: endPageIndex,
        sentenceIndex: whole.endSentence,
        text: '', // 只当下标用：文字不参与推进
      ),
      token,
    );
  }

  /// 从 [spoken] 这一句**之后**继续（读到头返回 false 并报 onFinished）
  ///
  /// [spoken] 不一定等于 `_current`：跨页合并句的终点在下一页，见 [_advancePast]。
  Future<bool> _advanceAfter(PdfSentenceRef spoken, int token) async {
    final ref = spoken;

    // ⚠️ v1.21.39 埋点：抓「同一拍被推进两次」（真机 v1.21.38 日志里
    // `seq=76` 与 `seq=77` 相隔 **0.066ms**、都从 `26:3` 起算各加一格
    // → 实际从 26:3 跳到 26:5，**中间那句被跳过没读**）。
    //
    // 结构上 `_readLoop` 每轮只调一次 `_advanceAfter`，所以这条日志如果
    // 连续出现两条且 `spoken` 相同，就能确定是**并行的两条推进链**
    // （或有一次推进在 `_setCurrent` 之前就取了值）。带上 `cur` 用来分辨。
    CrashLog.mark('推进[进入] token=$token ref=${ref.pageIndex}/${ref.sentenceIndex} '
        'cur=${_current?.pageIndex}/${_current?.sentenceIndex}');

    final following = await _nextSentenceAcrossPages(ref, token);
    if (following == null && token != _token) return false;
    if (following == null) {
      // ⚠️ 到这里已经是「往后翻到能抽的都抽过了、确实没有再往后一步」。
      // 区分两种收尾：
      //   1) 真的到文档末尾（后面只剩空白页 / 没有页了）→ 报「读完」
      //   2) 撞上还没抽出来的页 → **不是读完**，只是暂时推不动，留着让用户重试
      final nextPage = ref.pageIndex + 1;
      final blocked = nextPage < _pageCount && !isPageEmpty(nextPage);
      // 收尾（读完 / 暂时推不动）都要把位置刷盘：这是本次朗读的最后一个位置，
      // 防抖窗口里的值丢了就变成「重进定位到半路」
      unawaited(_flushSpot());
      if (blocked) {
        _playing = false;
        _listener?.onPlaybackStateChanged();
        notifyListeners();
        _notifyAudio();
        return false;
      }
      _finished = true;
      _playing = false;
      _paused = false;
      _listener?.onFinished();
      _listener?.onPlaybackStateChanged();
      notifyListeners();
      _notifyAudio();
      return false;
    }
    // 跳过了空白页也不该把 `_finished` 留着（用户可能在末尾点了播放）
    _finished = false;
    // ⚠️ **唤醒检查必须在写位置之前**（v1.21.37 修「点下一句会跳两句」）：
    // `_nextSentenceAcrossPages` 里有 await（要抽下一页的文本层）—— 这中间用户
    // 完全可能点了「下一句」或「点句」：那会把 `_token` 加一、并把 `_current`
    // 设成**用户目标句**。若这里不检查就直接 `_setCurrent(following)`，
    // 这次**已经算好的、属于旧那一拍的**推进会把位置再往后推一格，
    // 表现就是「朗读上一句时点下一句 → 跳到下一句的下一句」。
    // 位置归谁：唤醒之后由新的那次 [startAt] 说了算，旧循环只该退出。
    if (token != _token) return false;
    // 跳动检测（埋点 2）：PDF 侧的推进由本会话记账，代次取共享层当前代次，
    // 这样判定器才能把它和朗读事件（同属共享层）的代次对比。
    SpeechDiagnostics.instance.recordAdvance(
      before: '${ref.pageIndex}:${ref.sentenceIndex}',
      after: '${following.pageIndex}:${following.sentenceIndex}',
      delta: following.pageIndex == ref.pageIndex
          ? (following.sentenceIndex - ref.sentenceIndex).abs()
          : 1,
      epoch: TtsManager.instance.diagGeneration,
    );
    _setCurrent(following);
    _listener?.onSentenceChanged(following);
    // 跨页了就让页面跟上（同一页内不动，免得页面乱跳）
    if (following.pageIndex != ref.pageIndex) {
      _listener?.onPageShouldTurn(following.pageIndex);
    }
    return true;
  }

  /// 目标页首句的句下标；没有文字返回 null
  Future<PdfSentenceRef?> firstSentenceOnPageAsync(int pageIndex) async {
    final layer = await ensureLayer(pageIndex);
    return firstSentenceOnPage(pageIndex, layer);
  }

  /// 通知栏动作的出口（**可替换，仅供测试**）
  ///
  /// PDF 会话没挂在 `TtsManager` 的 listener 上，得自己推通知栏。
  /// 抽成可替换的桥是为了让「换书终止」能在单测里验证：
  /// `TtsAudioHandler` 依赖 audio_service（需要真实设备），跑不进纯 Dart 测试。
  @visibleForTesting
  PdfSessionAudioBridge audioBridge = PdfSessionAudioBridge.real();

  void _notifyAudio() => audioBridge.notifyIfActive(this);

  /// 把自己设为通知栏当前来源
  void _claimAudio() => audioBridge.claim(this);

  // ---------------- AudioSessionSource 实现（通知栏） ----------------

  @override
  String get sourceId => 'pdf-session';

  @override
  bool get hasSession => isActive;

  @override
  bool get playing => _playing && !_paused;

  @override
  bool get paused => _paused;

  @override
  bool get canSeek => false; // PDF 不按比例跳：拖到「第 5.3 句」没有意义

  @override
  double get rate => TtsManager.instance.rate;

  /// 进度按**页**算：通知栏显示「第 N/M 页」，与阅读页的页码一致
  @override
  int get progressTotal => _pageCount;

  @override
  int get progressIndex => _current?.pageIndex ?? 0;

  @override
  String get positionLabel {
    final ref = _current;
    if (ref == null || _pageCount <= 0) return '';
    return '第 ${ref.pageIndex + 1}/$_pageCount 页 · 第 ${ref.sentenceIndex + 1} 句';
  }

  @override
  void playFromCursor() {
    resume();
  }

  @override
  void seekToProgress(double fraction) {
    // canSeek = false，正常不会被调用；真被调用也不动（避免「拖了位置乱跳」）
  }

  /// 通知栏 / 耳机「上下一章」：PDF 一章即一页 → 跳到相邻页首句
  @override
  void skipChapter(int delta) {
    // 跳动检测：用户显式跳章（通知栏 / 耳机键）
    SpeechDiagnostics.instance.markUserAction('快进');
    final page = (_current?.pageIndex ?? 0) + delta;
    if (page < 0 || page >= _pageCount) return;
    unawaited(jumpToPage(page));
  }

  @override
  void skipSentenceForward() {
    final ref = _current;
    if (ref == null) return;
    final following = nextPdfSentence(
      ref,
      layerOf,
      isEmptyPage: isPageEmpty,
      pageCount: _pageCount,
    );
    if (following == null) return;
    // ⚠️ **目标句随这次点击一起绑定**（v1.21.37）：
    // 用 [diagSource]='快进' 让诊断把它记成用户显式跳转（不是自动推进）——
    // 否则这条"用户主动换句"会被 R3/R4 当成非显式的大跨度推进误报。
    startAt(following, diagSource: '快进');
  }

  @override
  void skipSentenceBackward() {
    final ref = _current;
    if (ref == null) return;
    // 同一页内退一句；已在页首就退到上一页最后一句
    if (ref.sentenceIndex > 0) {
      final layer = layerOf(ref.pageIndex);
      final prev = sentenceRefAt(
        ref.pageIndex,
        ref.sentenceIndex - 1,
        layer,
      );
      if (prev != null) {
        startAt(prev);
        return;
      }
    }
    final prevPage = ref.pageIndex - 1;
    if (prevPage < 0) return;
    final layer = layerOf(prevPage);
    if (layer == null || layer.sentences.isEmpty) return;
    final last = sentenceRefAt(prevPage, layer.sentences.length - 1, layer);
    if (last != null) startAt(last);
  }

  @override
  void skipPageForward() => skipChapter(1);

  @override
  void skipPageBackward() => skipChapter(-1);

  @override
  void onStop() {
    // 被 TtsManager 顶替（用户在读 PDF 时去读 TXT）：停声但**保留位置**，
    // 这样回到 PDF 还能接着读。
    //
    // ⚠️ v1.21.59：这里**必须用不碰 TTS 的版本**（[stopSoundLocalOnly]）。
    //
    // 原来调 [stopSound]，而它内部会 `await TtsManager.stop()` —— 那句话是
    // **异步**的，会在 `_restart()` 刚领完新代次**之后**才落地，于是
    // `_runBody` 在 `token != _generation` 处直接 return：
    // 真机表现为「按了播放、图标变成暂停、但没有声音，
    // 通知栏进度停在 `index=0/1`，日志里根本没有『开始朗读』」。
    //
    // 语义上也该如此：`onStop` 意味着"音频来源已经不是我了"，
    // 此刻 TTS 正被接管方使用，我没有任何理由去停它。
    unawaited(stopSoundLocalOnly());
  }
}

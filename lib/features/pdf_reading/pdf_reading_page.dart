import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../models/reader_style.dart';
import '../../models/structured_document.dart';
import '../../services/crash_log.dart';
import '../../services/pdf_outline.dart';
import '../../services/speech_diagnostics.dart';
import '../../services/storage_service.dart';
import '../../tts/tts_manager.dart';
import '../../widgets/speech_diag_overlay.dart';
import '../../widgets/toc_current_item.dart';
import 'pdf_control_bar.dart';
import 'pdf_page_layer.dart';
import 'pdf_page_turn_controller.dart';
import 'pdf_read_session.dart';
import 'pdf_text_layer.dart';
import 'sentence_centering.dart';

/// PDF 朗读页：渲染 + 透明文本层 + 点句朗读 + 自动连读 + 自动跟随滚动 + 目录。
///
/// ## 与 [PdfReadSession] 的分工
///
/// 这个页面**不再是朗读状态的持有者**，只是「挂上去看」：
///
/// | 谁 | 管什么 |
/// | --- | --- |
/// | [PdfReadSession]（单例） | 位置、推进循环、文本层缓存、播放状态 |
/// | 本页 | 渲染、滚动、高亮、控制栏、目录面板 |
///
/// 所以 `dispose` 只 **detach**，**不 stop** —— 退出阅读页朗读继续
/// （需求）。要停有两条明确路径：控制栏的 ■、通知栏。
///
/// ## 为什么位置不放在 State 里
///
/// 推进循环住在单例里。放在 State 里的话，`dispose` 之后 `mounted == false`，
/// 递归立刻断掉 —— 「退出阅读页继续读」就实现不了（HANDOFF §4.60 的老坑）。
class PdfReadingPage extends StatefulWidget {
  const PdfReadingPage({
    super.key,
    required this.filePath,
    required this.title,
    this.documentId,
    this.debugShowTextRects = false,
  });

  final String filePath;
  final String title;

  /// 文档在库里的 id（会话用它判「同一本书」）；不传就用文件路径
  final String? documentId;

  /// 打开后画出每个字符盒（排查命中问题用）
  final bool debugShowTextRects;

  /// 供测试 / 外部定位用的 Key
  static const Key viewKey = ValueKey<String>('pdf-reading-view');
  static const Key backToReadingKey =
      ValueKey<String>('pdf-reading-back-to-reading');
  static const Key loadingKey = ValueKey<String>('pdf-reading-loading');
  static const Key noTextLayerKey =
      ValueKey<String>('pdf-reading-no-text-layer');

  /// 扫描件（图片型 PDF）页面上那行提示
  ///
  /// ## 措辞演变（两轮用户决定，别改回去）
  ///
  /// 1. v1.21.45 前：含糊的"**可能是**扫描件" —— 用户反馈听着像"换个模式就能读"，
  ///    于是改成点明"要读它得先做 OCR"；
  /// 2. 2026-10-14 用户拍板：**应用内不做 OCR**（OCR 识别准确率没保证，
  ///    以后可能走 AI 接口做识别 + 翻译），所以**不再把 OCR 当解决方案挂在提示里**，
  ///    只说清两件事：**能正常翻阅**、**朗读不了**。
  ///
  /// 放在公开类上是为了让单测能直接断言文案（见 `test/scanned_pdf_hint_test.dart`）。
  static const String scannedPdfHint =
      '这是扫描件（图片型 PDF），没有文字层，无法朗读。'
      '可以正常翻页阅读，只是点句朗读用不了。';

  /// **一行判据**：视口显示的页 == 朗读句所在页 ？
  ///
  /// ⚠️ 必须放在这个**公开**类上（不能在私有 `PdfReadingPageState` 里），
  /// 否则测试文件引用不到 —— 这个错本仓库踩过一次
  /// （`tryNativeFolderOpen` 当初也误放进私有 State，导致测试
  /// `undefined_getter`）。
  ///
  /// 抽成独立函数**是为了能被单测直接打到"红"的那一支** ——
  /// 如果这个判据永远只显示"✅一致"，它就是个摆设（用户明确要求做负向验证）。
  ///
  /// ⚠️ 两个入参必须来自**互相独立**的来源，否则判据是循环的：
  /// * [viewportPage] 来自 `pageAtOffsetForTest`（**滚动位置**派生）；
  /// * [refPage] 来自朗读会话的当前句（**朗读位置**）。
  /// 实测两者确实独立：`_pageAtOffset` 只读 `_pageExtents` 与 offset，
  /// **从不读 session / ref**。
  static bool isViewportSyncedWithReading({
    required int viewportPage,
    required int refPage,
  }) =>
      viewportPage == refPage;

  /// 目录里「当前项」是第几条（-1 = 不标任何条目）
  ///
  /// ## v1.21.56：用户报「PDF 目录朗读位置图标失效」的真根因就在这个判据
  ///
  /// PDF 书签是**稀疏**的 —— 往往每章只有一条（如「第 20 页 第二章」），
  /// 而朗读位置是**按页**推进的（第 21 页）。
  /// 原来判的是 `起始页 == 当前页`（精确相等）→ **一条都命中不了**
  /// → 整份目录没有任何标记，用户看到的就是「图标失效」。
  /// 文字档那边章节连续、容易命中，所以这个坑只在 PDF 侧暴露。
  ///
  /// 现在改成「**当前所在章节**」：最后一条 `起始页 ≤ 当前页` 的条目。
  ///
  /// ## 为什么放在公开类上
  ///
  /// 与 [isViewportSyncedWithReading] 同一个理由：**必须能被单测直接打到**，
  /// 否则这条判据再错一次也没人发现（它已经错过一次了）。
  /// 放在私有 `_PdfReadingPageState` 里测试就引用不到。
  ///
  /// @param chapters 书签各自的起始页（**必须按页码升序**，`PdfOutlineReader` 保证）
  /// @param currentPage 当前朗读 / 视图所在页（0 起）
  /// @param pageCount 总页数（无书签时用来校验越界）
  @visibleForTesting
  static int currentTocIndex({
    required List<int> chapters,
    required int currentPage,
    required int pageCount,
  }) {
    // 没有书签：目录就是「第 N 页」平铺，当前页即当前项
    if (chapters.isEmpty) {
      return currentPage >= 0 && currentPage < pageCount ? currentPage : -1;
    }
    var hit = -1;
    for (var i = 0; i < chapters.length; i++) {
      if (chapters[i] <= currentPage) {
        hit = i;
      } else {
        break; // 书签按页码升序，往后只会更大
      }
    }
    // 全都比当前页大（当前页在第一枚书签之前）→ 不标，避免指错章
    return hit;
  }

  /// **按页高累加估算"第 [pageIndex] 页顶部"的偏移**（收敛链的单一事实来源）
  ///
  /// ## 为什么必须"空缺用估算顶替、绝不中断"
  ///
  /// `ListView.builder` **只给渲染过的页报页高** → `_pageExtents` 里大量是 0。
  /// 累加时若遇到 0 就 `break`，`sum` 会停在"最后一个连续量到的页"，
  /// **远小于真实目标** → 跳不到位（真机：57 跳 42，视图停在 60）。
  ///
  /// ⚠️ 这条语义原来**只写在 `_jumpTowardsPageByEstimate` 里**，
  /// 而 [_revealToPageIndex]（**进书定位 / 回到朗读位置**那条链）一直留着老的
  /// `if (e <= 0) break;` —— 同一件事两套写法，于是出现
  /// 「进书定位停在开头几页」（真机 15:01:22：恢复目标 18 页，`AF[真落位] page=11`
  /// 之后收敛链直接消失）。现在两处都调这里，**行为不可能再漂移**。
  ///
  /// 返回 `null` = 连一页估算都给不出（文档还没打开完）→ 这一拍没法算，下一帧再来。
  /// 全为 0 页高时，`estimatedExtent × pageIndex` 与老兜底**逐位等价**。
  @visibleForTesting
  static ({double offset, int estimated})? estimateOffsetToPage({
    required List<double> pageExtents,
    required int pageIndex,
    required double estimatedExtent,
  }) {
    if (pageIndex <= 0) return (offset: 0.0, estimated: 0);
    if (estimatedExtent <= 0) return null;
    var sum = 0.0;
    var estimated = 0;
    for (var i = 0; i < pageIndex && i < pageExtents.length; i++) {
      final double e = pageExtents[i];
      if (e > 0) {
        sum += e;
      } else {
        sum += estimatedExtent; // ★空缺用估算顶替，**不中断**
        estimated++;
      }
    }
    if (sum <= 0) return null;
    return (offset: sum, estimated: estimated);
  }

  /// 某页是否**实质可见**（≥ [minRatio] 的面积落在视口内）
  ///
  /// ## ⚠️ 为什么不能"沾一点边就算可见"（本轮修）
  ///
  /// 原判据是 `bottom > 视口顶 && top < 视口底` —— 只要与视口**有 1 像素重叠**就为真。
  /// 而 `ListView` 的 `cacheExtent` 会在视口上下**预建**好几页：目标页可能还在
  /// 预建区、离视口很远，却被判"已到位" → 收敛链立刻 `_turn.onRevealFinished(...)`
  /// 并**结束** → 「进书定位停在开头几页」（真机：恢复目标 18 页，停在 11 页）。
  ///
  /// 现在要求**至少一半落在视口内**，预建区里的页不再冒充"到位"。
  @visibleForTesting
  static bool isPageSubstantiallyVisible({
    required double pageTop,
    required double pageBottom,
    required double viewportTop,
    required double viewportBottom,
    double minRatio = 0.5,
  }) {
    final double height = pageBottom - pageTop;
    if (height <= 0 || viewportBottom <= viewportTop) return false;
    final double overlap =
        math.min(pageBottom, viewportBottom) - math.max(pageTop, viewportTop);
    return overlap >= height * minRatio;
  }

  /// 这条滚动通知是不是「**用户真的在拖**」的开始
  ///
  /// 见 [UserScrollStopTracker] 的说明：程序自己的 `animateTo` 只发
  /// `ScrollStartNotification`（`dragDetails == null`），不发用户拖动那种。
  @visibleForTesting
  static bool isUserDragScrollStart(ScrollNotification notification) =>
      notification is ScrollStartNotification && notification.dragDetails != null;

  @override
  State<PdfReadingPage> createState() => PdfReadingPageState();
}

/// **"用户停手"计时器**：只认真实拖动结束，不认程序滚动结束
///
/// ## 治什么（真机 14:52 日志）
///
/// `ScrollEndNotification` **程序自己的 `animateTo` 结束时也会发**。
/// 原实现无条件写 `_lastUserScrollEndAt = DateTime.now()`，于是：
/// ```
/// 14:52:38.738  AF[滚动到位] 偏移=38781 实际=38781     ← 程序自己滚完
/// 14:52:41.105  AF[等待接管] 停手仅 2348ms < 4s → 暂不自动滚动（ref=22）
/// ```
/// 倒推"停手时刻"= 38.757，正好落在程序滚动结束后 19ms 内 —— 而同期每一行
/// `AF[跟读]` 的 `userDriven=false` 证明**用户根本没碰屏幕**。
/// 后果：程序每自己滚一次，就白送 4 秒"让位"，跟读看起来卡顿/不跟。
///
/// ## 规则
///
/// * 只有「拖动开始」（[isUserDragScrollStart]）之后的那个 `ScrollEnd` 才算用户停手；
/// * 任何 `ScrollEnd` 都要把"正在拖"复位（不能把标志留脏）。
///
/// 抽成独立类**是为了能被单测直接打到**（纯逻辑、不碰 Widget）——
/// 这条规则错了在真机上只表现为"跟读变迟钝"，肉眼很难归因。
@visibleForTesting
class UserScrollStopTracker {
  bool _dragging = false;

  /// 上一次**用户真实停手**的时刻（程序滚动不写它）
  DateTime? lastUserStopAt;

  /// 正在拖动中（仅用户拖动会置真）
  bool get dragging => _dragging;

  /// 收到 `ScrollStartNotification`
  void onScrollStart({required bool isUserDrag}) {
    if (isUserDrag) _dragging = true;
  }

  /// 收到 `ScrollEndNotification`；返回**是否记了一次"用户停手"**
  bool onScrollEnd({required DateTime now}) {
    final bool record = _dragging;
    _dragging = false; // 无论哪种结束都复位，别留脏
    if (record) lastUserStopAt = now;
    return record;
  }
}

class PdfReadingPageState extends State<PdfReadingPage>
    implements PdfReadSessionListener {
  final PdfReadSession _session = PdfReadSession.instance;

  final ScrollController _scroll = ScrollController();

  /// 每页的 Key：`Scrollable.ensureVisible` 用它平滑滚过去
  final Map<int, GlobalKey> _pageKeys = <int, GlobalKey>{};

  /// 页高缓存：滚动落地后推算「当前在第几页」要用
  final List<double> _pageExtents = <double>[];

  /// 自动跟随（滚动）（规则见 [PdfPageTurnController]）
  late final PdfPageTurnController _turn;

  PdfDocument? _document;
  Object? _error;

  /// 控制栏是否收起成迷你条
  ///
  /// 用**静态字段**跨页面记住（对齐 HANDOFF §4.43 / §4.92），不写设置 ——
  /// 这是界面偏好，不是用户数据。
  static bool _controlCollapsed = false;

  /// 朗读位置滚出视野 → 显示「回到朗读位置」
  bool _backToReading = false;

  /// 用户手动滚动期间不强行把视图拉回朗读位置
  bool _userScrolling = false;
  Timer? _scrollIdle;

  /// 滚动落地的去抖（纵向滚动没有 onPageChanged，得自己推当前页）
  Timer? _settleDebounce;
  int _lastSettledPage = 0;

  /// 目录
  List<DocumentOutlineEntry> _outline = const <DocumentOutlineEntry>[];

  // ---------------- 只给测试 / 排查用的口子 ----------------

  /// 滚动动画目标（**诊断用**）
  ///
  /// §4.69 的教训：漂移基本都是「有两个东西各自在滚」。要定位就必须知道
  /// **当前有没有动画在跑、它要去哪**，只看最终位置是分不出谁的锅的。
  double? _scrollAnimTarget;
  String? _scrollAnimWho;

  /// 最近一次「往下滚」是谁发起的（诊断用）
  String? get debugLastScrollWho => _scrollAnimWho;

  /// 当前滚动动画的目标偏移（没有在跑则为 null）
  @visibleForTesting
  double? get debugScrollAnimTarget => _scrollAnimTarget;

  /// 跟随定位的诊断快照（**只给测试 / 真机排查看**）
  ///
  /// 照 HANDOFF §4.91 的 `ReaderPage.debugFollowSnapshot()` 的思路：
  /// 「高亮漂移 / 找不到框」这类问题必须一次把链路里的关键量都拿出来 ——
  /// 当前句在哪、那一页建出来没有、框在屏幕的什么位置、几个闸门什么状态、
  /// 有没有动画在跑、是谁发起的。
  @visibleForTesting
  Map<String, Object?> debugFollowSnapshot() {
    final ref = _session.current;
    final metrics =
        _scroll.hasClients ? _scroll.position : null;
    Rect? pageRect;
    Rect? sentenceRect;
    var anchorBuilt = false;
    if (ref != null) {
      final ctx = _pageKeys[ref.pageIndex]?.currentContext;
      final box = ctx?.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        anchorBuilt = true;
        pageRect = box.localToGlobal(Offset.zero) & box.size;
        final layer = _session.layerOf(ref.pageIndex);
        if (layer != null &&
            ref.sentenceIndex >= 0 &&
            ref.sentenceIndex < layer.sentences.length) {
          final bounds = layer.sentences[ref.sentenceIndex].bounds;
          final scale = layer.pageSize.width <= 0
              ? 1.0
              : box.size.width / layer.pageSize.width;
          sentenceRect = Rect.fromLTWH(
            pageRect.left + bounds.left * scale,
            pageRect.top + bounds.top * scale,
            bounds.width * scale,
            bounds.height * scale,
          );
        }
      }
    }
    final viewport = metrics == null
        ? null
        : Rect.fromLTWH(0, 0, metrics.viewportDimension, metrics.viewportDimension);
    return <String, Object?>{
      'page': ref?.pageIndex,
      'sentence': ref?.sentenceIndex,
      'text': ref?.text,
      'layerCached': ref == null ? null : _session.layerOf(ref.pageIndex) != null,
      'displayedPage': _turn.displayedPage,
      'pageCount': _session.pageCount,
      'turning': _turn.isTurning,
      'userDriven': _turn.userDriven,
      'anchorBuilt': anchorBuilt,
      'pageRect': pageRect,
      'sentenceRect': sentenceRect,
      'scrollPixels': metrics?.pixels,
      'viewportDim': metrics?.viewportDimension,
      'viewport': viewport,
      'backToReading': _backToReading,
      'userScrolling': _userScrolling,
      'animTarget': _scrollAnimTarget,
      'animWho': _scrollAnimWho,
      'user': _session.current != null && _turn.userDriven,
    };
  }

  @visibleForTesting
  PdfPageTextLayer? debugPageLayer(int pageNumber) =>
      _session.layerOf(pageNumber - 1);

  @visibleForTesting
  int? get debugReadingPage => _session.current?.pageIndex;

  @visibleForTesting
  int? get debugReadingSentence => _session.current?.sentenceIndex;

  /// 本页要高亮的**句索引**（null = 本页不画）
  ///
  /// ★v1.21.43 模型 A：返回类型从 `(int, int)?`（字符区间）改成 `int?`（句索引）——
  /// 一句跨两页时两页各自返回"本页那一半"的句索引，于是**两页都画**。
  @visibleForTesting
  int? debugHighlightFor(int pageNumber) => _highlightFor(pageNumber);

  /// 一句跨两页时，它在**续页**的句索引（null = 当前句不跨页）
  @visibleForTesting
  int? get debugSpanEndPage => _session.currentSpanEnd?.pageIndex;

  @visibleForTesting
  int? get debugSpanEndSentence => _session.currentSpanEnd?.sentenceIndex;

  @visibleForTesting
  bool get debugBackToReading => _backToReading;

  @visibleForTesting
  bool get debugControlCollapsed => _controlCollapsed;

  @visibleForTesting
  PdfPageTurnController get debugTurn => _turn;

  /// 当前落地页（**测试用**：验证「滚动请求次数 ≪ 快进次数」§4.100 任务 C）
  @visibleForTesting
  int debugDisplayedPage() => _turn.displayedPage;

  @visibleForTesting
  double debugScrollPixels() =>
      _scroll.hasClients ? _scroll.position.pixels : -1;

  /// 同一个目标页连续进入「恢复位置」[times] 次（**测试用**）
  ///
  /// 复现真机 v1.21.36+87 那条红判据：同一帧里 `_revealToPageIndex` 被重复下发，
  /// 每次 `attempt == 0` 都记一笔滚动事件 → R6「连续快速滚动」误判。
  /// 用例断言"只记一次"（见 `integration_test/pdf_restore_dedupe_test.dart`）。
  @visibleForTesting
  void debugRevealPageRepeatedly(int pageIndex, {int times = 5}) {
    for (var i = 0; i < times; i++) {
      _revealToPageIndex(pageIndex);
    }
  }

  /// 已记录的滚动事件条数（**测试用**：数"恢复位置"这类触发被记了几次）
  @visibleForTesting
  int debugTurnEventCount() => SpeechDiagnostics.instance.turnEventCount;

  /// 确保某页（1 起页码）的文本层已加载（**测试用**：让命中测试有东西可点）
  @visibleForTesting
  Future<void> debugEnsureLayer(int pageNumber) =>
      _session.ensureLayer(pageNumber - 1);

  /// 直接滚到某个像素偏移（**测试用**）
  ///
  /// 设备用例要把某一页滚进视野。用 `animateTo` 在 `runAsync` 里推会被
  /// 合并/取消 —— 实测「单独跑通过、整套跑挂在第一页」。`jumpTo` 是同步
  /// 落位，确定得多。
  @visibleForTesting
  bool debugJumpToOffset(double offset) {
    if (!_scroll.hasClients) return false;
    _scroll.jumpTo(offset.clamp(
      _scroll.position.minScrollExtent,
      _scroll.position.maxScrollExtent,
    ));
    return true;
  }

  @override
  void initState() {
    super.initState();
    _turn = PdfPageTurnController(pageCount: 0);
    _turn.jumpTo = _jumpToPage;
    _turn.animateTo = _animateToPage;
    // 设备用例要复现「用户滑动过 → 切书 → 点继续」，需要拿到本页的闸门实例
    PdfPageTurnController.debugActiveForTest = _turn;
    // 先把当前会话的位置认下来（重进时能接着上次的页）
    final current = _session.current;
    if (current != null) _lastSettledPage = current.pageIndex;
    _session.attach(this);
    // ⚠️ 必须监听会话：文本层是**异步**抽出来的，抽完只会让会话 `notifyListeners()`，
    // 不会自动让本页重建。少了这一行，凡是「首次 build 时层还没在缓存里」的页
    // 就会**永远显示成没有文字层** —— 于是点句没反应
    //（实测：会话缓存里明明有 `[0,1,2]` 三层，组件那侧还是「无层」）。
    _session.addListener(_onSessionChanged);
    unawaited(_open());
  }

  @override
  void dispose() {
    // ⚠️ 只 detach，**不 stop** —— 退出阅读页朗读继续（HANDOFF §4.60）
    _session.removeListener(_onSessionChanged);
    _session.detach(this);
    _scrollIdle?.cancel();
    _settleDebounce?.cancel();
    // 设备用例的全局引用要跟着本页一起清掉（避免指向已 dispose 的闸门）
    if (identical(PdfPageTurnController.debugActiveForTest, _turn)) {
      PdfPageTurnController.debugActiveForTest = null;
    }
    _turn.dispose();
    _scroll.dispose();
    _tocPageInput.dispose(); // 目录里的页码输入框（v1.21.56 新增）
    super.dispose();
  }

  /// 会话状态变了（文本层加载完成 / 播放状态变化）→ 重建
  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _open() async {
    // ★v1.22.24 计时（走 logcat 的 flutter 行，真机直接量，不用导日志）
    final Stopwatch sw = Stopwatch()..start();
    void stage(String name) {
      // ignore: avoid_print
      print('PDF_OPEN $name ${sw.elapsedMilliseconds}ms');
    }
    try {
      final doc = await PdfDocument.openFile(widget.filePath);
      stage('pdfrx-open');
      if (!mounted) {
        await doc.dispose();
        return;
      }
      final pageCount = doc.pages.length;
      setState(() {
        _document = doc;
        _pageExtents
          ..clear()
          ..addAll(List<double>.filled(pageCount, 0));
      });
      // 闸门补上真实页数（initState 时文档还没打开，只能给 0；
      // pageCount<=0 会把每一次滚动请求静默吞掉 —— §4.100 任务 C），
      // 并按会话已有位置认下初始页（重进时「已在目标页」不该再翻一次）。
      //
      // ⚠️ v1.21.43（P0-2）：这里**必须用 resetForDocument 而不是 attach**。
      // 本页的 `_turn` 虽是新建实例，但**同一页实例也可能被复用**去开另一本书
      // （会话是单例，页面重进时不保证拿到干净闸门）；更要紧的是 `_userDriven`
      // 一旦为 true，之后每一次跟读都会被 `turnTo` 静默挡下 —— 用户症状就是
      // 「切书后点继续不显示高亮、不跳页」。所以换书路径统一走复位。
      _turn.resetForDocument(
        pageCount: pageCount,
        initialPage: _session.current?.pageIndex,
      );
      // 页内去重变量与闸门的 `_displayedPage` 是**两个**状态，必须一起复位：
      // 只复位一个会让 `_scheduleSettle` 因 `page == _lastSettledPage` 提前 return，
      // 于是闸门永远收不到"落位完成"，`_turning` 一直挂着挡后续滚动。
      _lastSettledPage = _session.current?.pageIndex ?? 0;
      // 会话接管：同一本书重进会保留位置与文本层缓存。
      //
      // ⚠️ 这里**只给 layerLoader、不给 docRef**：页面自己已经打开了 doc，
      // 再给一个 `PdfDocumentRefFile` 会让会话去走「重新加载整份文件」的路径，
      // 内存直接翻倍（HANDOFF §4.3 的教训：PDF 加载是最贵的一步）。
      final opened = doc;
      await _session.open(
        documentId: widget.documentId ?? widget.filePath,
        title: widget.title,
        pageCount: pageCount,
        layerLoader: (pageIndex) async {
          if (pageIndex < 0 || pageIndex >= opened.pages.length) return null;
          // ★v1.21.45 改动 3：几何异常 → 由本页提示一次（见 _onTextLayerGeometry）
          return loadTextLayer(
            opened.pages[pageIndex],
            onGeometry: _onTextLayerGeometry,
          );
        },
      );
      stage('session-open');
      if (!mounted) return;
      // ★★ v1.21.43 · 第 4 步：**恢复之后**再对齐一次闸门（单一真相源 = _session.current）
      //
      // 上面 `resetForDocument`（在 `open()` 之前）拿到的是**恢复之前**的页码；
      // 真正的恢复发生在刚刚这个 `await _session.open(...)` 里。
      // 所以这里必须**按恢复后的位置**再对齐一次，否则：
      //   · 朗读从 21 开始，画面停在 15（真机两次复现的 6 页/1 页偏差）；
      //   · `_userDriven` 万一被程序化滚动置真，后续跟读会被静默挡下。
      // 进场居中重新武装（重进 / 换书都要）
      _firstCenterPending = true;
      _syncGateToSession();
      // 首页的文本层先备好，用户一点就有反应
      final startIndex = _session.current?.pageIndex ?? 0;
      unawaited(_session.ensureLayer(startIndex).then((_) => stage('first-layer')));
      stage('ready-for-frame');
      unawaited(_loadOutline());
      // ⚠️ §4.100 任务 D 症状②/③：新实例（从文档库重进 / 结束朗读后重进）
      // 必须把画面带到会话当前页 —— 原来 initState 只认了 `_lastSettledPage`，
      // ListView 却还是从第 0 页开始，「会话位置在、画面不在」就是这么来的。
      if (startIndex > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _revealToPageIndex(startIndex);
        });
      }
    } catch (e) {
      CrashLog.mark('打开 PDF 失败：$e');
      if (mounted) setState(() => _error = e);
    }
  }

  /// **把闸门与页内记账对齐到"会话当前页"**（v1.21.43 · 第 4 步）
  ///
  /// ## 为什么单独立一个方法（而不是继续散着写）
  ///
  /// 「定位不准」的根因是**同一件事有两个真相源**：
  /// · 会话的 `_current`（谁在读哪一页）；
  /// · 闸门的 `_displayedPage` + 页内的 `_lastSettledPage`（画面在哪一页）。
  ///
  /// 恢复路径原来只在 `open()` **之前**给闸门赋过一次值 —— 那次拿的是旧位置，
  /// 之后**再无对齐**。于是两个真相源永久分叉（真机：会话 21、画面 15）。
  ///
  /// 这里把它们**收拢到一处**：凡是要"对齐"的地方都调它，不再各写一份。
  /// 调用点：
  /// · `_open()` 里 `session.open()` **之后**（恢复路径）；
  /// · `_scrollToReading()`（用户点「回到朗读位置」）。
  void _syncGateToSession() {
    final page = _session.current?.pageIndex;
    if (page == null) return;
    final int before = _turn.displayedPage;
    final bool wasUserDriven = _turn.userDriven;
    _turn.resetForDocument(pageCount: _turn.pageCount, initialPage: page);
    _lastSettledPage = page;
    CrashLog.mark('AF[闸门对齐] 会话页=$page 闸门 $before→${_turn.displayedPage} '
        '本页记账=$_lastSettledPage userDriven $wasUserDriven→${_turn.userDriven}');
  }

  /// 读目录（PDF 书签）；失败按「没有目录」处理
  Future<void> _loadOutline() async {
    try {
      // 复用既有实现（Syncfusion 读书签，HANDOFF §4.90 之前的做法）
      final entries = await readPdfOutline(widget.filePath);
      if (!mounted) return;
      setState(() => _outline = entries);
    } catch (_) {
      // 没有目录不影响朗读
    }
  }

  // ---------------- PdfReadSessionListener ----------------

  /// **跟随路径回退开关**（v1.21.43 · 模型 A · S2a）
  ///
  /// `true`  = 新路：`centerOnSentence(ref)` —— 让朗读句滑到屏幕对齐位置
  /// `false` = 旧路：`_turnToWithRetry(ref.pageIndex)` —— 旧的"滚动状态机"
  ///
  /// ## 为什么留这个开关
  ///
  /// S2a 是**唯一切换运行行为的一步**。留着它，真机一旦出问题
  /// **改一个 bool 就能回旧路**，不用回退整个 S2a。
  ///
  /// ⚠️ **旧路只在 S3 删状态机之前回得去** —— S2a 里 `_turnToWithRetry`
  /// 与 `PdfPageTurnController` 都在位，翻 `false` 是**完整的旧行为**
  /// （含自动解闸 / 下一帧重试 / `AF[turnTo挡下]`，这些是新路**没有**的）。
  /// S3 删掉状态机后本开关作废，**届时一并删除**。
  ///
  /// ## 📌 TODO（S3，本步不实现）
  ///
  /// **1. force 三入口要切到新路。**
  /// 它们现在的语义是「用户立刻到某处」，而实现走的是
  /// `_turn.turnTo(pageIndex, force: true)` = **"跳到第 N 页"**（旧模型）。
  /// 新模型下应当走
  /// `centerOnSentence(ref, force: true, forceCenter: true)` =
  /// **"滚到那页那句并居中"** —— 后者才是用户真正要的（页面+句一起对齐）。
  /// 三处入口：`_scrollToReading`（回到朗读位置）、`_jumpToAndRead`（目录跳转）、
  /// `_readSentence`（点句朗读）。
  ///
  /// **2. `AF[turnTo开始]` 在生产路径里应只剩「首次进入定位」一处。**
  /// 即 `initState` 之后那次 `_revealToPageIndex(startIndex)`。其余触发源
  /// （跟读 / 跨页 / force 三入口）全切新路后，这条日志在跟读期间**不应再出现**。
  /// **真机判据**：连读十几句，`AF[turnTo开始]` 只应在**进入阅读页那一拍**出现一次。
  static const bool useSentenceCenterFollow = true;

  /// 页面刚打开、还没做过「进场居中」
  ///
  /// 只为进场那一拍服务：第一句要突破死区强制居中（见 `onSentenceChanged`），
  /// 之后仍按日常跟读的死区/让位规则走。
  bool _firstCenterPending = true;

  @override
  void onSentenceChanged(PdfSentenceRef ref) {
    if (!mounted) return;
    setState(() {});
    // ⚠️ 术语（v1.21.43）：PDF 朗读没有"翻页"，只有"让朗读句上下滑动到
    // 可见 / 对齐位置"（见 `sentence_centering.dart` 顶部术语表）。
    //
    // 新旧两条路的区别：
    // · 旧路 `_turnToWithRetry` —— 按**页**驱动：算"要不要换页 / 跨度多大 /
    //   瞬时还是动画"，再等落位回调确认。它假设底层是 PageView，
    //   而底层**一直是连续滚动的 ListView** → 那层抽象是多余的。
    // · 新路 `centerOnSentence` —— 直接算"这一句要滚到哪个偏移"，
    //   没有闸门、没有落位确认、没有页跨度概念。
    //
    // `_userScrolling` 守卫**保留**（开关 A：任何滑动 → 立刻让位，
    // 不等任何秒数）。它是第一道闸；`centerOnSentence` 内部还有第二道。
    if (!_userScrolling) {
      if (useSentenceCenterFollow) {
        // ★v1.22.24 修「从文档库进入 PDF，朗读句不在中间」
        //
        // 真机（平板，2026-10-19）：恢复位置后页面停在 alignment=0.15 的位置，
        // 而朗读句常常在页面下半部分 → 开屏就"看不见在读哪句"。
        //
        // 原因是进场这一拍走的是默认参数（forceCenter=false）：
        // 死区判定认为"已经够近"，于是**不滚**（日志 `死区=内 → 不滚`）。
        // 进场属于 sentence_centering 文档里写明的「首次进入 → forceCenter=true」
        // 场景，第一句必须无条件对齐到中间。
        final bool firstCenter = _firstCenterPending;
        _firstCenterPending = false;
        centerOnSentence(ref, forceCenter: firstCenter);
      } else {
        _turnToWithRetry(ref.pageIndex);
      }
    }
    // AF 埋点（v1.21.43 · P0-1）：跟读每一拍都记一条，用来和"位置写盘"对时间线。
    // ⚠️ 只在跟读时打（低频于每句一次的朗读事件，但足以还原竞态）；
    // 若日志量太大，把它收进诊断开关即可（见 v1.21.42 交接 §⑧ 的噪音约定）。
    _af('跟读');
  }

  /// 跟读滚动：**接住闸门的返回值，并允许重试一次**（v1.21.43 · P0-2）
  ///
  /// ## 为什么必须接返回值（真机症状：高亮不显示 / 不跳转朗读页）
  ///
  /// `turnTo` 有**三个会静默返回 false 的出口**：
  /// · `pageCount <= 0`（文档还没打开完）；
  /// · `_userDriven && !force`（用户手动滑过页）；
  /// · `_turning && !force`（上一次落位还没完成）。
  ///
  /// 原来调用方**把返回值丢掉**了 —— 一旦被挡，这一拍的跟读就**永久丢失**，
  /// 没有任何重试。表现就是用户报的「不显示高亮、不跳转朗读页、跳错页」。
  ///
  /// 现在：被挡就**下一帧重试一次**（多数情况是 `_turning` 恰好没落地，
  /// 一帧后就好了）；仍失败才记 `AF[turnTo挡下]`，把三个出口的原因写清楚。
  ///
  /// ## ⚠️ v1.21.43 · 第 3 步：`userDriven` 要能**自动解闸**
  ///
  /// 原来 `_userDriven` **永不过期** —— 用户滑过一次之后，只有
  /// 「回到朗读位置」或「点句朗读」两处显式指令会清它。
  /// 于是跟读**永久停摆**：朗读从 21 页读到 23 页，画面一直卡在 21，
  /// 而且**连 `AF[turnTo挡下]` 都不会打**（因为 `_userScrolling` 先一步
  /// 把整段跳过了）—— 用户症状就是"自动跟随滚动很迟钝 / 根本不翻"。
  ///
  /// 现在按**双条件**自动解闸（用户拍板的语义）：
  /// · 条件一：朗读**真的推进到新的一页**（`ref.pageIndex` 与闸门当前页不同）；
  /// · 条件二：用户**停止滑动满 2 秒**（不打断他当前的操作）。
  ///
  /// 只满足一个就**不解**，跟读只推进、不抢画面 —— 防"刚滑走就被抢回"，
  /// 也防"永久锁死"。
  void _turnToWithRetry(int pageIndex, {bool isRetry = false}) {
    // ★ S2a 静默点 ②（**防御性**：开关为 true 时已经没有调用点了）
    // 留着它是为了"将来任何一处漏判都不会重新打通旧路"。
    if (useSentenceCenterFollow) {
      CrashLog.mark('AF[旧路静默] _turnToWithRetry page=${pageIndex + 1}');
      return;
    }
    final ok = _turn.turnTo(pageIndex);
    if (ok) return;
    // ★被挡了：先看看该不该自动解闸（只对 userDriven 这一种挡法）
    if (_turn.userDriven && _canAutoResumeFollow(pageIndex)) {
      _turn.resumeAutoFollow();
      _lastSettledPage = pageIndex;
      if (_turn.turnTo(pageIndex)) {
        // ⚠️ 措辞必须是"**已请求**滚动"，不能写"已翻"（v1.21.43 修）：
        // `turnTo` 返回 true 只表示**滚动请求已发出**，不代表画面真的到位 ——
        // 真正到位要等 `onPageSettled` / `onRevealFinished` 落位确认，
        // 那一条叫 `AF[真落位]`（见闸门里那两处）。
        // 旧措辞"已翻"会让排查者以为"滚动到位了"，而实测里
        // `已翻` 之后 `disp` 仍可能停在旧页（假已翻）。
        CrashLog.mark('AF[自动解闸] 朗读已推进到第 $pageIndex 页且用户停手'
            '满 ${_autoFollowGrace.inSeconds} 秒 → 恢复跟读，已请求滚动'
            '（是否真到位看 AF[真落位]）');
        return; // ★成功就返回：**不再打 AF[turnTo挡下]**
      }
      // ★解闸了但这一拍仍没翻成（多半是 `_turning` 还没落地）。
      // 打一条**自己的**记录，然后走重试 —— 绝不再打 "原因=userDriven"
      // （那会让人以为解闸没生效；用户明确要求这两条不许同时出现）。
      CrashLog.mark('AF[自动解闸] 朗读已推进到第 $pageIndex 页且用户停手'
          '满 ${_autoFollowGrace.inSeconds} 秒 → 已恢复跟读，但这一拍仍被'
          '${_turn.isTurning ? "turning" : "其它"}挡住，转下一帧重试');
    }
    if (!isRetry) {
      // 下一帧再试一次：`_turning` 的超时兜底是 700ms，一帧不够就等一帧，
      // 这里只重试一次（不做循环重试，避免和用户手动滚动打架）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_userScrolling) return; // 用户正在滑：这一拍让给他
        _turnToWithRetry(pageIndex, isRetry: true);
      });
      return;
    }
    // 两次都被挡：如实记录「谁挡的」，别让它继续无声无息
    _af('turnTo挡下 page=$pageIndex '
        '原因=${_turn.pageCount <= 0 ? "pageCount<=0" : (_turn.userDriven ? "userDriven" : (_turn.isTurning ? "turning" : "未知"))}');
  }

  /// **AF 统一埋点**（v1.21.43 · P0-1）
  ///
  /// 用户报的两个症状（高亮不显示 / 跳转不准 / 通知栏不同步）都是**竞态**，
  /// 断点断不出来，只能靠一条字段齐全的日志事后还原。所以这里把
  /// 「谁在读、哪一拍、闸门什么状态、播放态如何」一次打全：
  ///
  /// ```
  /// AF[<动作>] doc=… src=… key=… token=… ref=… cur=… disp=…
  ///            userDriven=… turning=… playing=… paused=…
  ///            hasSession=… speaking=… borrowed=… seq=…
  /// ```
  ///
  /// 字段来源（避免各写一份各自漂移）：
  /// · `doc/src/key/token/ref/cur/playing/paused/hasSession/seq` → [PdfReadSession]
  /// · `speaking/borrowed` → [TtsManager]（PDF 借它发声，这两个是它的状态）
  /// · `disp/settled/userDriven/turning` → 本页的滚动跟随时序与页内落位
  ///
  /// ## ⚠️ `cur` 字段的坑（v1.21.43 修）
  ///
  /// 原来 `cur=` 打的是 `_lastSettledPage`（**页内**落位去重变量），
  /// 而它只在「滚动落位且页码变化」时才更新 —— **同一页内逐句推进时页面不滚动**，
  /// 于是 `cur=` **恒为 0**。真机日志里满屏 `cur=0`，排查时会误以为"位置丢了"。
  ///
  /// 现在拆成两个语义明确的字段：
  /// · `cur=` = **会话当前句**（`session.current`，与 `ref` 同源、可互相对照）；
  /// · `settled=` = 页内落位去重值（页面跟读状态的旁证）。
  void _af(String action) {
    final session = PdfReadSession.instance;
    final tts = TtsManager.instance;
    final ref = session.current;
    // ⚠️ 口径统一（v1.21.43 · 真机日志暴露的问题）：
    // **`refPage` / `curPage` 一律 1-based**，与界面"第 N 页"、
    // `位置[PDF恢复] 落定=`、`AF[居中] refPage=` **完全同口径**，可直接对比。
    //
    // 原来这里打的是 `${ref.pageIndex}`（**0-based 原始索引**），
    // 而 `AF[居中]` 打的是 `pageIndex + 1` —— 同一时刻同一次朗读，
    // 两条日志的页码差 1，排查时极易误判成"位置不一致 / 错位"。
    // 原始索引要看就**另起字段名**（`refPage0`），绝不与页码混用一个名字。
    CrashLog.mark('AF[$action] '
        'doc=${session.documentId ?? '-'} '
        'src=pdf-session '
        'key=${session.sessionKey} '
        'token=${session.tokenForDiag} '
        'refPage=${(ref?.pageIndex ?? -1) + 1} '
        'refSent=${ref?.sentenceIndex ?? -1} '
        'curPage=${(ref?.pageIndex ?? -1) + 1} '
        'refPage0=${ref?.pageIndex ?? -1} '
        'settled=$_lastSettledPage '
        // ★v1.21.43：删掉 `disp=`，改成与 `AF[居中]` **同源**的"视口页"。
        //
        // 原来这里打的是旧状态机的 `_turn.displayedPage`。旧路被静默之后
        // 它**不再变化**（会冻在最后一个值上），排查时会被当成"画面没动"
        // —— 又一个误导源。现在两条埋点都读**滚动位置反推**的视口页，
        // 可以逐拍互相印证。
        '视口页=${viewportPageForJudgement(_scroll.hasClients ? _scroll.position.pixels : 0) ?? "?"} '
        'userDriven=${_turn.userDriven} '
        'turning=${_turn.isTurning} '
        'playing=${session.isPlaying} '
        'paused=${session.isPaused} '
        'hasSession=${session.hasSession} '
        'speaking=${tts.speaking} '
        'borrowed=${tts.isBorrowedForOther} '
        'seq=${session.spotSeqForDiag}');
  }

  @override
  void onPageShouldTurn(int pageIndex) {
    if (!mounted) return;
    // ★★ v1.21.43 · S2a 静默点 ①（**真正漏掉的那一处**）
    //
    // 会话侧共 5 个 `onPageShouldTurn` 调用点，其中三个（`jumpToPage` 两处、
    // 推进循环 `:902`）是"**进页就调、不管是否跨页**"。S2a 只改了
    // `onSentenceChanged`，于是每次跨页都**先新滚一次、再旧滚一次** ——
    // 真机硬证据（新旧同拍）：
    // ```
    // 22:38:23.879  AF[居中] → 滚动                        ← 新路
    // 22:38:23.885  AF[turnTo开始] 第 18 页 距离=1（动画）  ← 旧路（就是这里）
    // 22:38:29.440  AF[居中] 死区=内 → 不滚                 ← 新路判定正确
    // 22:38:29.446  AF[turnTo开始] 第 18 页 …               ← 旧路照样滚
    // ```
    //
    // ⚠️ 静默它**不会丢掉"跨页强制居中"**：推进路径是
    // 「先 `onSentenceChanged`（→ `centerOnSentence`），跨页时才补
    // `onPageShouldTurn`」，而 `centerOnSentence` 内部靠
    // `ref.pageIndex != _lastCenteredPageIndex` **自己就能发现跨页**并强制对齐。
    if (useSentenceCenterFollow) {
      CrashLog.mark('AF[旧路静默] onPageShouldTurn page=${pageIndex + 1} '
          '（新路接管：跨页由 onSentenceChanged → centerOnSentence 自行发现）');
      return;
    }
    _turn.turnTo(pageIndex);
  }

  @override
  void onFinished() {
    if (!mounted) return;
    // 整篇读完：收起控制栏（会话保留，方便再点播放）
    setState(() => _controlCollapsed = true);
  }

  @override
  void onPlaybackStateChanged() {
    if (mounted) setState(() {});
  }

  // ---------------- 滚动落位 ----------------

  /// 瞬时落位（大跨度）：直接跳，不做逐页动画（HANDOFF §4.90）
  ///
  /// ⚠️ §4.100 任务 C：目标页**还没被 ListView 建出来**时 `_offsetOfPage`
  /// 会算不出偏移，旧实现这时直接 return —— 于是「闸门发了滚动、画面却
  /// 不动」（修完跟读收编进闸门后，这条路径就是唯一跟读通道，绝不能静默丢）。
  /// 现在统一委托 [_revealToPageIndex] 的逐帧收敛定位：先按已量页高逼近，
  /// 目标页建出来后再 ensureVisible 精确对齐。
  void _jumpToPage(int pageIndex) {
    // ★ S2a 静默点 ③：状态机的两条落位通道之一（绑在 `_turn.jumpTo`）。
    // 只要 `onPageShouldTurn` 被静默它就进不来，但**做防守**：
    // 任何一个漏判都不该重新把旧路打通。
    if (useSentenceCenterFollow) {
      CrashLog.mark('AF[旧路静默] jumpTo page=${pageIndex + 1}');
      return;
    }
    _revealToPageIndex(pageIndex);
  }

  /// 记一笔「这次滚动是谁发起的、要去哪」（诊断用，见 [debugFollowSnapshot]）
  void _noteScrollDriver(String who, double target) {
    _scrollAnimWho = who;
    _scrollAnimTarget = target;
  }

  /// 相邻页：带动画（同样走收敛定位，ensureVisible 自带 300ms 动画）
  void _animateToPage(int pageIndex, Duration duration) {
    // ★ S2a 静默点 ④：状态机的另一条落位通道（绑在 `_turn.animateTo`）
    if (useSentenceCenterFollow) {
      CrashLog.mark('AF[旧路静默] animateTo page=${pageIndex + 1}');
      return;
    }
    _revealToPageIndex(pageIndex);
  }

  /// 某一页在滚动内容里的偏移
  ///
  /// 优先用已渲染那一页的实际位置（最准）；还没渲染出来就按已量到的
  /// 页高累加估算。
  double? _offsetOfPage(int pageIndex) {
    final ctx = _pageKeys[pageIndex]?.currentContext;
    final box = ctx?.findRenderObject();
    if (box is RenderBox && _scroll.hasClients) {
      final viewport = RenderAbstractViewport.of(box);
      return viewport.getOffsetToReveal(box, 0).offset;
    }
    // 估算：把前面已量到的页高加起来
    if (_pageExtents.isEmpty || pageIndex >= _pageExtents.length) return null;
    var sum = 0.0;
    for (var i = 0; i < pageIndex; i++) {
      final extent = _pageExtents[i];
      if (extent <= 0) return null; // 有一段没量到，估算不可靠
      sum += extent;
    }
    return sum;
  }

  /// 用户手动滚动后，最后一次"手离开屏幕"的时刻（v1.21.43 · 第 3 步）
  ///
  /// 用途：**自动接管**里那个"停止滑动 ≥ N 秒"。`null` = 用户从没滑过。
  DateTime? _lastUserScrollEndAt;

  /// **"用户停手"计时器**（本轮修：程序滚动不许冒充用户停手）
  ///
  /// 规则与真机证据见 [UserScrollStopTracker] 的类注释。
  final UserScrollStopTracker _scrollStop = UserScrollStopTracker();

  /// **停手多久才允许自动接管**（v1.21.43 模型 A：2 秒 → **4 秒**）
  ///
  /// 为什么从 2 秒改成 4 秒：那个 2 秒是**在旧的"滚动状态机"语义下调的** ——
  /// 它当时要同时兼顾"翻页别太慢"和"别抢用户"。现在只有一件事
  /// （让朗读句待在屏幕对齐位置），**没有延迟压力**，纯让位语义 →
  /// 4 秒更合适：用户滑完想停下来看一眼，2 秒太短，容易被拽走。
  static const Duration _autoFollowGrace = Duration(seconds: 4);

  /// **两个独立开关**（用户拍板：不是"停手 4 秒才让位"）
  ///
  /// * 开关 A（[用户滑动]）—— **任何滑动 → 立刻停止自动滚动**，不等任何秒数。
  ///   见 [_onScrollNotification] 里 `ScrollStartNotification` 的处理。
  /// * 开关 B（[允许自动接管]）—— 停手满 [_autoFollowGrace]（4 秒）**才允许**接管。
  ///   它是 A 的**后续许可**，不是替代：任何滑动都会**立刻重置** B 的计时。
  ///
  /// ⚠️ 旧实现只有一条判据（`_userScrolling`），把"让位"和"接管"
  /// 糊在同一处 → 语义不清，且 `_userScrolling` 为真时会**整段跳过**滚动跟随。
  /// 现在拆开：A 负责"马上停"，B 负责"什么时候可以再动"。
  bool get _userStoppedScrollingLongEnough {
    final at = _lastUserScrollEndAt;
    if (at == null) return true; // 从没滑过：不算"正在操作"
    return DateTime.now().difference(at) >= _autoFollowGrace;
  }

  /// 页号显示的防抖（见 [_refreshDisplayedPageLabel]）
  Timer? _pageLabelDebounce;

  /// **页号进度显示用的页码**（v1.21.43 模型 A）
  ///
  /// 模型 A 里页号**只用于进度显示**，不再参与任何滚动判断 ——
  /// 所以它可以从滚动位置反推，而且**允许滞后**。
  ///
  /// 三条规则（用户拍板）：
  /// 1. **滚动中不更新**，停手 200ms 后再更新（否则 812 页里页号会疯狂跳变）；
  /// 2. **算不出来时保持上一次有效值**，从不显示 `?` 或 `0`；
  /// 3. 首次进入用会话恢复的页号做初值（不会从 `0/812` 开始）。
  int? _lastValidPageForDisplay;

  /// 从当前滚动位置反推页号并更新显示值（只在算得出时更新）
  void _refreshDisplayedPageLabel() {
    if (!mounted || !_scroll.hasClients) return;
    final p = _pageAtOffset(_scroll.position.pixels);
    if (p == null) return; // ★算不出 → 保持上一次有效值，不闪
    final next = p + 1; // 对外是 1 起
    if (next == _lastValidPageForDisplay) return;
    setState(() => _lastValidPageForDisplay = next);
    CrashLog.mark('AF[页号] 滚动位置→第 $next 页（仅用于进度显示）');
  }

  /// **该不该自动解闸**（双条件，用户拍板的语义）
  ///
  /// 条件一：朗读真的推进到**新的一页** —— `pageIndex != _turn.displayedPage`。
  /// ⚠️ 这一条同时就是**防抖**：同一页内逐句推进时它不成立，
  /// 所以绝不会"每句都滚"。配合 `turnTo` 自带的 `_turning` 闸门
  /// （一次落位没完成不再发第二次），最终效果是**每页最多翻一次**。
  ///
  /// 条件二：用户停止滑动满 [_autoFollowGrace]（2 秒）—— 见
  /// [_userStoppedScrollingLongEnough]。防"刚滑走就被抢回"。
  bool _canAutoResumeFollow(int pageIndex) {
    if (!_turn.userDriven) return false; // 不是"用户滑过"挡的，不归这里管
    if (pageIndex == _turn.displayedPage) return false; // 同页：不算推进
    if (!_userStoppedScrollingLongEnough) return false; // 用户刚停手，别抢
    return true;
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      // ★本轮修（缺陷 3）：只有**用户拖动**才算"用户在滑"。
      // 原来的判据已经是 `dragDetails != null`，这里只是把它抽成公开纯函数
      // （[PdfReadingPage.isUserDragScrollStart]）以便单测。
      if (PdfReadingPage.isUserDragScrollStart(notification)) {
        _userScrolling = true;
        _turn.markUserDriven();
        // ★用户又开始滑了 → 重置"接管已记录"标志，下次停手满 4 秒会再打一条
        _autoTakeoverLogged = false;
      }
      _scrollStop.onScrollStart(
        isUserDrag: PdfReadingPage.isUserDragScrollStart(notification),
      );
    }
    if (notification is ScrollUpdateNotification) {
      _syncBackToReading();
    }
    if (notification is ScrollEndNotification) {
      _scrollIdle?.cancel();
      // ⚠️ v1.21.43 · 第 3 步：**手一停就交还**，不再等 2 秒。
      //
      // 原来这里靠 `Timer(2000ms)` 才把 `_userScrolling` 放回 false，
      // 而 `_userScrolling` 为真时 `onSentenceChanged` 会**整段跳过滚动**
      // （`:418`）—— 于是"用户滑过一次"之后，跟读要等满 2 秒才开始重新滚动，
      // 而且中途每读一句都白读。用户症状就是"自动跟随滚动很迟钝"。
      //
      // 现在：滚动一结束立刻释放（这是"用户可以跟读了"的时刻）；
      // **2 秒的判定挪到"解闸"那一步**（见 [_maybeResumeAutoFollow]），
      // 即"停止滑动满 2 秒"才允许把画面抢回朗读位置 —— 语义更准确。
      _userScrolling = false;
      // ★本轮修（缺陷 3）：**程序自己的 animateTo 结束时也会发 ScrollEnd** ——
      // 原来在这里无条件写"用户停手时刻"，于是"程序滚完一次"就把
      // 「停手满 4 秒才允许接管」的计时重置，之后 4 秒跟读全部让位
      // （真机 14:52:38.738 `AF[滚动到位]` → 14:52:41.105 `停手仅 2348ms`，
      //  同期 `AF[跟读]` 全是 `userDriven=false`，用户根本没碰屏幕）。
      // 现在只有**用户真实拖动**结束才记（见 [UserScrollStopTracker]）。
      final bool recordedUserStop =
          _scrollStop.onScrollEnd(now: DateTime.now());
      if (recordedUserStop) _lastUserScrollEndAt = _scrollStop.lastUserStopAt;
      // ★停手 200ms 后再更新页号（用户拍板）：滚动中不更新，避免
      // 快速滑动时页号在 812 页里一秒跳几十次。
      _pageLabelDebounce?.cancel();
      _pageLabelDebounce = Timer(const Duration(milliseconds: 200), () {
        _refreshDisplayedPageLabel();
      });
      _scrollIdle = Timer(const Duration(seconds: 2), () {
        // 兜底：极端情况下（没有 ScrollEndNotification）也要恢复
        _userScrolling = false;
      });
      _syncBackToReading();
      _scheduleSettle(notification.metrics);
    }
    return false;
  }

  /// 纵向滚动没有 `onPageChanged`：滚动停下来之后推算落在第几页，
  /// 再告诉闸门「落位完成」（HANDOFF §4.58 的等价物）
  ///
  /// ⚠️ **恢复定位期间不覆盖闸门**（v1.21.43 · 第 4 步）：
  /// 那时页高多半还没量全，反推出来的页码是**估算值**，
  /// 会把 `_displayedPage` 改回旧页（真机表现为"恢复 21、画面停在 15"）。
  /// 所以恢复期只把"落位完成"告诉闸门（清 `_turning`），**不动 `_displayedPage`**。
  void _scheduleSettle(ScrollMetrics metrics) {
    _settleDebounce?.cancel();
    _settleDebounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted || !_scroll.hasClients) return;
      final page = _pageAtOffset(metrics.pixels);
      if (page == null || page == _lastSettledPage) return;
      // ★恢复定位收敛中：这一拍是程序在滚，不是用户的落位，别拿它改闸门
      if (_revealingToPage != null) {
        CrashLog.mark('AF[恢复期跳过反推] 推出来的页码=$page '
            '恢复目标=$_revealingToPage 闸门=${_turn.displayedPage} '
            '（页高未量全，估算不可信）');
        return;
      }
      _lastSettledPage = page;
      _turn.onPageSettled(page);
      _syncBackToReading();
    });
  }

  /// 从滚动偏移反推"主要显示第几页"（1 起），**未量到的页高用估算补齐**
  ///
  /// ⚠️ 这是**判据专用**的版本（`pageAtOffsetForTest` 那个精确版钩子已删：
  /// 它没人调用，且会在远页页高未量到时返回 null，正是本条要修掉的毛病）。
  ///
  /// ## 为什么判据需要"估算版"（实测踩到）
  ///
  /// 设备侧负向验证第一条就红了：滑到 `offset=72583` 时
  /// 精确版返回 **null** —— 它遇到第一个 `extent <= 0` 就放弃，
  /// 而 812 页里**远页的页高压根没量到**（`ListView` 只建可见区域附近的页）。
  ///
  /// 于是判据在"离得远"时算不出视口页 → 只能显示上一次有效值 → **看不出不一致**，
  /// 那这条判据在最需要它的时候（用户大跨度滑走）恰好失效。
  ///
  /// 所以判据用**估算补齐**的版本：逐页累加，没量到的用 fallback 顶替。
  ///
  /// ⚠️ 没有改精确版本身：它服务于 `_scheduleSettle` 的落位判断，
  /// 那里**"算不准就别算"比"算个大概"更安全**（精确语义必须保住）。
  /// —— 等 S3 删掉状态机、`_scheduleSettle` 一并废弃后，
  /// 精确版就只剩判据一个用途，**届时两者可合并**（见交接文档记账）。
  ///
  /// ## ★两次实测修正（TEST10 真机日志逼出来的）
  ///
  /// **修 1：改成"屏幕中心所在页"，不是"屏幕顶部所在页"。**
  /// 原实现返回"视口**顶边**落在哪一页"（第一个 `offset < 累计和` 的页）。
  /// 它会**系统性偏后**：屏幕显示「第 27 页尾部 + 第 28 页整页」时，
  /// 顶边已经落在第 28 页里 → 判成 28，而朗读句明明还在第 27 页 →
  /// 与死区判定（量的是**句的 y**）**结论相反**，看起来像"两个判据打架"。
  /// 朗读句是**居中**的，所以判据也必须以**屏幕中心**为准才自洽。
  ///
  /// **修 2：`fallback` 优先取"已量到的第一个真实页高"，估算只作末选。**
  /// 原来直接用 `_estimatedPageExtent()`（按**第 0 页**宽高比估算），
  /// 而真实页高普遍不同 → 累计和**系统性偏短** → 页号被推后
  /// （实测 `refPage=24` 报 25、`refPage=26` 报 27，稳定偏后 1）。
  /// 绝大多数情况下第 1 页已经渲染过、有真实高度，用它当 fallback 准得多。
  int? viewportPageForJudgement(double offset) {
    if (_pageExtents.isEmpty) return null;
    // fallback 优先用"已量到的第一个真实页高"；一个都没量到才退回估算
    double fallback = 0;
    for (final e in _pageExtents) {
      if (e > 0) {
        fallback = e;
        break;
      }
    }
    if (fallback <= 0) fallback = _estimatedPageExtent() ?? 0;
    if (fallback <= 0) return null;
    // ★以**屏幕中心**为准（与"朗读句居中"同一口径）
    final double half =
        _scroll.hasClients ? _scroll.position.viewportDimension / 2 : 0;
    final double probe = offset + half;
    var sum = 0.0;
    for (var i = 0; i < _pageExtents.length; i++) {
      final e = _pageExtents[i];
      sum += e > 0 ? e : fallback; // 没量到 → 用 fallback 顶
      if (probe < sum) return i + 1;
    }
    return _pageExtents.length;
  }

  /// 从滚动偏移反推的页号**是否用到了估算**（= 是否是近似值）
  ///
  /// 用于埋点显示 `视口页≈17`：只要"目标页之前的页高"里有一个没量到，
  /// 累计和就掺了估算 → 页号可能偏 1-2 页 → **必须标出来，否则会被当成真值**
  /// （用户明确要求：免得每次看到 `⚠️不一致` 以为是 bug）。
  bool viewportPageIsApproximate(double offset) {
    final int? page = viewportPageForJudgement(offset);
    if (page == null) return true;
    // 目标页之前（含目标页）只要有一个没量到，就说明掺了估算
    for (var i = 0; i < page && i < _pageExtents.length; i++) {
      if (_pageExtents[i] <= 0) return true;
    }
    return false;
  }

  /// 滚到某个偏移时「主要显示的是第几页」（0 起；页高缺失时 `null`）
  int? _pageAtOffset(double offset) {
    if (_pageExtents.isEmpty) return null;
    var sum = 0.0;
    for (var i = 0; i < _pageExtents.length; i++) {
      final extent = _pageExtents[i];
      if (extent <= 0) return null;
      sum += extent;
      if (offset < sum) return i;
    }
    return _pageExtents.length - 1;
  }

  /// 朗读位置是否已经不在视野里 → 决定「回到朗读位置」按钮
  ///
  /// ## ⚠️ 两个坑（v1.21.4 修，用户报「回到朗读位置键不生效」）
  ///
  /// 1. **坐标空间必须一致**。原来拿 `box.localToGlobal()`（**屏幕坐标**）
  ///    去比 `metrics.pixels`（**滚动偏移**）—— 两套互不相干的数。
  ///    在这台设备上 `pixels ∈ [0, ~550)` 而页面顶在屏幕 y≈80，
  ///    于是几乎恒判 `visible=true`。现在统一用
  ///    `RenderAbstractViewport.getOffsetToReveal()` 换算成滚动偏移再比。
  /// 2. **赋值反了**。原来是 `if (visible == _backToReading) _backToReading = !visible`，
  ///    可见时算出 `false`、不可见时算出 `true` —— 和 `_backToReading`
  ///    「为真才显示」的语义正好相反。正确写法是
  ///    `if (visible != _backToReading) _backToReading = !visible`。
  void _syncBackToReading() {
    final pageIndex = _session.current?.pageIndex;
    if (pageIndex == null) {
      if (_backToReading) setState(() => _backToReading = false);
      return;
    }
    final ctx = _pageKeys[pageIndex]?.currentContext;
    final box = ctx?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !_scroll.hasClients) {
      // 那一页还没建出来（离得远）：肯定不在视野里 → 要显示按钮
      if (!_backToReading) setState(() => _backToReading = true);
      return;
    }
    // ⚠️ 用 getOffsetToReveal 把「这一页」换算成滚动偏移，再和 position 比 ——
    // 不要再混用 localToGlobal（屏幕坐标）与 pixels（滚动偏移）。
    final position = _scroll.position;
    final reveal = RenderAbstractViewport.of(box)
        .getOffsetToReveal(box, 0, rect: Offset.zero & box.size);
    final pageTop = reveal.offset;
    final pageBottom = pageTop + box.size.height;
    final viewportTop = position.pixels;
    final viewportBottom = viewportTop + position.viewportDimension;
    final visible = pageBottom > viewportTop && pageTop < viewportBottom;
    if (visible == _backToReading) {
      setState(() => _backToReading = !visible);
    }
  }

  /// 某页当前是否**实质可见**（≥50% 落在视口内，判据见
  /// [PdfReadingPage.isPageSubstantiallyVisible]）
  ///
  /// ⚠️ 本轮把"沾边就算"改成"至少一半"：`ListView` 会把视口上下几页**预建**出来，
  /// 老判据（1 像素重叠）会把预建区里的页当成"已到位"，收敛链于是提前结束 ——
  /// 真机表现为「进书定位停在开头几页」。还没建出来一律算不可见。
  bool _isPageIndexVisible(int pageIndex) {
    final ctx = _pageKeys[pageIndex]?.currentContext;
    final box = ctx?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !_scroll.hasClients) return false;
    final reveal = RenderAbstractViewport.of(box)
        .getOffsetToReveal(box, 0, rect: Offset.zero & box.size);
    final top = reveal.offset;
    final bottom = top + box.size.height;
    final pos = _scroll.position;
    return PdfReadingPage.isPageSubstantiallyVisible(
      pageTop: top,
      pageBottom: bottom,
      viewportTop: pos.pixels,
      viewportBottom: pos.pixels + pos.viewportDimension,
    );
  }

  /// 一页大致多高（**估算**，只在「一页都还没量到」时用来起步）
  ///
  /// 页块的实际高度 ≈ 页面渲染高度 + 上下 8px 内边距 + 底部页码文字。
  /// 页面高度由 `AspectRatio(page.width / page.height)` 约束**横向可用宽度**
  /// 算出，所以 `(视口宽 − 左右各 8px) ÷ 宽高比` 就是页面高度。
  /// ⚠️ 不能用 `viewportDimension`：纵向 ListView 里那是**高度**不是宽度。
  /// §4.100 任务 D 的兜底用。
  double? _estimatedPageExtent() {
    final doc = _document;
    if (doc == null || doc.pages.isEmpty) return null;
    final first = doc.pages.first;
    if (first.width <= 0 || first.height <= 0) return null;
    if (!mounted) return null;
    final usable = MediaQuery.sizeOf(context).width - 16; // 左右各 8px 内边距
    if (usable <= 0) return null;
    return usable / (first.width / first.height) + 28.0; // + 上下内边距与页码行
  }

  /// 本帧内正在收敛的目标页（同帧重复进入去重，见 [_revealToPageIndex]）
  int? _revealingFrameTarget;

  /// **恢复定位期间的目标页**（v1.21.43 · 第 4 步）
  ///
  /// ## 治什么（真机症状：画面停在 15，朗读在 21）
  ///
  /// 用户日志（10:25 / 11:43 两次复现）：
  /// ```
  /// 位置[PDF恢复] 落定=21/4 页数=812
  /// AF[跟读] ref=21/4 cur=21/4 settled=15 disp=15   ← 差 6 页
  /// ```
  ///
  /// 根因是**恢复路径的赋值顺序**：
  /// · `resetForDocument`（`:316`）拿的是**恢复之前**的 `_session.current`
  ///   —— 那时位置还没读盘算出来，所以闸门拿到的是旧页码；
  /// · 真正的恢复发生在 `await _session.open(...)`（`:330`）里；
  /// · 之后只滚画面（`_revealToPageIndex`），**再没人把闸门对齐过**。
  ///
  /// 而恢复期间那段滚动本身**不可信**：`_pageAtOffset` 在页高没量全时
  /// 返回 null（`_scheduleSettle` 于是什么都不做），量到的又可能是**估算页高**
  /// 算出来的错页码 —— 会把 `_displayedPage` 改回 15 那种旧值。
  ///
  /// 所以：**恢复收敛期间，只认 `_session.current`，不让滚动反推覆盖闸门。**
  /// 收敛结束（目标页可见）后清空，日常滚动落位照常生效。
  int? _revealingToPage;

  /// 把「第 [pageIndex] 页」带进视野 —— 它可能很远、还没被 ListView 建出来。
  ///
  /// 只在**显式定位**时调用（进入阅读页 / 点「回到朗读位置」），不是每句都调 ——
  /// 日常跟读走滚动跟随时序。逐帧收敛：目标页建出来了就 `ensureVisible` 精确对齐；
  /// 还没建出来就按「已量到的连续页高」往前跳一块，逼途经的页报回真实页高，
  /// 估算越来越准；最多 24 帧兜底（§4.100 任务 D：解决「新实例停在第 0 页」）。
  ///
  /// ⚠️ **同一帧内对同一页只收敛一次**（v1.21.37 修）：
  /// 实测日志（v1.21.36+87，真机）出现过同一目标页在 **2 毫秒内被进入 5 次**，
  /// 每次 `attempt == 0` 都记一笔 `recordTurn(trigger: '恢复位置')` ——
  /// 于是诊断判据 R6「连续快速滚动」被**误判成红**
  /// （那 5 条的 `elapsed` 依次是 22605ms 然后 0/0/0/0，最后一条 408ms）。
  /// 用户并没有连滚动，只是"恢复位置"这一条指令在同帧被重复下发。
  ///
  /// 去重只针对**同一帧内的重复进入**：滚动结束后重试（下一帧）照旧生效，
  /// 所以不会掩盖"定位没落地"的真问题。
  void _revealToPageIndex(int pageIndex,
      {double alignment = 0.15, int attempt = 0}) {
    if (!mounted || pageIndex < 0 || _document == null) return;
    if (attempt == 0) {
      if (_revealingFrameTarget == pageIndex) return; // 同帧重复进入：丢弃
      _revealingFrameTarget = pageIndex;
      // ★恢复定位开始：收敛期间冻结闸门的"滚动反推"（见 _revealingToPage 说明）
      _revealingToPage = pageIndex;
      // 下一帧清掉，允许滚动结束后的重试重新进入
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _revealingFrameTarget = null;
      });
      // 跳动检测（埋点 3）：显式定位（进入阅读页 / 点「回到朗读位置」）。
      // 只在首帧记一次，后面的逐帧收敛不重复计。
      SpeechDiagnostics.instance.recordTurn(
        fromPage: _turn.displayedPage,
        toPage: pageIndex,
        sentencesOnFromPage: -1,
        trigger: '恢复位置',
      );
    }
    if (_isPageIndexVisible(pageIndex)) {
      // ★目标页真的可见了 → 恢复定位结束，交还日常滚动落位
      _revealingToPage = null;
      // ★改动 6：把"收敛结束"告诉闸门 —— 这是 `_jumpPending` 的第 4 个出口。
      // 少了它，一旦 `_pageAtOffset` 推不出页码（页高没量到 → `_scheduleSettle`
      // 直接 return），`_jumpPending` 会永久为真、硬上限每 3 秒空转重发 jump。
      _turn.onRevealFinished(pageIndex);
      _syncBackToReading();
      return;
    }
    if (attempt >= 24) {
      // ★兜底放弃也要解锁 + 通知闸门（同上，否则闸门永远不再跟随滚动）
      _revealingToPage = null;
      _turn.onRevealFinished(pageIndex);
      return;
    }
    final ctx = _pageKeys[pageIndex]?.currentContext;
    if (ctx != null) {
      _noteScrollDriver('定位(page=$pageIndex)', -1);
      unawaited(Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        alignment: alignment,
      ).catchError((Object _) {}));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scheduleSettle(_scroll.position);
      });
      return;
    }
    // 目标页还没建出来：按"已量页高 + 空缺用估算顶替"往前跳，逼它建出来。
    //
    // ★本轮修（缺陷 1）：这里原来是 `if (e <= 0) break;` —— 遇到第一页没量到
    //   就中断，`sum` 停在远小于真实目标的地方；进书那一刻 `_pageExtents`
    //   绝大部分是 0，于是**进书定位停在开头几页**（真机：恢复目标 18，停在 11）。
    //   现在与 [_jumpTowardsPageByEstimate] 共用同一个累加函数（单一事实来源），
    //   空缺处用 [_estimatedPageExtent] 顶替、绝不中断；老的
    //   `est * pageIndex` 兜底被它完全覆盖（全 0 时逐位等价），故删掉。
    var dest = _offsetOfPage(pageIndex);
    if (dest == null) {
      final est = _estimatedPageExtent() ?? 0;
      final r = PdfReadingPage.estimateOffsetToPage(
        pageExtents: _pageExtents,
        pageIndex: pageIndex,
        estimatedExtent: est,
      );
      dest = r?.offset;
      if (r != null) {
        _noteScrollDriver('定位-逼近(page=$pageIndex)', r.offset);
        CrashLog.mark('AF[定位逼近] 目标页=${pageIndex + 1} '
            '逼近偏移=${r.offset.toStringAsFixed(0)} '
            '其中估算页数=${r.estimated}${r.estimated > 0 ? "（误差随页数增大）" : "（全为实测）"}');
      }
    }
    if (dest != null && _scroll.hasClients) {
      _scroll.jumpTo(dest.clamp(
        _scroll.position.minScrollExtent,
        _scroll.position.maxScrollExtent,
      ));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealToPageIndex(pageIndex, alignment: alignment, attempt: attempt + 1);
    });
  }

  // ────────────────────────────────────────────────────────────────────────
  //  v1.21.43 · 模型 A：**让当前朗读句上下滑动到对齐位置**
  //
  //  术语：PDF 朗读没有"翻页"（见 sentence_centering.dart 顶部术语表）。
  //  这一块替代的是整个 `PdfPageTurnController`（505 行"滚动状态机"）。
  // ────────────────────────────────────────────────────────────────────────

  /// 上一次"因为页号变化而强制对齐"的页号（用于识别跨页时机）
  int? _lastCenteredPageIndex;

  /// **控制条展开时的对齐档位**（更靠上，给控制条腾地方）
  ///
  /// 用户真机拍板：展开时 0.35 → 0.25。
  static const double _alignmentWithControlBar = 0.25;

  /// **当前真正生效的对齐档位**
  ///
  /// `_controlCollapsed == false` 表示控制条**展开**（见字段初始化）。
  /// ⚠️ 这是个**反直觉的命名**：`_controlCollapsed` 为假 = 控制条是展开的。
  ///
  /// 为什么要分两档：控制条是 `bottomNavigationBar`，占的是 Scaffold 的
  /// 底部槽位 → **`ListView` 的视口是从底部缩的**（顶边不动、高度变小）。
  /// 于是同一个 0.35 在"矮视口"里给底部留的余量更少，句子容易被挤到控制条边上。
  /// 展开时切到 0.25，把句子再往上挪一档。
  double get effectivePdfSentenceAlignment => _controlCollapsed
      ? StorageService.instance.pdfSentenceAlignment
      : _alignmentWithControlBar;

  /// 「停手满 4 秒 → 自动接管」这条日志每次停手只打一条（防日志刷屏）
  bool _autoTakeoverLogged = false;

  /// 句级收敛链的同帧去重（对应页级的 `_revealingFrameTarget`）
  ///
  /// ⚠️ 实测它**只写不读**（`:1558/:1559/:1561` 三处都是写/清，没有任何地方读它）——
  /// 也就是这个"同帧去重"其实**没在起作用**。留着不动是因为本轮范围锁死；
  /// 真要它生效得在 `_convergeToSentence` 入口读一次并 `return`。
  PdfSentenceRef? _centeringFrameTarget;

  /// 粗跳重来的轮次（最多 3 轮，见 [_convergeToSentence]）
  int _convergeEpoch = 0;

  /// **收敛链的版本号**：任何一次新的居中都会 +1，让**上一条还没跑完的收敛链作废**
  ///
  /// ## 为什么必须有它（真机事故 2026-10-13 10:19:07）
  ///
  /// 「目录跳转」到第 69 页的收敛链没收敛（页高只能估算），它会**逐帧给自己续帧**
  /// 一直跑到"24 帧 × 最多 3 轮粗跳"才自然结束。这期间用户按了「回到朗读位置」：
  /// * `10:19:07.826` 按钮那条发出滚动 `目标偏移=17572`
  /// * `10:19:07.839` 69 页那条**还在续帧**（`逼近偏移=34454`）
  /// * `10:19:07.850` `AF[滚动到位] 偏移=17572 实际=34454` ← 画面被 69 抢回去了
  /// * `10:19:07.882` 69 页那条又粗跳一次，把画面钉在 34454
  ///
  /// 用户看到的就是"**回到朗读位置点了没反应**"。
  /// 有了版本号：新居中一进来就让旧链在**下一帧自查过期并退出**，不再发滚动。
  int _convergeToken = 0;

  /// **按页高估算跳到某一页附近**（收敛链专用）
  ///
  /// ## ★为什么不能"遇到空缺就 break"（v1.21.43 修的真 bug）
  ///
  /// 原实现：
  /// ```dart
  /// for (i < pageIndex) { final e = _pageExtents[i]; if (e <= 0) break; sum += e; }
  /// var dest = _offsetOfPage(pageIndex) ?? (sum > 0 ? sum : null);
  /// if (dest == null) { est = _estimatedPageExtent(); dest = est * pageIndex; }   // ← 兜底
  /// ```
  /// `ListView` **只给渲染过的页报页高**。从第 57 页跳到第 42 页时，
  /// 第 40 页附近**从没进过视野** → `_pageExtents[40] == 0` → **循环当场中断**，
  /// `sum` 只累到第 ~39 页 → **远小于第 42 页的真实偏移** → 跳不到位。
  /// 更糟的是那个兜底**永远轮不到**：`sum > 0` 时 `dest` 不为 null，兜底分支根本不执行。
  ///
  /// 现在：**空缺处用估算页高继续累加**，并把"估算页数"作为误差提示打出来。
  /// 这条同时修掉"目录跳转不滚/滚不到"（真机日志：视口停在 60、目标是 42）。
  void _jumpTowardsPageByEstimate(int pageIndex) {
    if (!_scroll.hasClients) return;
    // ★本轮：累加逻辑抽到 [PdfReadingPage.estimateOffsetToPage]，
    //   与 [_revealToPageIndex] 共用同一份（以前是两套写法，其中一套还带着
    //   `if (e <= 0) break;` 的老 bug）。**本函数的行为一字未改**。
    final double est = _estimatedPageExtent() ?? 0;
    final r = PdfReadingPage.estimateOffsetToPage(
      pageExtents: _pageExtents,
      pageIndex: pageIndex,
      estimatedExtent: est,
    );
    // 连估算都给不出（文档没打开完）：这一拍没法跳，下一帧再试
    if (r == null) return;
    final clamped = r.offset.clamp(
      _scroll.position.minScrollExtent,
      _scroll.position.maxScrollExtent,
    );
    _noteScrollDriver('句居中-逼近(ref=${pageIndex + 1})', clamped);
    CrashLog.mark('AF[居中逼近] 目标页=${pageIndex + 1} '
        '逼近偏移=${clamped.toStringAsFixed(0)} '
        '其中估算页数=${r.estimated}${r.estimated > 0 ? "（误差随页数增大）" : "（全为实测）"}');
    _scroll.jumpTo(clamped);
  }

  /// **让 [ref] 这一句滑到屏幕对齐位置**（模型 A 的核心入口）
  ///
  /// * [force] —— 突破**让位**：用户正在滑动 / 停手未满 4 秒时**仍可**滚动。
  ///   用在三个用户主动入口：回到朗读位置 / 点句朗读 / 目录跳转 / 首次进入。
  /// * [forceCenter] —— 突破**死区**：即便句已在死区内也重新对齐。
  ///   用在"页号变了"这种内容连续性被打断的时刻（含一句跨两页翻到续页）。
  ///
  /// 返回 `true` 表示**发出了**一次滚动（不代表已经滚到位）。
  bool centerOnSentence(
    PdfSentenceRef ref, {
    bool force = false,
    bool forceCenter = false,
  }) {
    if (!mounted || !_scroll.hasClients) return false;

    // ── 让位（开关 A）：用户正在滑动时绝不拽回（force 才可突破）──
    //
    // 这是**第二道**闸（第一道在 `onSentenceChanged` 的 `if (!_userScrolling)`）。
    // 有意做成双重保险：外层"调用点不发起"，内层"**所有非 force 调用者**都拦得住" ——
    // 以后新增的调用点（S2b / 目录跳转…）不会绕过它。两道判据同一个变量，不会打架。
    //
    // ⚠️ 措辞要准：内层拦的是**非 force**的调用者。**force 路径故意穿透**
    // （那是"用户主动请求"，见 `force` 参数说明），由调用方保证只在
    // 用户主动请求时传 `force: true` —— 不是"任何调用者都拦得住"。
    if (_userScrolling && !force) {
      CrashLog.mark('AF[滑动让位] 用户滑动中 → 不自动滚动（ref=${ref.pageIndex + 1}）');
      return false;
    }

    // ── 接管（开关 B）：停手满 4 秒才允许恢复自动滚动 ──
    //
    // 与开关 A 的分工（用户拍板：两条独立，不是"停手 4 秒才让位"）：
    // · A：任何滑动 → **立刻**停，不等秒数；
    // · B：停手满 [_autoFollowGrace]（4 秒）→ **才允许**再动。
    // B 不成立时**只推迟、不拽回**（用户可能只是停下来看一眼）。
    if (!force && !_userStoppedScrollingLongEnough) {
      final waited = _lastUserScrollEndAt == null
          ? 0
          : DateTime.now().difference(_lastUserScrollEndAt!).inMilliseconds;
      CrashLog.mark('AF[等待接管] 停手仅 ${waited}ms < '
          '${_autoFollowGrace.inSeconds}s → 暂不自动滚动（ref=${ref.pageIndex + 1}）');
      return false;
    }
    // 停手刚满 4 秒的**第一拍**：记一条，方便真机核对"没有提前接管"
    if (!force && _lastUserScrollEndAt != null && !_autoTakeoverLogged) {
      _autoTakeoverLogged = true;
      CrashLog.mark('AF[自动接管] 停手满 ${_autoFollowGrace.inSeconds} 秒 '
          '→ 恢复自动滚动（ref=${ref.pageIndex + 1}）');
    }

    // ── 跨页 / 换页时机：无视死区强制干净对齐一次 ──
    //
    // ⚠️ **`_lastCenteredPageIndex` 只在这里"记下我们正要去的页"，
    // 真正的提交推迟到视野确实落在该页之后**（见函数末尾）。
    //
    // 为什么（真机日志 23:16 那份）：原来一进函数就 `_lastCenteredPageIndex = ref.pageIndex`，
    // 而那一刻视图**还在旧页**（收敛还没成功）→ 之后每拍的 `pageChanged` 都是 false
    // → **`forceCenter` 只活了一拍就丢** → 后面全靠死区碰运气
    // （日志：`强制=跨页` 第 1 拍有、第 2 拍起变 `强制=无`）。
    final bool pageChanged = ref.pageIndex != _lastCenteredPageIndex;
    final bool fc = forceCenter || pageChanged;

    final viewportH = _scroll.position.viewportDimension;
    if (viewportH <= 0) return false;

    // ── ★本轮（cancel-stale-converge）：**接管滚动权** ──
    //
    // 从这一句起，"我"就是唯一有效的居中目标：
    // `++_convergeToken` 让**上一条还在续帧的收敛链**在下一帧自查过期并退出
    // （真机事故：目录跳转跳 69 页的残链把「回到朗读位置」的滚动抢回 34454，
    //  见 [_convergeToken] 的说明）；
    // `_convergeEpoch = 0` 是因为"粗跳轮次"属于**当前这条链** —— 换了链就该从 0 数，
    // 否则新链会继承死链的轮次，还没跳就先被 `>= 3` 判死。
    _convergeToken++;
    _convergeEpoch = 0;
    // ★有效档位：控制条展开时自动切 0.25（见 [effectivePdfSentenceAlignment]）
    final align = effectivePdfSentenceAlignment;

    final pageCtx = _pageKeys[ref.pageIndex]?.currentContext;
    final pageBox = pageCtx?.findRenderObject();

    // ── ★五数标定埋点（v1.21.43）——必须在"目标页未渲染"的早退【之前】打 ──
    //
    // 为什么挪到这里：原来探针在成功路径的末尾才打，于是
    // **"目录跳转到一个还没渲染的页"这种最需要它的情况，一条日志都没有**
    // （真机日志：57 跳 42，全程没有 AF[居中]）。
    //
    // 两个场景都要能分辨（用户明确要求）：
    // * 场景一「跳转」——目标页未渲染 → 页顶偏移=未就绪 → 靠 `收敛中` 标记识别
    // * 场景二「连续跟读」——目标页已渲染 → 五个数齐全 → 判断是滚过头还是滚不够
    //
    // 五个数：页顶偏移 / 视口高 / 档位 / 句centerY(点) / 句y(屏幕)
    final bool pageReady = pageBox is RenderBox && pageBox.hasSize;
    final double? pageTopForLog = pageReady
        ? RenderAbstractViewport.of(pageBox)
            .getOffsetToReveal(pageBox, 0, rect: Offset.zero & pageBox.size)
            .offset
        : null;
    final double? centerYPoints = _sentenceCenterYInPagePoints(ref);
    final double? centerYPx = pageReady ? _sentenceCenterYInPagePx(ref, pageBox) : null;
    final double? sentenceYForLog =
        pageReady ? _sentenceViewportY(ref, pageBox) : null;
    // 渲染缩放：页宽 ÷ PDF 页宽（宽度方向不含内边距干扰）
    final double? scaleForLog = pageReady ? _pageScale(pageBox, ref) : null;
    CrashLog.mark('AF[居中] ${pageReady ? "" : "收敛中 "}标定 '
        'refPage=${ref.pageIndex + 1} refSent=${ref.sentenceIndex} '
        '页顶偏移=${pageTopForLog?.toStringAsFixed(0) ?? "未就绪"} '
        '视口高=${viewportH.toStringAsFixed(0)} '
        '档位=$align(${_controlCollapsed ? "收起" : "展开"}) '
        '句centerY点=${centerYPoints?.toStringAsFixed(0) ?? "无"} '
        '句centerY像素=${centerYPx?.toStringAsFixed(0) ?? "无"} '
        'scale=${scaleForLog?.toStringAsFixed(3) ?? "未就绪"} '
        '句y=${sentenceYForLog?.toStringAsFixed(0) ?? "未就绪"}');

    if (!pageReady) {
      // 目标页还没建出来：走收敛链把它逼出来（下同）
      _convergeToSentence(ref, attempt: 0, force: force, forceCenter: fc);
      return true;
    }

    final sentenceY = _sentenceViewportY(ref, pageBox);
    if (sentenceY == null) {
      _convergeToSentence(ref, attempt: 0, force: force, forceCenter: fc);
      return true;
    }

    final viewport = RenderAbstractViewport.of(pageBox);
    final pageTopOffset = viewport
        .getOffsetToReveal(pageBox, 0, rect: Offset.zero & pageBox.size)
        .offset;
    // ★换算成像素（原先是 PDF 点，与 pageTopOffset / viewportH 不同单位）
    final sentenceCenterInPage = _sentenceCenterYInPagePx(ref, pageBox);
    if (sentenceCenterInPage == null) {
      _convergeToSentence(ref, attempt: 0, force: force, forceCenter: fc);
      return true;
    }

    final target = SentenceCentering.targetOffset(
      pageTopOffset: pageTopOffset,
      sentenceCenterY: sentenceCenterInPage,
      viewportHeight: viewportH,
      alignment: align,
    );
    final clamped = SentenceCentering.clampOffset(
      target,
      _scroll.position.minScrollExtent,
      _scroll.position.maxScrollExtent,
    );

    final bool inside = SentenceCentering.isInsideDeadZone(
      sentenceY: sentenceY,
      viewportHeight: viewportH,
      alignment: align,
    );
    final bool go = SentenceCentering.shouldScroll(
      sentenceY: sentenceY,
      viewportHeight: viewportH,
      alignment: align,
      targetOffsetValue: clamped,
      currentScrollOffset: _scroll.position.pixels,
      force: force,
      forceCenter: fc,
    );

    // ── 埋点：refPage vs 视口页 ──
    //
    // ⚠️ 这里**绝不能**用 `_lastValidPageForDisplay`，也**不能**用
    // `_turn.displayedPage`（旧状态机）—— 它们都不是"屏幕现在显示在哪一页"：
    // · `_turn.displayedPage`：旧状态机的账，S2a 之后跟读已不走它，会一直不动；
    // · `_lastValidPageForDisplay`：我 S1 新增的**派生值**，但**UI 目前没接它**
    //   （UI 的 `_pageLabel()` 读的是 `_session.current`，即朗读位置）。
    // 真正反映"屏幕显示"的只有**从滚动位置反推**的页号 —— 现算现用。
    //
    // ⚠️ 用**估算补齐版**（[viewportPageForJudgement]）而不是精确版：
    // 精确版在"远页页高还没量到"时返回 null，而那正是判据最该起作用的场景
    // （用户大跨度滑走）—— 实测就是它让设备侧负向验证第一条红了。
    //
    // ★"算不出"必须有**独立表示**，不能退化成一个假的页码：
    // 原来写成 `?? -1`，于是刚进页面（页高全 0）时打 `视口页=-1`，
    // 判据又拿它去比 `refPage` → 必然 `⚠️不一致`。**一个假的页码比没有更坏**。
    // 现在算不出就显示 `?`，并且**判据直接判"未知"**（不报不一致）。
    final int? viewportPage = viewportPageForJudgement(
      _scroll.hasClients ? _scroll.position.pixels : 0,
    );
    // ★近似标记：掺了估算的页号标成 `≈`，且**差 1 页不再报"不一致"**
    // （用户拍板：`视口页` 是近似值，免得每次 ⚠️不一致 误导排查）
    final bool approx = viewportPage != null &&
        viewportPageIsApproximate(
            _scroll.hasClients ? _scroll.position.pixels : 0);
    final bool synced = viewportPage != null &&
        PdfReadingPage.isViewportSyncedWithReading(
          viewportPage: viewportPage,
          refPage: ref.pageIndex + 1,
        );
    // 近似值允许 ±1 页：页高估算误差本身就有这个量级
    final int diff = viewportPage == null ? 0 : (viewportPage - (ref.pageIndex + 1)).abs();
    final String syncMark = viewportPage == null
        ? "❓未知"
        : (synced
            ? "✅一致"
            : (approx && diff <= 1 ? "≈差1" : "⚠️不一致"));

    CrashLog.mark('AF[居中] refPage=${ref.pageIndex + 1} '
        'refSent=${ref.sentenceIndex} 视口页=${approx ? "≈" : ""}${viewportPage ?? "?"} '
        '$syncMark '
        // ★强制对齐的**来源**要写出来（真机判据）：
        // `force` = 用户显式请求；`跨页` = 页号变了（一句跨两页翻到续页 /
        // 朗读推进到新页）；空 = 日常跟读（受死区约束）。
        // 静默 `onPageShouldTurn` 之后，"跨页强制居中"是否仍然发生，
        // 全靠这个字段一眼判断。
        '强制=${force ? "用户" : (pageChanged ? "跨页" : "无")} '
        '句y=${sentenceY.toStringAsFixed(0)} 目标偏移=${clamped.toStringAsFixed(0)} '
        '实际=${_scroll.position.pixels.toStringAsFixed(0)} '
        '死区=${inside ? "内" : "外"} '
        // 档位要带状态：0.25 只在控制条**展开**时生效（见 effectivePdfSentenceAlignment），
        // 否则日志里看到一个 0.25 会以为设置被改了。
        '档位=$align(${_controlCollapsed ? "收起" : "展开"}) '
        '${go ? "→ 滚动" : "→ 不滚"}');

    // ★提交 `_lastCenteredPageIndex` 的两个时机（都表示"视野确实已落在这页"）：
    //   · `go == true` → 我们正要把它滚过去；
    //   · `inside`（落在死区内）→ 它已经在"对齐位置附近"，无需再强制。
    // 两者都不成立（既在死区外、又不滚）不会发生：死区外必然 go。
    if (pageChanged) {
      _lastCenteredPageIndex = ref.pageIndex;
      CrashLog.mark('AF[跨页提交] 第 ${ref.pageIndex + 1} 页'
          '（视野已落在该页；此后同页内不再强制对齐）');
    }

    if (!go) return false;
    _noteScrollDriver('句居中(ref=${ref.pageIndex + 1})', clamped);
    _animateScrollTo(clamped);
    return true;
  }

  /// 句心在**该页内的** y（**PDF 点**，页内 0 起）
  ///
  /// ⚠️ **单位是 PDF 点，不是屏幕像素** —— 见 [sentenceCenterYInPagePx]。
  /// 保留它只为埋点显示原始点值（方便核对换算）。
  double? _sentenceCenterYInPagePoints(PdfSentenceRef ref) {
    final layer = _session.layerOf(ref.pageIndex);
    if (layer == null) return null;
    if (ref.sentenceIndex < 0 || ref.sentenceIndex >= layer.sentences.length) {
      return null;
    }
    return layer.sentences[ref.sentenceIndex].centerY;
  }

  /// **PDF 点 → 屏幕像素的缩放**（页层用的就是这个口径）
  ///
  /// 推导来自 `PdfPageLayer._scale`（`pdf_page_layer.dart:132`）：
  /// ```dart
  /// double get _scale => rendered.width / layer.pageSize.width;
  /// ```
  /// 而 `rendered` 是**图像的实际渲染宽**，它由内层 `AspectRatio` 决定：
  /// * `_pageKeys[pageIndex]` 挂在 `_pageItem` 的 **`Padding`** 上
  ///   （`padding: EdgeInsets.fromLTRB(8, 8, 8, 8)`），所以
  ///   `pageBox.size.width` = 图像宽 **+ 16**；
  /// * `AspectRatio` 用"可用宽度"布局 → 图像宽 = `pageBox.width − 16`。
  ///
  /// → `scale = (pageBox.size.width − 16) / pageSize.width`
  ///
  /// ⚠️ 不要用 `pageBox.size.height / pageSize.height`：页块高度里还含
  /// **底部页码文字行**，那会让 scale 偏大（这正是"用高度会引入新偏差"的原因）。
  double? _pageScale(RenderBox pageBox, PdfSentenceRef ref) {
    final layer = _session.layerOf(ref.pageIndex);
    if (layer == null) return null;
    final double pw = layer.pageSize.width;
    if (pw <= 0) return null;
    final double imageWidth = pageBox.size.width - 16.0; // 左右各 8px 内边距
    if (imageWidth <= 0) return null;
    return imageWidth / pw;
  }

  /// 句心在**该页内的** y，**已换算成屏幕像素**（v1.21.43 修）
  ///
  /// ## 为什么必须换算（真机 bug 的根因）
  ///
  /// `PdfTextChar.rect` 的注释写得很清楚（`pdf_text_layer.dart:27`）：
  /// > 在 PDF 页面坐标系里的包围盒（原点左上，**单位点 = 72dpi 的像素**）
  ///
  /// 而目标偏移公式里另外两项（`pageTopOffset`、`viewportHeight`）都是**屏幕像素**。
  /// 原来直接拿点值当像素用 → **坐标系统一不了** →
  /// 目标偏移算错 → 真机症状：**"页面整体偏上、朗读句在下方看不见"**。
  double? _sentenceCenterYInPagePx(PdfSentenceRef ref, RenderBox pageBox) {
    final points = _sentenceCenterYInPagePoints(ref);
    if (points == null) return null;
    final scale = _pageScale(pageBox, ref);
    if (scale == null) return null;
    return points * scale;
  }

  /// 句心当前在**视口内**的 y（屏幕坐标，0 = 视口顶）
  ///
  /// 用「页的 render box 屏幕位置 + 句在页内的 y」求，**不需要句级 Key**。
  ///
  /// ★v1.21.43：句内 y 必须用**换算成像素**的版本（[sentenceCenterYInPagePx]），
  /// 否则这里报出来的 `句y` 会带同一个单位错误（真机表现为
  /// `句y` 老是为负 —— 而它同时喂给死区判定，于是死区也跟着错）。
  double? _sentenceViewportY(PdfSentenceRef ref, RenderBox pageBox) {
    final inPage = _sentenceCenterYInPagePx(ref, pageBox);
    if (inPage == null) return null;
    final pageTopOnScreen = pageBox.localToGlobal(Offset.zero).dy;
    return pageTopOnScreen + inPage;
  }

  /// 句级收敛链：目标页还没建出来时，逐帧把它逼出来再对齐
  ///
  /// 复用页级收敛链的骨架（同帧去重 + `attempt` 上限），**目标从"页"换成"句"**。
  /// 为什么需要它：`ListView` 只建可见区域附近的页，跳到很远的句时
  /// 目标页可能压根还没被 build。
  ///
  /// ## 逼近方式（v1.21.43 修过一次）
  ///
  /// **空缺页高不再中断累加** —— 见 [_jumpTowardsPageByEstimate] 的说明。
  /// 原来"遇到第一个 `extent <= 0` 就 break"会让远距离跳转**跳到一半就停**
  /// （真机：57 跳 42，视图停在 60）。
  void _convergeToSentence(
    PdfSentenceRef ref, {
    required int attempt,
    required bool force,
    required bool forceCenter,
    int? token,
  }) {
    if (!mounted || !_scroll.hasClients) return;
    // ★本轮（cancel-stale-converge）：**本链的版本号**。
    // 起始那次由 `centerOnSentence` 刚 `++` 过的值兜底；递归续帧时**必须原样带着**，
    // 这样"被新居中顶掉"的旧链才能认出自己过期。
    final int myToken = token ?? _convergeToken;
    if (myToken != _convergeToken) {
      // ★过期退出：新的居中已经接管滚动权（真机事故见 [_convergeToken] 的说明）。
      // 这里**必须 return**，不能再发任何滚动 —— 否则就会把新目标的画面抢回去。
      CrashLog.mark('AF[居中过期] ref=${ref.pageIndex + 1}/${ref.sentenceIndex} '
          '已被新的居中目标取代 → 退出（不再发滚动）');
      return;
    }
    if (_centeringFrameTarget != ref) {
      _centeringFrameTarget = ref;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _centeringFrameTarget = null;
      });
    }
    if (attempt >= 24) {
      // ★兜底不放弃，改"**粗跳重来一轮**"（v1.21.43 修）
      //
      // 为什么不能停在原地：24 帧（≈400ms）内没把目标页逼出来，
      // 多半是"距离太远 + 页高没量全"（真机日志：57 跳 42，视图停在 60）。
      // 停在原地等于**跳转彻底失败**，用户看到的是"页面纹丝不动"。
      //
      // 现在：把 `attempt` 归零、**直接按估算页高跳到目标页附近**，
      // 再重新收敛一轮。最多重来 3 轮（避免病态情况下无限重试）。
      if (_convergeEpoch >= 3) {
        CrashLog.mark('AF[居中放弃] ref=${ref.pageIndex + 1}/${ref.sentenceIndex} '
            '粗跳重来 $_convergeEpoch 轮仍未建出该页 → 停在当前位置');
        return;
      }
      _convergeEpoch++;
      CrashLog.mark('AF[居中粗跳] ref=${ref.pageIndex + 1}/${ref.sentenceIndex} '
          '24 帧未到位 → 按估算页高粗跳重来第 $_convergeEpoch 轮');
      _jumpTowardsPageByEstimate(ref.pageIndex);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _convergeToSentence(ref,
            attempt: 0,
            force: force,
            forceCenter: forceCenter,
            token: myToken); // ★带着本链版本号续帧（过期就在下一帧退出）
      });
      return;
    }
    // 已经能算准了：直接交回主路径
    final pageCtx = _pageKeys[ref.pageIndex]?.currentContext;
    final pageBox = pageCtx?.findRenderObject();
    if (pageBox is RenderBox && pageBox.hasSize) {
      _convergeEpoch = 0; // 到位了：轮次计数归零
      centerOnSentence(ref, force: force, forceCenter: forceCenter);
      return;
    }
    // 还没建出来：按已量页高逼近；**遇到没量到的页不再 break**，改用估算顶替
    //
    // ★为什么必须改掉 `break`（v1.21.43 修）：
    //   原来 `if (e <= 0) break;` —— 从第 57 页跳到第 42 页时，
    //   第 40 页附近**从没渲染过** → 循环在第一个空缺处就断 → `sum` 只累到
    //   "最后一个连续量到的页"，**远小于第 42 页的真实偏移** → 跳不到位。
    //   而兜底 `_estimatedPageExtent() * pageIndex` 只在 `sum == 0` 时才生效，
    //   所以它**永远不会被用上**。现在改成"空缺处用估算页高继续累加"。
    _jumpTowardsPageByEstimate(ref.pageIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _convergeToSentence(ref,
          attempt: attempt + 1,
          force: force,
          forceCenter: forceCenter,
          token: myToken); // ★同上：续帧带着版本号
    });
  }

  /// 发一次滚动动画（覆盖式：新动画打断旧的，**不排队**）
  void _animateScrollTo(double offset) {
    if (!_scroll.hasClients) return;
    unawaited(_scroll
        .animateTo(
          offset,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        )
        .catchError((Object _) {})
        .whenComplete(() {
      // 滚完记一条"到位"日志（**是否真到位由下一次居中时的句 y 反映**）
      if (mounted) {
        CrashLog.mark('AF[滚动到位] 偏移=${offset.toStringAsFixed(0)} '
            '实际=${_scroll.hasClients ? _scroll.position.pixels.toStringAsFixed(0) : "?"}');
      }
    }));
  }

  /// 「回到朗读位置」：把当前朗读句拉回屏幕对齐位置（**走新路**）
  ///
  /// ## ⚠️ 本轮（真机反馈「回到朗读位置按键定位失败」）修的就是这里
  ///
  /// 原来是**两条**调用：
  /// ```dart
  /// _turn.turnTo(pageIndex, force: true);            // ← 旧路（滚动状态机）
  /// _revealToPageIndex(pageIndex, alignment: 0.25);  // ← 新路（逐帧收敛）
  /// ```
  /// 旧路那条**早被 S2a 静默了**：`turnTo` 最终落到 delegate 的
  /// `_jumpToPage` / `_animateToPage`，而这两条的开关分支只打一句
  /// `AF[旧路静默] jumpTo / animateTo` 就 `return` —— **按一下键，那一跳被原地丢掉**。
  /// 剩下 `_revealToPageIndex` 一条在干活，而它遇到"目标页还没渲染"时
  /// 只能靠**已量页高估算**逼近 —— 真机实测那条估算链会空转
  /// （同一个偏移反复发、24 帧后放弃；与"远跳转第二次必卡"同一个病根）。
  ///
  /// 现在改成**与目录跳转同一条已验证的通道**（`_jumpToAndRead` 里就是这一句，
  /// 真机日志出现过 `AF[滚动到位] 偏移=… 实际=…`）：
  /// * `force: true` → 突破"用户在滑动"（用户主动请求，该抢回画面）
  /// * `forceCenter: true` → 突破死区，**必定**对齐到
  ///   [effectivePdfSentenceAlignment]（控制条展开 0.25 / 收起 0.35）
  /// * `ref` 直接取 [_session.current]（当前朗读句），不再只拿 pageIndex
  ///
  /// **真机日志核对**：应出现 `AF[居中] … 强制=用户`；
  /// **不再**出现 `AF[旧路静默] jumpTo`（那条旧路已经没有任何调用点）。
  Future<void> _scrollToReading() async {
    final ref = _session.current;
    if (ref == null) return;
    setState(() => _backToReading = false);
    _userScrolling = false;
    // 显式指令：复位闸门记账，突破「用户手动滚动」暂停自动跟读的闸门（§4.66）
    // ★v1.21.43 第 4 步：统一走 _syncGateToSession（同一份对齐逻辑，不再各写一份）
    _syncGateToSession();
    // ★本轮：两条并成一条新路（旧路那条已静默，见方法注释）
    centerOnSentence(ref, force: true, forceCenter: true);
    if (mounted) setState(() {});
  }

  /// 正在朗读的高亮：**要画的那一句在本页的句索引**（null = 本页不画）
  ///
  /// ## ★v1.21.43 模型 A：一句跨两页 → **两页都画**
  ///
  /// 旧实现在这里返回**字符区间** `(first, last)`，而绘制侧用
  /// `sentenceAtRange` 反查整句 —— 一句从第 7 页末延到第 8 页头时：
  /// * 第 7 页：区间对得上"本页那一半" → 画 ✅
  /// * 第 8 页：区间**对不上任何整句**（本页只有后半句的字符）→ **不画** ❌
  /// 这就是用户报的「跨页句只框在上一页」。
  ///
  /// 现在返回**句索引**，每页各自取"本页那一半"的句对象 → 两页都能画：
  /// * [ref] 所在页 → 画起始句（`ref.sentenceIndex`）
  /// * [PdfReadSession.currentSpanEnd] 所在页 → 画**续页那一句**
  ///
  /// 高亮**永远跟着 `ref`（朗读位置）**，不跟滚动位置 ——
  /// 用户滑走再回来，仍能看到"读到哪了"。
  int? _highlightFor(int pageNumber) {
    final pageIndex = pageNumber - 1;
    final ref = _session.current;
    if (ref == null) return null;
    // ① 起始页：画朗读句本身
    if (ref.pageIndex == pageIndex) {
      final layer = _session.layerOf(pageIndex);
      if (layer == null) return null;
      if (ref.sentenceIndex < 0 || ref.sentenceIndex >= layer.sentences.length) {
        return null;
      }
      return ref.sentenceIndex;
    }
    // ② 续页：一句跨两页时，在**下一页**也画它那一半
    final end = _session.currentSpanEnd;
    if (end != null && end.pageIndex == pageIndex) {
      final layer = _session.layerOf(pageIndex);
      if (layer == null) return null;
      if (end.sentenceIndex < 0 || end.sentenceIndex >= layer.sentences.length) {
        return null;
      }
      return end.sentenceIndex;
    }
    return null;
  }

  GlobalKey _pageKey(int pageNumber) =>
      _pageKeys.putIfAbsent(pageNumber, () => GlobalKey());

  // ---------------- 交互 ----------------

  /// ★v1.21.45 改动 3：已经提示过「文字位置异常」的文档（进程内记忆，按 documentId）
  ///
  /// 施工单要求：**同一文档只弹一次**，后续页不重复弹。
  /// 记成 static 是为了"退出再进同一份 PDF 也不重复烦人" —— 进程内有效即可，
  /// 重启应用后重新提示一次是合理的。
  static final Set<String> _geometryWarnedDocs = <String>{};

  @visibleForTesting
  static void debugResetGeometryWarnings() => _geometryWarnedDocs.clear();

  /// 文字层几何异常 → 提示一次
  ///
  /// 只在 [loadTextLayer] 判为异常时被回调；`loadTextLayer` 本身没有 SnackBar 上下文，
  /// 所以提示挂在这里（施工单明确要求如此）。
  void _onTextLayerGeometry(PdfTextLayerGeometry geometry) {
    if (!mounted) return;
    final String key = widget.documentId ?? widget.filePath;
    if (!_geometryWarnedDocs.add(key)) return; // 这份文档已经提示过
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          '检测到部分页面的文字位置异常，可能是这份 PDF 本身的问题'
          '（朗读高亮可能与文字对不齐）',
        ),
        duration: Duration(seconds: 6),
      ),
    );
  }

  /// 点中某页某句 → 从这里开始（自动连读由会话负责）
  void _readSentence(int pageNumber, int sentenceIndex) {
    final layer = _session.layerOf(pageNumber - 1);
    if (layer == null) return;
    final ref = sentenceRefAt(pageNumber - 1, sentenceIndex, layer);
    if (ref == null) return;
    // 用户显式点句 = 恢复自动跟随
    _turn.resumeAutoFollow();
    _session.startAt(ref);
  }

  /// 栏内播放/暂停键
  ///
  /// ⚠️ v1.21.38：判据改成**三态**（与通知栏一致）。
  /// 原来只看 `isPlaying`，于是"暂停中"与"方块键停声后"都落到 `resume()` 分支 ——
  /// 而通知栏按的是 `hasSession && playing && !paused`，两处对同一状态给出不同动作，
  /// 表现就是用户报的「按了之后与栏内不同步」。
  Future<void> _togglePlayPause() async {
    final session = _session;
    if (session.isPlaying && !session.isPaused) {
      await session.pause();
    } else {
      session.resume();
    }
  }

  /// 方块键：停声 + 收起成迷你条（**会话保留**，HANDOFF §4.92）
  Future<void> _stopAndCollapse() async {
    await _session.stopSound();
    if (mounted) setState(() => _controlCollapsed = true);
  }

  /// 目录：有书签列条目，没有就退回「第 N 页」
  ///
  /// ## v1.21.56 重写（用户要求：**换成和 EPUB 一样的样式**）
  ///
  /// 改了三件事，前两件是用户直接说的，第三件是修「图标失效」的真根因：
  ///
  /// 1. **样式对齐文字档目录**（`pages/toc_sheet.dart`）：
  ///    标题改 `titleLarge`、加页码跳转输入框、面板固定 75% 高度、
  ///    列表用 `Expanded`（原来用 `shrinkWrap` + `Flexible`，
  ///    条目多时高度算得不准、还会抖）。
  /// 2. **当前项实时跟随**：原来 `currentPage` 是打开面板那一刻取的
  ///    **局部变量**，面板又是独立路由、**不订阅 `_session`** ——
  ///    面板开着时朗读往前推进，那一行「当前」标识不会动。
  ///    现在整块包进 `ListenableBuilder(listenable: _session)`。
  /// 3. **「当前项」改成「当前所在章节」而不是精确相等** ——
  ///    这才是用户说的「图标失效」的真根因：
  ///    PDF 书签是**稀疏**的（往往每章只有一条，比如「第 20 页 开始第二章」），
  ///    而朗读位置是**按页**推进的（第 21 页）。
  ///    原来判 `pageIndex == currentPage` → 一条都对不上 → **整份目录没有任何标记**；
  ///    文字档那边章节连续、容易命中，所以没暴露。
  ///    现在取「最后一条 pageIndex ≤ 当前页」的条目 = 当前所在章节，
  ///    与阅读器里「正在读哪一章」的语义一致。
  Future<void> _openToc() async {
    final pageCount = _document?.pages.length ?? 0;
    if (pageCount == 0) return;
    final entries = _outline;
    _tocPageInput.text = '${(_session.current?.pageIndex ?? 0) + 1}';

    /// 当前所在的条目下标（-1 = 无可标记项）
    ///
    /// 判据本体在 [PdfReadingPage.currentTocIndex]（公开静态、可被单测直接打到）。
    int currentIndexOf(int currentPage) => PdfReadingPage.currentTocIndex(
          chapters: <int>[for (final e in entries) e.chapter],
          currentPage: currentPage,
          pageCount: pageCount,
        );

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final scheme = theme.colorScheme;
        return SizedBox(
          // 与文字档目录同一个高度比例
          height: MediaQuery.sizeOf(sheetContext).height * 0.75,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: <Widget>[
                    Text('目录', style: theme.textTheme.titleLarge),
                    const Spacer(),
                    Text('共 $pageCount 页',
                        style: theme.textTheme.labelMedium),
                  ],
                ),
              ),
              // 页码跳转：与文字档目录同款（用户要求样式一致）
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _tocPageInput,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.go,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: '跳转到第几页',
                          helperText: '当前第 '
                              '${(_session.current?.pageIndex ?? 0) + 1} 页，'
                              '共 $pageCount 页',
                          border: const OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _jumpFromToc(sheetContext),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => _jumpFromToc(sheetContext),
                      child: const Text('跳转'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // ★订阅会话：面板开着时朗读继续推进，这一行也要跟着动
              Expanded(
                child: ListenableBuilder(
                  listenable: _session,
                  builder: (context, _) {
                    final currentPage = _session.current?.pageIndex ?? 0;
                    final activeIndex = currentIndexOf(currentPage);
                    return ListView.builder(
                      itemCount: entries.isEmpty ? pageCount : entries.length,
                      itemBuilder: (context, index) {
                        // 没有书签：退回「第 N 页」列表（章号 == 页号）
                        final String label;
                        final int pageIndex;
                        if (entries.isEmpty) {
                          pageIndex = index;
                          label = '第 ${index + 1} 页';
                        } else {
                          final entry = entries[index];
                          pageIndex = entry.chapter;
                          label = entry.title.isEmpty
                              ? '第 ${pageIndex + 1} 页'
                              : entry.title;
                        }
                        final selected = index == activeIndex;
                        // ★当前项标识：与文字档目录共用同一套装饰
                        //（`TocCurrentItem`：淡色圆角背景 + 加粗 + graphic_eq）
                        return TocCurrentItem(
                          active: selected,
                          child: ListTile(
                            dense: true,
                            leading: Text('${pageIndex + 1}'),
                            title: Text(
                              label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: selected
                                  ? TextStyle(
                                      color: scheme.primary,
                                      fontWeight: FontWeight.w600,
                                    )
                                  : null,
                            ),
                            subtitle: Text(
                              '第 ${pageIndex + 1} 页',
                              style: theme.textTheme.labelSmall,
                            ),
                            trailing: selected
                                ? Icon(
                                    TocCurrentItem.currentIcon,
                                    size: 18,
                                    color: scheme.primary,
                                  )
                                : null,
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              unawaited(_jumpToAndRead(pageIndex));
                            },
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 目录里的「跳转到第几页」输入框（与文字档目录同款）
  final TextEditingController _tocPageInput = TextEditingController();

  /// 从目录的输入框跳页：**只移动视图，不激活朗读**（与点条目同一语义）
  void _jumpFromToc(BuildContext sheetContext) {
    final pageCount = _document?.pages.length ?? 0;
    final typed = int.tryParse(_tocPageInput.text.trim());
    if (typed == null || pageCount <= 0) return;
    // 越界夹取到有效范围（不报错、不回到开头）
    final target = (typed - 1).clamp(0, pageCount - 1);
    Navigator.of(sheetContext).pop();
    unawaited(_jumpToAndRead(target));
  }

  /// 目录跳转：**只移动视图，不激活朗读**（v1.21.43 · 语义 B）
  ///
  /// ## 用户拍板的语义（语义 B）
  ///
  /// > 「跳转不该激活对应页首的朗读，朗读应**暂停在正在朗读的位置**，
  /// > 没有正在朗读的就不进行朗读，等待人工激活想读的句子。」
  ///
  /// * **有正在读** → **声音真停**（`_paused = true`），且**朗读位置（`_current`）不动**
  /// * **没在读** → 什么都不启动（`pause()` 自带 early-return，不会凭空起读）
  /// * **视图** → 移动到目录选的那一页并**居中该页首句**
  /// * 用户**手点某一句**才从那里开始读（那是 `_readSentence`，语义不同）
  ///
  /// ## 为什么这是"只移动视图"而不是 `jumpToPage(autoPlay: false)`
  ///
  /// `session.jumpToPage(pageIndex, autoPlay: false)` **会把 `_current` 移到目标页首句**
  /// （`_setCurrent(ref, immediate: true)`）—— 那是**语义 A**（朗读位置也跟着走）。
  /// 语义 B 要求**朗读暂停在原位置**，所以这里**不调 `jumpToPage`**，
  /// 只用 `firstSentenceOnPageAsync` 拿目标句**当定位锚点**，绝不写 `_current`。
  ///
  /// ## 顺带把这条路径切到新路
  ///
  /// 原来第 1 步是 `_turn.turnTo(pageIndex, force: true)`（旧路），
  /// 而旧路的落位通道已被静默 → **跳转根本不滚**（真机日志：57 跳 42、视图停在 60）。
  /// 现在直接走 `centerOnSentence(force: true, forceCenter: true)`：
  /// 用户显式请求 → **突破让位 + 突破死区**。
  Future<void> _jumpToAndRead(int pageIndex) async {
    // ① 朗读暂停在原位置（没在读时 `pause()` 自己 early-return，不会凭空起读）
    await _session.pause();
    // ② 目标页首句 —— **只作定位锚点**，不写 `_current`
    final anchor = await _session.firstSentenceOnPageAsync(pageIndex);
    if (!mounted) return;
    CrashLog.mark('AF[目录跳转] 只移动视图不激活朗读：目标页=${pageIndex + 1} '
        '锚点句=${anchor?.sentenceIndex ?? "无"} '
        '朗读位置保持不变=${(_session.current?.pageIndex ?? -1) + 1}/'
        '${_session.current?.sentenceIndex ?? -1}');
    if (anchor != null) {
      centerOnSentence(anchor, force: true, forceCenter: true);
    }
    if (mounted) setState(() {});
  }

  // ---------------- 构建 ----------------

  @override
  Widget build(BuildContext context) {
    final doc = _document;
    final session = _session;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          IconButton(
            key: PdfControlBar.tocKey,
            onPressed: doc == null ? null : () => unawaited(_openToc()),
            icon: const Icon(Icons.list_alt),
            tooltip: '目录',
          ),
        ],
      ),
      body: Stack(
        // 放**左下角**：右下角被「回到朗读位置」FAB 占着（Scaffold 的
        // floatingActionButton），两个都显示时会重叠。
        alignment: Alignment.bottomLeft,
        children: <Widget>[
          _error != null
              ? _errorView()
              : (doc == null ? _loadingView() : _pagesView(doc)),
          // B-P5：PDF **原版式**页原先没有朗读诊断指示灯（只有 ReaderPage 有），
          // 这里挂上同一个实现；关闭时是零尺寸的 SizedBox，不占布局。
          // heroTag 与阅读页不同：两个页面都挂 FAB 时同名 Hero 会在路由切换时撞车。
          ValueListenableBuilder<bool>(
            valueListenable: StorageService.instance.speechDiagEnabled,
            builder: (context, enabled, _) => enabled
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: speechDiagIndicator(
                          context,
                          heroTag: 'speech-diag-indicator-pdf',
                        ) ??
                        const SizedBox.shrink(),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
      floatingActionButton: _backToReading
          ? FloatingActionButton.extended(
              key: PdfReadingPage.backToReadingKey,
              onPressed: _scrollToReading,
              icon: const Icon(Icons.my_location),
              label: const Text('回到朗读位置'),
            )
          : null,
      // 控制栏：PDF 会话活着才显示（双源分派在 reading_control_bar 那边）
      bottomNavigationBar: session.isActive
          ? PdfControlBar(
              collapsed: _controlCollapsed,
              title: widget.title,
              pageLabel: _pageLabel(),
              // 正在出声 = "在播且没暂停"（与通知栏 `playing && !paused` 同一口径）
              playing: session.isPlaying && !session.isPaused,
              paused: session.isPaused,
              rate: TtsManager.instance.rate,
              onToggleCollapsed: () {
                setState(() => _controlCollapsed = !_controlCollapsed);
                // ★展开/收起改变了**可视高度** + **生效档位**（0.35 ↔ 0.25）→
                // 必须立刻按新档位重新对齐一次，否则句子会被控制条挤到边上
                // （用户真机反馈："一展开就挡住"）。
                //
                // `forceCenter: true` —— 视口刚变，必须重算，**无视死区**；
                // `force: false`（默认）—— **仍尊重"用户正在滑动就让他"**：
                // 用户正滑着的时候展开控制条，不该把他拽回去。
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  final ref = _session.current;
                  if (ref == null) return;
                  CrashLog.mark('AF[档位切换] 控制条'
                      '${_controlCollapsed ? "收起" : "展开"} '
                      '→ 档位=$effectivePdfSentenceAlignment 重新对齐 '
                      '（ref=${ref.pageIndex + 1}/${ref.sentenceIndex}）');
                  centerOnSentence(ref, forceCenter: true);
                });
              },
              onPlayPause: () => unawaited(_togglePlayPause()),
              onPrevious: session.skipSentenceBackward,
              onNext: session.skipSentenceForward,
              onStop: () => unawaited(_stopAndCollapse()),
              onRateChanged: (value) => unawaited(_setRate(value)),
              onOpenToc: () => unawaited(_openToc()),
            )
          : null,
    );
  }

  String _pageLabel() {
    final ref = _session.current;
    final total = _document?.pages.length ?? 0;
    if (ref == null) return total == 0 ? '' : '第 1/$total 页';
    return '第 ${ref.pageIndex + 1}/$total 页';
  }

  Future<void> _setRate(double value) async {
    await TtsManager.instance.setRate(value);
    if (mounted) setState(() {});
  }

  Widget _loadingView() => const Center(
        key: PdfReadingPage.loadingKey,
        child: CircularProgressIndicator(),
      );

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.error_outline, size: 40),
              const SizedBox(height: 12),
              Text('打开 PDF 失败：$_error'),
            ],
          ),
        ),
      );

  Widget _pagesView(PdfDocument doc) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: ListView.builder(
        key: PdfReadingPage.viewKey,
        controller: _scroll,
        itemCount: doc.pages.length,
        itemBuilder: (context, index) {
          final pageNumber = index + 1;
          // 预取这一页与下一页的文本层，减少「点了没反应」的窗口
          unawaited(_session.ensureLayer(index));
          return _pageItem(doc, pageNumber);
        },
      ),
    );
  }

  Widget _pageItem(PdfDocument doc, int pageNumber) {
    final pageIndex = pageNumber - 1;
    final layer = _session.layerOf(pageIndex);
    // 「没有文字层」要等真的抽过才敢报（否则会闪一下提示）
    final noText = _session.isPageEmpty(pageIndex);
    final totalPages = doc.pages.length;
    final page = doc.pages[pageIndex];
    return Padding(
      key: _pageKey(pageIndex),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AspectRatio(
            aspectRatio: page.width / page.height,
            child: Builder(
              builder: (context) {
                return PdfPageLayer(
                  document: doc,
                  pageNumber: pageNumber,
                  textLayer: layer,
                  highlightSentence: _highlightFor(pageNumber),
                  // 高亮底色派生自当前主题（跟随 / 动态取色），
                  // 与文本模式同源：ReaderStyle.pdfHighlightColor（§4.53）
                  highlightColor: ReaderStyle.pdfHighlightColor(
                    Theme.of(context).colorScheme,
                  ),
                  showDebugRects: widget.debugShowTextRects,
                  onReadSentence: (index) => _readSentence(pageNumber, index),
                  onExtentChanged: (extent) {
                    if (pageIndex < _pageExtents.length) {
                      _pageExtents[pageIndex] = extent;
                    }
                  },
                );
              },
            ),
          ),
          if (noText)
            Padding(
              key: PdfReadingPage.noTextLayerKey,
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                // ★v1.21.45 改动 4：说硬话（文案是公开常量，单测直接断言）
                PdfReadingPage.scannedPdfHint,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '$pageNumber / $totalPages',
              style: Theme.of(context).textTheme.labelSmall,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

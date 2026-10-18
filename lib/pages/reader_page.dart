import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
// `RenderParagraph`（实测句子的真实排版盒，见 `_measureSentenceInParagraph`）
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../models/bookmark.dart';
import '../models/document.dart';
import '../models/pdf_line_box.dart';
import '../models/reader_paging.dart';
import '../models/reader_style.dart';
import '../models/structured_document.dart';
import '../services/auto_sleep.dart';
import '../services/crash_log.dart';
import '../services/document_cache.dart';
import '../services/document_service.dart';
import '../services/paragraph_reflow.dart';
import '../services/speech_diagnostics.dart';
import '../services/storage_service.dart';
import '../features/pdf_reading/pdf_read_session.dart';
import '../tts/tts_manager.dart';
import '../widgets/adaptive.dart';
import '../widgets/speech_diag_overlay.dart';
import 'export_audio_page.dart';
import 'toc_sheet.dart';

/// 这条滚动通知是否代表「用户自己在操作」。
///
/// ★**`UserScrollNotification` 不等于「用户碰了屏幕」**：任何滚动**结束时**
/// `goIdle()` 都会发一条 `direction == idle` 的它
/// （`ScrollPositionWithSingleContext.beginActivity`：活动不再滚动就
/// `updateUserScrollDirection(ScrollDirection.idle)`）。
///
/// 我们自己的跟随滚动用 `animateTo`（`DrivenScrollActivity`），一结束就发这一条。
/// 原来不看 direction、一律当成「用户滚动」——于是**程序滚动把自己判成了人工操作**：
/// `_userScrolling` 被置真 2.5 秒，期间 `_followCursor` / `_ensureSentenceVisible`
/// 全部让位。真机表现就是「自动翻页之后视图与朗读脱节（`用户滚动=true`
/// 而用户没碰屏幕）」。
///
/// 只有**方向不是 idle** 才是用户在拖；`ScrollUpdateNotification` 看 dragDetails。
@visibleForTesting
bool isUserScrollNotification(ScrollNotification notification) {
  if (notification is UserScrollNotification) {
    return notification.direction != ScrollDirection.idle;
  }
  if (notification is ScrollUpdateNotification) {
    return notification.dragDetails != null;
  }
  return false;
}

/// 外推定位的**单轮位移上限**（像素）。
///
/// 目标段落很远时 `(target - reference) * perBlock` 会一次算出上万像素
/// （真机 `43.4 → 11396`），`jumpTo` 直接把画面甩到别处，随后重试又跳回来
/// —— 用户看到「先闪错、再跳回」。限成 [maxViewports] 个视口高，靠多轮迭代
/// 逼近：每轮都落在附近，观感连续。
@visibleForTesting
double clampExtrapolateStep({
  required double want,
  required double from,
  required double viewport,
  double maxViewports = 3.0,
}) {
  final double maxStep = viewport * maxViewports;
  if (maxStep <= 0) return want;
  final double gap = want - from;
  if (gap.abs() <= maxStep) return want;
  return from + gap.sign * maxStep;
}

/// 正文块：章节标题栏或段落。扁平化成一条列表交给 ListView 惰性构建，
/// 避免「一章几万段」时一次性构建全部 TextSpan 造成卡顿 / OOM。
sealed class _Block {
  const _Block();
}

class _ChapterBlock extends _Block {
  const _ChapterBlock(this.chapter);

  final int chapter;
}

class _ParagraphBlock extends _Block {
  const _ParagraphBlock(this.chapter, this.paragraph);

  final int chapter;
  final int paragraph;
}

/// 阅读页
///
/// PDF：按原版式单页翻页显示，朗读进度到哪一页视图就跟到哪一页（可暂停跟随）；
/// TXT / EPUB：正文惰性渲染，按句 / 章 / 页朗读并高亮，跟随滚动只在必要时发生。
class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.document, this.startAt});

  final Document document;

  /// 打开后从这个游标开始（书签跳转 / 继续阅读用）
  final (int, int, int)? startAt;

  /// 原版式下「正在朗读的那句话」的字幕条（设备用例用它断言字幕真的显示了）
  static const Key captionBarKey = ValueKey<String>('reader-caption-bar');

  /// 分页版面的 PageView（用例用它翻页 / 断言当前页）
  static const Key pageViewKey = ValueKey<String>('reader-page-view');

  /// 悬浮定位按钮**已按需求删除**；保留这个 Key 只为让用例断言它确实不在了
  static const Key locateButtonKey = ValueKey<String>('reader-locate-button');

  /// 「返回朗读页」按钮（用户离开朗读位置时出现）
  static const Key backToReadingKey = ValueKey<String>('reader-back-to-reading');

  /// 控制中心里的上一页 / 下一页按钮
  static const Key previousPageKey = ValueKey<String>('reader-prev-page');
  static const Key nextPageKey = ValueKey<String>('reader-next-page');

  /// 控制中心里的「下一句」（用例用它推进朗读位置）
  static const Key nextSentenceKey = ValueKey<String>('reader-next-sentence');

  /// 控制中心里的方块键：结束朗读（同时退出朗读模式）
  static const Key stopReadingKey = ValueKey<String>('reader-stop-reading');

  /// 展开态的底部控制中心
  static const Key controlCenterKey = ValueKey<String>('reader-control-center');

  /// 折叠态的控制条
  static const Key collapsedControlKey =
      ValueKey<String>('reader-control-collapsed');

  /// 「收起控制中心」按钮
  static const Key collapseControlKey =
      ValueKey<String>('reader-control-collapse');

  /// 「展开控制中心」按钮
  static const Key expandControlKey = ValueKey<String>('reader-control-expand');

  /// 「自动排版」按钮
  static const Key autoFormatKey = ValueKey<String>('reader-auto-format');

  /// 正文里**正在朗读的那一句**所在的文本块（用例据此量它在屏幕上的位置）
  static const Key activeSentenceKey = ValueKey<String>('reader-active-sentence');

  /// 扫描件（图片型 PDF）在阅读页顶部横幅上那行提示
  ///
  /// ## 措辞（2026-10-14 用户拍板，别改回去）
  ///
  /// 应用内**不做 OCR**（准确率没保证，以后可能走 AI 接口做识别 + 翻译），
  /// 所以提示**不承诺 OCR**，只说清：**能正常翻阅**、**朗读不了**。
  /// 公开常量便于单测断言文案（见 `test/scanned_pdf_hint_test.dart`）。
  static const String scannedPdfHint =
      '这是扫描件（图片型 PDF），没有文字层，无法朗读。'
      '可以正常翻页阅读，只是点句朗读用不了。';

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  final TtsManager _tts = TtsManager.instance;
  final ScrollController _scroll = ScrollController();
  final PdfViewerController _pdf = PdfViewerController();

  /// 分页版面：正文按章节切页，一屏一页（PDF 原版式不走这条）
  PageController? _pageController;
  ReaderPaging _paging = ReaderPaging.empty;

  /// 阅读区宽度（`_pageView` 里量得；用于「段内偏移 → 第几句」的估算）
  double _pageViewportWidth = 0;

  /// 当前页内的滚动控制器：一页一个，翻页时切换
  final Map<int, ScrollController> _pageScrolls = <int, ScrollController>{};

  /// 页内滚动控制器（没有就建一个）
  ScrollController _pageScroll(int pageIndex) =>
      _pageScrolls.putIfAbsent(pageIndex, ScrollController.new);

  /// 当前页下标
  ///
  /// 读数来自 `PageController.page`，翻页动画**过程中**它已经在两页之间 ——
  /// 所以判定「读完本页没有」不能用它，那里用 [_displayedPage]（只在落页后更新）。
  int get _pageIndex {
    final controller = _pageController;
    if (controller == null || !controller.hasClients) return _displayedPage;
    final page = controller.page?.round() ?? _displayedPage;
    return page < 0 ? 0 : (page >= _paging.pageCount ? _lastPageIndex : page);
  }

  int get _lastPageIndex => _paging.pageCount <= 0 ? 0 : _paging.pageCount - 1;

  /// **已经落定的**当前页：只在 `onPageChanged`（动画结束）与初始化时更新
  ///
  /// 与 [_pageIndex] 的区别很关键：`_pageIndex` 在动画途中就变了，
  /// 用它判「本页读完了吗」会在翻页过程中拿错页的范围，从而误判成「又读完了」
  /// —— 这正是「切换下一句时概率性快速连续翻页」的一个来源。
  int _displayedPage = 0;

  /// 已经发起（或完成）过的最后一次自动翻页
  ///
  /// **防连翻的核心**：同一个或更小的目标页只允许翻一次。
  /// 朗读推进很快时 `_followCursor` 会被调用很多次，若只靠 `_pageTurning` 闸门，
  /// 闸门一放开就可能对同一个目标再翻一次 —— 表现为「一连翻好几页」。
  int? _lastAutoTurnTarget;

  /// 翻页闸门：一次翻页动画没结束就不再发新的，避免「一句话一次连续翻页」
  bool _pageTurning = false;
  Timer? _pageTurnSettle;

  /// 最近一次翻页落地的时间
  ///
  /// 翻页落地后还有一段「不安定期」：新页刚布局完，页内滚动位置还没稳定。
  /// 这段窗口内**不要**再发页内滚动（跟随 / 自动定位），否则会与翻页动画
  /// 抢同一个轴 —— 表现就是「密集内容 + 连点快进时页面快速上下翻」。
  DateTime? _pageSettledAt;

  /// 翻页落地后是否还在不安定期内
  bool get _inPageSettleWindow {
    final at = _pageSettledAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < _pageQuietWindow;
  }

  static const Duration _pageQuietWindow = Duration(milliseconds: 600);

  /// 自动翻页是否跟随朗读（对应用户手动翻页后「不跟」的状态）
  ///
  /// 与 PDF 原版式的 `_pdfFollowing` 同义：用户自己翻到别处看时就不再自动跟，
  /// 想跟回来按「回到朗读页」。
  bool _pageAutoFollow = true;

  /// 本页最后一句的游标（自动翻页的判据：读完它才翻下一页）
  (int, int, int)? _lastSpotOfPage(int pageIndex) {
    final page = _paging.pageAt(pageIndex);
    if (_paging.isEmpty) return null;
    final document = _doc;
    if (document == null) return null;
    if (page.chapter < 0 || page.chapter >= document.chapters.length) return null;
    final paragraphs = document.chapters[page.chapter].paragraphs;
    final lastParagraph = page.paragraphEnd - 1;
    if (lastParagraph < 0 || lastParagraph >= paragraphs.length) return null;
    final sentences = paragraphs[lastParagraph].sentences;
    if (sentences.isEmpty) return null;
    return (page.chapter, lastParagraph, sentences.length - 1);
  }

  /// 游标是否已经读完**本页**（到了本页最后一段的最后一句）
  ///
  /// 这是「读完当前页才激活翻页」的判据：只有它成立才允许自动翻到下一页，
  /// 否则光靠「游标落到别的页」会在朗读一开始就连续往后翻。
  bool _cursorFinishedPage((int, int, int) cursor, int pageIndex) {
    final last = _lastSpotOfPage(pageIndex);
    if (last == null) return false;
    final document = _doc;
    if (document == null) return false;
    final current = document.indexOfCursor(cursor);
    final end = document.indexOfCursor(last);
    return current >= end;
  }

  // 仅在目标块附近保留 GlobalKey，避免为每个块建 key
  final Map<int, GlobalKey> _anchors = <int, GlobalKey>{};

  StructuredDocument? _doc;
  List<_Block> _blocks = const <_Block>[];
  List<int> _chapterStart = const <int>[];

  /// 当前文档元数据（解析后会补上文本层信息，退出时据此回写进度）
  late Document _meta = widget.document;

  /// 全部文档的书签（面板里同时展示其它文档的书签）
  List<Bookmark> _allBookmarks = const <Bookmark>[];

  DocumentParseTask? _task;
  ParseProgress? _progress;
  String? _error;
  bool _loading = true;

  /// 解析缓存目录（首次求值后记住；空串表示不启用缓存）
  String? _cacheDirValue;

  /// PDF 超过该体积时默认用文本层阅读：原版式视图会再解析一份文档并渲染位图，内存压力大
  static const int _originalLayoutLimit = 40 * 1024 * 1024;

  /// PDF 显示模式：true = 文本层阅读，false = 原版式翻页
  bool _pdfTextView = false;

  /// 解析时检测到的文本层结果（null = 尚未解析）
  bool? _hasTextLayer;

  /// PDF 每页的文字行位置（原版式「点哪一行就从哪一句读」用；非 PDF 或行数超限时为空）
  ///
  /// ⚠️ v1.21.35 / L2b-2 起**这不再是"整份行表"**：它是「当前装载进来的那些页」，
  /// 数据源是分块文件 `<docId>.lines.<n>.ttsl`（每 [DocumentCache.linesChunkPages] 页一块）。
  /// 别名 [_pdfLinesLoadedPages] 记录"哪些页真装着"，缺页时按块去读。
  final Map<int, List<PdfLineBox>> _pdfLines = <int, List<PdfLineBox>>{};

  /// 「行表分块索引」：块号 → 覆盖的页区间（闭区间）
  ///
  /// 来源：命中缓存时是主缓存里的那份（`ParseResult.linesChunks`），
  /// 真解析时由 `DocumentCache.chunksOf` 现算。**空 = 这份文档没有行表**
  /// （扫描件 / 行数超上限），此时按块读一律作废，点句即读不可用。
  Map<int, LinesChunkRef> _pdfChunks = <int, LinesChunkRef>{};

  /// 真正装进 [_pdfLines] 的页号（**与它同步增删**）
  ///
  /// 为什么不直接看 `_pdfLines.containsKey`：块读有"确认读不出来"的负缓存，
  /// 缺页时两者会分叉 —— 这个集合只记"手上真有数据"的页。
  final Set<int> _pdfLinesLoadedPages = <int>{};

  /// 上次把行表装到"多满"（**只给测试看的记账**）
  ///
  /// 这个数字 > 0 就代表"表是残缺的"——它替代了 v1.21.32 那个粘性布尔
  /// [_pdfLinesTrimmed]：分块读入的模型下，粘性标记容易和真实状态脱节，
  /// 「装进来的页数 < 总页数」才是硬判据。
  @visibleForTesting
  int debugPdfLinesLoadedPeak = 0;

  /// PDF 页面尺寸（解析时由文字行外框推算；拿不到就一直为空）
  Size? _pdfPageSize;

  // PDF 视图状态
  bool _pdfReady = false;
  bool _pdfFollowing = true;

  /// 程序化跳页的目标页（用于区分用户手动翻页）
  int? _pdfTargetPage;

  /// 正在翻页（程序化跳页已发出、目标页还没确认到达）
  ///
  /// 朗读推进得比翻页动画快时（一句只读几百毫秒，翻页要 300ms 以上），
  /// 没有这个闸门就会「一句一次 jumpToPage」，页面看着就是连续快速翻动。
  bool _pdfTurning = false;

  /// 用户正在操作 PDF（手指按着 / 正在滑动）
  bool _pdfTouching = false;

  /// 用户刚刚操作过 PDF（松手后的冷却期）
  ///
  /// 朗读自动翻页与人工翻页抢同一条翻页通道，是「有概率快速翻动」的根因：
  /// 用户刚滑走，朗读又立刻把页面拉回来，两边互相打架。冷却期内不自动翻页，
  /// 用户想跟回去按「回到朗读页」即可。
  bool _pdfUserRecent = false;

  Timer? _pdfUserCooldown;
  Timer? _pdfTurnTimeout;

  /// 用户正在缩放 / 滚动 PDF（此时高亮框必须关掉动画，否则会「追」页面）

  /// 上一次缩放级别（用控制器通知判断「是不是在缩放」）


  /// PDF 页面区尺寸（高亮框按它做坐标换算）
  Size _pdfViewport = Size.zero;

  /// 折叠朗读控制中心（只记住本次会话，不写设置）
  ///
  /// 方块键关掉朗读模式时也会置真：**收起成迷你条**（用户澄清过「收起」
  /// 就是截图里那条 46dp 的播放条，不是整条消失）。
  static bool _controlCollapsed = false;

  // 文本视图跟随状态
  bool _userScrolling = false;

  /// 朗读位置不在视野里时显示「回到朗读页」（文本模式，与 PDF 原版式行为一致）
  bool _backToReading = false;

  Timer? _scrollResume;

  /// 跳转代次：新的跳转一发起，旧的微调循环立刻退出（防止多个循环抢滚动位置）
  int _jumpToken = 0;

  /// 已构建段落的每句字符区间：`"章:段" → [(句, 起, 止)]`
  ///
  /// 由 [_ParagraphView] 在构建后上报。跟随滚动靠它在**段内**定位到具体某一句，
  /// 而不是只把整段滚进视野（段很长时那等于没跟随）。
  final Map<String, List<(int, int, int)>> _sentenceSpans =
      <String, List<(int, int, int)>>{};

  /// PDF 原版式：文档还没加载完时记下的待跳页码（加载完成后补跳）
  int? _pendingPdfPage;

  /// 跟随滚动的代次：新的一发起，旧的立刻 stop 并退出（防止多个滚动叠加）

  bool get _isPdf => widget.document.type == DocumentType.pdf;

  @override
  void initState() {
    super.initState();
    // 自动休眠动作（空闲暂停 / 定时停止）给一条提示，否则「自己停了」会像故障
    AutoSleepController.instance.notice.addListener(_showAutoSleepNotice);
    // 阅读排版（字号 / 行距 / 底色）改了要立刻反映到正文上
    StorageService.instance.readerStyle.addListener(_onStyleChanged);
    // PDF 的滚动 / 缩放都会影响高亮框的位置，跟着重建
    _pdf.addListener(_onPdfControllerChanged);
    // 朗读游标一动就记下「读到哪」。
    //
    // 用**直接监听**而不是在 build 里顺手记：build 只在有重建时跑，
    // 而 `speakFrom` / 快进 / 点句会立刻改游标，不一定会带来一次重建 ——
    // 漏记就会在「停止（游标被清零）→ 退出 → 重进」后回到开头。
    _tts.addListener(_onCursorMoved);
    // §4.100 任务 E：换书时 `TtsManager.loadDocument(别的书)` 会先调这里，
    // 让**本页**把「旧文档停在哪」写回文档库（管理器不知道视图停留位置，
    // 也算不准自动排版后的坐标系，所以写盘交给页面）。
    //
    // ⚠️ 必须**自证身份**：切换的瞬间新页可能也挂上了回调，而
    // `_saveProgress()` 写的是 `widget.document` —— 不加这道判断，
    // 旧页会把**自己的**位置写到新书的进度上。
    // `hasDocument` 只对「管理器当前持有的那本书」放行，天然互斥。
    _tts.onBeforeDocumentSwitch = _persistProgressBeforeSwitch;
    // ★v1.21.59：文字档阅读页进来了 → PDF 不再算"用户正在看的那本"。
    //
    // 这个标记只用于 `TtsAudioHandler.play()` 派发（见 `PdfReadSession.isForeground`）。
    // 不清的话，从 PDF 页返回文字档后按耳机仍会被判成"在 PDF 页"，又读错书。
    PdfReadSession.instance.setForeground(false);
    _buildPdfViewer();
    unawaited(_reloadBookmarks());
    _parse();
    // 位置记忆埋点 A（进入）：进来时文档对象带着什么进度
    CrashLog.mark('位置[进入阅读页] docId=${widget.document.id} '
        'type=${widget.document.type.name} '
        'progress=${widget.document.progress} '
        'startAt=${widget.startAt}');
  }

  /// 换书前把本页的位置写回文档库（只在「管理器当前持有的就是本书」时动手）
  void _persistProgressBeforeSwitch() {
    if (!_tts.holdsDocument(widget.document.id)) return;
    _saveProgress();
  }

  /// 游标变化：把「读到哪」单独记在 [_readingSpot] 里
  ///
  /// **不能直接写 `_lastSpot`**：那个字段表示「用户的视图停在哪」，会被
  /// 滚动 / 翻页 / 跟随逻辑不断改写，写进去马上就被覆盖掉了。
  ///
  /// 为什么要单独记：`TtsManager.stop()` 会把游标清成 (0,0,0)
  /// （方块键要求「回到刚打开软件的样子」），游标一没，位置就丢了 ——
  /// 用户再进来只能回到开头。
  void _onCursorMoved() {
    if (_doc == null || !_tts.holdsDocument(widget.document.id)) return;
    final cursor = _tts.cursor;
    if (cursor.$1 < 0 || cursor.$1 >= _doc!.chapters.length) return;
    _readingSpot = cursor;
    // 观测①：游标变更收到（哪一句、第几章、段内句号）
    _followLog(
      '游标',
      '章=${cursor.$1} 段=${cursor.$2} 句=${cursor.$3} '
      'speaking=${_tts.speaking} playing=${_tts.playing} paused=${_tts.paused}',
    );
    // 朗读位置变了，按钮的显示也要跟着刷（用户可能停在同一页的另一段，
    // 也可能已经翻到别的页）—— 只在滚动通知里刷会漏掉这些情况。
    _syncBackToReading();
  }

  @override
  void dispose() {
    AutoSleepController.instance.notice.removeListener(_showAutoSleepNotice);
    StorageService.instance.readerStyle.removeListener(_onStyleChanged);
    _pdf.removeListener(_onPdfControllerChanged);
    _tts.removeListener(_onCursorMoved);
    // §4.100 任务 E：注销换书回调（只有还在持有的那本书才需要它）
    if (_tts.onBeforeDocumentSwitch == _persistProgressBeforeSwitch) {
      _tts.onBeforeDocumentSwitch = null;
    }
    _saveProgress();
    _task?.cancel(); // 解析中途退出：立即终止后台 isolate
    _scrollResume?.cancel();
    _pdfUserCooldown?.cancel();
    _pdfTurnTimeout?.cancel();
    // **不在这里 stop 朗读**（用户要求：「从文档中退出至文档库界面不打断朗读」）。
    //
    // 朗读要继续，就必须保证它不依赖本页的对象：`TtsManager` 持有的是
    // `StructuredDocument` 本体（解析结果），不是本页；本页只是「显示 + 跟随」。
    // 所以退出阅读页只该停掉与显示相关的定时器，声音让它继续。
    // 想停有两条明确路径：控制栏的「停止」按钮，或自动休眠到点。
    _scroll.dispose();
    _pdf.dispose();
    super.dispose();
  }

  /// PDF 控制器有变化（滚动 / 缩放 / 换页）：高亮框要跟着动
  ///
  /// 只在「正在朗读 + 原版式」时才重建，避免平时白白刷新整页。
  void _onPdfControllerChanged() {
    if (!mounted) return;
    if (!_tts.speaking || _pdfTextView || !_isPdf) return;
    setState(() {});
  }

  /// 弹出自动休眠提示（提示本身只消费一次）
  void _showAutoSleepNotice() {
    final notice = AutoSleepController.instance.notice.value;
    if (notice == null || !mounted) return;
    AutoSleepController.instance.clearNotice();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(notice)));
  }

  /// 阅读排版变化：重建正文（字号 / 行距 / 底色立即生效）
  void _onStyleChanged() {
    if (mounted) setState(() {});
  }

  /// 当前阅读排版
  ReaderStyle get _style => StorageService.instance.readerStyle.value;

  /// 正文实际生效的排版：在用户设置之上加「大屏页边距下限」
  ///
  /// 手机保持用户设置（默认 12）；平板 / 超宽屏至少 32 / 40，否则文字会贴着
  /// 栏边。用户自己调得更大时以用户为准（这里只抬下限，不压低）。
  ///
  /// ⚠️ 量句子位置（[_measureSentence]）必须用**同一个** style，否则实测宽度
  /// 与真实排版宽度不一致，句顶/句心会系统性偏。
  ReaderStyle get _pageStyle {
    if (!mounted) return _style;
    final base = _style;
    final minMargin = readerMinPageMargin(context);
    if (base.pageMargin >= minMargin) return base;
    return base.copyWith(pageMargin: minMargin);
  }

  // ---------------- 解析（后台 isolate） ----------------

  Future<void> _parse() async {
    debugParseForTestCount++; // 测试用：见 debugParseForTestCount 的说明
    _task?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _progress = null;
    });
    // 封面输出路径与缓存目录都只是「加分项」：先各自跑起来，
    // 但**解析要等它们出结果**（缓存命中与否决定了要不要起 isolate）。
    // 两者并发求值，避免串行等两次平台通道。
    final coverFuture = _coverOutPath();
    final cacheFuture = _cacheDir();
    final coverOut = await coverFuture;
    final cacheDir = await cacheFuture;
    final task = DocumentService.parseAsync(
      widget.document,
      coverOutPath: coverOut,
      cacheDir: cacheDir,
      onProgress: (progress) {
        if (!mounted) return;
        setState(() => _progress = progress);
      },
    );
    _task = task;
    try {
      final result = await task.result;
      if (!mounted) return;
      final document = result.document;
      // 编码探测在 isolate 里做（那里不能碰插件），日志回到这里写
      final encoding = result.encoding;
      if (encoding != null) {
        CrashLog.mark(
          'TXT 编码：$encoding（${DocumentService.shortPath(widget.document.path)}，'
          '${result.textCharCount} 字，${document.chapters.length} 章）',
        );
      }
      if (result.fromCache) {
        CrashLog.mark(
          '解析缓存命中：${DocumentService.shortPath(widget.document.path)}'
          '（${document.chapters.length} 章，${result.textCharCount} 字）',
        );
      }
      // 大 PDF 默认走文本层：原版式渲染要额外解析并栅格化整份文档，低内存设备容易闪退
      if (_isPdf) {
        // 上次退出时用的是哪种模式，这次就进哪种模式
        // （文档库控制栏的「返回朗读页」要求回到对应界面）
        _pdfTextView = StorageService.instance.isTextMode(widget.document.id);
        if (!_pdfTextView) {
          // 没记录过：按体积决定默认（超大 PDF 强制文本模式，避免低内存闪退）
          _pdfTextView = result.fileSize > _originalLayoutLimit;
        }
        // 记录里是文本模式、但这份文件大到不该走原版式，以体积为准
        if (result.fileSize > _originalLayoutLimit) _pdfTextView = true;
      }
      // PDF 由原版式视图渲染时用不到文本行信息，文本模式才需要
      final needBlocks = !_isPdf || _pdfTextView;
      // 1) 先把「本次解析出来的 PDF 信息」落到字段上
      //
      // 必须**在排版判定之前**赋值：`_pdfLines` 是重排的数据源，
      // 而 `needBlocks`/`_pdfTextView` 决定这份文档要不要分页。
      // 早先这几行写在末尾的 setState 里，重构时漏掉就会表现为
      // 「文本模式没了、排版按钮也不见了」。
      _pdfPageSize = result.pageSize;
      _hasTextLayer = result.hasTextLayer;

      // 2) 定位：优先按「上次退出时停留的位置」在页面坐标系里解析
      // （这一步只是把坐标解析出来，真正绑定要等排版确定之后）
      //
      // 内存游标要在 `loadDocument` **之前**取：那个调用会把它重置成 (0,0,0)。
      final memoryCursor = TtsManager.instance.holdsDocument(widget.document.id)
          ? TtsManager.instance.cursor
          : null;
      final savedSpot = _resolveStart(document, memoryCursor);
      _lastSpot = savedSpot ?? (0, 0, 0);

      // 2.5) 行表按模式装页（v1.21.35 / L2b-2）
      //
      // ⚠️ 必须在下面那个 `canFormat = needBlocks && _pdfLines.isNotEmpty` **之前**：
      // 那个判据看的就是"行表里有没有内容"，晚一步就会出现
      // 「自动排版开着但进文本模式没效果」。
      //
      // 装哪一页：文本模式要整份（排版遍历全部页），原版式只要"这次打开的那一页"
      // 所在的块。_lastSpot 的第 0 项就是页下标（PDF 一章即一页）。
      //
      // 这里是 `await`：块读要靠缓存目录，而它是个 Future
      //（单测环境那条平台通道可能不回复 → 超时即降级成"整份表常驻"，功能不受影响）。
      if (_isPdf) {
        await _cacheDir();
        if (!mounted) return;
        _adoptPdfLines(result, _lastSpot.$1, textMode: _pdfTextView);
      }

      // 3) 先确定「最终用哪份文档」：开了自动排版就用重排结果
      //
      // **顺序很关键**（修过的一个 bug）：重排会改变段落下标，
      // 所以必须**先排版、再按重排后的坐标系定位**。原来的顺序是
      // 「先定位 + 建分页，再排版」—— 于是：
      //   - `_lastSpot` 会变成重排前的坐标系；
      //   - `_pageIndexForParagraph` 也按重排前的段落算；
      //   两者混用就出现「从文档库返回朗读页时回不到原来那句」。
      final autoFormat = StorageService.instance.isAutoFormat(widget.document.id);
      var finalDoc = document;
      var start = savedSpot;
      final canFormat = needBlocks && _pdfLines.isNotEmpty;
      if (autoFormat && canFormat) {
        final reflowed = _tryReflow(document, silent: true);
        if (reflowed != null) {
          // 段落下标全变了：用「同一句话」把位置映射到新坐标系
          final mapped = _remapSpot(document, reflowed, _lastSpot);
          finalDoc = reflowed;
          start = mapped;
          _lastSpot = mapped;
        }
      }

      // 4) 排版定稿后再绑定朗读与版面
      // 原始结构留一份：自动排版可以撤销，撤销时要换回它。
      // 这份**永远是解析出来的原样**，不能被重排结果覆盖。
      _originalDoc = document;
      _tts.loadDocument(
        finalDoc,
        at: start,
        title: widget.document.title,
        documentId: widget.document.id,
      );
      await _tts.setGranularity(ReadGranularity.sentence);
      _buildLayout(finalDoc, start);
      // 回写封面与文本层检测结果，避免下次重复解析
      var meta = _meta;
      var changed = false;
      final cover = result.coverPath;
      if (cover != null && cover != meta.coverPath) {
        meta = meta.copyWith(coverPath: cover);
        changed = true;
      }
      if (meta.hasTextLayer != result.hasTextLayer) {
        meta = meta.copyWith(hasTextLayer: result.hasTextLayer);
        changed = true;
      }
      if (changed) {
        _meta = meta;
        unawaited(StorageService.instance.upsertDocument(meta));
      }
      // 缓存命中时不会走 isolate，封面也就不会被顺手抽出来：
      // 首次导入时中途退出过的话（还没写出封面），这里补一次。
      if (result.fromCache && coverOut != null) {
        unawaited(_backfillCover(coverOut, meta));
      }
      // 继续阅读 / 书签跳转：解析完成后把视图对齐到起始位置
      // （`_buildLayout` 已经按 `start` 定好了页，这里只补页内对齐）
      final alignTo = start;
      if (alignTo != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _alignTo(alignTo);
        });
      }
    } catch (e) {
      if (!mounted || !identical(_task, task)) return;
      setState(() {
        _error = '解析失败：$e';
        _loading = false;
      });
    }
  }

  /// 缓存命中路径下补抽 EPUB 封面（首次真解析时是由 isolate 顺手写出的）
  Future<void> _backfillCover(String coverOutPath, Document meta) async {
    try {
      if (await File(coverOutPath).exists()) return;
      final cover =
          await DocumentService.extractCover(widget.document, coverOutPath);
      if (cover == null || !mounted) return;
      _meta = _meta.copyWith(coverPath: cover);
      await StorageService.instance.upsertDocument(_meta);
    } catch (_) {
      // 封面失败不影响阅读
    }
  }

  /// 本次打开要从哪里开始
  ///
  /// 优先级：
  /// 1. 显式传入的位置（书签跳转 / 目录跳转）；
  /// 2. **「内存里的朗读游标」与「写回的进度」中更靠后的那个**；
  /// 3. 从头开始。
  ///
  /// 为什么两者要取靠后的：它们都可能过期，而且谁更新并不固定 ——
  /// - 退出时 `_saveProgress()` 是异步写盘，列表页可能还没读到新值；
  /// - 反过来，同一个 id 的文档被带着新进度再次打开时，内存里的游标又是旧的。
  ///
  /// 取靠后的那个在两种情况下都对：用户上次读到/看到哪，就回到哪
  /// （正常阅读是单向推进的，所以「更靠后」≈「更近的一次」）。
  /// 需求「退出时在哪，重进就在哪」对文字模式与 PDF 原版式同样适用
  /// （PDF 一章即一页，进度换算回来就是页码）。
  ///
  /// ⚠️ **必须在 `loadDocument` 之前读内存游标**：`TtsManager.loadDocument` 在
  /// `at == null` 时会**无条件把游标重置成 (0,0,0)**，而 `_parse` 紧接着就会调用它。
  /// 于是「上一次会话留下的游标」会被自己清成 0，这一步再读就只能读到 0
  /// → **回到开头**。所以 [memoryCursor] 由调用方在载入前取好传进来。
  (int, int, int)? _resolveStart(
    StructuredDocument document,
    (int, int, int)? memoryCursor,
  ) {
    final explicit = widget.startAt;
    if (explicit != null) return explicit;

    // 写回的进度 → 位置
    var saved = document.cursorAt(widget.document.progress);
    if (widget.document.progress <= 0) saved = (0, 0, 0);

    // 内存里的游标：只认「这本书正被管理器持有」的情况（TtsManager 是单例，
    // 读别的书时它记的是别的书的游标）
    final memory = memoryCursor ?? (0, 0, 0);

    final first = document.indexOfCursor(saved);
    final second = document.indexOfCursor(memory);
    final spot = first >= second ? saved : memory;
    // 位置记忆埋点 B（恢复）：写回进度 / 内存游标 / 最终选了哪个
    CrashLog.mark('位置[恢复] docId=${widget.document.id} '
        'saved=${widget.document.progress}→$saved '
        'memory=$memory 取="${first >= second ? "saved" : "memory"}" '
        'spot=$spot 章数=${document.chapters.length}');
    if (spot.$1 == 0 && spot.$2 == 0 && spot.$3 == 0) return null;
    return (
      spot.$1.clamp(0, document.chapters.length - 1),
      spot.$2,
      spot.$3,
    );
  }

  /// 把视图（正文列表 / PDF 页）对齐到某个位置
  void _alignTo((int, int, int) spot) {
    if (!mounted) {
      _followLog('进入定位', 'spot=$spot 但已 unmounted');
      return;
    }
    final document = _doc;
    if (document == null || document.chapters.isEmpty) {
      _followLog('进入定位', 'spot=$spot 但文档未就绪（doc=${document == null ? "null" : "空章"}）');
      return;
    }
    final chapter = spot.$1.clamp(0, document.chapters.length - 1);
    // 观测⑤：进入阅读页定位 —— 请求的 spot 与当前 TTS 游标是否一致
    _followLog(
      '进入定位',
      'spot=$spot 夹取章=$chapter 块数=${_blocks.length} '
      'tts游标=${_tts.cursor} 视图位置=$_lastSpot 朗读位置=$_readingSpot '
      '落定页=$_displayedPage 目标页=$_pageIndex',
    );
    if (_isPdf && !_pdfTextView) {
      // 原版式：一章即一页。文档还没加载完就先记下来，
      // 等 onDocumentLoaded 再跳 —— 否则这次跳页会被视图丢掉，
      // 表现就是「重进回到了第 1 页」。
      if (!_pdfReady) {
        _pendingPdfPage = chapter + 1;
        _followLog('进入定位', 'PDF 未就绪 → 记下待跳页=${chapter + 1}');
        return;
      }
      _goToPdfPage(chapter + 1);
      return;
    }
    if (_blocks.isEmpty) {
      _followLog('进入定位', '★块列表为空 → 定位无法执行（spot=$spot）');
      return;
    }
    final paragraphs = document.chapters[chapter].paragraphs;
    if (paragraphs.isEmpty) {
      unawaited(_revealBlock(_chapterBlockIndex(chapter)));
      return;
    }
    final paragraph = spot.$2.clamp(0, paragraphs.length - 1);
    final block = _chapterBlockIndex(chapter) + 1 + paragraph;
    unawaited(_revealBlock(block));
    // ★v1.21.53：进入定位**不能只管段落**。
    //
    // 「重回阅读页有概率不在朗读位置」的根因之一就在这里：
    // 原来只 `_revealBlock`（把**段落**按 alignment 拉进视野）就结束了，
    // 而一个中文字幕段落常常比视口高好几倍 —— 段落进视野 ≠ **那一句**进视野。
    // 于是「页对了、段对了，但正在读的那句在屏幕外」，用户看到的就是
    // 「回到朗读页却不在朗读位置」。
    //
    // 修法（对照 PDF 的做法）：`_revealBlock` 之后**再校验一次「句子可见」**，
    // 不可见就按句对齐；并且**等布局稳定后再补一次**（PDF 是逐帧收敛最多 24 帧）。
    // 这里用「帧后 → 再等一帧 → 校验 → 必要时对齐」的有限轮次，不做无限重试。
    unawaited(_alignToSentenceAfterLayout(chapter, paragraph, spot.$3));
  }

  /// ★负向自检专用开关（**必须保持 false**）：置 true 则跳过句子级进入定位
  static const bool _negativeSkipEntryAlign = false;

  /// 进入阅读页的**句子级**定位（在段落定位之后跑）
  ///
  /// 与 PDF `_revealToPageIndex` 的逐帧收敛同义：目标可能还没建出来
  /// （ListView 惰性构建），所以要跨几帧重试；但轮次必须有限，
  /// 否则会和后续的跟随滚动抢同一个控制器（那正是「页面乱抽」的来源）。
  Future<void> _alignToSentenceAfterLayout(
    int chapter,
    int paragraph,
    int sentence,
  ) async {
    if (_negativeSkipEntryAlign) return; // ★负向自检开关
    for (var attempt = 0; attempt < 8; attempt++) {
      await _nextFrame();
      if (!mounted) return;
      if (_userScrolling || _pageTurning || _inPageSettleWindow) continue;
      final block = _paragraphBlockIndex(chapter, paragraph);
      if (block < 0) return;
      // 用**请求恢复的那个 spot** 量几何（不是 `_tts.highlightCursor` —— 那条在
      // 没朗读时恒为 null，见 `_geometryForCursor` 的说明）。
      final geometry = _geometryForCursor((chapter, paragraph, sentence));
      if (geometry == null) {
        // 段落还没建出来 / 视口没就绪：这一轮跳过，等下一帧
        continue;
      }
      // 句心是否已落在「可见范围」内（用比舒适区更宽的可接受区间：
      // 这里的目标是「看得见、且不是贴着边缘」，不是把它对齐到 38% ——
      // 对齐留给用户点「回到朗读页」那种显式指令）
      final h = geometry.height;
      final top = geometry.sentenceTop;
      final visible = top >= h * 0.05 && top <= h * 0.85;
      _followLog(
        '进入定位校验',
        '第${attempt + 1}轮 章=$chapter 段=$paragraph 句=$sentence 块=$block '
        '句心=${top.toStringAsFixed(1)} 视口高=${h.toStringAsFixed(0)} '
        '可见=$visible $_lastSentenceMeasure',
      );
      if (visible) {
        _followLog('进入定位完成', '章=$chapter 段=$paragraph 句=$sentence 已在视野内');
        return;
      }
      // 不可见：按句对齐一次（复用跟随滚动的对齐口径），下一轮再校验
      final scroll = _pageScroll(_displayedPage);
      if (!scroll.hasClients) continue;
      final position = scroll.position;
      final want = (position.pixels + top - h * 0.38)
          .clamp(0.0, position.maxScrollExtent);
      if ((want - position.pixels).abs() < 2) continue;
      _followLog(
        '进入定位补正',
        '句心=${top.toStringAsFixed(1)} 不在可见区 → 对齐目标=${want.toStringAsFixed(1)}',
      );
      await scroll.animateTo(
        want,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      ).catchError((Object _) {});
    }
    _followLog('进入定位结束', '章=$chapter 段=$paragraph 句=$sentence 轮次用尽');
  }

  /// EPUB 首次打开时抽取封面；已有封面则不重复抽取
  Future<String?> _coverOutPath() async {
    if (widget.document.type != DocumentType.epub) return null;
    try {
      final existing = widget.document.coverPath;
      if (existing != null &&
          existing.isNotEmpty &&
          await File(existing).exists()) return null;
      final dir = await getApplicationDocumentsDirectory();
      return '${dir.path}/covers/${widget.document.id}.jpg';
    } catch (_) {
      return null;
    }
  }

  /// 解析缓存目录（拿不到就不启用缓存，解析照常）
  ///
  /// 只求值一次并记住：`getApplicationDocumentsDirectory` 每次都要过平台通道。
  /// **不能在解析之前 await 它** —— 测试环境（以及个别 ROM）里这个通道可能一直不回复，
  /// 会把解析本身也一起挂住。
  ///
  /// ⚠️ v1.21.35 / L2b-2：改成**缓存 Future 本身**（而不是只缓存结果）。
  /// 原因：行表按块读要靠这个目录，而 `_parse`（先 await 它）与
  /// `_switchToTextMode`（同步入口、不能 await）两条路都要用它 ——
  /// 只缓存"已经求出来的值"会让后到的那条看到空串，
  /// 表现就是"块读不可用 → 行表退化"（这条坑真踩过：自动排版按钮消失）。
  Future<String>? _cacheDirFuture;

  Future<String> _cacheDir() {
    final cached = _cacheDirFuture;
    if (cached != null) return cached;
    final future = _resolveCacheDir();
    _cacheDirFuture = future;
    return future;
  }

  Future<String> _resolveCacheDir() async {
    String dir;
    try {
      dir = await DocumentService.cacheDirectory();
    } catch (_) {
      dir = '';
    }
    _cacheDirValue = dir;
    return dir;
  }

  // ---------------- PDF 行表：按块读（v1.21.35 / L2b-2） ----------------

  /// 块读取器：`(缓存目录, 文档 id, 块号) → 该块行表`；读不出来返回 null
  ///
  /// 抽成字段是为了**测试可注入**：单测环境拿不到 `path_provider` 的缓存目录，
  /// 真块文件读不出来，只能靠注入验「读了几块 / 读满没有」这条不变量。
  Map<int, List<PdfLineBox>>? Function(String, String, int) _chunkLoader =
      DocumentCache.readLineChunkByName;

  /// 当前是否"整份行表常驻内存"
  ///
  /// 两种模式：
  /// - **按块读**（`false`，正常路径）：解析出的整份表只取"地图"，页数据丢给 GC，
  ///   翻到哪页读哪块（这是本轮的内存收益）；
  /// - **整份常驻**（`true`，降级路径）：**块读不可用**时（拿不到缓存目录 /
  ///   没有分块索引 —— 例如缓存写失败、path_provider 不可用），
  ///   整份表是**唯一数据源**，丢掉就再也补不回来 → 此时一律不裁、不释放。
  ///
  /// ⚠️ 不这么分会出现"行表凭空消失"：自动排版按钮消失、点句即读全废。
  bool _pdfLinesFullTable = false;

  /// 把「整份行表」压成索引（只留块号 + 页区间，页数据本身丢掉）
  ///
  /// 真解析出来的 `result.pdfLines` 是**整份**的（812 页可能上百 MB），
  /// L2b-2 只留它的地图，页数据让 GC 回收、等翻到再按块读 —— 这就是本轮的内存收益。
  void _indexPdfChunks(List<LinesChunkRef>? chunks, Map<int, List<PdfLineBox>>? lines) {
    final Map<int, LinesChunkRef> map = <int, LinesChunkRef>{};
    if (chunks != null) {
      for (final LinesChunkRef ref in chunks) {
        map[ref.chunk] = ref;
      }
    } else if (lines != null && lines.isNotEmpty) {
      for (final LinesChunkRef ref in DocumentCache.chunksOf(lines)) {
        map[ref.chunk] = ref;
      }
    }
    _pdfChunks = map;
  }

  /// 分块读是否可用：既要有地图，也要能拿到缓存目录
  ///
  /// ⚠️ 两者缺一就**不能裁行表**：裁了就再也补不回来，表现是「切文本模式排版残缺」。
  /// 这种降级路径（拿不到缓存目录 / 没有分块索引）下整份行表留在内存里
  /// （见 [_pdfLinesFullTable]），与 L2b-1 之前的行为一致。
  bool get _chunkReadAvailable =>
      _pdfChunks.isNotEmpty && (_cacheDirValue ?? '').isNotEmpty;

  /// 覆盖 [page] 的那一块（没有地图时按页号推算兜底）
  int _pdfChunkOf(int page) =>
      _pdfChunks.values
          .where((LinesChunkRef r) => page >= r.startPage && page <= r.endPage)
          .map((LinesChunkRef r) => r.chunk)
          .firstOrNull ??
      (page < 0 ? 0 : page ~/ DocumentCache.linesChunkPages);

  /// 解析完成后决定"行表归谁管"，并装上需要的那部分页
  ///
  /// - 块读可用 → 只留地图，按模式装页（文本模式读满全部块 / 原版式只装当前块）；
  /// - 块读不可用 → **整份表留在内存**（降级），一行都不裁。
  void _adoptPdfLines(ParseResult result, int startPage, {required bool textMode}) {
    _indexPdfChunks(result.linesChunks, result.pdfLines);
    _pdfLines.clear();
    _pdfLinesLoadedPages.clear();
    _pdfLinesFullTable = false;
    if (!_chunkReadAvailable) {
      // 降级：块读拿不到数据源，整份表就是唯一来源（扫描件时它本来就是空的）
      final Map<int, List<PdfLineBox>>? lines = result.pdfLines;
      if (lines != null && lines.isNotEmpty) {
        _pdfLines.addAll(lines);
        _pdfLinesLoadedPages.addAll(lines.keys);
        _pdfLinesFullTable = true;
      }
      return;
    }
    if (textMode) {
      _loadAllPdfLineChunks();
    } else {
      _loadPdfLinesForPage(startPage);
    }
  }

  /// 确保 [page] 那一页的行表在手上（不在就按块读一次）
  ///
  /// 块读缓存（[DocumentCache.maxChunkCacheBytes] ≈2MB，按字节淘汰最旧）挡在前面：
  /// 用户在同一块内来回翻页**不会反复读同一个文件**。
  /// 返回这一页最终有没有行表 —— 没抽出来（缺块 / 扫描页）就是 false。
  bool _ensurePdfLinesForPage(int page) {
    if (_pdfLinesFullTable) return _pdfLines.containsKey(page);
    if (_pdfLinesLoadedPages.contains(page)) return true;
    if (!_chunkReadAvailable) return false;
    final int chunk = _pdfChunkOf(page);
    final Map<int, List<PdfLineBox>>? loaded =
        _chunkLoader(_cacheDirValue ?? '', widget.document.id, chunk);
    if (loaded == null) return false;
    // ⚠️ 只把**块里真有数据的页**记成已装：块缺页时留个未装的缝，
    // 下次访问那一页还能再试（而块读缓存里已经有负缓存，不会反复碰盘）。
    _pdfLines.addAll(loaded);
    _pdfLinesLoadedPages.addAll(loaded.keys);
    if (_pdfLinesLoadedPages.length > debugPdfLinesLoadedPeak) {
      debugPdfLinesLoadedPeak = _pdfLinesLoadedPages.length;
    }
    // ⚠️ 裁剪时必须把 [page] 本身也算进保留窗口：否则刚读回来的这一页
    // 会被"窗口外"顺手丢掉（`_speakPdfLine` 点句就白读了）。
    _trimPdfLinesOutsideWindow(page, alsoKeep: page);
    return _pdfLinesLoadedPages.contains(page);
  }

  /// 原版式装载策略：只留「当前页 ±3 ∪ 朗读页 ±3」，其余页按块读为数据源
  ///
  /// 与 v1.21.31 那个裁剪的判据完全一致（[`_pdfLinesMaxPages`] 以内不动手），
  /// 区别只是**丢掉的页不再是"丢了就没了"** —— 翻回去会按块读回来。
  void _loadPdfLinesForPage(int page) {
    if (_pdfLinesFullTable) return; // 降级模式：整份表常驻，不动它
    if (!_chunkReadAvailable) return;
    if (!_ensurePdfLinesForPage(page)) return;
    _trimPdfLinesOutsideWindow(page);
  }

  /// 真的丢掉窗口外的页（调用方保证"块读可用"）
  ///
  /// [alsoKeep] 是"必须留住"的额外页（调用方刚花一次读盘换来的那一页）。
  void _trimPdfLinesOutsideWindow(int page, {int? alsoKeep}) {
    if (_pdfLinesFullTable) return; // 降级模式：丢了就补不回来
    if (!_chunkReadAvailable) return;
    if (_pdfLinesLoadedPages.length <= _pdfLinesMaxPages) return;
    final int readingPage = _tts.cursor.$1;
    final Set<int> keep = <int>{};
    for (var d = -_pdfLineWindow; d <= _pdfLineWindow; d++) {
      keep.add(page + d);
      keep.add(readingPage + d);
    }
    if (alsoKeep != null) keep.add(alsoKeep);
    final List<int> drop = _pdfLinesLoadedPages
        .where((int p) => !keep.contains(p))
        .toList(growable: false);
    if (drop.isEmpty) return;
    for (final int p in drop) {
      _pdfLines.remove(p);
      _pdfLinesLoadedPages.remove(p);
    }
    // ignore: avoid_print
    assert(() {
      debugPrint(
        'PDF 行表：留 ${_pdfLinesLoadedPages.length} 页'
        '（丢了 ${drop.length} 页，翻回去按块读回）',
      );
      return true;
    }());
  }

  /// 文本模式：**顺序读完全部块**拼回整份行表（A 方案）
  ///
  /// 为什么必须读满：自动排版（`_reflowedChapters`）与「能不能排版」的判据
  /// 都要遍历整份行表 —— 只装当前块的话，用户会看到**残缺的排版**。
  /// 为什么不用重跑 `_parse()`：那是 v1.21.32 的临时补法（借缓存命中的毫秒级读回），
  /// L2b-2 有了块文件，直接按块读更便宜也更可控。
  ///
  /// ⚠️ 入口是 **async**（`_switchToTextMode` 是同步的，调用处不 await）：
  /// 缓存目录是个 Future，必须等它落定才知道"块读到底可不可用"。
  /// 单测环境里那个平台通道可能一直不回复 —— 所以**它不回复就等于不可用**，
  /// 走整份表常驻的降级路径，功能不受影响。
  Future<void> _loadAllPdfLineChunks() async {
    await _cacheDir();
    if (_pdfLinesFullTable) return; // 降级模式：整份表已经在手上了
    if (!_chunkReadAvailable) return;
    final List<int> chunkIds = _pdfChunks.keys.toList()..sort();
    for (final int chunk in chunkIds) {
      final Map<int, List<PdfLineBox>>? loaded =
          _chunkLoader(_cacheDirValue ?? '', widget.document.id, chunk);
      if (loaded == null) continue; // 缺块：这些页没抽出来（语义与"没行表"一致）
      _pdfLines.addAll(loaded);
      _pdfLinesLoadedPages.addAll(loaded.keys);
    }
    if (_pdfLinesLoadedPages.length > debugPdfLinesLoadedPeak) {
      debugPdfLinesLoadedPeak = _pdfLinesLoadedPages.length;
    }
    // ignore: avoid_print
    assert(() {
      debugPrint('PDF 文本模式：读入 ${_pdfLinesLoadedPages.length} 页 '
          '（块数 ${chunkIds.length}）');
      return true;
    }());
  }

  /// 切回原版式：把文本模式读进来的整份行表**释放回窗口**
  ///
  /// 「退出文本模式释放」是本轮的内存闭环：不释放的话，用户切一次文本模式
  /// 就永久多背着一整份行表，L1/L2 的内存收益全丢。
  void _dropPdfLinesToWindow(int page) {
    if (_pdfLinesFullTable) return; // 降级模式：整份表是唯一数据源，不能丢
    if (!_chunkReadAvailable) return;
    final Set<int> keep = <int>{};
    final int readingPage = _tts.cursor.$1;
    for (var d = -_pdfLineWindow; d <= _pdfLineWindow; d++) {
      keep.add(page + d);
      keep.add(readingPage + d);
    }
    final List<int> drop = _pdfLinesLoadedPages
        .where((int p) => !keep.contains(p))
        .toList(growable: false);
    for (final int p in drop) {
      _pdfLines.remove(p);
      _pdfLinesLoadedPages.remove(p);
    }
  }

  /// 切模式时把行表拉到该模式需要的程度（幂等，可重复调用）
  Future<void> _syncPdfLinesForMode() async {
    if (!_isPdf) return;
    if (_pdfTextView) {
      await _loadAllPdfLineChunks();
      return;
    }
    await _cacheDir();
    if (!_chunkReadAvailable) return;
    final int page = _pdfReady ? math.max(_pdf.pageNumber - 1, 0) : 0;
    _loadPdfLinesForPage(page);
    _dropPdfLinesToWindow(page);
  }

  /// 退出时把**用户停留的位置**与**当前阅读模式**写回
  ///
  /// 用 [_lastSpot]（用户看的地方）而不是朗读游标：用户可能只是翻看没朗读，
  /// 或者朗读到一半又手动翻到别处去了 —— 需求是「退出在哪，重进就在哪」。
  ///
  /// 阅读模式（PDF 原版式 / 文本模式）也要落盘：用户要求「文档库控制栏的
  /// 返回朗读位置按钮要识别退出时是哪种模式，返回时回到对应界面」。
  void _saveProgress() {
    final document = _doc;
    if (document == null || document.isEmpty) return;
    // 退出前再刷一次：滚动 / 翻页都会更新 `_lastSpot`，这里兜一次底
    // （注意：dispose 阶段 ScrollPosition 已经摘掉，这次调用通常量不到，
    //   真正生效的是滚动 / 翻页时的记录 —— 见 `_rememberVisibleSpot` 的说明）
    _rememberVisibleSpot();
    _persistProgress();
  }

  /// 写回用的位置 =「视图停留位置」与「朗读游标」中更靠后的那个
  ///
  /// - 用户翻到哪就该回到哪（视图位置通常更靠后）；
  /// - 但也可能是**跳着读**（点句起读 / 快进 / 目录跳转）：游标在前面而视图还没
  ///   跟过去，只写视图位置就会丢掉刚跳到的进度。
  ///   例：点第 40 段那一句听了一下就退出 —— 视图没滚动，游标已在第 40 段；
  ///   只写视图位置的话再进来还停在原处（用户看到的「不能正确返回朗读位置」）。
  /// 取靠后的那个等价于「上次读到/看到的最远处」，单向阅读时两者一致。
  ///
  /// 判据不用 `speaking`：用户可能**暂停**在某一句话上就退出了，
  /// 那时游标仍然是有效位置，必须算进来。
  (int, int, int) _progressSpot(StructuredDocument document) {
    var spot = _lastSpot;
    final candidates = <(int, int, int)>[
      if (_tts.holdsDocument(widget.document.id)) _tts.cursor,
      if (_readingSpot != null) _readingSpot!,
    ];
    for (final candidate in candidates) {
      if (candidate.$1 < 0 || candidate.$1 >= document.chapters.length) continue;
      if (document.indexOfCursor(candidate) > document.indexOfCursor(spot)) {
        spot = candidate;
      }
    }
    return spot;
  }

  /// 把当前位置换算成进度写回文档库（不含「再量一次」）
  void _persistProgress() {
    final document = _doc;
    if (document == null || document.isEmpty) return;
    final spot = _progressSpot(document);
    final progress = document.progressOf(spot);
    // 位置记忆埋点 C（写回）：算出来的 spot 与折算出的进度
    CrashLog.mark('位置[写回] docId=${widget.document.id} spot=$spot '
        'progress=$progress 视图位置=$_lastSpot 朗读位置=$_readingSpot '
        'tts游标=${_tts.cursor} 持有=${_tts.holdsDocument(widget.document.id)}');
    unawaited(
      StorageService.instance.upsertDocument(
        _meta.copyWith(
          progress: progress,
          lastReadAt: DateTime.now(), // 「最近阅读」排序用
        ),
      ),
    );
    if (_isPdf) {
      unawaited(
        StorageService.instance.setTextMode(widget.document.id, _pdfTextView),
      );
    }
  }

  // ---------------- 导出朗读音频 ----------------

  /// 打开导出页：把当前章或整本合成成音频文件
  Future<void> _exportAudio() async {
    final document = _doc;
    if (document == null || document.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExportAudioPage(
          title: widget.document.title,
          chapters: document.chapters,
          initialChapter: _tts.cursor.$1,
        ),
      ),
    );
  }

  // ---------------- 书签 ----------------
  /// 当前文档的书签（按创建时间倒序）
  List<Bookmark> get _bookmarks => _allBookmarks
      .where((bookmark) => bookmark.documentId == widget.document.id)
      .toList();

  /// 当前朗读 / 停留位置；不在朗读时用游标（即上次读到的地方）
  (int, int, int) get _currentSpot => _tts.highlightCursor ?? _tts.cursor;

  /// 用户最后停留的位置：退出时写进进度，重进时按它还原
  ///
  /// 与 [_tts.cursor] 的区别：游标是「正在朗读到哪」，这里是「用户把页面停在哪」。
  /// 用户可能只是翻看、没朗读 —— 那种情况也必须回到他看的地方。
  /// PDF 原版式下 `$1` 是页码（一章即一页），文字模式下是段落下标。
  (int, int, int) _lastSpot = (0, 0, 0);


  /// 当前位置是否已有书签
  Bookmark? get _bookmarkHere {    final spot = _currentSpot;
    for (final bookmark in _bookmarks) {
      if (bookmark.matches(spot)) return bookmark;
    }
    return null;
  }

  Future<void> _reloadBookmarks() async {
    final bookmarks = await StorageService.instance.loadDocBookmarks();
    if (!mounted) return;
    setState(() => _allBookmarks = bookmarks);
  }

  /// 在当前位置加书签 / 取消书签
  Future<void> _toggleBookmark() async {
    final existing = _bookmarkHere;
    final messenger = ScaffoldMessenger.of(context);
    if (existing != null) {
      await StorageService.instance.removeDocBookmark(existing.id);
      await _reloadBookmarks();
      messenger.showSnackBar(const SnackBar(content: Text('已删除当前位置的书签')));
      return;
    }
    final spot = _currentSpot;
    final bookmark = Bookmark(
      id: '${widget.document.id}.${DateTime.now().microsecondsSinceEpoch}',
      documentId: widget.document.id,
      documentTitle: widget.document.title,
      chapter: spot.$1,
      paragraph: spot.$2,
      sentence: spot.$3,
      preview: _previewAt(spot),
      createdAt: DateTime.now(),
    );
    await StorageService.instance.addDocBookmark(bookmark);
    await _reloadBookmarks();
    messenger
        .showSnackBar(SnackBar(content: Text('已添加书签：${bookmark.label()}')));
  }

  /// 书签处的正文片段（用于在列表里辨认）
  String _previewAt((int, int, int) spot) {
    final document = _doc;
    if (document == null || spot.$1 < 0 || spot.$1 >= document.chapters.length) {
      return '';
    }
    final chapter = document.chapters[spot.$1];
    if (spot.$2 < 0 || spot.$2 >= chapter.paragraphs.length) {
      return chapter.title;
    }
    final paragraph = chapter.paragraphs[spot.$2];
    if (spot.$3 < 0 || spot.$3 >= paragraph.sentences.length) {
      return Bookmark.makePreview(paragraph.text);
    }
    return Bookmark.makePreview(paragraph.sentences[spot.$3].text);
  }

  /// 打开书签面板：本文档的书签可直接跳转，其它文档的书签打开对应文档
  Future<void> _openBookmarks() async {
    await _reloadBookmarks();
    if (!mounted) return;
    final action = await showModalBottomSheet<_BookmarkAction>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BookmarkSheet(
        currentDocumentId: widget.document.id,
        bookmarks: _allBookmarks,
        chapterIsPage: _doc?.chapterIsPage ?? false,
      ),
    );
    if (action == null || !mounted) return;
    if (action.deleted != null) {
      await StorageService.instance.removeDocBookmark(action.deleted!.id);
      await _reloadBookmarks();
      return;
    }
    final bookmark = action.jump;
    if (bookmark == null) return;
    if (bookmark.documentId == widget.document.id) {
      final document = _doc;
      if (document == null) return;
      final chapter = bookmark.chapter.clamp(0, document.chapters.length - 1);
      final paragraphs = document.chapters[chapter].paragraphs;
      final paragraph = bookmark.paragraph
          .clamp(0, paragraphs.isEmpty ? 0 : paragraphs.length - 1);
      final sentences = paragraphs.isEmpty
          ? const <Sentence>[]
          : paragraphs[paragraph].sentences;
      final sentence = bookmark.sentence
          .clamp(0, sentences.isEmpty ? 0 : sentences.length - 1);
      _tts.speakFrom(chapter, paragraph, sentence);
      unawaited(
        _revealBlock(_chapterBlockIndex(chapter) +
            (paragraphs.isEmpty ? 0 : paragraph + 1)),
      );
      return;
    }
    await _openOtherDocument(bookmark);
  }

  /// 跳到另一本文档的书签位置
  Future<void> _openOtherDocument(Bookmark bookmark) async {
    final documents = await StorageService.instance.loadDocuments();
    Document? target;
    for (final document in documents) {
      if (document.id == bookmark.documentId) {
        target = document;
        break;
      }
    }
    if (!mounted) return;
    if (target == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这本书已从文档库移除，无法跳转')),
      );
      return;
    }
    final document = target;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ReaderPage(document: document, startAt: bookmark.cursor),
      ),
    );
  }

  // ---------------- 块下标换算 ----------------
  //
  // 这三种换算把「朗读游标」映射成「块下标」，而游标可能来自上一份文档
  // （切文档、重解析、通知栏拖动都会改游标）。越界下标一旦流进
  // ListView.builder 的 itemBuilder，就会以 RangeError 的形式闪退，
  // 因此这里全部夹取到有效范围，绝不返回越界值。

  int _chapterBlockIndex(int chapter) {
    if (_blocks.isEmpty || _chapterStart.isEmpty) return 0;
    final safe = chapter < 0
        ? 0
        : (chapter >= _chapterStart.length
            ? _chapterStart.length - 1
            : chapter);
    final index = _chapterStart[safe];
    return index < 0
        ? 0
        : (index >= _blocks.length ? _blocks.length - 1 : index);
  }

  int _paragraphBlockIndex(int chapter, int paragraph) {
    if (_blocks.isEmpty) return 0;
    final base = _chapterBlockIndex(chapter);
    final offset = paragraph < 0 ? 0 : paragraph;
    final index = base + 1 + offset;
    if (index >= _blocks.length) return _blocks.length - 1;
    return index < 0 ? 0 : index;
  }

  /// 当前高亮句：非按句粒度或不在本段时返回 -1
  int _activeSentence((int, int, int)? cursor, int chapter, int paragraph) {
    if (cursor == null || _tts.granularity != ReadGranularity.sentence) {
      return -1;
    }
    if (cursor.$1 != chapter || cursor.$2 != paragraph) return -1;
    return cursor.$3;
  }

  /// 按页粒度时，本段是否属于当前朗读页
  bool _pageHighlighted((int, int, int)? cursor, int chapter, int paragraph) {
    final document = _doc;
    if (cursor == null || document == null) return false;
    if (_tts.granularity != ReadGranularity.page) return false;
    if (cursor.$1 != chapter || document.chapterIsPage) return false;
    final perPage = StorageService.instance.paragraphsPerPage;
    return document.pageOf(chapter, paragraph, perPage) ==
        document.pageOf(cursor.$1, cursor.$2, perPage);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _tts,
      builder: (context, _) {
        final cursor = _tts.highlightCursor;
        if (cursor != null) _followCursor(cursor);
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.document.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: <Widget>[
              if (_isPdf)
                IconButton(
                  tooltip: _pdfTextView ? '切换为原版式' : '切换为文本模式',
                  onPressed: _doc == null ? null : _togglePdfMode,
                  icon: Icon(_pdfTextView
                      ? Icons.picture_as_pdf_outlined
                      : Icons.article_outlined),
                ),
              IconButton(
                tooltip: _bookmarkHere == null ? '在当前位置加书签' : '取消当前位置的书签',
                onPressed: _doc == null ? null : _toggleBookmark,
                icon: Icon(
                  _bookmarkHere == null
                      ? Icons.bookmark_add_outlined
                      : Icons.bookmark_added,
                ),
              ),
              IconButton(
                tooltip: '书签',
                onPressed: _openBookmarks,
                icon: Badge(
                  isLabelVisible: _bookmarks.isNotEmpty,
                  label: Text('${_bookmarks.length}'),
                  child: const Icon(Icons.bookmarks_outlined),
                ),
              ),
              IconButton(
                tooltip: '目录',
                onPressed: _doc == null ? null : _openToc,
                icon: const Icon(Icons.list_alt),
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (value) {
                  if (value == 'export') unawaited(_exportAudio());
                },
                itemBuilder: (context) => <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'export',
                    enabled: _doc != null && !_doc!.isEmpty,
                    child: const ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.download_outlined),
                      title: Text('导出朗读音频'),
                      subtitle: Text('用系统语音合成成音频文件，离线听'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          floatingActionButton: _speechDiagIndicator(),
          body: Column(
            children: <Widget>[
              // 朗读字幕条紧贴导航栏下方（原版式下呈现当前朗读句）
              _captionBar(),
              if (_tts.error != null) _banner(_tts.error!, error: true),
              if (_hasTextLayer == false)
                _banner(
                  // ★v1.21.45 改动 4：说硬话（文案是公开常量，单测直接断言）
                  ReaderPage.scannedPdfHint,
                ),
              Expanded(child: _readingArea(cursor)),
              // 控制栏：**关闭朗读模式后整条收起**（用户要求）。
              //
              // 注意与「折叠」的区别：折叠（[_controlCollapsed]）是用户自己按
              // 收起键留下的 46dp 迷你条，这里说的是方块键关掉朗读模式之后
              // **整条不再显示**，要重新朗读（PDF 点句 / 文本双击）它才回来。
              // 控制栏：方块键关掉朗读模式后**收起成迷你条**（用户澄清过：
              // 「收起」是截图里那种 46dp 的播放条，**不是**整条消失）。
              // 迷你条留着才能一键继续读，位置信息也还在。
              if (_doc != null && _doc!.chapters.isNotEmpty) _controls(),
            ],
          ),
        );
      },
    );
  }

  // ---------------- 顶部提示条 ----------------

  Widget _banner(String text, {bool error = false}) {
    final scheme = Theme.of(context).colorScheme;
    final background =
        error ? scheme.errorContainer : scheme.secondaryContainer;
    final foreground =
        error ? scheme.onErrorContainer : scheme.onSecondaryContainer;
    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: <Widget>[
          Icon(error ? Icons.info_outline : Icons.text_fields,
              size: 18, color: foreground),
          const SizedBox(width: 8),
          Expanded(
            child:
                Text(text, style: TextStyle(color: foreground, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  /// 原版式 / 文本层 两种 PDF 模式互切
  void _togglePdfMode() {
    if (_pdfTextView) {
      // v1.21.35 / L2b-2：切回原版式要把文本模式读进来的整份行表**释放回窗口**。
      // 不释放的话，用户切一次文本模式就永久多背一整份行表，
      // L1/L2 的内存收益全丢 —— 这是本轮"退出释放"那一半。
      // ⚠️ 必须在 `_pdfTextView = false` 之后：装表逻辑按模式分流。
      setState(() {
        _pdfTextView = false;
        _pdfFollowing = true;
      });
      // 释放是异步的（要等缓存目录 Future 落定才敢决定能不能丢页）
      unawaited(_syncPdfLinesForMode());
      // 记住这次选择：从文档库「返回朗读页」要回到对应界面
      unawaited(StorageService.instance.setTextMode(widget.document.id, false));
      // 切回原版式后把视图对齐到正在朗读的页
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToReadingPage();
      });
      return;
    }
    _switchToTextMode();
  }

  /// 切到文本模式，并把视图对齐到当前朗读位置
  void _switchToTextMode({bool showHint = false}) {
    // ⚠️ v1.21.35 / L2b-2：先**顺序读完全部块**，把行表补满，再建版面。
    //
    // 顺序不能反：自动排版（`_reflowedChapters`）与「能不能排版」的判据都要遍历
    // 整份行表，只装了当前块就排版 → 用户看到**残缺的排版**。
    //
    // 旧做法（v1.21.32）是"发现裁过就重跑 `_parse()` 借缓存读回"，见 [_loadAllPdfLineChunks]。
    // 补表是异步的（要等缓存目录那个 Future 落定）：补完再刷一帧，
    // 否则"排版按钮"要等下一次重建才出现。
    unawaited(
      _loadAllPdfLineChunks().then((_) {
        if (mounted) setState(() {});
      }),
    );
    setState(() {
      _pdfTextView = true;
      // 文本模式才需要段落块列表
      _buildBlocksIfNeeded();
    });
    // 记住这次选择：从文档库「返回朗读页」要回到对应界面
    unawaited(StorageService.instance.setTextMode(widget.document.id, true));
    // 自动排版是固化选择：这次进来还没机会应用（解析完成时还在原版式），
    // 一进文本模式就补上，否则「上次开着排版」重进会看不到效果。
    _applySavedAutoFormat();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _alignTo(_tts.cursor);
    });
    if (!showHint) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 4),
        content: Text('已切到文本模式：这一模式才有逐句高亮，点任意句可从该句开始读；'
            '想在原版式里读，直接点页面上的任意一行'),
      ),
    );
  }

  /// 补应用「上次记住的自动排版选择」（幂等：已经在排版态就什么都不做）
  void _applySavedAutoFormat() {
    if (!_canAutoFormat) return;
    if (!StorageService.instance.isAutoFormat(widget.document.id)) return;
    if (identical(_doc, _originalDoc) == false) return; // 已经是重排结果
    _applyAutoFormat(enable: true, silent: true);
  }

  /// 大 PDF 初始走原版式、切到文本模式时才需要块列表：按最终文档补建版面
  ///
  /// 与 [_buildLayout] 是同一套逻辑，这里只是「没有目标位置就用当前游标」的入口。
  void _buildBlocksIfNeeded() {
    final document = _doc;
    if (document == null || _blocks.isNotEmpty) return;
    _buildLayout(document, _tts.cursor);
  }

  // ---------------- PDF：原版式单页视图 ----------------

  /// PDF 视图只构建一次。
  ///
  /// 关键：`SfPdfViewer` 的 `didUpdateWidget` 会调用 `_compareDocument()`，把整个 PDF 文件
  /// 重新读进内存并逐字节比较（`listEquals`）。朗读时阅读页每推进一句就会重建，
  /// 如果这里每次 rebuild 都新建 widget，就会不停重读整个 PDF → CPU/内存抖动直至闪退。
  /// 缓存同一个 widget 实例后，Flutter 在 `updateChild` 阶段发现 `child.widget == newWidget`
  /// 会直接跳过更新，`didUpdateWidget` 不再被调用。
  ///
  /// 在 `initState` 里构建而不是 `late final ... = ...`：后者一旦在 dispose 之后才被
  /// 首次访问，就会带着已失活的 context 去查主题（见 HANDOFF 第 9 节第 26 条）。
  late final Widget _pdfViewer;

  void _buildPdfViewer() {
    _pdfViewer = SfPdfViewer.file(
      File(widget.document.path),
      controller: _pdf,
      // 连续滚动版式：一页接一页往下滚（用户要求的「像参考图那样」）。
      //
      // 为什么改（原来用 single 单页）：单页模式下 `zoomLevel = 1.0` 已经是
      // 适应宽度、没有再放大的余地，视觉上「一屏就一页、看不到下一页」，
      // 想多看一点只能整页翻 —— 参考图里的阅读器就是连续滚动的观感。
      //
      // 改连续模式后原有的「程序化跳页」逻辑仍然适用：`onPageChanged` 在
      // 滚动跨页时回调，`_goToPdfPage` 的闸门与目标页识别都不用改。
      pageLayoutMode: PdfPageLayoutMode.continuous,
      enableTextSelection: false,
      // 关掉「双击缩放」：它会让插件**吞掉连点中的第二下**
      // （插件内部 `_isDoubleTapped` 一旦为真就不再回调 onTap）。
      // 现在点句虽然改走原始指针事件、不再依赖那个回调，
      // 但插件吞掉的第二下仍会干扰「连着点两下换句子」的手感，
      // 所以继续关着。放大改用双指捏合（这个开关不影响捏合缩放）。
      enableDoubleTapZooming: false,
      onDocumentLoaded: (details) {
        if (!mounted) return;
        setState(() => _pdfReady = true);
        // 文档刚加载完这一帧视口还没测出来：放到帧后再定初始缩放
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _applyInitialPdfZoom());
        // 还原「上次退出的那一页」必须等文档加载完才能跳
        // （解析完成时 PDF 视图可能还没 ready，那时的 jumpToPage 会被丢掉）
        final pending = _pendingPdfPage;
        if (pending != null) {
          _pendingPdfPage = null;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _goToPdfPage(pending, force: true);
          });
        }
      },
      onDocumentLoadFailed: (details) {
        if (mounted) {
          setState(() => _error = '打开 PDF 失败：${details.description}');
        }
      },
      onPageChanged: _handlePdfPageChanged,
      // 注意：**不用**插件的 onTap 做点句 —— 它在识别为双击时不回调，
      // 无法用来区分单击 / 双击。点句走 Listener 的原始指针事件（见 _pdfPointerUp）。
    );
  }

  // ---------------- 平板：按屏幕大小放大 PDF 页面 ----------------

  /// 是否已经定过初始缩放（只做一次，不覆盖用户自己的缩放）
  bool _pdfZoomSettled = false;

  /// 按屏幕大小决定 PDF 页面的初始缩放（平板 / 大屏才动手，手机保持适应宽度）
  ///
  /// ⚠️ **实测结论（很重要，别再想当然地调大）**：
  /// `SfPdfViewer` 在 `zoomLevel = 1.0` 时**已经是「适应宽度」** ——
  /// 把整页宽度铺满视口。所以在 zoom 1.0 之上**再加倍率只会让页面溢出视口**，
  /// 后果是页面底部的行跑到屏幕外，点页面上的行会被插件判成「页面外」
  /// （实测 2.4 倍时 `pageNumber = -1`，点句直接失效）。
  ///
  /// 也就是说「页面太小」在**单页版式**下没有可放大空间；要更大只能：
  /// 用户自己捏合放大，或改用连续滚动版式。
  /// 这里保留一个**保守**的初始缩放：只在视口够高、放大后页面仍能落在
  /// 视口内时才放大（竖屏平板的常见情形），否则就停在 1.0。
  void _applyInitialPdfZoom() {
    if (_pdfZoomSettled || !mounted || !_pdfReady) return;
    final viewport = _pdfViewport;
    // 页面尺寸解析时量得，拿不到就退回视口大小（此时按 1:1 处理）
    final pageSize = _pdfPageSize ?? _pdfViewport;
    if (viewport.isEmpty || pageSize.width <= 0 || pageSize.height <= 0) return;
    if (!isLargeScreen(context)) {
      _pdfZoomSettled = true; // 手机上不动，保持适应宽度
      return;
    }
    _pdfZoomSettled = true;
    final zoom = _initialPdfZoom(viewport, pageSize);
    if (zoom <= 1.02) return;
    try {
      _pdf.zoomLevel = zoom;
    } catch (_) {
      // 视图尚未就绪：保持默认缩放，用户自己也能捏合放大
    }
  }

  /// 平板 / 大屏下的 PDF 初始缩放系数（见顶层 [pdfInitialZoom]）
  double _initialPdfZoom(Size viewport, Size pageSize) => pdfInitialZoom(
        viewport: viewport,
        pageSize: pageSize,
        wide: isWideLayout(context),
      );

  /// PDF 原版式：是否已进入「朗读模式」
  ///
  /// 交互（用户要求的最终版）：**点击即读** ——
  /// 点一下文本层的句子就进入朗读模式并从该句读起，
  /// 再点其他句子直接切过去。
  ///
  /// 注：文本模式（TXT / EPUB / PDF 转文本）**仍然是**「双击进入、单击切换」，
  /// 两者行为不同是刻意的。
  ///
  /// ## 为什么不依赖插件的 `onTap`
  ///
  /// 它挂 `Timer(kDoubleTapTimeout)`，回调条件是
  /// `!_isDoubleTapped && _canInvokeOnTap` —— **识别为双击时根本不回调**，
  /// 单次回调还要等 300ms。也就是说插件那条路**要么慢 300ms、要么整个丢事件**，
  /// 这就是之前「双击进不了朗读模式 / 加了闸门后连单击也失效」的根源。
  /// 现在统一走 `Listener` 的原始指针事件（见 [_pdfPointerUp]）。
  ///
  /// ## 坐标换算
  ///
  /// 插件公开了 `scrollOffset`（逻辑像素）与 `zoomLevel`。用两次真实点击校对过：
  ///
  /// ```
  /// 视口 y=386.2 → 插件报页内 591.1   → 差 204.9
  /// 视口 y=214.7 → 插件报页内 550.4   → 差 335.7（期间用户往下滚了）
  /// ```
  ///
  /// 差值恰好等于当时的 `scrollOffset.dy`，即
  /// **`页内 = 视口 + scrollOffset`（zoomLevel == 1）**。
  /// 换算抽成了纯函数 [viewportToPagePosition]，有专门的单测覆盖。
  bool _pdfReadMode = false;

  /// 指针按下时的信息（区分「点击」与「滑动 / 长按」）
  Offset? _pdfPointerDownPos;
  DateTime? _pdfPointerDownAt;
  bool _pdfPointerMoved = false;

  /// 指针按下
  void _pdfPointerDown(PointerDownEvent event) {
    _markPdfUserTouched();
    _pdfPointerDownPos = event.localPosition;
    _pdfPointerDownAt = DateTime.now();
    _pdfPointerMoved = false;
  }

  /// 指针移动：超过触摸阈值就算滑动（翻页 / 滚动，不是点句）
  void _pdfPointerMove(PointerMoveEvent event) {
    _markPdfUserTouched();
    final start = _pdfPointerDownPos;
    if (start != null &&
        (event.localPosition - start).distance > kTouchSlop) {
      _pdfPointerMoved = true;
    }
  }

  /// 指针抬起：判「点了一下」→ 立刻从那一句开始读
  ///
  /// **对照原版 1.20.0（versionCode 41）实测确认：PDF 原版式是「点击即读」** ——
  /// 单击文本层就开始朗读，不需要双击。之前这里做成了「双击进入」，
  /// 与原版不一致（用户要求完全回退）。
  ///
  /// 插件本身已经把**滚动 / 长按**过滤掉了（`onPointerMoved` 超过阈值、
  /// 按住超过 `kLongPressTimeout` 都不算点击），所以「点一下就读」
  /// 不会因为滑动而误触发；另有 [_scrollCooldownActive] 再挡一层滑动收尾。
  void _pdfPointerUp(PointerUpEvent event) {
    final downAt = _pdfPointerDownAt;
    final downPos = _pdfPointerDownPos;
    final moved = _pdfPointerMoved;
    _pdfPointerDownAt = null;
    _pdfPointerDownPos = null;
    _pdfPointerMoved = false;
    if (downAt == null || downPos == null) return;
    // 只认「短按且几乎没移动」：滚动 / 长按 / 选字都不算点击
    if (moved) return;
    if (DateTime.now().difference(downAt) > kLongPressTimeout) return;
    // 刚滑动过：这一下很可能是滑动的收尾误触（用户要求防误触）
    if (_scrollCooldownActive) return;

    _pdfReadMode = true;
    _speakPdfLineAtViewport(event.localPosition);
  }

  /// 视口坐标 → 页内坐标 → 命中行 → 开始朗读
  void _speakPdfLineAtViewport(Offset viewportPosition) {
    final position = _viewportToPage(viewportPosition);
    if (position == null) {
      CrashLog.mark('点句失败：视口坐标 $viewportPosition 换算不出页内坐标');
      return;
    }
    if (_speakPdfLine(position.$1, position.$2)) return;
    CrashLog.mark(
      '点句失败：第 ${position.$1 + 1} 页 页内 '
      '${position.$2.dx.round()},${position.$2.dy.round()} 没落在文字上',
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('这一点没落在文字上（图片页 / 扫描件没有文本层）')),
    );
  }

  /// 视口坐标 → (页下标, 页内坐标)；算不出来返回 null
  ///
  /// 依据（已用真实点击校对，见 [_pdfReadMode] 的说明）：
  /// `页内 = 视口 + scrollOffset`（`zoomLevel == 1`）。
  /// 连续滚动版式里视口可能同时露出两页，所以还要按各页高度判断点在哪一页。
  (int, Offset)? _viewportToPage(Offset viewportPosition) {
    // 页数**优先用解析结果**，不要只信 `_pdf.pageCount`。
    //
    // 实测（真实 319 页 PDF、模拟器）：PDF 已经渲染出来、`_pdfReady` 也为真了，
    // 但 `_pdf.pageCount` 仍然是 **0** —— 插件控制器要更晚才把它填上。
    // 之前直接用 `_pdf.pageCount`，换算那一步就返回 null，
    // 表现是**点了完全没反应**（这就是「PDF 朗读还是不生效」的真正原因）。
    // 解析时早就知道页数了（PDF 里一章就是一页），用它最稳。
    final parsedPages = _doc?.chapters.length ?? 0;
    final pageCount = parsedPages > 0 ? parsedPages : _pdf.pageCount;
    return viewportToPagePosition(
      viewportPosition: viewportPosition,
      scrollOffset: _pdf.scrollOffset,
      pageSize: _pdfPageSize ?? Size.zero,
      zoomLevel: _pdf.zoomLevel,
      pageCount: pageCount,
    );
  }

  bool _speakPdfLine(int pageIndex, Offset pagePosition) {
    final document = _doc;
    if (document == null || document.isEmpty) return false;
    if (pageIndex < 0 || pageIndex >= document.chapters.length) return false;
    // v1.21.35 / L2b-2：点句是"按需读盘"的第二个入口 ——
    // 用户可能停在某页不动、直接点这一页的某一行，而此时窗口里没有它。
    _ensurePdfLinesForPage(pageIndex);
    final lines = _pdfLines[pageIndex];
    if (lines == null || lines.isEmpty) return false;
    final line = PdfLineBox.find(lines, pagePosition);
    if (line == null) {
      // 落到这里通常意味着「行坐标」与点击坐标不同源。带上实际数值便于定位，
      // 这条日志在真机排查「点句没反应」时是唯一线索。
      var maxBottom = 0.0;
      var maxRight = 0.0;
      for (final item in lines) {
        if (item.bounds.bottom > maxBottom) maxBottom = item.bounds.bottom;
        if (item.bounds.right > maxRight) maxRight = item.bounds.right;
      }
      CrashLog.mark(
        '点句未命中：页=${pageIndex + 1} 点 ${pagePosition.dx.round()},'
        '${pagePosition.dy.round()}，该页 ${lines.length} 行，'
        '首行 ${lines.first.bounds}，右下 ${maxRight.round()},${maxBottom.round()}',
      );
      return false;
    }
    final spot = document.locateText(pageIndex, line.text);
    if (spot == null) {
      CrashLog.mark('点句未命中：行「${line.text}」在正文里定位不到对应句子');
      return false;
    }
    CrashLog.mark(
      '点句：第 ${pageIndex + 1} 页 ${pagePosition.dx.round()},'
      '${pagePosition.dy.round()} → 行「${line.text}」'
      '→ 第 ${spot.$1 + 1} 段第 ${spot.$2 + 1} 句',
    );
    // 方块键关掉朗读模式后 `_doc` 会被清掉，这里先把文档绑回去
    _ensureDocumentBound((pageIndex, spot.$1, spot.$2));
    _tts.speakFrom(pageIndex, spot.$1, spot.$2);
    return true;
  }

  /// 行表保留窗口（页）：当前视图页 ± 3 与朗读页 ± 3
  ///
  /// ⚠️ **不能低于 8 页**：PDF 原版式的点句（`_speakPdfLine`）要读行表，
  /// 窗口太小会频繁重抽，用户的感受是"点句没反应"。`±3` 两侧共 7 页，
  /// 再加朗读页那一侧，实际保留 ≥8 页。
  static const int _pdfLineWindow = 3;

  /// 裁掉窗口外的行表（v1.21.31 / P1-L1；v1.21.35 / L2b-2 改为"缺了再按块读"）
  ///
  /// - **文本模式（`_pdfTextView`）不裁**：自动排版要遍历整份行表
  ///   （`_reflowedChapters` 是现算的），裁了排版就残了；
  /// - 只有**原版式**、且行表已经多到值得裁时才动（≤ [`_pdfLinesMaxPages`] 直接返回）。
  ///
  /// L2b-2 的关键区别：被丢掉的页**不再是丢一次就没了** —— 数据源是块文件，
  /// 用户翻回去时 [_ensurePdfLinesForPage] 会按块读回来。
  void _trimPdfLines(int currentPage1Based) {
    if (_pdfTextView || !_isPdf) return;
    final int viewPage = currentPage1Based - 1;
    // 先确保这一页在手上（翻页是"跨块读盘"的唯一入口）
    _ensurePdfLinesForPage(viewPage);
    _trimPdfLinesOutsideWindow(viewPage);
  }

  /// 行表超过这个页数才裁（小于它时留着也不占多少内存，且省得动）
  static const int _pdfLinesMaxPages = 16;

  /// 区分「程序化跳页」与「用户手动翻页」
  void _handlePdfPageChanged(PdfPageChangedDetails details) {
    // 无论谁翻的，页变了就把「退出时的位置」更新成当前页 ——
    // 需求：退出时在 PDF 第 N 页，重进就回到第 N 页
    final page = details.newPageNumber;
    // v1.21.31 / P1-L1：翻页时裁行表（812 页的 PDF 全量常驻要上百 MB，
    // 实际只会用到当前页 ±3 与朗读页 ±3）。
    // v1.21.35 / L2b-2：裁剪的同时把这一页所在的块读进来 ——
    // 「跨块翻页才读盘」就是这里，读盘次数由 `DocumentCache.blockReadCount` 记账。
    _trimPdfLines(page);
    if (page >= 1 && (page - 1) > _lastSpot.$1) _lastSpot = (page - 1, 0, 0);

    // 翻页闸门：程序化跳页到达（或超时兜底）后放开，允许下一次自动翻页
    if (_pdfTargetPage != null && page == _pdfTargetPage) {
      _pdfTargetPage = null;
      _pdfTurning = false;
      _pdfTurnTimeout?.cancel();
      _pdfTurnTimeout = null;
      // 用户如果正好自己滑到了朗读页，恢复跟随
      if (_tts.speaking) setState(() => _pdfFollowing = true);
      return;
    }
    if (!mounted) return;
    final readingPage = _tts.cursor.$1 + 1;
    // 停在朗读页（无论是谁翻过来的）就恢复跟随；否则只关掉跟随，不抢用户的翻页
    final onReadingPage = page == readingPage;
    if (onReadingPage) {
      if (!_pdfFollowing) setState(() => _pdfFollowing = true);
      return;
    }
    if (_tts.speaking && _pdfFollowing && !_pdfTouching) {
      setState(() => _pdfFollowing = false);
    }
  }

  /// 用户碰了 PDF：暂停自动翻页 / 自动定位，松手后再留一小段冷却
  ///
  /// 「朗读自动翻页」与「人工翻页」抢的是同一条翻页通道，这是「有概率快速翻动」
  /// 的根因：用户刚滑走，朗读立刻把页面拉回来，两边来回打架看起来就是连续快翻。
  ///
  /// 用户要求：「在朗读完当前 PDF 页面前，人工上下滑动不进行强制定位；
  /// **切换到下一页时再进行强制定位翻页**」。
  /// 做法正是这里 —— 人工一碰就把 [_pdfFollowing] 关掉（滚动 / 翻页都不再强拉），
  /// 而 [_handlePdfPageChanged] 会在**用户自己滑到朗读页**时把它打开；
  /// 朗读推进到下一页时，`_followCursor` 会因为「朗读页 ≠ 当前页」而**先重新打开**
  /// 跟随（见那里的说明），于是「切到下一页」那一刻恢复强制跟随。
  void _markPdfUserTouched() {
    if (_pdfTouching && _pdfUserRecent) return;
    _pdfTouching = true;
    _pdfUserRecent = true;
    if (_pdfFollowing && _tts.speaking) setState(() => _pdfFollowing = false);
    _pdfUserCooldown?.cancel();
    _pdfUserCooldown = Timer(const Duration(milliseconds: 1500), () {
      _pdfTouching = false;
      _pdfUserRecent = false;
    });
  }

  /// PDF 总页数：**优先用解析结果**，插件控制器的值只作兜底
  ///
  /// 实测（真实 319 页 PDF、模拟器）：PDF 已经渲染出来、`_pdfReady` 也为真了，
  /// 但 `_pdf.pageCount` 仍然是 **0** —— 插件控制器要更晚才把它填上，
  /// 甚至点了页面之后还是 0。
  ///
  /// 解析时早就知道页数了（PDF 里一章就是一页），所以一律先用它。
  /// 这个坑让「点句」和「跳页」两个功能都静默失效过，别再改回只用插件值。
  int get _pdfPageCountForJump {
    final parsed = _doc?.chapters.length ?? 0;
    if (parsed > 0) return parsed;
    return _pdf.pageCount;
  }

  /// 跳页：带边界保护，并记录目标页用于识别程序化跳转
  ///
  /// 翻页闸门 [_pdfTurning]：上一次跳页还没确认到达就不再发新的请求。
  /// 没有它时，朗读推进快于翻页动画会「一句一次 jumpToPage」，页面连续快翻。
  void _goToPdfPage(int page, {bool force = false}) {
    if (!_pdfReady) return;
    if (_pdfTurning && !force) return;
    // 页数优先用解析结果：插件控制器的 `pageCount` 在文档 loaded 之后
    // **仍可能长时间是 0**（实测 319 页的 PDF 点了也还是 0），
    // 用它当守卫会让跳页静默失效。见 [_viewportToPage] 的说明。
    final count = _pdfPageCountForJump;
    if (count <= 0) return;
    final target = page < 1 ? 1 : (page > count ? count : page);
    if (_pdf.pageNumber == target) {
      _pdfTurning = false;
      return;
    }
    _pdfTargetPage = target;
    _pdfTurning = true;
    // 兜底：某些情况下 onPageChanged 不会回调（页面被同一帧重建等），
    // 超时后主动放开闸门，否则「自动翻页」会永远停住
    _pdfTurnTimeout?.cancel();
    _pdfTurnTimeout = Timer(const Duration(milliseconds: 1200), () {
      _pdfTargetPage = null;
      _pdfTurning = false;
    });
    try {
      _pdf.jumpToPage(target);
    } catch (_) {
      _pdfTargetPage = null;
      _pdfTurning = false; // 视图尚未就绪时忽略这次跳转
    }
  }

  /// 让 PDF 视图回到正在朗读的页（用户显式要求，重置跟随与冷却）
  void _jumpToReadingPage() {
    if (!_pdfReady) return;
    _pdfUserCooldown?.cancel();
    _pdfTouching = false;
    _pdfUserRecent = false;
    setState(() => _pdfFollowing = true);
    _goToPdfPage(_tts.cursor.$1 + 1, force: true);
  }

  Widget _pdfView() {
    if (_loading) return _loadingView();
    final error = _error;
    if (error != null) {
      return _hint(Icons.error_outline, error,
          FilledButton.tonal(onPressed: _parse, child: const Text('重试')));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_pdfViewport != constraints.biggest) {
          _pdfViewport = constraints.biggest;
        }
        return Stack(
          children: <Widget>[
            // 用户一碰 PDF 就算「人工操作」：自动翻页让位，避免两边抢翻页通道。
            // 滚动通知另外用来关掉高亮框的位移动画（否则框会延迟追页面）。
            NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                return false;
              },
              child: Listener(
                onPointerDown: _pdfPointerDown,
                onPointerMove: _pdfPointerMove,
                onPointerUp: _pdfPointerUp,
                child: _pdfViewer,
              ),
            ),
            // 正在朗读的那句话：改用顶部导航栏下方的**字幕条**呈现
            // （用户要求取消原版式里的高亮文本框）
            // 子节点数量保持恒定：避免跟随按钮出现/消失时改变 PDF 视图的槽位
            Positioned(
              right: 12,
              bottom: 12,
              child: _pdfFollowing
                  ? const SizedBox.shrink()
                  : FilledButton.tonalIcon(
                      onPressed: _jumpToReadingPage,
                      icon: const Icon(Icons.my_location, size: 18),
                      label: const Text('回到朗读页'),
                    ),
            ),
          ],
        );
      },
    );
  }

  // ---------------- 文本正文 ----------------

  /// 阅读区：原版式 PDF 直接给视图，其余走正文；自定义阅读底色包在最外层
  Widget _readingArea((int, int, int)? cursor) {
    final child = _isPdf && !_pdfTextView ? _pdfView() : _content(cursor);
    final background = _style.background;
    // PDF 原版式自带页面底色，不套阅读底色，免得页面外圈出现色块
    if (background == null || (_isPdf && !_pdfTextView)) return child;
    return ColoredBox(color: background, child: child);
  }

  Widget _content((int, int, int)? cursor) {
    if (_loading) return _loadingView();
    final error = _error;
    if (error != null) {
      return _hint(Icons.error_outline, error,
          FilledButton.tonal(onPressed: _parse, child: const Text('重试')));
    }
    final document = _doc;
    if (document == null || document.isEmpty) {
      return _hint(Icons.article_outlined, '没有解析到可朗读的文本', null);
    }
    if (_paging.isEmpty) {
      return _hint(Icons.article_outlined, '没有解析到可朗读的文本', null);
    }
    return Stack(
      children: <Widget>[
        // 平板横屏下正文限宽居中：一行铺满 1200dp 会很难换行
        ContentWidth(
          // 平板上按屏宽分档（手机 820 / 平板 900 / 超宽 960）：
          // 原来写死 820，平板上就是「手机那一栏居中放」，两侧空一大片。
          maxWidth: readerMaxContentWidth(context),
          child: LayoutBuilder(
            builder: (context, constraints) {
              _pageViewportWidth = constraints.maxWidth;
              return Listener(
                // 用户**拖动**正文（滑动翻页 / 滚动）= 自己翻着看：暂停自动跟随
                // （想跟回来按「回到朗读页」）。与 PDF 原版式的「用户碰了页面就不跟」同义。
                //
                // ⚠️ 这里必须区分「点」和「拖」，不能一碰就关掉跟随。
                // 用户报的「点下一句有概率导致文本框定位失败」根因就在这：
                // 点句子朗读（以及点句切换）也是 `onPointerDown`，原来一律
                // 把 `_pageAutoFollow` 置假 —— 而 `_followCursor` 开头就有
                // `if (!_pageAutoFollow) return`，于是**从此再也不翻页**：
                // 游标读到下一页的段落时页面不跟，那一页从没被建出来，
                // 高亮框自然量不到（`rect == null`），看着就是「定位失败」。
                //
                // 判据：手指移动超过 `kTouchSlop` 才算「拖」；只是点一下不算。
                onPointerDown: _onPagePointerDown,
                onPointerMove: _onPagePointerMove,
                onPointerUp: (_) => _pagePointerDragged = false,
                onPointerCancel: (_) => _pagePointerDragged = false,
                child: PageView.builder(
                  key: ReaderPage.pageViewKey,
                  controller: _pageController,
                  itemCount: _paging.pageCount,
                  onPageChanged: _onPageChanged,
                  itemBuilder: (context, index) =>
                      _pageView(document, cursor, index),
                ),
              );
            },
          ),
        ),
        // 「返回朗读页」：正在朗读、而用户已经离开朗读位置时出现。
        //
        // 与「自动定位」的分工（用户要求「保证不和高亮文本框的移动冲突」）：
        // - 自动定位只在**朗读推进到下一句**时动手，且人为操作期间完全不抢；
        // - 这个按钮是用户主动按的，按下去先**停掉自动定位这一轮**（清去重标记
        //   与抑制窗口），再一次性滚到朗读位置；滚到位后自动跟随照旧接管，
        //   所以不会出现「按钮和高亮框各滚各的」来回抖。
        Positioned(
          right: 12,
          bottom: 12,
          child: _backToReading ? _backToReadingButton() : const SizedBox.shrink(),
        ),
      ],
    );
  }

  /// 「返回朗读页」按钮：点一下回到正在朗读的位置
  Widget _backToReadingButton() => FilledButton.tonalIcon(
        key: ReaderPage.backToReadingKey,
        onPressed: _jumpToReading,
        icon: const Icon(Icons.my_location, size: 18),
        label: const Text('返回朗读页'),
      );

  /// 一页的内容：章标题（只在本章首页）+ 该页的段落
  ///
  /// 页内仍然是一个可滚动列表：小屏 / 大字号时一页的段落放不下，
  /// 硬撑会把文字挤没；语音推进时页内会跟着滚，读到最后一句才会翻到下一页。
  Widget _pageView(StructuredDocument document, (int, int, int)? cursor, int index) {
    final page = _paging.pageAt(index);
    // 大屏上页边距有下限（见 [_pageStyle]）；量句子用的是同一个 style
    final style = _pageStyle;
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      // 页面底色必须**跟着阅读底色走**。
      //
      // 这里原来硬写 `scheme.surface`，等于给每一页又铺了一层主题表面色，
      // 把外层 `_readingArea` 的阅读底色整个盖住 —— 用户选了纸白 / 羊皮纸 /
      // 护眼绿 / 夜间都没反应，就是这个原因（看起来像「底色设置不生效」）。
      decoration: BoxDecoration(color: style.background ?? scheme.surface),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          // 位置变了就刷新「回到朗读页」的显示（程序化滚动也要刷，否则按钮会赖着不走）
          if (notification is ScrollUpdateNotification) {
            _syncBackToReading();
            // 用户滚到哪了：**趁活着的时候记下来**（dispose 时 ScrollPosition
            // 已经摘掉，量不到）。这是「退出重进回到同一位置」的数据来源。
            // 每帧都会来一条，内部有节流（见 [_rememberVisibleSpot]）。
            _rememberVisibleSpot();
          } else if (notification is ScrollEndNotification) {
            // 滚动停下来：再记一次落点（同值会被日志去重，不产生噪声）
            _rememberVisibleSpot();
          }
          // 用户自己在滚（不是跟随滚动）：暂停跟随，停止滚动 2.5 秒后恢复
          //
          // ⚠️ **`UserScrollNotification` 不等于「用户碰了屏幕」**：
          // 任何滚动**结束时** `goIdle()` 都会发一条 `direction == idle` 的它
          // （`ScrollPositionWithSingleContext.beginActivity` → 活动不滚动就
          // `updateUserScrollDirection(idle)`）。我们自己的跟随 `animateTo`
          // 一结束就发这一条，原来不看 direction 一律当成"用户滚动" ——
          // 于是**程序滚动把自己判成了人工操作**：`_userScrolling` 被置真
          // 2.5 秒，期间 `_followCursor` / `_ensureSentenceVisible` 全部让位。
          // 真机表现：自动翻页后视图与朗读脱节（`用户滚动=true` 而用户没碰）。
          final byUser = isUserScrollNotification(notification);
          if (byUser) {
            _markUserScrolling();
            // 用户要求：**滑动页面时不要误触朗读**。
            // 手指在滑动过程中抬起、或滑完立刻点一下，都可能是误触 ——
            // 这些点击一律不当作「点句」，见 [_scrollCooldownActive]。
            _scrollCooldownUntil =
                DateTime.now().add(_scrollCooldownWindow);
          }
          return false;
        },
        child: ListView.builder(
          key: ValueKey<String>('reader-page-$index'),
          controller: _pageScroll(index),
          // 上下留白按屏宽分档：手机上顶部 8 / 底部 80（最后一行不被控制栏挡住），
          // 平板屏幕高得多，沿用这两个值会让正文顶到状态栏、底部空一大片。
          padding: EdgeInsets.only(
            top: readerPageVerticalPadding(context).top,
            bottom: readerPageVerticalPadding(context).bottom,
          ),
          itemCount: page.blockCount,
          itemBuilder: (context, local) {
            final blockIndex = page.blockStart + local;
            if (blockIndex < 0 || blockIndex >= _blocks.length) {
              return const SizedBox.shrink();
            }
            final block = _blocks[blockIndex];
            final child = switch (block) {
              _ChapterBlock(:final chapter) =>
                chapter < document.chapters.length
                    ? _chapterHeader(document, chapter, cursor)
                    : const SizedBox.shrink(),
              _ParagraphBlock(:final chapter, :final paragraph) => _paragraphView(
                  document,
                  cursor,
                  chapter,
                  paragraph,
                  style,
                ),
            };
            // 每段挂一个 GlobalKey，两个用途：
            // 1) `_revealBlock` 用它把目标段落滚进视野（`Scrollable.ensureVisible`）；
            // 2) `_rememberVisibleSpot` 用它量出「视口顶端是哪一段」。
            // **必须在渲染时创建**：早先只有「读取」没有「创建」（旧实现里是
            // `_jumpToBlock` 顺便建的，重构时丢了），结果是 `_anchors` 恒为空 ——
            // 于是「退出后返回朗读位置」既不滚也不准（`_lastSpot` 一直是 (0,0,0)）。
            final anchor = _anchors.putIfAbsent(blockIndex, () => GlobalKey());
            return KeyedSubtree(key: anchor, child: child);
          },
        ),
      ),
    );
  }

  /// 翻页完成：更新落定页、放开闸门
  void _onPageChanged(int index) {
    // 只有这里（动画落地）才更新「已落定的页」——自动翻页的「读完本页」判据用它
    _displayedPage = index;
    _pageTurning = false;
    _pageTurnSettle?.cancel();
    _pageTurnSettle = null;
    // 记下落地时间：之后一小段窗口内不再发页内滚动（见 `_pageQuietWindow`）
    _pageSettledAt = DateTime.now();
    if (!mounted) return;
    // 翻页也改变了「用户停在哪」，但**此刻量不到**：翻页动画刚落地时，
    // 旧页的列表已经拆掉、新页的还没建出来（两边的 ScrollController 都没挂上）。
    // 所以放到下一帧再量 —— 那时新页已经布局完成。
    // （dispose 阶段更量不到：ScrollPosition 会被提前摘掉，所以位置必须提前记好。）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _rememberVisibleSpot();
      _persistProgress();
    });
    _rememberVisibleSpot();
    // 翻页同样会改变「朗读位置是否还在视野里」：必须在这里也刷一次，
    // 否则「回到朗读页」按钮要等到下一次滚动通知才出现（表现为点了按钮翻页后
    // 按钮不出现，看起来像功能失效）。
    _syncBackToReading();
    setState(() {});
  }

  /// 用户滚动：暂停跟随、重置空闲计时
  void _markUserScrolling() {
    _userScrolling = true;
    // 滚动也算「有操作」，自动休眠的空闲计时重来
    AutoSleepController.instance.notifyUserActivity();
    // 用户把页面滚到别处看了：把「退出时的位置」记成他现在看的地方
    _rememberVisibleSpot();
    _scrollResume?.cancel();
    _scrollResume = Timer(const Duration(milliseconds: 2500), () {
      // 人为操作结束：**恢复自动跟随**。
      //
      // 需求原话：「人为操作时不生效，结束人为操作、并切换到下一句时再生效」——
      // 也就是手停下来之后，下一句朗读就该把视图带回正在读的位置。
      // 这里只是把闸门放开，真正动手的是 `_ensureSentenceVisible`（下一句推进时触发），
      // 所以不会「一松手就立刻把用户拉走」。
      _userScrolling = false;
      _pageAutoFollow = true;
    });
  }

  /// 排版定稿后重建版面：块列表 + 分页切分 + PageView 控制器 + 视图落位
  ///
  /// [document] 必须是**最终生效**的那份（已重排就传重排结果），
  /// [start] 是同一坐标系下的起始位置。三者（文档 / 位置 / 分页）必须同源，
  /// 否则就会出现「回到朗读页却回不到原来那句」。
  void _buildLayout(StructuredDocument document, (int, int, int)? start) {
    final needBlocks = !_isPdf || _pdfTextView;
    final blocks = <_Block>[];
    final chapterStart = <int>[];
    if (needBlocks) {
      for (var c = 0; c < document.chapters.length; c++) {
        chapterStart.add(blocks.length);
        blocks.add(_ChapterBlock(c));
        final count = document.chapters[c].paragraphs.length;
        for (var p = 0; p < count; p++) {
          blocks.add(_ParagraphBlock(c, p));
        }
      }
    }
    final paging = needBlocks
        ? ReaderPaging.build(document, StorageService.instance.paragraphsPerPage)
        : ReaderPaging.empty;
    final pageIndex = start == null || paging.isEmpty
        ? 0
        : paging.pageIndexForParagraph(start.$1, start.$2);
    setState(() {
      _doc = document;
      _blocks = blocks;
      _chapterStart = chapterStart;
      _paging = paging;
      _displayedPage = pageIndex;
      _pageTurning = false;
      _lastAutoTurnTarget = null;
      _pageAutoFollow = true;
      // 版面建好了才算「解析完成」：这个标志也必须在这里清掉，
      // 否则界面会一直停在加载态（重构时漏过一次，表现为正文全空）
      _loading = false;
    });
    _rebuildPageController(pageIndex);
  }

  /// 试着重排：判据认为不需要重排时返回 null（不弹提示，由调用方决定要不要说）
  StructuredDocument? _tryReflow(StructuredDocument document, {bool silent = false}) {
    final chapters = _reflowedChapters(document);
    if (chapters == null) {
      // 诊断日志**无条件**打：设备用例靠 `有变化=` 这个标记确认
      // 「判据认为无需重排」，排查也全靠它 —— 只在点了按钮时才打
      // 会漏掉「进入阅读页自动恢复」那条路径。
      final report =
          ParagraphReflow.analyze(document.chapters, _reflowLinesByPage());
      CrashLog.mark(
        'PDF 自动排版诊断（切换）：有变化=false｜${report.summary}｜'
        '${report.diagnostic}',
      );
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 5),
            content: Text(
              report.pagesWithLines == 0
                  ? '这份 PDF 没有可用的文字行信息（扫描件或行数超限），无法自动排版'
                  : '这份 PDF 的文本已经排好了，无需重排（${document.paragraphCount} 段）',
            ),
          ),
        );
      }
      return null;
    }
    return StructuredDocument(
      chapters: chapters,
      chapterIsPage: document.chapterIsPage,
      outline: document.outline,
    );
  }

  /// 当前界面停在第几页（1 起）；量不到返回 -1
  ///
  /// **只给测试用**：PDF 原版式取插件页码，分页版面取已落定页 +1。
  /// 生产代码各处的取页方式不同（各自有各自的含义），这里只是让设备用例
  /// 能直接断言「现在停在第几页」，不必去猜插件的 controller 放在哪。
  ///
  /// 注意：**不要求 `_pdfReady`**。设备用例里 `onDocumentLoaded` 可能还没回调，
  /// 而控制器的 `pageNumber` 已经是有效值；这里再卡一个 ready 会让用例
  /// 一直读到 -1，看起来像「功能坏了」，其实是钩子太严。
  @visibleForTesting
  int debugCurrentPage() {
    if (_isPdf && !_pdfTextView) {
      try {
        final page = _pdf.pageNumber;
        // 控制器还没就绪时它会给出 0 或 1：退回「离开时记下的页」
        final count = _pdfPageCountForJump;
        if (page >= 1 && (count <= 0 || page <= count)) return page;
        return _lastSpot.$1 + 1;
      } catch (_) {
        return _lastSpot.$1 + 1;
      }
    }
    if (_paging.isEmpty) return -1;
    return _displayedPage + 1;
  }

  /// 让设备 / widget 用例直接进入文本朗读模式；**只给测试用**
  ///
  /// 为什么要这个口子：双击由手势竞技场判定，而用例里紧接着还要用
  /// `tester.tap` 连续点句子 —— 段落上的 `DoubleTapGestureRecognizer`
  /// 会和后续单击在竞技场里互相干扰（实测手动两次 tap 之后，后续 tap 收不到
  /// 任何回调）。所以「点击优先」「方块键」这类用例用这个入口做前置，
  /// 「双击进入」本身由 `reader_read_mode_test` 的手势用例覆盖。
  @visibleForTesting
  void debugEnterTextReadMode() {
    _textReadMode = true;
  }

  /// 当前是否处于文本朗读模式（**只给测试看**）
  @visibleForTesting
  bool get debugTextReadMode => _textReadMode;

  /// 跟随定位的诊断快照（**只给测试 / 真机排查看**）
  ///
  /// 「文本框定位失败」这种问题光看现象没法定位，必须一次把链路里的
  /// 几个关键量都拿出来：游标 → 块下标 → 块所在页 → 当前页 →
  /// 锚点有没有建出来 → 段落是否可见。
  @visibleForTesting
  Map<String, Object?> debugFollowSnapshot() {
    final cursor = _tts.highlightCursor;
    final block = cursor == null
        ? -1
        : _paragraphBlockIndex(cursor.$1, cursor.$2);
    return <String, Object?>{
      'cursor': cursor,
      'block': block,
      'blocks': _blocks.length,
      'pageOfBlock': block < 0 ? -1 : _pageOfBlock(block),
      'pageIndex': _pageIndex,
      'displayedPage': _displayedPage,
      'pageCount': _paging.pageCount,
      'anchorBuilt': block >= 0 && _anchors[block]?.currentContext != null,
      'visible': block >= 0 && _paragraphVisible(block),
      'comfortable': block >= 0 && _paragraphComfortable(block),
      'userScrolling': _userScrolling,
      'autoFollow': _pageAutoFollow,
      'rememberSkipped': _rememberSpotSkipped,
      'suppressed': _autoFollowSuppressed,
      'pageTurning': _pageTurning,
      'settling': _inPageSettleWindow,
      'pendingReveal': _pendingReveal,
      'wantBlock': _revealWantBlock,
    };
  }

  /// 诊断日志（**只给测试看**）
  @visibleForTesting
  List<String> get debugCrashLog => CrashLog.recent;

  /// 「视图位置」（用户停在哪 / 退出时写回哪个 spot）（**只给测试看**）
  ///
  /// 「重回阅读页不在朗读位置」那条用例要断的就是它：退出再进来之后，
  /// 这里必须等于**朗读句**，而不是段首。
  @visibleForTesting
  (int, int, int) get debugLastSpot => _lastSpot;

  /// 「朗读位置」（独立于视图位置，见 [_readingSpot]）（**只给测试看**）
  @visibleForTesting
  (int, int, int)? get debugReadingSpot => _readingSpot;

  /// 显式给一个 spot，量它的句心几何（**只给测试看**）
  ///
  /// 「重回阅读页」的用例要在**朗读已停**时验证"那一句进视野了没"，
  /// 而 [debugSentenceGeometry] 依赖 `_tts.highlightCursor`（停读时为 null），
  /// 所以这里用请求恢复的 spot 来量 —— 与生产代码 `_alignToSentenceAfterLayout`
  /// 走的是同一条 `_geometryForCursor`。
  @visibleForTesting
  Map<String, Object?>? debugGeometryForSpot((int, int, int) spot) {
    final geometry = _geometryForCursor(spot);
    if (geometry == null) {
      return <String, Object?>{'null': true, 'measureTag': _lastSentenceMeasure};
    }
    final block = _paragraphBlockIndex(spot.$1, spot.$2);
    final measured = _measureSentenceInParagraph(block, spot.$1, spot.$2, spot.$3);
    return <String, Object?>{
      'sentenceCenter': geometry.sentenceTop,
      'viewportHeight': geometry.height,
      'measureTag': _lastSentenceMeasure,
      'topInParagraph': measured?.top,
      'bottomInParagraph': measured?.bottom,
    };
  }

  /// 当前朗读句的**实测**几何（**只给测试看**）
  ///
  /// 返 `null` 表示量不到。字段含义：
  /// * `sentenceCenter` —— 句心相对视口顶的偏移（负值 = 已在视口上方）
  /// * `measured` —— 这一句是用**实测**还是退回**估算**得到的
  /// * `centerInParagraph` —— 句心相对段落文字块顶部的偏移（实测时才有意义）
  ///
  /// 为什么用例必须能直接看到"实测还是估算"：这次的 bug 正是"估算把软换行
  /// 当成没有换行"，只看屏幕截图分不清是"判据错"还是"滚动没跑"。
  @visibleForTesting
  Map<String, Object?>? debugSentenceGeometry() {
    final cursor = _tts.highlightCursor;
    if (cursor == null) return null;
    final geometry = _geometryForCursor(cursor);
    if (geometry == null) return null;
    final block = _paragraphBlockIndex(cursor.$1, cursor.$2);
    final measured = _measureSentenceInParagraph(
      block,
      cursor.$1,
      cursor.$2,
      cursor.$3,
    );
    return <String, Object?>{
      'cursor': cursor,
      'sentenceCenter': geometry.sentenceTop,
      'viewportHeight': geometry.height,
      'measured': measured != null,
      'measureTag': _lastSentenceMeasure,
      'topInParagraph': measured?.top,
      'bottomInParagraph': measured?.bottom,
    };
  }

  /// PDF 原版式是否已进入朗读模式（**只给测试看**）
  @visibleForTesting
  bool get debugPdfReadMode => _pdfReadMode;

  /// 用**真实指针事件序列**点一下 PDF（**只给测试用**）
  ///
  /// 走的就是用户手指那条路（`Listener` → `_pdfPointerDown` → `_pdfPointerUp`），
  /// 只是坐标由测试给定。设备上没法用合成触摸驱动插件的手势链，
  /// 但这条路是应用自己的代码，可以稳定驱动，用来验证：
  /// 坐标换算 → 命中文字行 → 开始朗读 这一整条。
  @visibleForTesting
  void debugPdfTapViaPointer(Offset viewportPosition) {
    // `PointerEvent.localPosition` 默认就等于 `position`（无变换时），
    // 所以这里直接给 position 就行。
    _pdfPointerDown(PointerDownEvent(position: viewportPosition));
    _pdfPointerUp(PointerUpEvent(position: viewportPosition));
  }

  /// 视口坐标换算出的 (页下标, 页内坐标)（**只给测试看**）
  @visibleForTesting
  (int, Offset)? debugViewportToPage(Offset viewportPosition) =>
      _viewportToPage(viewportPosition);

  /// PDF 视图是否已加载完成（**只给测试看**）
  @visibleForTesting
  bool get debugPdfReady => _pdfReady;

  /// 某一页解析出来的文字行（**只给测试看**）：诊断「点句」为什么没命中
  @visibleForTesting
  List<PdfLineBox>? debugPdfLinesAt(int pageIndex) => _pdfLines[pageIndex];

  /// 测试用：当前"装进来"的行表覆盖多少页 / 触发一次按页装表与模式切换
  ///
  /// 见 `test/pdf_text_mode_restore_test.dart`：验"原版式只装窗口 → 切文本模式
  /// 必须把整份读回来"，否则排版残缺。
  /// ⚠️ L2b-2 起这个数字**天然小于总页数**（只装当前块 / 窗口），
  /// 所以它不再等于"整份行表有多少页"。
  @visibleForTesting
  int get debugPdfLinesPageCount => _pdfLines.length;

  /// 测试用：当前装载的页号集合（与 [debugPdfLinesPageCount] 同步）
  @visibleForTesting
  Set<int> get debugPdfLinesLoadedPages =>
      Set<int>.unmodifiable(_pdfLinesLoadedPages);

  @visibleForTesting
  void debugTrimPdfLinesForTest(int currentPage1Based) =>
      _trimPdfLines(currentPage1Based);

  @visibleForTesting
  void debugSwitchToTextModeForTest() => _switchToTextMode();

  /// 测试用：走一次"原版式 ↔ 文本模式"互切（验退出文本模式要释放回窗口）
  @visibleForTesting
  void debugTogglePdfModeForTest() => _togglePdfMode();

  /// 测试用：**注入块读取器**（单测环境拿不到 path_provider 缓存目录，真块文件读不出来）
  ///
  /// 注入后 `_chunkReadAvailable` 依然要求"有地图 + 有缓存目录"，所以用例还要
  /// 调 [debugSetCacheDirForTest]。返回 null 表示"这一块读不出来"。
  @visibleForTesting
  void debugSetChunkReaderForTest(
    Map<int, List<PdfLineBox>>? Function(String, String, int) loader,
  ) {
    _chunkLoader = loader;
  }

  /// 测试用：注入缓存目录（否则块读一律不可用，退化成"整份表常驻"）
  @visibleForTesting
  void debugSetCacheDirForTest(String dir) {
    _cacheDirValue = dir;
  }

  /// 测试用：当前生效的缓存目录 / 读取地图块数（诊断"块读可用吗"）
  @visibleForTesting
  String get debugCacheDirForTest => _cacheDirValue ?? '';

  @visibleForTesting
  int get debugChunkCountForTest => _pdfChunks.length;

  /// 测试用：注入"读取地图"（正常运行时来自主缓存 / 解析结果）
  @visibleForTesting
  void debugSetLinesChunksForTest(List<LinesChunkRef> chunks) {
    _indexPdfChunks(chunks, null);
  }

  /// 测试用：塞一份**合成**行表（模拟"解析结果刚塞进来、还没按块读"的状态）
  ///
  /// 会把读取地图清空、块读取器复位 —— 合成数据只可能在内存里，
  /// 这样用例能精确控制"哪些页靠注入、哪些页靠块读"。
  @visibleForTesting
  void debugSeedPdfLines(Map<int, List<PdfLineBox>> lines) {
    _pdfLines
      ..clear()
      ..addAll(lines);
    _pdfLinesLoadedPages
      ..clear()
      ..addAll(lines.keys);
    _pdfChunks = <int, LinesChunkRef>{};
    _chunkLoader = DocumentCache.readLineChunkByName;
    debugPdfLinesLoadedPeak = _pdfLinesLoadedPages.length;
  }

  /// 测试用：`_parse()` 被调用的次数
  ///
  /// ⚠️ L2b-2 起**没有生产代码消费它**（切文本模式改为按块读，不再重跑 `_parse`）：
  /// 只保留它在 `_parse()` 里的一次自增，供用例断"确实没再重跑解析"。
  @visibleForTesting
  int debugParseForTestCount = 0;

  /// 第 1 页的页面尺寸（**只给测试看**）：把页内坐标换算成屏幕坐标
  @visibleForTesting
  double get debugPdfPageWidth => _pdfPageSize?.width ?? 0;

  @visibleForTesting
  double get debugPdfPageHeight => _pdfPageSize?.height ?? 0;

  /// 直接走一次「按坐标点句」，绕开插件手势（**只给测试用**）
  @visibleForTesting
  bool debugTapPdfAt(int pageNumber1Based, Offset pagePosition) =>
      _speakPdfLine(pageNumber1Based - 1, pagePosition);

  /// 让设备用例驱动 PDF 原版式翻页（等价于用户滑一页）；**只给测试用**
  ///
  /// 注意这里的 `ready` 由 [SfPdfViewer.onDocumentLoaded] 置位。它不是**唯一**
  /// 的可用性判据 —— 控制器一旦挂上，`pageNumber` 就已经是有效值。
  /// 所以这里用「尝试 jumpToPage，失败就报告」的方式，别一上来就 return。
  @visibleForTesting
  void debugFlipPdfPage(bool forward) {
    if (!_isPdf || _pdfTextView) return;
    // 真实用户滑页会先经过 `Listener` → `_markPdfUserTouched()`，
    // 于是自动跟随让位（`_pdfFollowing` 关掉）。这里必须一起模拟：
    // 否则翻过去之后「跟随朗读位置」立刻把页面拉回朗读页 ——
    // 那是**正确行为**（朗读时页面就该跟着朗读走），
    // 用例却会读成「翻页没生效」。
    _markPdfUserTouched();
    try {
      final target = forward ? _pdf.pageNumber + 1 : _pdf.pageNumber - 1;
      _goToPdfPage(target, force: true);
    } catch (_) {
      // 视图没就绪：忽略
    }
  }

  /// PDF 原版式的当前页码（1 起）；拿不到返回 null
  ///
  /// 两处来源都要看：
  /// - `onPageChanged` 回调里记下的 [_lastSpot]（用户手动滑页时它会更新）；
  /// - 控制器的 `pageNumber`（程序化 `jumpToPage` 之后它更可靠）。
  /// 有些路径下 `onPageChanged` 不会回调（例如完全由代码跳页），
  /// 只看回调会漏记；只看控制器又怕它在初始化前是 1。取两者里更靠后的那个：
  /// 正常阅读都是往后走的，取靠后 ≈ 取更近的一次。
  int? _currentPdfPage() {
    if (!_isPdf || _pdfTextView || !_pdfReady) return null;
    // 同上：页数用解析结果兜底，别信插件可能为 0 的 pageCount
    final count = _pdfPageCountForJump;
    var page = _pdf.pageNumber;
    final fromCallback = _lastSpot.$1 + 1;
    if (fromCallback > page && fromCallback <= count) page = fromCallback;
    if (page < 1 || (count > 0 && page > count)) return null;
    return page;
  }

  /// 记住用户**当前看到**的位置（退出时用它还原）
  ///
  /// 与朗读游标的区别：朗读游标是「正在读的那一句」，而这里要的是
  /// 「用户把页面停在哪」—— 他可能只是翻看、没朗读，那就该回到他看的地方。
  /// 需求：「退出时在 PDF 页面，重新进入时就在退出时的页面；文字模式也一样」。
  ///
  /// ⚠️ **必须在「活着」的时候刷新**：`dispose()` 里已经**量不到了** ——
  /// Flutter 会先把 `ScrollPosition` 从 `ScrollController` 上摘下来，
  /// 那时 `hasClients` 已经是 false。所以这里只在滚动 / 翻页时更新，
  /// `dispose()` 只做「用最后一次算好的值写盘」。
  /// 早先的做法是「退出前再量一次」，结果一直量不到、`_lastSpot` 停在 (0,0,0)，
  /// 表现就是「原格式下也有概率不能准确返回朗读位置」。
  /// 上一次已经打过日志的视图位置（**同值不重复打**）
  ///
  /// 滚动动画每帧都会发 `ScrollUpdateNotification`，原来每帧都完整量一遍
  /// 并且打一条 `朗读跟随[视图位置]` —— 真机实测 2 秒内上百条，把真机日志
  /// 冲得没法看，也让「是不是用户滚动」的判断更难读。
  ///
  /// ⚠️ 这里**不能按墙钟时间节流**：widget 测试里所有帧都在几毫秒真实时间内
  /// 跑完，按 `DateTime.now()` 节流会把最后那一次落点一起吞掉 ——
  /// `reader_jump_test` 的「原格式退出在哪页」当场变红（实测）。
  /// 所以改成**按值去重**：位置没变就不打日志，但 `_lastSpot` 每次都更新。
  (int, int, int)? _lastLoggedSpot;

  /// 被合并掉的日志条数（观测用，不参与任何判定）
  int _rememberSpotSkipped = 0;

  void _rememberVisibleSpot() {
    final document = _doc;
    if (document == null || document.isEmpty) return;

    // PDF 原版式：一章即一页，当前页码就是章号
    if (_isPdf && !_pdfTextView) {
      final page = _currentPdfPage();
      if (page == null) return;
      _lastSpot = (page - 1, 0, 0);
      return;
    }

    // 分页版面：用**当前页自己的**滚动控制器（每页一个，`_scroll` 在这条路径上没用）。
    //
    // 「用哪个控制器 / 量哪一页」都以 [_displayedPage]（已落定的页）为准：
    // 它在 `dispose` 时仍然可读，而 `PageController.page` 在 `dispose` 里
    // 会直接抛断言（PageView 已卸载）—— 位置保存正好发生在 dispose。
    final scroll = _pageScroll(_displayedPage);
    if (!scroll.hasClients || _blocks.isEmpty) return;
    final pixels = scroll.position.pixels;

    // ★v1.21.53：「重回阅读页有概率不在朗读位置」的另一半根因。
    //
    // 跟随滚动的设计是**把正在读的那句放到视口 38% 处**（见 `_followSentence`），
    // 所以「视口顶端那一段」**必然**是正在读的那段**之前**的段落。
    // 而这里原来一律取"视口顶端那一段"当视图位置 —— 于是在朗读时，
    // 记下来的视图位置**系统性地落后于朗读位置**。真机日志：
    //   `位置[写回] spot=(1,2,1) 视图位置=(1,0,0) 朗读位置=(1,2,1)`
    // （朗读在第 2 段，视图位置却记成第 0 段）。
    //
    // 修法：**朗读正在进行、且朗读位置就在当前页**时，视图位置直接取朗读位置。
    // 这正是"用户此刻在看哪"的真实答案 —— 画面是跟随逻辑摆的，
    // 它摆到哪，用户看的就是哪。
    //
    // 只在"同一页"时这样做：朗读已经跑到别的页（用户手动翻走了）时，
    // 视图位置仍应按用户实际停留处记，否则会把用户翻到的位置写丢。
    if (_tts.speaking &&
        !_negativeDisableReadingSpot &&
        !_pageTurning &&
        !_inPageSettleWindow) {
      final cursor = _tts.cursor;
      final readingBlock = _paragraphBlockIndex(cursor.$1, cursor.$2);
      final readingPage = _paging.isEmpty
          ? -1
          : _paging.pageIndexForParagraph(cursor.$1, cursor.$2);
      if (readingPage == _displayedPage && readingBlock >= 0) {
        // 量得到锚点才认（段落还没建出来时不写，避免记下一个"没显示过"的位置）
        final ctx = _anchors[readingBlock]?.currentContext;
        if (ctx != null && ctx.mounted) {
          final box = ctx.findRenderObject();
          if (box is RenderBox && box.hasSize) {
            final spot = (cursor.$1, cursor.$2, cursor.$3);
            _lastSpot = spot;
            // 同值不重复打日志：这里每帧都会被调用一次，值不变时打日志
            // 只会把真机日志刷爆（真机实测 2 秒上百条）。
            if (_lastLoggedSpot != spot) {
              _lastLoggedSpot = spot;
              _followLog(
                '视图位置',
                '朗读中 → 取朗读位置 (${cursor.$1},${cursor.$2},${cursor.$3})',
              );
            } else {
              _rememberSpotSkipped++;
            }
            return;
          }
        }
      }
    }

    // 只认「属于当前页」的段落。
    //
    // 翻页动画途中**相邻两页同时挂在树上**，各段的全局 Y 是叠在一起算的；
    // 不加这个限制就会量到正在退场的那一页，于是「翻到第 6 页却记住第 5 页的位置」。
    final page = _paging.isEmpty ? null : _paging.pageAt(_displayedPage);

    // 找「视口顶端那一段」：它最能代表用户现在在看哪里。
    //
    // 位置用「段落矩形相对视口顶的偏移」直接算，**不要**用
    // `RenderAbstractViewport.getOffsetToReveal` —— 这里是「PageView 里的
    // ListView」这种嵌套视口，那个 API 返回的偏移与 ListView 自己的
    // `pixels` 不在同一坐标系里，比较结果全错。
    final viewportTop = -pixels;
    double? topOfParagraph;
    var topBlock = -1;
    for (var index = 0; index < _blocks.length; index++) {
      final block = _blocks[index];
      if (block is! _ParagraphBlock) continue;
      if (page != null) {
        if (block.chapter != page.chapter) continue;
        if (block.paragraph < page.paragraphStart ||
            block.paragraph > page.paragraphEnd) {
          continue;
        }
      }
      final context = _anchors[index]?.currentContext;
      if (context == null || !context.mounted) continue;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy - viewportTop;
      if (top + box.size.height <= 0) continue; // 整段都在视口上方
      topOfParagraph = top;
      topBlock = index;
      break;
    }
    if (topBlock < 0 || topOfParagraph == null) return;
    final block = _blocks[topBlock];
    if (block is! _ParagraphBlock) return;
    final paragraph = document.chapters[block.chapter].paragraphs[block.paragraph];
    // 段内偏了多少像素：用它反推该段里哪一句在顶端，重进时才能落到同一句，
    // 而不是「页对了、但停在段首」（那段在视口上方时按 0 算）。
    final sentence = _sentenceAtOffset(paragraph, -topOfParagraph);
    _lastSpot = (block.chapter, block.paragraph, sentence);
  }

  /// 段内偏移 [dy] 像素处是第几句（按行高与每行字数估算）
  ///
  /// 精确值要 `TextPainter` 重新排版整段，代价高；这里只要「落在同一句」，
  /// 用「行高 + 每行大致字数」折算字符偏移就够 —— 一段十几句时误差远小于一句。
  int _sentenceAtOffset(Paragraph paragraph, double dy) {
    final sentences = paragraph.sentences;
    if (sentences.length <= 1 || dy <= 0) return 0;
    final total = paragraph.text.length;
    if (total <= 0) return 0;
    final style = _pageStyle;
    final lineHeight = style.fontSize * style.lineHeight;
    if (lineHeight <= 0) return 0;
    // 每行大致能排多少字：字号 × 1.0 是中文全角宽度的常用估法，
    // 再按可用宽度折算（拿不到宽度就用一个中性值）
    final width = _pageViewportWidth - style.pageMargin * 2 - 20;
    final perLine = width > 40
        ? (width / (style.fontSize * 1.0)).clamp(4.0, total.toDouble())
        : 20.0;
    final linesDown = (dy / lineHeight).floor();
    if (linesDown <= 0) return 0;
    final charOffset = (linesDown * perLine).clamp(0.0, (total - 1).toDouble());
    var at = 0;
    for (var s = 0; s < sentences.length; s++) {
      at += sentences[s].text.length;
      if (charOffset < at) return s;
    }
    return sentences.length - 1;
  }

  /// 按需更新「回到朗读页」按钮：正在朗读、且朗读位置已经**不在当前页**时才出现
  ///
  /// 分页版面下判据从「段落是否在视野里」变成「段落是否在当前页」：
  /// 一页的滚动范围是独立的，跨页才是真的「看不到了」。
  void _syncBackToReading() {
    final document = _doc;
    if (document == null || _blocks.isEmpty || _paging.isEmpty) return;
    final cursor = _tts.highlightCursor;
    if (cursor == null) {
      if (_backToReading) setState(() => _backToReading = false);
      return;
    }
    final valid = cursor.$1 >= 0 && cursor.$1 < document.chapters.length;
    // 「离开朗读位置」的判据：朗读所在的**页**不是当前页，
    // 或者本页内那一句已经滚出可见范围（用户往下翻着看别处了）。
    var away = false;
    if (valid) {
      if (_paging.pageIndexForParagraph(cursor.$1, cursor.$2) != _displayedPage) {
        away = true;
      } else {
        final block = _paragraphBlockIndex(cursor.$1, cursor.$2);
        away = !_paragraphVisible(block);
      }
    }
    if (away != _backToReading) setState(() => _backToReading = away);
  }

  /// 把正文滚回正在朗读的位置（「返回朗读页」按钮）
  ///
  /// 与自动定位的协调（用户要求「保证不和高亮文本框的移动冲突」）：
  /// 1. 先把自动定位这一轮的**闸门全部放开**（清去重标记、清抑制窗口、
  ///    清「用户正在滚动」）——否则按钮点下去会被去重逻辑挡掉、一动不动；
  /// 2. 滚到位后再把 `_pageAutoFollow` 置真，让后续句子继续正常跟随。
  ///
  /// 顺序很关键：**先**清闸门再滚动，滚动期间不会有第二个人来抢位置，
  /// 所以不会出现「按钮滚一次、高亮框又滚回去」的拉扯。
  /// 回到正在朗读的位置（字幕条点击 / 「返回朗读页」按钮共用）
  ///
  /// **两种模式都要能定位**：PDF 原版式翻到朗读所在页；
  /// 分页版面（文本 / PDF 转文本）走 [_revealBlock]。
  /// 原来这里只处理分页版面 —— 原版式下点字幕条会一动不动。
  void _jumpToReading() {
    final document = _doc;
    if (document == null) return;
    setState(() {
      _backToReading = false;
      _userScrolling = false;
      _pageAutoFollow = true;
    });
    _pendingReveal = null;
    _autoFollowSuppressedUntil = null;
    _scrollResume?.cancel();
    // 用户主动要求定位：正在跑的跟随滚动先停掉，避免两个动画抢同一个位置
    _followScrollTarget = null;
    _followScrollTimer?.cancel();

    if (_isPdf && !_pdfTextView) {
      // 原版式：翻到朗读所在页
      _pdfFollowing = true;
      _goToPdfPage(_tts.cursor.$1 + 1, force: true);
      return;
    }
    if (_blocks.isEmpty) return;
    final cursor = _readingSpot ?? _tts.cursor;
    if (cursor.$1 < 0 || cursor.$1 >= document.chapters.length) return;
    unawaited(
      _revealBlock(_paragraphBlockIndex(cursor.$1, cursor.$2), alignment: 0.35),
    );
  }

  /// 段落块：下标越界（文档与块列表错位）时退化为空占位，避免 build 期抛 RangeError
  Widget _paragraphView(
    StructuredDocument document,
    (int, int, int)? cursor,
    int chapter,
    int paragraph,
    ReaderStyle style,
  ) {
    if (chapter < 0 || chapter >= document.chapters.length) {
      return const SizedBox.shrink();
    }
    final paragraphs = document.chapters[chapter].paragraphs;
    if (paragraph < 0 || paragraph >= paragraphs.length) {
      return const SizedBox.shrink();
    }
    return _ParagraphView(
      key: ValueKey<String>('p:$chapter:$paragraph'),
      chapterIndex: chapter,
      paragraphIndex: paragraph,
      paragraph: paragraphs[paragraph],
      activeSentence: _activeSentence(cursor, chapter, paragraph),
      highlighted: _pageHighlighted(cursor, chapter, paragraph),
      style: style,
      // 点句起读：**以点击的句子为优先**
      //
      // 光调 `speakFrom` 还不够：自动朗读可能正好在推进，随后触发一次
      // 「跟随滚动 / 自动定位」，把视图从刚点的位置拉开（用户看到的
      // 「点其他句子时文本框上下移动」）。所以点击时先压住自动跟随一小会儿，
      // 让这次点击成为这一轮的最终状态。
      //
      // **对照原版 1.20.0（versionCode 41）实测确认：文本模式同样是「点击即读」** ——
      // 单击句子就开始读，之后点其他句子直接切换，没有「双击进入」这一步。
      // 原版提示语：`已从这一句开始朗读：点其他句子可直接切换`。
      onSpeakSentence: (sentence) {
        _handleSentenceTap(chapter, paragraph, sentence);
      },
      // 点段落空白处：从该段第一句开始读
      onSpeakParagraph: () {
        _handleSentenceTap(chapter, paragraph, 0);
      },
      onUserTap: AutoSleepController.instance.notifyUserActivity,
      onSentenceSpans: _onSentenceSpans,
      cursorOnParagraph: _currentSpot.$1 == chapter && _currentSpot.$2 == paragraph,
    );
  }

  /// 文本朗读模式是否已进入（与 PDF 原版式的 [_pdfReadMode] 同义）
  bool _textReadMode = false;

  /// 处理一次「点击某一句」：**点一下就开始读**
  ///
  /// 与原版 1.20.0 一致（PDF 原版式那边也是单击即读）。
  void _handleSentenceTap(int chapter, int paragraph, int sentence) {
    // 刚滑动过：这一下很可能是滑动的收尾误触，不当作点句。
    // （用户要求「滑动页面时不要误触朗读」）
    if (_scrollCooldownActive) return;
    final firstTime = !_textReadMode;
    _textReadMode = true;
    if (firstTime && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 2),
          // 原版 1.20.0 的原话
          content: Text('已从这一句开始朗读：点其他句子可直接切换'),
        ),
      );
    }
    _speakSentenceAt(chapter, paragraph, sentence);
  }

  /// 真正开始读某一句（双击进入与单击切换共用）
  void _speakSentenceAt(int chapter, int paragraph, int sentence) {
    _ensureDocumentBound((chapter, paragraph, sentence));
    // **先定位、再抑制**，顺序不能反：
    // - 定位链里遇到 `_autoFollowSuppressed` 会让位，所以必须在抑制之前把
    //   这次「用户点的位置」排进去，点一下才能立刻看到框移过去；
    // - 抑制窗口负责挡住**随后**的自动跟随，别让它把视图从刚点的地方拉开。
    _buildBlocksIfNeeded();
    _scheduleReveal(_paragraphBlockIndex(chapter, paragraph));
    _suppressAutoFollow(const Duration(milliseconds: 900));
    _tts.speakFrom(chapter, paragraph, sentence);
    // 立刻把「读到哪」记下来并写盘：用户可能听一句就退出，
    // 那时视图还没滚动，只能靠这里保住位置。
    _lastSpot = (chapter, paragraph, sentence);
    _persistProgress();
  }

  /// 确保 TtsManager 那边**绑着的是这本书**，而不是上一本
  ///
  /// 两种情况都要处理：
  ///
  /// 1. **换书**：在朗读 A 的时候打开 B（文档库点另一本、书签跳另一本），
  ///    阅读页会 push 一个新实例，A 那个页面还活着 → 读 B 的时候
  ///    A 的声音会一起响。用户要求「切换朗读时切换文档，应终止上一文档的播放」。
  /// 2. **会话被清掉**：方块键走 `endSessionAndClear()`，它清掉 `_doc`
  ///    （这正是「会话结束、控制栏收起」的依据），再 `speakFrom` 是读不出来的
  ///    —— `_runBody` 第一句就是 `if (doc == null) return`。
  ///
  /// 所以统一在这里：**只要正在朗读的是别的文档，先把它停掉**，再把本书绑回去。
  /// 放在朗读入口（点句 / 点行 / 章标题 / 播放键都经过 [_startReading]）而不是
  /// 每个调用点，避免「漏一个入口就出一次点了没反应」。
  void _ensureDocumentBound((int, int, int) at) {
    final document = _doc;
    if (document == null) return;
    final active = _tts.activeDocumentId;
    final readingOther = active != null &&
        active != widget.document.id &&
        _tts.hasSession;
    if (readingOther) {
      // 上一本文档还在朗读：先停掉它，否则两本书会一起响
      CrashLog.mark('切换文档：停止上一本的朗读（$active → ${widget.document.id}）');
      _tts.endSessionAndClear();
    }
    if (_tts.holdsDocument(widget.document.id)) return;
    _tts.loadDocument(
      document,
      at: at,
      title: widget.document.title,
      documentId: widget.document.id,
    );
  }

  /// 段落视图上报每句的字符区间（跟随滚动定位到句要用）
  void _onSentenceSpans(int chapter, int paragraph, List<(int, int, int)> spans) {
    final key = '$chapter:$paragraph';
    final previous = _sentenceSpans[key];
    if (previous != null && _sameSpans(previous, spans)) return;
    // 重新插入到末尾（Map 保序），这样淘汰的是最久没用到的段
    _sentenceSpans.remove(key);
    _sentenceSpans[key] = spans;
    while (_sentenceSpans.length > 80) {
      _sentenceSpans.remove(_sentenceSpans.keys.first);
    }
  }

  static bool _sameSpans(List<(int, int, int)> a, List<(int, int, int)> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ---------------- 朗读字幕条 ----------------

  /// 当前朗读句的字幕条：放在顶部导航栏**下方**
  ///
  /// 取代了原来的「PDF 原版式页面上的高亮文本框」（用户要求取消）：
  /// - 背景**透明**（`Colors.transparent`），只留一层很淡的描边勾勒出圆角块，
  ///   所以不会在 PDF 页面上压出一块实色；
  /// - 四角圆角；
  /// - 一句话太长时最多显示两行，超出省略。
  ///
  /// 只在「正在朗读 + PDF 原版式」时出现：文本模式本来就有逐句高亮，
  /// 再压一条字幕是重复。
  Widget _captionBar() {
    final cursor = _tts.highlightCursor;
    if (cursor == null) return const SizedBox.shrink();
    if (!(_isPdf && !_pdfTextView)) return const SizedBox.shrink();
    final document = _doc;
    if (document == null) return const SizedBox.shrink();
    if (cursor.$1 < 0 || cursor.$1 >= document.chapters.length) {
      return const SizedBox.shrink();
    }
    final paragraphs = document.chapters[cursor.$1].paragraphs;
    if (cursor.$2 < 0 || cursor.$2 >= paragraphs.length) {
      return const SizedBox.shrink();
    }
    final sentences = paragraphs[cursor.$2].sentences;
    if (sentences.isEmpty) return const SizedBox.shrink();
    final index = cursor.$3 < 0
        ? 0
        : (cursor.$3 >= sentences.length ? sentences.length - 1 : cursor.$3);
    final text = sentences[index].text.trim();
    if (text.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: ReaderPage.captionBarKey,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Material(
        // 透明底 + 描边（原样式不变），但**可点**：
        // 需求「点击上方字幕条也可定位朗读位置」——用户读着读着翻到别处去了，
        // 顺手点这条字幕就能回到正在读的那一页。
        color: Colors.transparent,
        child: InkWell(
          onTap: _jumpToReading,
          borderRadius: BorderRadius.circular(12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              // 透明背景：不遮住下面的 PDF 内容，只靠描边圈出范围
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: scheme.outlineVariant, width: 1),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 8),
                    child: Icon(Icons.volume_up_outlined,
                        size: 16, color: scheme.primary),
                  ),
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  // 定位提示：让「这条可以点」看得出来
                  Padding(
                    padding: const EdgeInsets.only(left: 4, top: 2),
                    child: Icon(Icons.my_location,
                        size: 14, color: scheme.outline),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _loadingView() {
    final progress = _progress;
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
                width: 220,
                child: LinearProgressIndicator(value: progress?.value)),
            const SizedBox(height: 16),
            Text(progress == null
                ? '正在准备解析…'
                : '${progress.stage} · ${progress.percent}%'),
            const SizedBox(height: 8),
            Text(
              '大文件在后台线程解析，界面不会卡死；也可返回稍后再打开',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _hint(IconData icon, String text, Widget? action) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(text,
                textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
            if (action != null) ...<Widget>[const SizedBox(height: 20), action],
          ],
        ),
      ),
    );
  }

  Widget _chapterHeader(
    StructuredDocument document,
    int chapterIndex,
    (int, int, int)? cursor,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (chapterIndex < 0 || chapterIndex >= document.chapters.length) {
      return const SizedBox.shrink();
    }
    final chapter = document.chapters[chapterIndex];
    final active = cursor != null && cursor.$1 == chapterIndex;
    final highlighted = active && _tts.granularity == ReadGranularity.chapter;
    final style = _style;
    final highlight = style.highlightColors(scheme);
    return Material(
      color: highlighted ? highlight.$1 : style.headerColor(scheme),
      child: InkWell(
        onTap: () => _tts.speakFrom(chapterIndex, 0, 0),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
          child: Row(
            children: <Widget>[
              IconButton(
                tooltip: '朗读本章',
                visualDensity: VisualDensity.compact,
                onPressed: () => _tts.speakFrom(chapterIndex, 0, 0),
                icon: Icon(
                  active && _tts.playing
                      ? Icons.graphic_eq
                      : Icons.play_circle_outline,
                  color: active ? scheme.primary : null,
                ),
              ),
              Expanded(
                child: Text(
                  chapter.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: highlighted ? highlight.$2 : style.theme.foreground,
                  ),
                ),
              ),
              Text('${chapter.paragraphs.length} 段',
                  style: theme.textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- 定位与跟随滚动 ----------------

  // ── 朗读跟随观测（v1.21.53 排查用）──────────────────────────────────
  //
  // ⚠️ 这一批**只观测、不改判据**（交接文档第三节的规矩：先加观测再改代码）。
  // 一条链原本几乎没有日志，于是「该居中却没居中」到底断在
  // ①没收到游标 ②收到但被闸门挡住 ③量不到几何 ④滚了但目标算错
  // ⑤滚动被下一句打断，完全无从判断。加完之后按日志一次定位。
  //
  // 前缀统一 `朗读跟随[...]`，整条链按它筛：
  //   游标 → 决策 → 几何 → 跟随 → 滚动/跳过 → 定位链 → 进入页面定位
  void _followLog(String tag, String detail) {
    CrashLog.mark('朗读跟随[$tag] $detail');
  }

  /// 跟随相关闸门的状态快照（统一口径，避免各调用点各写一份）
  ///
  /// 只读，不产生副作用 —— 观测期必须保证「打日志本身不会改变行为」。
  String _followGates() {
    final scroll = _pageScroll(_displayedPage);
    final hasClients = scroll.hasClients;
    final pixels = hasClients ? scroll.position.pixels : null;
    return '页=$_displayedPage/落定=$_pageIndex '
        '翻页中=$_pageTurning 落位窗=$_inPageSettleWindow '
        '用户滚动=$_userScrolling 抑制=$_autoFollowSuppressed 自动跟随=$_pageAutoFollow '
        '有客户端=$hasClients '
        '偏移=${pixels == null ? "?" : pixels.toStringAsFixed(1)} '
        '在跑目标=${_followScrollTarget?.toStringAsFixed(1) ?? "无"}';
  }

  /// 段落锚点是否已建出来 + 能不能量到尺寸（跟随失败的常见断点）
  String _anchorProbe(int blockIndex) {
    final context = _anchors[blockIndex]?.currentContext;
    if (context == null) return '锚点=无';
    if (!context.mounted) return '锚点=已卸载';
    final box = context.findRenderObject();
    if (box is! RenderBox) return '锚点=非RenderBox';
    if (!box.hasSize) return '锚点=无尺寸';
    return '锚点=有(${box.size.height.toStringAsFixed(1)}px)';
  }

  // ---------------- 分页导航 ----------------

  /// 重建分页控制器（换文档 / 换「每页段数」都要重来）
  ///
  /// [initialPage] 是打开时要落到的页：重进阅读页要回到上次的位置，
  /// 用 `initialPage` 一次性到位，避免先显示第 1 页再跳过去（会闪一下）。
  void _rebuildPageController(int initialPage) {
    final old = _pageController;
    final total = _paging.pageCount <= 0 ? 1 : _paging.pageCount;
    final initial = initialPage.clamp(0, total - 1);
    _displayedPage = initial;
    _pageTurning = false;
    _lastAutoTurnTarget = null;
    _pageController = PageController(initialPage: initial);
    if (old != null) {
      // 旧的控制器等这一帧过去再释放：它的 PageView 可能还在树上
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  /// 某个**全局块下标**落在哪一页（页下标）
  int _pageOfBlock(int blockIndex) {
    if (_paging.isEmpty || _blocks.isEmpty) return 0;
    final target = blockIndex.clamp(0, _blocks.length - 1);
    final (chapter, paragraph) = switch (_blocks[target]) {
      _ChapterBlock(:final chapter) => (chapter, 0),
      _ParagraphBlock(:final chapter, :final paragraph) => (chapter, paragraph),
    };
    return _paging.pageIndexForParagraph(chapter, paragraph);
  }

  /// 把视图移到某个块：先翻到它所在的页，再在页内把这一段滚进视野
  ///
  /// 分页版面下「跳转」是两件事：**页级**交给 PageView，**页内**用该页自己的
  /// 滚动控制器。原来那套「估算滚动偏移 + 反复微调」在分页下没有意义
  /// （每一页的滚动范围都是独立的），也正好把「跳转时页面乱动」的老问题绕开了。
  Future<void> _revealBlock(int blockIndex, {double alignment = 0.05}) async {
    if (_blocks.isEmpty || _paging.isEmpty || !mounted) {
      _followLog(
        '定位放弃',
        '块=$blockIndex 前提不满足（块数=${_blocks.length} 分页空=${_paging.isEmpty} mounted=$mounted）',
      );
      return;
    }
    final target = blockIndex.clamp(0, _blocks.length - 1);
    final pageIndex = _pageOfBlock(target);
    _anchors.putIfAbsent(target, () => GlobalKey());
    _followLog(
      '定位开始',
      '块=$target 页=$pageIndex 当前落定页=$_displayedPage ${_anchorProbe(target)} '
      '对齐=$alignment ${_followGates()}',
    );

    // 页还没到位：先翻过去，等 PageView 把这一页建出来
    if (pageIndex != _pageIndex) {
      _jumpToPage(pageIndex);
      final token = ++_jumpToken;
      var waited = 0;
      for (var attempt = 0; attempt < 12; attempt++) {
        await WidgetsBinding.instance.endOfFrame;
        if (token != _jumpToken || !mounted) return;
        if (pageIndex == _pageIndex) break;
        waited++;
      }
      if (token != _jumpToken) return;
      _followLog('定位翻页', '目标页=$pageIndex 已到位（等 $waited 帧）');
    }

    // 页内对齐：本页的列表可能还在构建，给它几帧
    for (var attempt = 0; attempt < 6; attempt++) {
      final anchorContext = _anchors[target]?.currentContext;
      if (anchorContext != null && anchorContext.mounted) {
        await Scrollable.ensureVisible(
          anchorContext,
          duration: Duration.zero,
          alignment: alignment,
        );
        _pruneAnchors(target);
        _followLog(
          '定位完成',
          '块=$target 第${attempt + 1}次尝试 ensureVisible(瞬时) '
          '落点=${_pageScroll(_displayedPage).hasClients ? _pageScroll(_displayedPage).position.pixels.toStringAsFixed(1) : "?"}',
        );
        return;
      }
      await _nextFrame();
      if (!mounted) return;
    }

    // 目标段落离视口太远：`ListView.builder` 根本不会把它建出来，
    // 也就永远没有锚点可用（`ensureVisible` 无能为力）。
    // 这时按「已建出来的相邻段落」外推一个滚动位置先滚过去，
    // 滚进可见范围后它就会被构建，于是锚点出现、下一轮再精确对齐。
    //
    // 这条路径正是「朗读位置跑很远 / 点别处起读之后，界面不跟」的原因。
    //
    // ⚠️ 这里**用瞬时跳转（jumpTo）而不是动画**：外推本身要迭代几轮，
    // 每轮都跑 200ms 动画的话整条定位要一秒多 —— 期间游标早就又往前走了，
    // 于是永远追不上（表现成「点了没反应 / 框乱跳」）。
    _followLog('定位外推', '块=$target 锚点 6 帧未建出 → 进入外推（最多 10 轮）');
    for (var round = 0; round < 10; round++) {
      if (!mounted) return;
      if (_anchors[target]?.currentContext != null) break;
      _scrollTowardBlock(target, alignment: alignment, instant: true);
      await _nextFrame();
      // 只等一帧：让 ListView 把新范围内的段落建出来
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    for (var attempt = 0; attempt < 6; attempt++) {
      final anchorContext = _anchors[target]?.currentContext;
      if (anchorContext != null && anchorContext.mounted) {
        await Scrollable.ensureVisible(
          anchorContext,
          duration: Duration.zero,
          alignment: alignment,
        );
        _pruneAnchors(target);
        _followLog(
          '定位完成',
          '块=$target 第${attempt + 1}次尝试 ensureVisible（外推后）',
        );
        return;
      }
      await _nextFrame();
      if (!mounted) return;
    }
    _followLog(
      '定位失败',
      '★块=$target 外推 10 轮后锚点仍未建出 ${_anchorProbe(target)} '
      '偏移=${_pageScroll(_displayedPage).hasClients ? _pageScroll(_displayedPage).position.pixels.toStringAsFixed(1) : "无客户端"}',
    );
  }

  /// 等下一帧结束
  ///
  /// 用 `endOfFrame` + 定时器双保险：`endOfFrame` 依赖调度器真的在出帧，
  /// 某些时序（比如测试里没有待处理帧）会让它一直挂着，整条定位链路就卡死。
  Future<void> _nextFrame() async {
    final done = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!done.isCompleted) done.complete();
    });
    Timer.run(() {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
  }

  /// 按「已建出来的相邻段落」外推，把滚动位置推到目标段落附近
  ///
  /// 取离目标最近的两个**已渲染**段落，用它们的实际高度估算每段平均高度，
  /// 再按块下标之差折算要滚多少。段落高度通常一致，误差很小；
  /// 即便差几行也没关系 —— 只要它进入可见范围，`ListView` 就会把它建出来，
  /// 随后 `ensureVisible` 会精确对齐。
  void _scrollTowardBlock(
    int target, {
    double alignment = 0.05,
    bool instant = false,
  }) {
    final scroll = _pageScroll(_displayedPage);
    if (!scroll.hasClients) return;
    final position = scroll.position;
    if (!position.hasContentDimensions) return;

    // 找最近的两个已渲染段落（一个在目标之前、一个之后，取不到就只用一侧）
    int? before;
    int? after;
    for (var i = target - 1; i >= 0 && before == null; i--) {
      if (_anchors[i]?.currentContext != null) before = i;
    }
    for (var i = target + 1; i < _blocks.length && after == null; i++) {
      if (_anchors[i]?.currentContext != null) after = i;
    }
    final reference = before ?? after;
    if (reference == null) return;
    final referenceTop = _paragraphScrollOffset(reference, position);
    if (referenceTop == null) return;

    // 每段平均高度：优先用「两侧都有」时的实测间距，否则退化为单段高度
    double perBlock;
    if (before != null && after != null && after > before) {
      final afterTop = _paragraphScrollOffset(after, position);
      if (afterTop != null) {
        perBlock = (afterTop - referenceTop) / (after - before);
      } else {
        perBlock = _blockHeight(reference) ?? 0;
      }
    } else {
      perBlock = _blockHeight(reference) ?? 0;
    }
    if (perBlock <= 0) return;

    final delta = (target - reference) * perBlock;
    final viewport = position.viewportDimension;
    double want = (referenceTop + delta - viewport * alignment)
        .clamp(0.0, position.maxScrollExtent);
    // ★单轮限幅（真机 `偏移 43.4 → 11396` 的来源）：
    // 目标段落离得很远时（冷启动 / 跳读 / 锚点还没建出来），
    // `(target - reference) * perBlock` 会一次算出上万像素，`jumpTo` 直接
    // 把画面甩到别处，随后重试又跳回来 —— 用户看到的就是「先闪错再跳回」。
    // 限成 3 个视口高，靠 `_revealBlock` 的多轮迭代逼近：每轮都落在附近，
    // 观感是连续推进，且 6 轮内仍能走完 ~18 屏。
    if (instant) {
      want = clampExtrapolateStep(
        want: want,
        from: position.pixels,
        viewport: viewport,
        maxViewports: _maxExtrapolateViewports,
      );
    }
    if ((want - position.pixels).abs() < 2) return;
    // 外推定位用瞬时跳转（见 `_revealBlock` 里对 jumpTo 的说明）：
    // 每次迭代都快，几轮就能把目标段落带进可见范围。
    if (instant) {
      position.jumpTo(want);
      return;
    }
    if (_alreadyScrollingTo(want)) return;
    _startFollowScroll(scroll, want);
  }

  /// 外推单轮最多移动几个视口高（见 [_scrollTowardBlock] 的限幅说明）
  static const double _maxExtrapolateViewports = 3.0;

  double? _blockHeight(int blockIndex) {
    final box = _anchors[blockIndex]?.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size.height : null;
  }

  /// 只保留目标附近的 key，避免长文档下 key 无限增长
  void _pruneAnchors(int center) {
    if (_anchors.length <= 60) return;
    _anchors.removeWhere((index, _) => (index - center).abs() > 80);
  }

  /// 朗读推进时跟随：PDF 原版式跟页，分页版面按「读完本页才翻」翻页
  void _followCursor((int, int, int) cursor) {
    _followLog('决策', '章=${cursor.$1} 段=${cursor.$2} 句=${cursor.$3} ${_followGates()}');
    if (_isPdf && !_pdfTextView) {
      final page = cursor.$1 + 1;

      // 人工浏览期间不抢页面；但**朗读推进到下一页时必须恢复强制跟随** ——
      // 需求：「朗读完当前页面前人工上下滑动不定位，切换到下一页时再强制翻页」。
      //
      // 判据：朗读所在页与**用户当前停留页**不同 = 朗读已经读过了用户看的那一页，
      // 该把视图拉回朗读页了。用 [_lastSpot]（用户停留位置，翻页/滚动都会更新）
      // 而不是插件页码，避免程序化翻页途中读到中间值。
      final userPage = _lastSpot.$1 + 1;
      if (!_pdfFollowing &&
          _tts.speaking &&
          !_pdfTouching &&
          !_pdfUserRecent &&
          page > userPage) {
        if (mounted) setState(() => _pdfFollowing = true);
      }

      if (!_pdfFollowing || !_pdfReady) return;
      // 用户正在操作（或刚操作过）：这一轮让位，别和人工翻页抢页面
      if (_pdfTouching || _pdfUserRecent) return;
      // 上一页还在翻：等它到位再说，否则会「一句一次跳页」连着重叠动画
      if (_pdfTurning) return;
      if (_pdf.pageNumber == page || _pdfTargetPage == page) return;
      // 翻页放到帧后执行，避免在 build 期间触发 PDF 视图重建
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pdfFollowing || !_pdfReady) return;
        if (_pdfTouching || _pdfUserRecent || _pdfTurning) return;
        _goToPdfPage(page);
      });
      return;
    }

    // 分页版面：先保证视图停在「游标所在的那一页」
    final target = _paging.pageIndexForParagraph(cursor.$1, cursor.$2);
    if (target != _pageIndex) {
      // 用户自己翻到别处看了：这一轮不自动跟（想跟回来按「回到朗读页」）
      if (!_pageAutoFollow) {
        _followLog('跳过', '目标页=$target≠当前页=$_pageIndex 且 自动跟随=false（用户翻到别处）');
        return;
      }

      // 自动翻页**只在读完本页最后一句时**才发生。
      //
      // 用户要求「文本高亮读完当前页时才激活翻页」：光标可能因为跳转 / 用户点句
      // 直接落到别的页上，那不是「读完」——只有当前页读到最后一句才翻。
      // 这一条也是「不出现快速翻页」的根本：翻页由「读完一页」触发，
      // 而不是由「光标跑到别处」触发，一页最多翻一次。
      //
      // 判定必须用 [_displayedPage]（已落定的页）而不是 [_pageIndex]：
      // 后者在翻页动画途中就已经指向新页，拿它当「本页」会算错范围，
      // 于是「刚翻过去就又被判定为读完」→ 连着往后翻。
      final current = _paging.pageAt(_displayedPage);
      final readingForward = cursor.$1 > current.chapter ||
          (cursor.$1 == current.chapter && cursor.$2 >= current.paragraphEnd);
      if (!readingForward) {
        _followLog('跳过', '目标页=$target≠当前页=$_pageIndex 但未向前读（段=${cursor.$2} '
            '本页段范围=${current.paragraphStart}~${current.paragraphEnd} '
            '当前页所在章=${current.chapter} 游标所在章=${cursor.$1}）');
        return;
      }
      if (!_cursorFinishedPage(cursor, _displayedPage)) {
        _followLog('跳过', '目标页=$target≠当前页=$_pageIndex 但本页未读完');
        return;
      }

      // **同一目标页只自动翻一次**：朗读推进很快时这里会被反复调用，
      // 只靠翻页闸门不够（闸门一放开就会对同一个目标再翻一次）。
      final last = _lastAutoTurnTarget;
      if (last != null && target <= last) {
        _followLog('跳过', '目标页=$target 已被同一目标去过（last=$last）');
        return;
      }
      _lastAutoTurnTarget = target;
      _followLog('翻页', '自动翻页 → 目标页=$target（本页=$_displayedPage）');
      _turnPageTo(target);
      return;
    }

    // 已经跟到位了：允许下一次自动翻页
    _lastAutoTurnTarget = null;

    // 先看看有没有「欠着的定位」要补（上一次定位失败留下的）
    _runPendingReveal();

    // 「用户跳过来了」还是「朗读往后读了一句」？
    //
    // 这条区分很关键：**自动朗读只往后跟**（往前滚会让框上下乱跳），
    // 但**用户主动跳转**（点句起读 / 快进 / 跳章 / 书签）必须双向跟随 ——
    // 他从第 20 段点回第 2 段，视图就该滚回第 2 段，而不是把第 2 段晾在上面。
    final previous = _lastCursorSpot;
    _lastCursorSpot = cursor;
    final jumpedBackward = previous != null &&
        _doc != null &&
        _doc!.indexOfCursor(cursor) < _doc!.indexOfCursor(previous) - 1;
    if (jumpedBackward) {
      final block = _paragraphBlockIndex(cursor.$1, cursor.$2);
      if (!_paragraphVisible(block)) _scheduleReveal(block);
      return;
    }

    // 同一页内：按**句**跟随（只向下跟随，向上交给翻页）。
    //
    // 这里只做「框掉到下方就往下跟」这一件事；「框跑到上方 / 贴到顶部」由
    // `_ensureSentenceVisible` 统一处置（它会强制翻页而不是上滚）——
    // 两个回调各滚各的，正是「框上下乱跳 + 快速向后翻页」的根源。
    if (_userScrolling) {
      _followLog('跳过', '用户正在滚动');
      return;
    }
    if (_autoFollowSuppressed) {
      _followLog('跳过', '刚点过句子的抑制窗口内');
      return;
    }
    if (_pageTurning || _inPageSettleWindow) {
      _followLog('跳过', '翻页中或落位窗口内（翻页中=$_pageTurning 落位窗=$_inPageSettleWindow）');
      return;
    }
    final geometry = _readingGeometry();
    if (geometry == null) {
      // 量不到几何（段落还没渲染 / 视口没就绪）：它可能离得很远 ——
      // 例如点句起读直接跳到本页靠后的段落，那一段从没进过视野，
      // 于是「句子锚点」根本没建出来。这时用段落锚点兜底把它拉进来，
      // 拉进来之后后续就是正常的按句跟随。
      final block = _paragraphBlockIndex(cursor.$1, cursor.$2);
      final visible = _paragraphVisible(block);
      _followLog(
        '几何失败',
        '块=$block ${_anchorProbe(block)} 段落可见=$visible '
        '→ ${visible ? "不兜底（已可见，等下一句再试）" : "走段落兜底定位"}',
      );
      if (!visible) _scheduleReveal(block);
      return;
    }
    _followLog(
      '几何',
      '句顶=${geometry.sentenceTop.toStringAsFixed(1)} 视口高=${geometry.height.toStringAsFixed(1)} '
      '上界=${(geometry.height * _visibleUpperBound).toStringAsFixed(1)} '
      '下界=${(geometry.height * _visibleLowerBound).toStringAsFixed(1)} '
      '占位=${(geometry.sentenceTop / geometry.height * 100).toStringAsFixed(0)}%',
    );
    if (geometry.sentenceTop <= geometry.height * _visibleUpperBound) {
      // 还在舒服区内 / 已经在上方：不向下滚。上方的情况交给 `_ensureSentenceVisible`
      _followLog('不滚', '句顶在 72% 线以上（舒服区 / 已在上方）→ 交给 _ensureSentenceVisible');
      _ensureSentenceVisible();
      return;
    }

    final key = '${cursor.$1}:${cursor.$2}';
    final spans = _sentenceSpans[key];
    final span = spans?.where((item) => item.$1 == cursor.$3).toList();
    if (span == null || span.isEmpty) {
      _followLog('跳过', '占位=$key 句号=${cursor.$3} 的字符区间还没上报（已缓存段=${_sentenceSpans.length}）');
      _ensureSentenceVisible();
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _userScrolling) return;
      if (_autoFollowSuppressed) return;
      if (_pageTurning || _inPageSettleWindow) return;
      _followSentence(cursor, span.first);
    });
  }

  /// 用户点了某一句之后的短暂抑制窗口
  ///
  /// 窗口内不做自动跟随滚动 / 自动定位：手刚点过的地方就是用户想看的地方，
  /// 不能让「朗读推进」把它拉开。窗口过后自动跟随恢复（需求：
  /// 「结束人为操作，并切换到下一句时再生效」）。
  DateTime? _autoFollowSuppressedUntil;

  void _suppressAutoFollow(Duration window) {
    // **续期而不是取较大值**：用户连点两句之间只要没超过这个窗口，
    // 抑制就一直保持着 —— 于是连点过程中一次自动跟随都不会发生，
    // 手停下来之后才统一定位到**最后点的那一句**。
    //
    // 这正是「多次点击时页面不抽搐」的关键：不续期的话，两次点击之间的
    // 空档里跟随会插进来滚一次（滚向刚点的那句），下一次点击又滚一次，
    // 攒起来就是来回抖动。
    _autoFollowSuppressedUntil = DateTime.now().add(window);
  }

  bool get _autoFollowSuppressed {
    final until = _autoFollowSuppressedUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  /// 正在朗读的**段落**是否有任何部分落在可见范围里
  ///
  /// 用于「句号锚点还没建出来」时的兜底：`_sentenceSpans` 只有在段落被渲染过
  /// 之后才有数据，而段落一旦从没进过视野就永远没数据 —— 于是跟随滚动会一直
  /// 放弃（表现为「朗读位置跑很远，界面不跟」）。这时改用段落锚点兜底。
  bool _paragraphVisible(int blockIndex) {
    final scroll = _pageScroll(_displayedPage);
    if (!scroll.hasClients) return true;
    final top = _paragraphScrollOffset(blockIndex, scroll.position);
    if (top == null) return false; // 锚点都没有 = 这一页还没建出来
    final height = scroll.position.viewportDimension;
    if (height <= 0) return true;
    final box = _anchors[blockIndex]?.currentContext?.findRenderObject();
    final size = box is RenderBox && box.hasSize ? box.size.height : 0.0;
    final delta = top - scroll.position.pixels;
    return delta + size > 0 && delta < height;
  }

  /// **实测**某一段里第 [sentence] 句的纵向区间（相对该段文字块顶部），量不到返回 null
  ///
  /// ## 为什么要实测（v1.21.53 修「不居中 / 位置不对」的根因）
  ///
  /// 原来用 `显式换行数 × 行高` 估算句内偏移，**只数 `\n`**。而中文字幕段落
  /// 几乎全是**软换行**（一个 `\n` 都没有）——实测日志：
  /// `朗读跟随[跟随] 块=8 段顶=452.0 显式换行=0 行高=28.9 句内偏移=0.0`。
  /// 于是**段内每一句的「句顶」恒等于「段顶」**：
  /// - 「舒服区」判据比的是**段顶**，段中间/段尾的句子永远不会被判成「太靠下」
  ///   → 该滚的时候不滚；
  /// - 真要滚时把**段顶**对齐到 38%，而被读的那句在段内很深（段常比视口高好几倍）
  ///   → 句字落在屏幕外或明显偏心。
  ///
  /// 与 PDF 的对照：`features/pdf_reading/sentence_centering.dart` 的
  /// `targetOffset` 两个输入都是**实测值**（`getOffsetToReveal` 的页顶偏移 +
  /// 句的 `bounds.center.dy`）——PDF 稳就稳在"不猜"。这里用
  /// `RenderParagraph.getBoxesForSelection` 把同一件事在 EPUB 上做实：
  /// 每个句子本来就是独立的 `TextSpan`（见 `_ParagraphViewState._span`），
  /// 字符区间由 `_onSentenceSpans` 上报，所以能精确定位到**那一句**的盒子。
  ///
  /// 返回 `(top, bottom)`：句首行的上沿与末行的下沿（相对文字块顶部）。
  ({double top, double bottom})? _measureSentenceInParagraph(
    int blockIndex,
    int chapter,
    int paragraphIndex,
    int sentence,
  ) {
    final box = _anchors[blockIndex]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    // ★负向自检开关：置 true 等于退回"只用估算"的旧行为（软换行 bug 复现）
    if (_negativeDisableMeasure) return null;
    // 段落视图结构：Padding > GestureDetector > DecoratedBox > Padding > Text.rich
    // 最内层的 RenderParagraph 才是排版结果；直接按类型向下找，别写死层数。
    final paragraphRender = _findRenderParagraph(box);
    if (paragraphRender == null) return null;
    final spans = _sentenceSpans['$chapter:$paragraphIndex'];
    if (spans == null) return null;
    final hit = spans.where((item) => item.$1 == sentence).toList();
    if (hit.isEmpty) return null;
    final start = hit.first.$2;
    final end = hit.first.$3;
    if (end <= start) return null;
    final boxes = paragraphRender.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
    );
    if (boxes.isEmpty) return null;
    var top = double.infinity;
    var bottom = -double.infinity;
    for (final b in boxes) {
      if (b.top < top) top = b.top;
      if (b.bottom > bottom) bottom = b.bottom;
    }
    if (!top.isFinite || !bottom.isFinite || bottom <= top) return null;
    return (top: top, bottom: bottom);
  }

  /// 在渲染子树里找最内层的 [RenderParagraph]（段落文字的真实排版盒）
  RenderParagraph? _findRenderParagraph(RenderObject root) {
    RenderParagraph? found;
    void visit(RenderObject node) {
      if (found != null) return;
      if (node is RenderParagraph) {
        found = node;
        return;
      }
      node.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  /// 正在朗读的那一段、那一句相对本页视口的位置
  ///
  /// 这是整套「跟随」的唯一判据来源 —— 位置分档之后各走各的处置，
  /// 避免再出现「两个回调各滚各的」互相拉扯。
  /// 量不到（段落没渲染 / 视口没就绪）返回 null，调用方按「不知道」处理。
  ({double sentenceTop, double paragraphTop, double paragraphBottom, double height})?
      _readingGeometry() {
    final cursor = _tts.highlightCursor;
    if (cursor == null) return null;
    return _geometryForCursor(cursor);
  }

  /// 与 [_readingGeometry] 同一套算术，但**显式指定游标**
  ///
  /// 为什么必须分开：`_tts.highlightCursor` **只在朗读进行中**才非空
  /// （见 `TtsManager.highlightCursor`：`_speaking && !_oneShot`）。
  /// 而「重回阅读页」恰恰是**没有在朗读**的场景（用户退出去了、或读完了），
  /// 于是进入定位那条链永远拿不到几何 → 一句校验都做不了
  /// （真机日志表现：`[进入定位结束] 轮次用尽` 而 `[进入定位校验]` 一条都没有）。
  /// 进入定位要量的是「请求恢复的那个 spot」，所以游标由调用方给。
  ({double sentenceTop, double paragraphTop, double paragraphBottom, double height})?
      _geometryForCursor((int, int, int) cursor) {
    final scroll = _pageScroll(_displayedPage);
    if (!scroll.hasClients) return null;
    final position = scroll.position;
    if (!position.hasContentDimensions) return null;
    final height = position.viewportDimension;
    if (height <= 0) return null;
    final block = _paragraphBlockIndex(cursor.$1, cursor.$2);
    final paragraphTop = _paragraphScrollOffset(block, position);
    if (paragraphTop == null) return null;
    final box = _anchors[block]?.currentContext?.findRenderObject();
    final size = box is RenderBox && box.hasSize ? box.size.height : 0.0;
    // 句子的纵向位置：**优先实测**（见 `_measureSentenceInParagraph`），
    // 量不到才退回「显式换行数 × 行高」的估算。
    //
    // ⚠️ 实测路径与估算路径必须都保留：段落文字块还没排版出来时
    // （`getBoxesForSelection` 拿不到盒子）仍然要能分档，否则跟随会整条失效。
    //
    // 口径统一为**句心**（不是句顶）：与 `_followSentence` 的滚动目标、
    // 以及 PDF 的 `bounds.center.dy` 完全一致，避免"判据看句心、滚动按句顶"。
    var sentenceCenter = paragraphTop + size / 2;
    final key = '${cursor.$1}:${cursor.$2}';
    final spans = _sentenceSpans[key];
    final span = spans?.where((item) => item.$1 == cursor.$3).toList();
    final measured = _measureSentenceInParagraph(
      block,
      cursor.$1,
      cursor.$2,
      cursor.$3,
    );
    if (measured != null) {
      // 段落文字块顶部相对段落锚点还有一段内边距（`_ParagraphView` 的
      // `EdgeInsets.symmetric(horizontal: 10, vertical: 8)`），必须补上，
      // 否则实测值会系统性偏上 8px。
      sentenceCenter = paragraphTop +
          _paragraphTextInsetTop +
          (measured.top + measured.bottom) / 2;
      _lastSentenceMeasure = '实测(顶=${measured.top.toStringAsFixed(1)} '
          '底=${measured.bottom.toStringAsFixed(1)})';
    } else if (span != null && span.isNotEmpty) {
      final paragraph = _doc?.chapters[cursor.$1].paragraphs[cursor.$2];
      if (paragraph != null) {
        final start = span.first.$2.clamp(0, paragraph.text.length);
        final breaks =
            '\n'.allMatches(paragraph.text.substring(0, start)).length;
        final lineHeight = _style.fontSize * _style.lineHeight;
        // 估算只能给出"该句起始行"的位置，取该行**中线**当作句心近似
        sentenceCenter += breaks * lineHeight + lineHeight / 2;
        _lastSentenceMeasure = '估算(显式换行=$breaks)';
      }
    } else {
      _lastSentenceMeasure = '无(无字符区间,退化为段心)';
    }
    return (
      sentenceTop: sentenceCenter - position.pixels,
      paragraphTop: paragraphTop - position.pixels,
      paragraphBottom: paragraphTop + size - position.pixels,
      height: height,
    );
  }

  /// 朗读推进到下一句时，按「正在读的那一句在哪」决定处置
  ///
  /// 需求（用户反复强调的三条）合成一套判据：
  /// 1. 框**向下**离开可见范围 → 向下跟随（不抢用户的手动滚动）；
  /// 2. 框跑到**上方**去了 → 说明本页已经读完，「强制翻到下一页」，
  ///    **绝不上滚** —— 上滚正是「框上下乱跳」的来源；
  /// 3. 框贴到本页**顶部附近**（本页只剩几句）→ 提前翻页，
  ///    免得框被顶到页首之后再翻，造成定位失败。
  ///
  /// 「不被人工触发打断」：只要用户没在手动滚动 / 没刚点过句子，
  /// 第 2、3 条的翻页就不受「是否读完整页」的额外限制（翻页闸门照旧防连翻）。
  ///
  /// ⚠️ 真正的动作必须**延到帧后**：本方法会被 `_followCursor` 在 **build 期间**
  /// 调到（`_followCursor` 挂在 `ListenableBuilder` 的 builder 里），
  /// 而动作会 `setState` —— 直接在 build 里执行就是
  /// `setState() called during build`，整棵树报错、定位彻底失效。
  void _ensureSentenceVisible() {
    // 翻页刚落地（或在翻）时不动作：新页刚布局，滚了会与翻页动画抢位置。
    // 等窗口过去后，下一句推进会照常处置（不会漏掉）。
    if (_pageTurning || _inPageSettleWindow) return;
    if (_userScrolling) return; // 人为操作中：不抢（结束后由 _markUserScrolling 放开）
    if (_autoFollowSuppressed) return; // 刚点过句子：别把它拉开
    if (!_tts.speaking || !_pageAutoFollow) return;
    final geometry = _readingGeometry();
    if (geometry == null) return;
    final top = geometry.sentenceTop;
    final height = geometry.height;

    // 只处理「向下离开」：框掉到视口下方 → 往下跟。
    if (top > height * _visibleUpperBound) {
      _scheduleReveal(_paragraphBlockIndex(_tts.cursor.$1, _tts.cursor.$2));
      return;
    }

    // 框还在舒服的位置：什么都不做（这是「不乱跳」的关键）
    if (top >= height * _visibleLowerBound) return;

    // 框到了本页顶部附近或已经跑到上方：本页读完了。
    // 先试「翻到下一页」；翻不了（已是最后一页等）才退回把这一段拉进视野。
    final block = _paragraphBlockIndex(_tts.cursor.$1, _tts.cursor.$2);
    if (_turnForwardFromExhaustedPage()) return;
    if (!_paragraphVisible(block)) _scheduleReveal(block);
  }

  /// 框落在视口 [顶部下限, 底部上限] 之间算「舒服」
  ///
  /// 上限取 0.72（不是更小的值）：句子要走到屏幕下方 3/4 处才滚，
  /// 中间那一大段怎么读都不动；下限取 0.30：低于它说明本页快读完了，该翻页。
  static const double _visibleUpperBound = 0.72;
  static const double _visibleLowerBound = 0.30;

  /// 本页读到头了：翻到下一页（成功返回 true）
  ///
  /// 这是「高亮框到本页最上方就强制翻页」的落地。与 `_followCursor` 里的
  /// 自动翻页共用同一套防连翻闸门（[_pageTurning] / [_lastAutoTurnTarget]），
  /// 所以两条路径不会各翻一次。
  ///
  /// **必须同时满足「光标已经在本页最后一段」**：光看「框靠近页顶」会误翻 ——
  /// 页面刚打开、或某一段正好停在靠上位置时框本来就在上方，
  /// 那不是「读完了」，硬翻就是用户看到的「乱翻页」。
  bool _turnForwardFromExhaustedPage() {
    if (_displayedPage >= _lastPageIndex) return false; // 已经是最后一页
    // 只有到了本页最后一段，才算「这一页读到头了」
    final current = _paging.pageAt(_displayedPage);
    if (_paging.isEmpty) return false;
    final cursor = _tts.highlightCursor;
    if (cursor == null) return false;
    if (cursor.$1 != current.chapter) return false;
    if (cursor.$2 < current.paragraphEnd - 1) return false;
    final next = _displayedPage + 1;
    final last = _lastAutoTurnTarget;
    if (last != null && next <= last) return false; // 同一个目标只翻一次
    if (_pageTurning) return false;
    _lastAutoTurnTarget = next;
    _turnPageTo(next);
    return true;
  }

  /// 安排一次「把朗读位置拉进视野」
  ///
  /// ## 为什么必须显式串行（用户报的「多次点击页面抽搐」根因）
  ///
  /// 定位一次要跨好几帧（翻页 → 等锚点 → `ensureVisible` → 验证 → 可能重试）。
  /// 原来的去重标志 `_pendingReveal` 在**帧回调一触发就清掉了**，
  /// 而 `_revealWithVerify` 那时才刚开始跑 —— 于是第二次点击看到「没有在跑」，
  /// 又起了一条并发的定位链。两条链同时 `ensureVisible` / `animateTo`
  /// 抢同一个 ScrollController：互相打断、来回重开动画，画面就是**抽搐**。
  ///
  /// 所以改成：**一次只跑一条链**（[_revealBusy]），链内循环追最新目标。
  /// 期间来的新目标只覆盖 [_revealWantBlock]，由正在跑的那条链接手续做 ——
  /// 既不会并发，也不会漏掉最后一次点击。
  DateTime? _revealScheduledAt;

  /// 是否已有一条定位链在跑（**覆盖它整个生命周期**，不是只到帧回调）
  bool _revealBusy = false;

  void _scheduleReveal(int block) {
    // 记下最新目标：正在跑的那条链会接过去
    _revealWantBlock = block;
    _followLog('定位安排', '块=$block 已在跑=$_revealBusy 上次=<$_revealScheduledAt>');
    if (_revealBusy) return;
    // 节流：两条链之间留一点间隔，避免刚落地又立刻重开
    final scheduled = _revealScheduledAt;
    if (scheduled != null &&
        DateTime.now().difference(scheduled) <
            const Duration(milliseconds: 180)) {
      _revealRetryAt ??= scheduled.add(const Duration(milliseconds: 200));
      return;
    }
    _revealBusy = true;
    _pendingReveal = '$block';
    _revealScheduledAt = DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingReveal = null;
      if (!mounted) {
        _revealBusy = false;
        return;
      }
      unawaited(_runRevealChain());
    });
  }

  /// 唯一的定位链：一直跑到「没有新目标」且「当前位置舒服」为止
  Future<void> _runRevealChain() async {
    try {
      // 放弃当前这轮时，把目标留成「待补」而不是丢掉 ——
      // 丢掉就会出现「这一次定位彻底没发生」（用户报过的「框不见了」）。
      void defer() {
        final at = DateTime.now().add(const Duration(milliseconds: 240));
        _revealRetryAt = at;
      }

      var stall = 0;
      while (mounted) {
        // 人在滚动 / 刚点过句子：这一轮让位。注意**目标要留着**，
        // 等这些窗口过去后由 [_runPendingReveal] 接着做。
        if (_userScrolling || _autoFollowSuppressed) {
          defer();
          return;
        }
        if (_pageTurning || _inPageSettleWindow) {
          // 翻页中：等它落地再继续（不算失败）
          await _nextFrame();
          if (++stall > 12) {
            defer();
            return;
          }
          continue;
        }
        final want = _revealWantBlock;
        if (want == null) return;
        // ⚠️ **不要在这里清 `_revealWantBlock`**。
        // 清了就会在 `_revealBlock` 的 await 期间丢掉「刚点的那一句」：
        // 链做完旧目标、走到下面的 `if (_revealWantBlock == null) return`
        // 时看到的是空，于是直接收工，那次点击的定位**永远不执行**
        // （实测：`wantBlock` 一直挂着旧值 1，而游标早跑到 5 了）。
        // 改成「成功且没有新目标时才清」，失败时原值留给重试。
        final cursor = _tts.highlightCursor;
        if (cursor == null) {
          _followLog('定位链', '游标为空 → 收工');
          return;
        }
        final live = _paragraphBlockIndex(cursor.$1, cursor.$2);
        await _revealBlock(live, alignment: 0.35);
        if (!mounted) return;
        final ok = _paragraphComfortable(live);
        _followLog(
          '定位链',
          '块=$live 结果=${ok ? "已舒适落位" : "★未落位（将重试）"} stall=$stall '
          '想要=$_revealWantBlock ${_anchorProbe(live)}',
        );
        if (ok) {
          stall = 0;
          // 落好了：期间没有新目标才算真的收工
          if (_revealWantBlock == want) {
            _revealWantBlock = null;
            _revealRetryAt = null;
            return;
          }
          continue;
        }
        // 没落上：等一帧让它有机会被构建出来，再试（目标保持不动）
        await _nextFrame();
        await Future<void>.delayed(const Duration(milliseconds: 24));
        if (++stall > _revealMaxAttempts + 2) {
          // 用完了重试次数：留个待办，让跟随周期稍后再补一次
          defer();
          return;
        }
      }
    } finally {
      _revealBusy = false;
    }
  }

  /// 段落是否已经**舒服地**落在视野内（不只是「碰巧露一点」）
  bool _paragraphComfortable(int blockIndex) {
    final scroll = _pageScroll(_displayedPage);
    if (!scroll.hasClients) return false;
    final position = scroll.position;
    final top = _paragraphScrollOffset(blockIndex, position);
    if (top == null) return false;
    final height = position.viewportDimension;
    if (height <= 0) return true;
    final box = _anchors[blockIndex]?.currentContext?.findRenderObject();
    final size = box is RenderBox && box.hasSize ? box.size.height : 0.0;
    final delta = top - position.pixels;
    // 要求整段（或至少大部分）在视口内，且不在边缘上
    final visible = delta + size > 0 && delta < height;
    if (!visible) return false;
    return delta >= -size * 0.5 && delta <= height * 0.9;
  }

  /// 重试次数上限（每个定位任务）
  static const int _revealMaxAttempts = 3;

  /// 「还欠一次定位」的目标段落与时间（见 [_scheduleReveal]）
  int? _revealWantBlock;
  DateTime? _revealRetryAt;

  /// 每个跟随周期都看一眼：有没有欠着的定位要补
  ///
  /// 这里不依赖「下一次游标变化」—— 定位失败往往就发生在游标连续快进时，
  /// 若只靠下一次推进来补，用户会看到框一直不在视野里。
  void _runPendingReveal() {
    final at = _revealRetryAt;
    if (at == null) return;
    if (DateTime.now().isBefore(at)) return;
    final want = _revealWantBlock;
    _revealRetryAt = null;
    if (want == null) return;
    if (_userScrolling || _autoFollowSuppressed) return;
    if (_pageTurning || _inPageSettleWindow) return;
    _scheduleReveal(want);
  }

  /// 上一次跟随到的游标（用于区分「自动往后读」与「用户跳转」）
  (int, int, int)? _lastCursorSpot;

  /// 正在进行的「定位到朗读段」任务标识（去重用，见 `_ensureSentenceVisible`）
  String? _pendingReveal;

  /// 「读到哪」：由 [_onCursorMoved] 维护，**独立于** `_lastSpot`（视图位置）
  ///
  /// 存在的意义：`TtsManager.stop()` 会把游标清成 (0,0,0)，而停止之后
  /// 用户仍可能退出阅读页/重进这本书 —— 那时只能靠这里记住的位置还原。
  (int, int, int)? _readingSpot;

  /// 翻到指定页
  ///
  /// **防连翻**（用户反复强调的点）：
  /// - [_pageTurning] 闸门：一次翻页动画没结束就不发新的请求；
  /// - 目标就是当前页 / 已经在翻去那一页：直接返回；
  /// - `onPageChanged` 到达后放开闸门；万一它没回调（同一帧重建等），
  ///   [_pageTurnSettle] 超时兜底放开，否则翻页会永远卡住。
  ///
  /// [byUser] 为真表示用户主动翻页（按钮 / 手势）。用户翻页**不需要**读完整页，
  /// 朗读暂停时也照样能翻 —— 用户要求「在朗读暂停时允许向前翻页」。
  void _turnPageTo(int index, {bool byUser = false}) {
    final controller = _pageController;
    if (controller == null || !controller.hasClients) return;
    final target = index.clamp(0, _lastPageIndex);
    if (_pageTurning) return; // 上一次还没落地：这一轮让位（连点也不叠加动画）
    if (target == _pageIndex) return;
    if (byUser) {
      // 用户自己翻页 = 暂时不跟朗读；想跟回来按「回到朗读页」
      _pageAutoFollow = false;
      _lastAutoTurnTarget = null;
    }
    // 跳动检测（埋点 3）：只记录本次翻页，不参与闸门判断。
    // sentencesOnFromPage 传 -1：由采样器按「停留期间实际推进了几次」推算（R8 口径）。
    SpeechDiagnostics.instance.recordTurn(
      fromPage: _displayedPage,
      toPage: target,
      sentencesOnFromPage: -1,
      trigger: byUser ? '用户' : '自动',
    );
    _pageTurning = true;
    _pageTurnSettle?.cancel();
    _pageTurnSettle = Timer(const Duration(milliseconds: 700), () {
      _pageTurning = false;
    });

    // **跨页多了就直接跳，不做逐页动画。**
    //
    // 用户报「朗读时通过目录跳转会快速翻页」就是这么来的：
    // `animateToPage` 会把中间每一页都**真的滑过去** ——
    // 从第 1 页跳到第 148 页要连续渲染 147 页，
    // 全程看着就是「页面疯狂往后翻」；而且中间每帧都会触发
    // `PageView.onPageChanged`，可能再叠加新的翻页请求。
    // 实测轨迹：0 → 60 → 101 → 125 → 137 → 144 → 147（正是逐页动画的痕迹）。
    //
    // 所以只给「相邻一两页」保留动画（正常跟读时看着自然），
    // 大跨度（目录跳章、书签跳转、通知栏拖动进度）一律瞬时落位。
    const animateLimit = 2;
    if ((target - _pageIndex).abs() > animateLimit) {
      _displayedPage = target;
      _lastAutoTurnTarget = null;
      _pageTurning = false;
      _pageTurnSettle?.cancel();
      _pageTurnSettle = null;
      // ⚠️ 这一段**不能直接 setState / jumpToPage**：
      // - `_turnPageTo` 可能正是在 build 期间被 `_followCursor` 调用的
      //   （`_followCursor` 在 build 里跑，见它调用点），
      //   此时 setState 会直接抛「setState() called during build」；
      // - `jumpToPage` 又会**同步**触发 `PageView.onPageChanged`，那里同样 setState。
      // 所以两件事都放到帧后做 —— 与 PDF 那边的 `_goToPdfPage` 一样。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final c = _pageController;
        if (c != null && c.hasClients) c.jumpToPage(target);
        setState(() {});
      });
      return;
    }

    unawaited(
      controller
          .animateToPage(
            target,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          )
          .catchError((Object _) {
        // 被新的翻页打断是正常的，不是错误
        _pageTurning = false;
      }),
    );
  }

  // ---------------- 朗读跳动检测（诊断系统，默认关） ----------------

  /// 阅读页右下角的指示灯（关闭时返回 null，Scaffold 什么都不显示）。
  ///
  /// v1.21.13 / B-P5：实现搬到 `widgets/speech_diag_overlay.dart` —— 原先它是
  /// 这里的内联 FAB，所以只有走 ReaderPage 的 TXT / EPUB / PDF 文本模式有指示灯，
  /// **PDF 原版式**（PdfReadingPage）没有。现在两个页面共用同一份实现。
  Widget? _speechDiagIndicator() => speechDiagIndicator(context);

  /// 用户主动翻页（左右滑动由 PageView 自己处理；这里给按钮 / 手势用）
  ///
  /// **朗读暂停时也要能翻**：翻页是「看」的操作，与朗读状态无关；
  /// 只有「自动跟读翻页」才需要朗读在进行。
  void _goToNextPage() {
    if (_pageIndex >= _lastPageIndex) return;
    _turnPageTo(_pageIndex + 1, byUser: true);
  }

  void _goToPreviousPage() {
    if (_pageIndex <= 0) return;
    _turnPageTo(_pageIndex - 1, byUser: true);
  }

  /// 跳到某一页（目录 / 书签 / 恢复位置用）：不做「读完本页」的判断，直接跳
  void _jumpToPage(int index, {bool animate = false}) {
    final controller = _pageController;
    final target = index.clamp(0, _lastPageIndex);
    // 跳页是「用户主动到达」：落定页立即跟上，并允许后续自动翻页从新位置继续
    _displayedPage = target;
    _lastAutoTurnTarget = null;
    if (controller == null || !controller.hasClients) {
      // 视图还没建好：记下目标，等 PageView 挂上后由 initialPage 落位
      if (mounted) setState(() {});
      return;
    }
    if (target == _pageIndex) return;
    if (!animate) {
      controller.jumpToPage(target);
      return;
    }
    _turnPageTo(target);
  }

  /// 正文区按下的位置（用来区分「点一下」与「拖动」）
  Offset? _pagePointerDownAt;

  /// 这一轮触摸已经变成拖动（移动超过 `kTouchSlop`）
  bool _pagePointerDragged = false;

  /// 滑动刚结束的冷却期：这段时间内的「点击」不算点句（防误触）
  ///
  /// 用户报「滑动页面时可能存在误触」。滑动的收尾动作很容易被识别成一次点击：
  /// - 手指已经在滑动、抬起的瞬间落在某句上；
  /// - 滑动惯性还没停就点了一下（本意是"让它停下"）。
  /// 两种都会让朗读跳到手指底下那一句，看着就是"滑着滑着自己读起来了"。
  ///
  /// 所以滑动过之后留一小段窗口不认点击。取 250ms：比双击间隔短，
  /// 不影响正常操作，但足够滤掉滑动收尾的误触。
  DateTime? _scrollCooldownUntil;
  static const Duration _scrollCooldownWindow = Duration(milliseconds: 250);

  bool get _scrollCooldownActive {
    final until = _scrollCooldownUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  void _onPagePointerDown(PointerDownEvent event) {
    _pagePointerDownAt = event.localPosition;
    _pagePointerDragged = false;
  }

  /// 手指移动超过 `kTouchSlop` 才算「用户在拖动浏览」→ 暂停自动跟随
  ///
  /// 只是点一下（点句朗读、点句切换）**不算**：那种情况下跟随必须保留，
  /// 否则 `_followCursor` 会被开头那个 `!_pageAutoFollow` 一直挡住，
  /// 朗读读到下一页的段落时页面不跟、那一页根本没被建出来，
  /// 高亮框量不到 = 用户看到的「文本框定位失败」。
  void _onPagePointerMove(PointerMoveEvent event) {
    final down = _pagePointerDownAt;
    if (down == null) return;
    if ((event.localPosition - down).distance <= kTouchSlop) return;
    if (!_pagePointerDragged) {
      _pagePointerDragged = true;
      _pageAutoFollow = false;
    }
    // 拖动过程中持续续期：一松手还有一小段冷却，见 [_scrollCooldownUntil]
    _scrollCooldownUntil = DateTime.now().add(_scrollCooldownWindow);
  }

  /// 让**当前句**停在屏幕的舒适区里（不是整段）
  ///
  /// 舒适区取「视口 8% ~ 72%」：句子上边缘高于 8% 说明快滑出上方，
  /// 低于 72% 说明快滑出下方，两种情况才滚；中间位置一律不动 —— 这是
  /// 「朗读时页面不乱划」的关键。
  ///
  /// **「快进导致页面快速滑动」的根因**（v1.17.4 修）：
  /// - 每次游标推进都直接 `animateTo`，连点快进时会有**多个滚动动画叠加**，
  ///   互相抢位置 → 画面连续乱滑。现在每次跟随滚动前先把上一个动画停掉
  ///   （`jumpTo(当前像素)`），不会叠加；
  /// - 另外加了**阻尼**：滚到位后把当前句放在视口 38% 处，而不是紧贴下边缘。
  ///   这样它要再往下走 34% 的视口高度才会触发下一次滚动，
  ///   连续快进时会「攒几句再滚一次」，而不是每句都蹭一下。

  /// 段落文字块相对段落锚点的**上内边距**
  ///
  /// `_ParagraphView` 的结构是 `Padding(vertical: paragraphSpacing/2)` →
  /// 手势/装饰 → `Padding(horizontal: 10, vertical: 8)` → `Text.rich`。
  /// 实测句子盒子时量到的是**文字块内部**的 y，而段落锚点量的是**最外层**的
  /// y，两者差着这段内边距。不补就会让句顶系统性偏上。
  static const double _paragraphTextInsetTop = 8.0;

  /// 最近一次句顶用的是实测还是估算（只用于观测日志）
  String _lastSentenceMeasure = '?';

  /// ★负向自检专用开关（**必须保持 false**）
  ///
  /// 置 true 会让 [RenderParagraph] 实测失效、退回"显式换行数 × 行高"的旧估算，
  /// 用来验证「软换行」那两条用例真的在守这条线（实测：置 true 后两条都变红）。
  /// 生产代码永远不该动它 —— 它存在的唯一目的是让负向自检可复现。
  static const bool _negativeDisableMeasure = false;

  /// ★负向自检专用开关（**必须保持 false**）
  ///
  /// 置 true 会让「朗读中记视图位置」退回原来的"取视口最顶端那一段"，
  /// 用来验证「重回阅读页」那条用例真的在守这条线。
  static const bool _negativeDisableReadingSpot = false;

  /// 段落（锚点）在**所属滚动列表**里的绝对偏移；量不到返回 null
  ///
  /// 为什么不用 `RenderAbstractViewport.getOffsetToReveal`：分页版面是
  /// 「PageView 里的 ListView」这种嵌套视口，那个 API 返回的偏移与
  /// ListView 自己的 `pixels` **不在同一坐标系**，拿它去算「滚到哪」会全错
  /// （表现为滚动位置乱跳 / 该滚的时候不滚）。
  /// 这里改成量「段落顶与列表顶的屏幕距离」，再加上当前 `pixels` —— 自己算，坐标自洽。
  double? _paragraphScrollOffset(int blockIndex, ScrollPosition position) {
    final context = _anchors[blockIndex]?.currentContext;
    if (context == null || !context.mounted) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final listBox = position.context.storageContext.findRenderObject();
    if (listBox is! RenderBox || !listBox.hasSize) return null;
    final delta = box.localToGlobal(Offset.zero).dy -
        listBox.localToGlobal(Offset.zero).dy;
    return position.pixels + delta;
  }

  void _followSentence((int, int, int) cursor, (int, int, int) span) {
    // 只滚**当前页**的控制器：翻页动画由 PageView 负责，
    // 拿别页的控制器去滚会互相打架（也是「页面乱动」的一个来源）。
    final scroll = _pageScroll(_displayedPage);
    if (!scroll.hasClients) {
      _followLog('跟随跳过', '页=$_displayedPage 的控制器没有客户端');
      return;
    }
    final block = _paragraphBlockIndex(cursor.$1, cursor.$2);
    final paragraphTop = _paragraphScrollOffset(block, scroll.position);
    if (paragraphTop == null) {
      _followLog('跟随跳过', '块=$block ${_anchorProbe(block)} 量不到段落偏移');
      return;
    }

    final style = _style;
    final lineHeight = style.fontSize * style.lineHeight;
    final paragraph = _doc?.chapters[cursor.$1].paragraphs[cursor.$2];
    if (paragraph == null) {
      _followLog('跟随跳过', '取不到段落文本 章=${cursor.$1} 段=${cursor.$2}');
      return;
    }

    // 句内纵向位置：**优先实测**（与 `_readingGeometry` 同一来源，
    // 保证「判据」与「滚动目标」用的是同一个数，不会一个实测一个估算而互相打架）。
    // 量不到才退回「显式换行数 × 行高」的估算 —— 中文字幕段落几乎全是软换行，
    // 估算恒为 0，这正是原来「句顶恒等于段顶」的根因（详见 `_measureSentenceInParagraph`）。
    final measured = _measureSentenceInParagraph(
      block,
      cursor.$1,
      cursor.$2,
      cursor.$3,
    );
    final double sentenceInset;
    if (measured != null) {
      // 句心相对段落文字块顶部；用「句心」而不是「句顶」对齐，
      // 与 PDF 的 `sentenceCenterY`（`bounds.center.dy`）口径一致 ——
      // 句顶对齐会让长短句的视觉重心忽上忽下。
      // 补上文字块的上内边距后，`paragraphTop + sentenceInset` 即绝对句心。
      sentenceInset =
          _paragraphTextInsetTop + (measured.top + measured.bottom) / 2;
    } else {
      final start = span.$2.clamp(0, paragraph.text.length);
      final before = paragraph.text.substring(0, start);
      final explicitBreaks = '\n'.allMatches(before).length;
      sentenceInset = explicitBreaks * lineHeight;
    }

    final scrollPosition = scroll.position;
    // 句心相对视口顶的偏移
    final sentenceInsetAbs = paragraphTop + sentenceInset;
    final sentenceCenter = sentenceInsetAbs - scrollPosition.pixels;
    final viewportHeight = scrollPosition.viewportDimension;
    // 舒适区：句心落在视口 8% ~ 72% 之间就不动
    //
    // 区间的选择直接决定「快进时会不会一直滑」：
    // - 判定用 72%（而不是更小的值）：句子要走到屏幕下方 3/4 处才滚，
    //   中间那一大段怎么读都不动；
    // - 滚到位后落在 38%：于是它要再往下走 34% 的视口高度才会触发下一次，
    //   连续快进时会「攒几句再滚一次」。
    // 这两条合起来就是「不每句都滚」的原因。
    final topLimit = viewportHeight * 0.08;
    final bottomLimit = viewportHeight * 0.72;
    _followLog(
      '跟随',
      '块=$block 段顶=${paragraphTop.toStringAsFixed(1)} 句位=$_lastSentenceMeasure '
      '句内偏移=${sentenceInset.toStringAsFixed(1)} '
      '句心=${sentenceCenter.toStringAsFixed(1)} 视口高=${viewportHeight.toStringAsFixed(0)} '
      '区间=[${topLimit.toStringAsFixed(0)},${bottomLimit.toStringAsFixed(0)}] '
      '偏移=${scrollPosition.pixels.toStringAsFixed(1)} max=${scrollPosition.maxScrollExtent.toStringAsFixed(1)}',
    );
    if (sentenceCenter >= topLimit && sentenceCenter <= bottomLimit) {
      _followLog('不滚', '句心=${sentenceCenter.toStringAsFixed(1)} 落在舒适区内');
      return;
    }

    // 目标：把**句心**放到视口 38% 处（与 PDF 的 alignment 口径一致）。
    // 原来是把「段顶」放到 38%，段比视口高时被读的那句会落到屏幕外。
    final want = (scrollPosition.pixels + sentenceCenter - viewportHeight * 0.38)
        .clamp(0.0, scrollPosition.maxScrollExtent);
    if ((want - scrollPosition.pixels).abs() < 2) {
      _followLog('不滚', '目标=${want.toStringAsFixed(1)} 与当前偏移之差<2px');
      return;
    }
    if (_alreadyScrollingTo(want)) {
      _followLog('不滚', '已有一次滚向 ${want.toStringAsFixed(1)} 的动画在跑（防无限重启）');
      return;
    }

    _followLog(
      '滚动',
      '目标=${want.toStringAsFixed(1)} 起点=${scrollPosition.pixels.toStringAsFixed(1)} '
      '位移=${(want - scrollPosition.pixels).toStringAsFixed(1)} 对齐=句心38% 动画=200ms',
    );
    _startFollowScroll(scroll, want);
  }

  /// 启动一次跟随滚动（始终只有一次在跑：新的一来就把旧的停掉）
  /// 正在进行的跟随滚动目标（用于避免反复重启动画）
  double? _followScrollTarget;
  Timer? _followScrollTimer;

  /// 是否已经有一次「滚向 [target] 附近」的动画在跑
  ///
  /// 必须判：`_startFollowScroll` 每次都会先取消上一个动画再重开，
  /// 如果调用方在动画期间反复请求同一目标（定位重试、逐句跟随都会），
  /// 动画会被无限重启、位置永远不动 —— 表现就是「定位到朗读位置没反应」。
  bool _alreadyScrollingTo(double target) {
    final current = _followScrollTarget;
    if (current == null) return false;
    return (current - target).abs() < 8;
  }

  void _startFollowScroll(ScrollController scroll, double target) {
    // 关键：先把正在跑的滚动动画停住。
    // `jumpTo(当前像素)` = 取消动画但不移动，否则两次 animateTo 会叠加、画面来回抖。
    if (!scroll.hasClients) {
      _followLog('滚动跳过', 'animateTo 前控制器已无客户端');
      return;
    }
    final from = scroll.position.pixels;
    scroll.position.jumpTo(scroll.position.pixels);
    _followScrollTarget = target;
    _followScrollTimer?.cancel();
    // 动画 200ms；多留一点余量再允许下一次同目标滚动
    _followScrollTimer = Timer(const Duration(milliseconds: 260), () {
      _followScrollTarget = null;
    });
    // 观测③：用的就是 animateTo；把「起点 / 目标 / 是否打断了上一次」记下来。
    final interrupted = from != scroll.position.pixels;
    unawaited(
      scroll
          .animateTo(
            target,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
          )
          .then((_) {
        // 动画正常收尾：回报实际落点（判断"有没有滚到位"）
        if (!mounted || !scroll.hasClients) return;
        final landed = scroll.position.pixels;
        _followLog(
          '滚动完成',
          '目标=${target.toStringAsFixed(1)} 落点=${landed.toStringAsFixed(1)} '
          '误差=${(landed - target).abs().toStringAsFixed(1)}px '
          '${(landed - target).abs() < 1.5 ? "已到位" : "★未到位（被后续滚动接管或撞界）"}',
        );
      })
          .catchError((Object _) {
        // 被新的跟随滚动打断是正常的，不是错误
      }),
    );
    _followLog(
      '滚动发起',
      'API=animateTo 起点=${from.toStringAsFixed(1)} 目标=${target.toStringAsFixed(1)} '
      '打断上一次=$interrupted',
    );
  }

  // ---------------- 目录 / 页数 ----------------

  Future<void> _openToc() async {
    final document = _doc;
    if (document == null) return;
    final result = await showModalBottomSheet<(int, int)>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => TocSheet(
        document: document,
        cursor: _tts.cursor,
        paragraphsPerPage: StorageService.instance.paragraphsPerPage,
      ),
    );
    if (result == null || !mounted) return;
    // 目录里的下标来自未变的那份文档；仍夹取一次，避免任何越界值进入朗读游标
    final chapter = result.$1 < 0
        ? 0
        : (result.$1 >= document.chapters.length
            ? document.chapters.length - 1
            : result.$1);
    final paragraph = result.$2 < 0 ? 0 : result.$2;

    // v1.20.0 行为：目录跳转**直接跳过去并朗读**（不暂停）。
    // 「跳转时先暂停」是 1.20.9 才加的，用户回退时把它一起去掉了。
    if (_isPdf && !_pdfTextView) {
      _jumpToReadingPageFor(chapter);
    } else {
      _buildBlocksIfNeeded();
      // 目录是用户主动跳转：直接落到目标页，不经过「读完本页才翻」的判据
      unawaited(_revealBlock(_paragraphBlockIndex(chapter, paragraph)));
    }
    // 用户要求：**朗读时用目录跳转 → 原来那一句暂停，跳到目标页后不自动朗读**。
    //
    // 顺序很重要：
    // 1. 先 `pause()` —— 它会作废当前朗读令牌，正在跑的那一轮循环随即退出。
    //    不先暂停的话，紧接着的 `moveCursorTo` 会因为「正在发声」而被拒（见 TtsManager）。
    // 2. 再把游标挪到目标位置（**不发声**）。这样点播放键就是从目标位置接着读，
    //    而不是从上一次读的那一句开始。
    // 3. 最后定位视图。朗读没有开始，所以不会有「跟着朗读位置往回翻」把页面拉走。
    final wasReading = _tts.speaking;
    if (wasReading) unawaited(_tts.pause());

    if (_isPdf && !_pdfTextView) {
      _jumpToReadingPageFor(chapter);
    } else {
      _buildBlocksIfNeeded();
      // 目录是用户主动跳转：直接落到目标页，不经过「读完本页才翻」的判据
      unawaited(_revealBlock(_paragraphBlockIndex(chapter, paragraph)));
    }
    _tts.moveCursorTo(chapter, paragraph, 0);
    if (mounted) {
      setState(() {});
      if (wasReading) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 2),
            content: Text('已跳到该页并暂停：点播放键从这里接着读'),
          ),
        );
      }
    }
  }

  /// 目录跳转用：显式要求跟到某一页（用户操作，重置冷却与闸门）
  void _jumpToReadingPageFor(int chapter) {
    if (!_pdfReady) return;
    _pdfUserCooldown?.cancel();
    _pdfTouching = false;
    _pdfUserRecent = false;
    setState(() => _pdfFollowing = true);
    _goToPdfPage(chapter + 1, force: true);
  }

  // ---------------- PDF 自动排版（可切换、且固化选择）----------------

  /// 解析出来的**原始**章节结构（未重排）
  ///
  /// 「自动排版」是可逆开关：关掉时要用它换回原样。
  /// 重排结果本身不缓存（`_reflowedChapters` 从 `_pdfLines` 现算，很快），
  /// 但原始结构必须留着，否则撤销就没有数据源了。
  StructuredDocument? _originalDoc;

  /// 这份文档当前是否生效自动排版（从存储里读，退出重进保持）
  bool get _autoFormatted =>
      StorageService.instance.isAutoFormat(widget.document.id);

  /// 能不能切换自动排版：PDF、文本模式、且有页面文字行信息
  ///
  /// 与否决「已经排版过」无关 —— 用户要求「再点一次恢复原排版」，
  /// 所以排过之后按钮仍然要可用。
  bool get _canAutoFormat =>
      _isPdf && _pdfTextView && _doc != null && _pdfLines.isNotEmpty;

  /// 「自动排版」开关：点一次排版，再点一次恢复原排版
  ///
  /// 用户要求：
  /// - **单点是排版，再次点击是恢复原排版**；
  /// - **不再次点击就不更改当前生效排版**（所以这个选择必须落盘，
  ///   而不是每次进来重新算一遍）；
  /// - **退出重进也不更改选择**。
  ///
  /// 实现：开关存在 `StorageService`（按文档 id），解析完成时按它决定
  /// 要不要重排；这里只负责「翻转开关 + 立刻应用」。
  void _toggleAutoFormat() {
    final document = _doc;
    if (document == null || !_canAutoFormat) return;
    final next = !_autoFormatted;
    if (next) {
      _applyAutoFormat(enable: true);
    } else {
      _applyAutoFormat(enable: false);
    }
  }

  /// 应用 / 撤销自动排版，并把选择落盘
  ///
  /// [silent] 为真时不弹提示（重进阅读页时静默恢复上次的选择）
  void _applyAutoFormat({required bool enable, bool silent = false}) {
    final document = _doc;
    if (document == null) return;
    // 位置用**朗读游标**（正在读/刚被打断的那一句）而不是 [_lastSpot]：
    // 游标是「朗读到哪」，重排后必须跟着走，否则返回朗读页会回不到同一句。
    final cursor = _tts.cursor;

    if (!enable) {
      // 恢复原排版：用解析出来的原始章节换回去
      final original = _originalDoc;
      if (original == null) return;
      CrashLog.mark(
        'PDF 自动排版：已恢复原排版（${document.paragraphCount} 段 → '
        '${original.paragraphCount} 段）',
      );
      _swapDocument(
        original,
        cursor: cursor,
        autoFormatted: false,
        silent: silent,
        message: '已恢复原排版（${original.paragraphCount} 段）'
            '—— 这个选择会被记住，下次进来仍是原排版',
      );
      return;
    }

    final beforeParagraphs = document.paragraphCount;
    final updated = _tryReflow(document, silent: silent);
    if (updated == null) {
      // 判据认为本来就排好了 / 没有行信息：开关不翻转，
      // 避免留下一个「开了但没效果」的状态。
      // 诊断日志已经由 `_tryReflow` 打过（带 `有变化=` 标记），这里不再重复。
      return;
    }
    CrashLog.mark('PDF 自动排版：$beforeParagraphs 段 → ${updated.paragraphCount} 段');
    _swapDocument(
      updated,
      cursor: cursor,
      autoFormatted: true,
      silent: silent,
      message: '已自动排版：$beforeParagraphs 段 → ${updated.paragraphCount} 段'
          '（再点一次可恢复原排版，选择会被记住）',
    );
  }

  /// 逐页（PDF 一页一章）的行信息，供语义重排使用
  Map<int, List<ReflowLine>> _reflowLinesByPage() {
    final linesByPage = <int, List<ReflowLine>>{};
    _pdfLines.forEach((page, boxes) {
      linesByPage[page] = <ReflowLine>[
        for (final box in boxes)
          ReflowLine(
            text: box.text,
            left: box.bounds.left,
            top: box.bounds.top,
            right: box.bounds.right,
            bottom: box.bounds.bottom,
          ),
      ];
    });
    return linesByPage;
  }

  /// 按语义重排；判据认为无需重排时返回 null
  List<Chapter>? _reflowedChapters(StructuredDocument document) {
    final report = ParagraphReflow.analyze(document.chapters, _reflowLinesByPage());
    CrashLog.mark('PDF 自动排版诊断：${report.summary}｜${report.diagnostic}');
    return report.chapters;
  }

  /// 换排版时把位置从 [from] 映射到 [to] 的坐标系
  ///
  /// **优先按文字定位，失败才退回按全局句序号**。
  ///
  /// 为什么不能只按句序号：自动排版会把跨页断开的行并成一段，各页段数
  /// 有增有减，全局句序号整体会漂。在《共产主义ABC》（319 页、8346 段）
  /// 上实测：按句序号映射 5 个抽查位置有 **4 个落到别的句子**上 ——
  /// 这正是用户报的「自动排版后从文档库返回朗读页不能准确定位」。
  ///
  /// 按文字定位（[StructuredDocument.locateTextAnywhere]）不受段数变化影响；
  /// 只有文字也找不到（重排把这一句改写了）才退回句序号近似。
  (int, int, int) _remapSpot(
    StructuredDocument from,
    StructuredDocument to,
    (int, int, int) spot,
  ) {
    // 原文这一句的文字（夹取到合法范围）
    String? text;
    if (spot.$1 >= 0 && spot.$1 < from.chapters.length) {
      final paragraphs = from.chapters[spot.$1].paragraphs;
      if (spot.$2 >= 0 && spot.$2 < paragraphs.length) {
        final sentences = paragraphs[spot.$2].sentences;
        if (spot.$3 >= 0 && spot.$3 < sentences.length) {
          text = sentences[spot.$3].text;
        }
      }
    }
    if (text != null && text.trim().isNotEmpty) {
      final hit = to.locateTextAnywhere(text, hintChapter: spot.$1);
      if (hit != null) return hit;
    }
    // 兜底：按全局句序号近似（至少不会跑到书首）
    return to.cursorAtIndex(from.indexOfCursor(spot));
  }

  /// 换掉当前生效的文档（重排 / 还原共用）
  ///
  /// 重排后段落下标会变，所以用「朗读到哪一句」重新定位；**版面也交给
  /// [_buildLayout] 统一重建** —— 这样「文档 / 朗读游标 / 分页下标 / 停留位置」
  /// 四者永远出自同一份文档、同一套坐标系。早先这里是自己零散地改 `_paging`
  /// 与块列表，正是「重排后从文档库返回朗读页回不到原句」的根源。
  void _swapDocument(
    StructuredDocument updated, {
    required (int, int, int) cursor,
    required bool autoFormatted,
    required String message,
    bool silent = false,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    final spot = _remapSpot(_doc ?? updated, updated, cursor);
    _tts.loadDocument(
      updated,
      at: spot,
      title: widget.document.title,
      documentId: widget.document.id,
    );
    // 停留位置跟着换到新坐标系（否则退出时会把旧下标写回进度）
    _lastSpot = spot;
    unawaited(StorageService.instance.setAutoFormat(
      widget.document.id,
      autoFormatted,
    ));
    _anchors.clear();
    _buildLayout(updated, spot);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _alignTo(spot);
    });
    if (silent) return;
    messenger.showSnackBar(
      SnackBar(duration: const Duration(seconds: 4), content: Text(message)),
    );
  }

  // ---------------- 底部控制栏 ----------------

  void _toggle() {
    if (_tts.playing) {
      _tts.pause();
    } else if (_tts.speaking && _tts.paused) {
      _tts.resume();
    } else {
      _startReading();
    }
  }

  /// 方块键：结束朗读**并退出朗读模式**（与 PDF 原版式一致）
  ///
  /// 用户要求保留「终止朗读进程」这个语义：终止 = 退出朗读模式 ——
  /// 之后单击不再切句，要重新朗读再点一下句子即可（点击即读）。
  ///
  /// 控制中心保持**展开可见**：方块键只清掉「朗读模式」，
  /// 不改变控制栏的折叠状态（折叠是用户自己按收起键的选择）。
  void _stopReading() {
    _pdfReadMode = false;
    _textReadMode = false;
    _rememberVisibleSpot();
    _persistProgress();
    unawaited(_tts.stop());
    if (mounted) setState(() {});
  }

  /// 从当前游标开始朗读
  ///
  /// PDF 原版式下先切到文本模式：**点句起读**只有文本模式才稳
  /// （原版式只能点页面上已有的那一行），且文本模式在大 PDF 上更省内存。
  /// 想留在原版式里读，直接点页面上的任意一行 —— 那种情况下正在读的句子
  /// 由顶部字幕条呈现（见 [_captionBar]）。
  void _startReading() {
    if (_isPdf && !_pdfTextView) _switchToTextMode(showHint: true);
    final cursor = _tts.cursor;
    // 方块键关掉朗读模式后 `_doc` 被清掉了，先绑回来（否则点了没反应）
    _ensureDocumentBound(cursor);
    _tts.speakFrom(cursor.$1, cursor.$2, cursor.$3);
  }

  Widget _controls() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final document = _doc!;
    final cursor = _tts.cursor;
    final playing = _tts.playing;
    final perPage = StorageService.instance.paragraphsPerPage;

    final String position;
    // 游标理论上始终有效，这里仍做一次边界保护，避免极端情况下取章越界
    final chapterIndex =
        cursor.$1 < 0 || cursor.$1 >= document.chapters.length ? 0 : cursor.$1;
    final chapterParagraphs = document.chapters[chapterIndex].paragraphs;
    final safeParagraph = cursor.$2 < 0
        ? 0
        : (cursor.$2 >= chapterParagraphs.length
            ? chapterParagraphs.length - 1
            : cursor.$2);
    if (document.chapterIsPage) {
      position = '第 ${chapterIndex + 1}/${document.chapters.length} 页';
    } else {
      final page = document.pageOf(chapterIndex, safeParagraph, perPage);
      final totalPages = chapterParagraphs.isEmpty
          ? 1
          : document.pageCountOf(chapterIndex, perPage);
      position =
          '第 ${chapterIndex + 1} 章 第 $page/$totalPages 页 · 第 ${safeParagraph + 1} 段';
    }

    if (_controlCollapsed) return _collapsedControls(theme, playing, position);
    return Material(
      key: ReaderPage.controlCenterKey,
      color: scheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 翻页行：分页版面下按「页」翻，与左右滑动是同一套（都走 _turnPageTo）
              if (!_paging.isEmpty)
                Row(
                  children: <Widget>[
                    IconButton(
                      key: ReaderPage.previousPageKey,
                      tooltip: '上一页',
                      visualDensity: VisualDensity.compact,
                      onPressed:
                          _pageIndex > 0 ? () => _goToPreviousPage() : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          '第 ${_pageIndex + 1}/${_paging.pageCount} 页'
                          '${_paging.pageAt(_pageIndex).isChapterFirstPage ? '' : ' · 本章续页'}',
                          style: theme.textTheme.labelMedium,
                        ),
                      ),
                    ),
                    IconButton(
                      key: ReaderPage.nextPageKey,
                      tooltip: '下一页',
                      visualDensity: VisualDensity.compact,
                      onPressed: _pageIndex < _lastPageIndex
                          ? () => _goToNextPage()
                          : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: <Widget>[
                  IconButton.filledTonal(
                    tooltip: '上一句',
                    onPressed: _tts.skipSentenceBackward,
                    icon: const Icon(Icons.fast_rewind),
                  ),
                  IconButton.filled(
                    tooltip: playing ? '暂停' : '播放',
                    iconSize: 32,
                    onPressed: _toggle,
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  ),
                  IconButton.filledTonal(
                    key: ReaderPage.nextSentenceKey,
                    tooltip: '下一句',
                    onPressed: _tts.skipSentenceForward,
                    icon: const Icon(Icons.fast_forward),
                  ),
                  // 方块键：结束朗读（与文档库控制栏那个方块键同义）
                  IconButton.filledTonal(
                    key: ReaderPage.stopReadingKey,
                    tooltip: '结束朗读',
                    onPressed: _stopReading,
                    icon: const Icon(Icons.stop),
                  ),
                  if (_canAutoFormat)
                    IconButton.filledTonal(
                      key: ReaderPage.autoFormatKey,
                      // 一个按钮两种状态：点亮 = 排版已生效，再点恢复原排版。
                      // 选择会落盘，退出重进保持。
                      tooltip: _autoFormatted
                          ? '恢复原排版'
                          : '自动排版：把被折行切断的句子接回整段',
                      isSelected: _autoFormatted,
                      onPressed: _toggleAutoFormat,
                      icon: const Icon(Icons.auto_fix_high),
                    ),
                  IconButton.filledTonal(
                    tooltip: '目录 / 选择页数',
                    onPressed: _openToc,
                    icon: const Icon(Icons.list_alt),
                  ),
                  IconButton.filledTonal(
                    key: ReaderPage.collapseControlKey,
                    tooltip: '收起控制中心',
                    onPressed: () => setState(() => _controlCollapsed = true),
                    icon: const Icon(Icons.keyboard_arrow_down),
                  ),
                ],
              ),
              Row(
                children: <Widget>[
                  const Icon(Icons.speed, size: 20),
                  Expanded(
                    child: Slider(
                      value: _tts.rate,
                      min: 0.5,
                      max: 2.0,
                      divisions: 15,
                      label: '${(_tts.rate * 100).round()}%',
                      onChanged: _tts.setRate,
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    child: Text(
                      '${(_tts.rate * 100).round()}%',
                      textAlign: TextAlign.end,
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                ],
              ),
              _localEngineBar(theme),
              // 实时进度：与高亮框用**同一个游标**算出来，所以「框在哪」与
              // 「进度显示到哪」永远一致（以前只显示页码/段号，看不出进度对齐没有）
              _progressRow(theme, position),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '${_tts.activeEngineName} · ${_tts.granularity.label}',
                  style: theme.textTheme.labelSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 控制中心里的实时进度条 + 位置
  ///
  /// 进度取自 [TtsManager.progressIndex] / [progressTotal]，与通知栏进度条
  /// 和逐句高亮是同一份数据；位置文案与它放在同一行，一眼就能看出是否同步。
  Widget _progressRow(ThemeData theme, String position) {
    final total = _tts.progressTotal;
    final index = _tts.progressIndex;
    final value = total <= 0 ? 0.0 : (index / total).clamp(0.0, 1.0);
    final percent = '${(value * 100).round()}%';
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: total <= 0 ? 0 : value,
                    minHeight: 3,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(percent, style: theme.textTheme.labelSmall),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            position,
            style: theme.textTheme.labelSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// 折叠态控制中心：只留「播放/暂停 + 当前位置 + 展开」
  ///
  /// 朗读时用户主要看正文，控制中心占掉屏幕下方一大块很碍事；
  /// 折起来仍然能暂停 / 继续，位置信息也留着。
  Widget _collapsedControls(ThemeData theme, bool playing, String position) {
    final scheme = theme.colorScheme;
    return Material(
      key: ReaderPage.collapsedControlKey,
      color: scheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 46,
          child: Row(
            children: <Widget>[
              const SizedBox(width: 6),
              IconButton.filledTonal(
                tooltip: playing ? '暂停' : '播放',
                onPressed: _toggle,
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${_tts.documentTitle.isEmpty ? widget.document.title : _tts.documentTitle}'
                  ' · $position',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium,
                ),
              ),
              IconButton(
                key: ReaderPage.expandControlKey,
                tooltip: '展开控制中心',
                onPressed: () => setState(() => _controlCollapsed = false),
                icon: const Icon(Icons.keyboard_arrow_up),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 本地 TTS 选择栏：设备上装了多个本地语音引擎时，一键切换
  ///
  /// 只有一个可选引擎（或只有云端）时整条栏不显示，免得白占一行。
  Widget _localEngineBar(ThemeData theme) {
    final tts = _tts;
    final engines = tts.localEngines;
    if (engines.length < 2) return const SizedBox.shrink();
    final scheme = theme.colorScheme;
    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
            child: Center(
              child: Text('本地 TTS', style: theme.textTheme.labelSmall),
            ),
          ),
          for (final engine in engines)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(
                  engine.isDefault ? '${engine.label}（默认）' : engine.label,
                  style: theme.textTheme.labelSmall,
                ),
                selected: engine.isCurrent,
                visualDensity: VisualDensity.compact,
                onSelected: (_) =>
                    unawaited(tts.setLocalEngine(engine.package)),
              ),
            ),
          if (tts.cloudConfigured)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                avatar:
                    Icon(Icons.cloud_outlined, size: 16, color: scheme.primary),
                label: Text('云端 TTS', style: theme.textTheme.labelSmall),
                visualDensity: VisualDensity.compact,
                onPressed: () => unawaited(tts.setActiveEngine('cloud')),
              ),
            ),
        ],
      ),
    );
  }
}

/// 平板 PDF 初始缩放的「不允许超过」上限（护栏，不是「要放大到多少」）
///
/// ⚠️ 关键实测结论：`SfPdfViewer` 在 `zoomLevel = 1.0` 时**已经是适应宽度**
/// （整页宽度铺满视口）。所以在 1.0 之上再加倍率只会让页面**溢出视口**：
/// 页面底部的行跑到屏幕外，点页面上的行会被插件判成「页面外」
/// （实测 2.4 倍时 `pageNumber = -1`，**点句起读直接失效**）。
///
/// 因此初始缩放恒定为 [pdfInitialZoom] 的返回值（= 适应宽度），
/// 这个常量只作为「任何人将来想调大时的上限参照」，同时被单测引用为护栏。
const double maxTabletPdfZoom = 1.0;

/// PDF 页码滚动头占的宽度（与插件里的 `_kPdfScrollHeadSize` 一致）
const double pdfScrollHeadSize = 48;

/// 平板 / 大屏下的 PDF 初始缩放系数
///
/// 顶层纯函数（只做算术，不依赖控制器与 BuildContext），便于单测。
///
/// ## 为什么这里几乎总是返回 1.0
///
/// 在平板 AVD（2560x1600 = 1280x740 dp）上用真实 `SfPdfViewer` 实测得到两条：
///
/// 1. **`zoomLevel = 1.0` 已经是「适应宽度」**：整页宽度铺满视口。
///    页面上的行长占屏宽约 88%，与用户给的参考图（浏览器里的 PDF 阅读器）
///    观感一致 —— 也就是说「显示太小」并不是缩放没开，1.0 就是参考图那个尺寸。
/// 2. **在 1.0 之上再加倍率只会让页面溢出视口**。实测 2.4 倍时，
///    点页面任意位置的回报都是 `pageNumber = -1`（判成「页面外」），
///    **点句起读直接失效** —— 这是真正的功能损坏，比「字略小」严重得多。
///
/// 所以初始缩放取 1.0（= 适应宽度），把「再放大」留给用户自己捏合：
/// 那时用户是有意识地放大局部，点句失效的代价可接受。
///
/// [viewport] / [pageSize] / [wide] 保留在签名里：一来单测要覆盖参数组合，
/// 二来将来若 Syncfusion 改了 `zoomLevel` 的语义，可以在这里按实测定倍数。
double pdfInitialZoom({
  required Size viewport,
  required Size pageSize,
  required bool wide,
}) {
  // 参数只做有效性校验：无效输入同样返回 1.0，不让界面算出 NaN / 除零
  final availableWidth = viewport.width - pdfScrollHeadSize;
  final availableHeight = viewport.height - pdfScrollHeadSize;
  if (availableWidth <= 0 || availableHeight <= 0) return 1;
  if (pageSize.width <= 0 || pageSize.height <= 0) return 1;
  // 视口窄到连页面都放不下（手机竖屏）时也不放大，保持适应宽度
  if (wide && availableHeight <= 0) return 1;
  return maxTabletPdfZoom;
}

/// 书签面板的操作结果：跳转或删除
class _BookmarkAction {
  const _BookmarkAction.jump(this.jump) : deleted = null;

  const _BookmarkAction.delete(this.deleted) : jump = null;

  final Bookmark? jump;
  final Bookmark? deleted;
}

/// 书签面板：本文档的书签可跳转 / 删除，其它文档的书签点开对应文档
class _BookmarkSheet extends StatelessWidget {
  const _BookmarkSheet({
    required this.currentDocumentId,
    required this.bookmarks,
    required this.chapterIsPage,
  });

  final String currentDocumentId;
  final List<Bookmark> bookmarks;
  final bool chapterIsPage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mine =
        bookmarks.where((b) => b.documentId == currentDocumentId).toList();
    final others =
        bookmarks.where((b) => b.documentId != currentDocumentId).toList();

    Widget tile(Bookmark bookmark, {required bool jumpable}) => ListTile(
          leading: Icon(jumpable ? Icons.bookmark : Icons.bookmark_border),
          title: Text(bookmark.label(chapterIsPage: jumpable && chapterIsPage)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (bookmark.preview.isNotEmpty)
                Text(bookmark.preview,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
              Text(
                jumpable
                    ? _formatTime(bookmark.createdAt)
                    : '${bookmark.documentTitle} · ${_formatTime(bookmark.createdAt)}',
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
          trailing: IconButton(
            tooltip: '删除书签',
            icon: const Icon(Icons.delete_outline),
            onPressed: () =>
                Navigator.pop(context, _BookmarkAction.delete(bookmark)),
          ),
          onTap: () => Navigator.pop(context, _BookmarkAction.jump(bookmark)),
        );

    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('书签（${mine.length}）',
                  style: theme.textTheme.titleMedium),
            ),
            if (mine.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Text('这本书还没有书签。朗读到想记住的地方，点右上角的书签按钮即可添加。'),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: <Widget>[
                    for (final bookmark in mine) tile(bookmark, jumpable: true)
                  ],
                ),
              ),
            if (others.isNotEmpty) ...<Widget>[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text('其它文档（${others.length}）',
                    style: theme.textTheme.titleSmall),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: <Widget>[
                    for (final bookmark in others)
                      tile(bookmark, jumpable: false),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  static String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }
}

/// 段落视图：自己持有本段所有句子的 TapGestureRecognizer，并缓存 TextSpan
///
/// 关键优化：识别器与段落同生命周期（滚动出屏即释放），TextSpan 只在「当前句」变化时重建，
/// 因此每推进一句只重排两个段落，而不是整篇文档。
class _ParagraphView extends StatefulWidget {
  const _ParagraphView({
    super.key,
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.paragraph,
    required this.activeSentence,
    required this.highlighted,
    required this.style,
    required this.onSpeakSentence,
    required this.onSpeakParagraph,
    required this.onUserTap,
    this.onSentenceSpans,
    this.cursorOnParagraph = false,
  });

  final int chapterIndex;
  final int paragraphIndex;
  final Paragraph paragraph;
  final int activeSentence;
  final bool highlighted;

  /// 阅读排版（字号 / 行距 / 页边距 / 底色）
  final ReaderStyle style;
  final void Function(int sentence) onSpeakSentence;
  final VoidCallback onSpeakParagraph;

  /// 用户点了正文：自动休眠的空闲计时重来
  final VoidCallback onUserTap;

  /// 上报每句在本段文字里的字符区间 `(句下标, 起始, 结束)`
  ///
  /// 阅读页用它算出「当前句在屏幕上的位置」，跟随滚动才能精确到**句**而不是段
  /// —— 这正是「文本框没有正确选中文本 / 快进时乱动」的关键：
  /// 原来只按段滚动，一段有十几句时框会在段内乱跑甚至跑出屏幕。
  final void Function(int chapter, int paragraph, List<(int, int, int)> spans)?
      onSentenceSpans;

  /// 朗读游标是否正落在这一段（用例定位「正在读的位置」用）
  final bool cursorOnParagraph;

  @override
  State<_ParagraphView> createState() => _ParagraphViewState();
}

class _ParagraphViewState extends State<_ParagraphView> {
  /// 每句一个 TapGestureRecognizer，按 "章:段:句" 索引，dispose 时统一释放
  final Map<String, TapGestureRecognizer> _recognizers =
      <String, TapGestureRecognizer>{};

  TextSpan? _spanCache;
  List<Object?>? _spanCacheKey;

  /// 逐项比对缓存键（不能用哈希值比对，见 [_span] 里的说明）
  bool _sameKey(List<Object?> next) {
    final previous = _spanCacheKey;
    if (previous == null || previous.length != next.length) return false;
    for (var i = 0; i < next.length; i++) {
      if (previous[i] != next[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    _recognizers.clear();
    super.dispose();
  }

  TapGestureRecognizer _recognizer(int sentence) {
    final key = '${widget.chapterIndex}:${widget.paragraphIndex}:$sentence';
    return _recognizers.putIfAbsent(
      key,
      () => TapGestureRecognizer()
        ..onTap = () => _onTap(() => widget.onSpeakSentence(sentence)),
    );
  }

  TextSpan _span(ColorScheme scheme, (Color, Color) highlight) {
    // 缓存键必须**逐项比对**，不能把几项塞进 Object.hash 后比哈希值。
    //
    // 这里踩过一个很隐蔽的坑：`Object.hash(-1, ...)` 与 `Object.hash(0, ...)`
    // 可能撞成同一个 32 位值（实测就撞上了 449065489）。一旦撞上，
    // 「当前句从 -1 变成 0」就不会触发重建，界面看起来就是**该高亮的那句不高亮**，
    // 而且只在特定主题 / 字号组合下复现，极难查。
    final cacheKey = <Object?>[
      widget.activeSentence,
      scheme.brightness,
      identityHashCode(widget.paragraph),
      highlight,
      widget.style.fontSize,
      widget.style.lineHeight,
      widget.style.letterSpacing,
    ];
    final cached = _spanCache;
    if (cached != null && _sameKey(cacheKey)) return cached;

    final sentences = widget.paragraph.sentences;
    final spans = <InlineSpan>[];
    final offsets = <(int, int, int)>[];
    var at = 0;
    for (var s = 0; s < sentences.length; s++) {
      final text = sentences[s].text;
      spans.add(
        TextSpan(
          text: text,
          style: widget.activeSentence == s
              ? TextStyle(backgroundColor: highlight.$1, color: highlight.$2)
              : null,
          recognizer: _recognizer(s),
        ),
      );
      offsets.add((s, at, at + text.length));
      at += text.length;
    }
    _spanCacheKey = cacheKey;
    _spanCache = TextSpan(children: spans);
    _reportSpans(offsets);
    return _spanCache!;
  }

  /// 上报每句的字符区间（帧后执行，避免在 build 期间触发 setState）
  void _reportSpans(List<(int, int, int)> offsets) {
    final report = widget.onSentenceSpans;
    if (report == null) return;
    final chapter = widget.chapterIndex;
    final paragraph = widget.paragraphIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      report(chapter, paragraph, offsets);
    });
  }

  /// 用户点了正文（空白处、句子、整段高亮框）：都算一次操作
  void _onTap(VoidCallback action) {
    widget.onUserTap();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = widget.style;
    final highlight = style.highlightColors(scheme);
    // 朗读游标是否落在这一段（不论粒度：按句/按章都要能定位到当前读的地方）
    final cursorOnParagraph = widget.cursorOnParagraph;
    return Padding(
      // 页边距与段间距来自阅读排版设置
      padding: EdgeInsets.symmetric(
        horizontal: style.pageMargin,
        vertical: style.paragraphSpacing / 2,
      ),
      // 点段落任意空白处：从该段第一句开始读（与原版 1.20.0 的 PDF 原版式一致）。
      //
      // 这里**没有** `onDoubleTap`：原版 1.20.0 是「点击即读」，没有双击这一步。
      // 顺带一个好处：段落上不再有双击识别器，句子的单击识别器不会在
      // 手势竞技场里输给段落 —— 连点两句时两句都能生效。
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _onTap(widget.onSpeakParagraph),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: widget.highlighted ? highlight.$1 : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Text.rich(
              // 游标落在这一段时挂上 Key：用例据此量「正在朗读的位置」在屏幕上的
              // 位置，验证快进 / 自动跟随之后它仍在屏幕内（不会乱动到看不见的地方）
              key: cursorOnParagraph ? ReaderPage.activeSentenceKey : null,
              _span(scheme, highlight),
              style: style
                  .apply(theme.textTheme.bodyLarge ?? const TextStyle())
                  .copyWith(
                    color: widget.highlighted
                        ? highlight.$2
                        : style.theme.foreground,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

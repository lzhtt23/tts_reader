import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/source_rule.dart';
import '../models/structured_document.dart';
import '../services/legado_source_store.dart';
import '../services/source_client.dart';
import '../services/storage_service.dart';
import '../tts/tts_manager.dart';
import '../widgets/gear_spinner.dart';
import '../widgets/wavy_progress.dart';

/// 在线书阅读页：拉目录 → 按需取正文 → **分页阅读** → 交给 TtsManager 朗读
///
/// ## 分页方式与本地 EPUB 一致
///
/// 本地阅读器（`ReaderPage`）的文本模式是「按 `paragraphsPerPage` 个段落分一页」，
/// 左右翻页。这里沿用同一套：把窗口内的所有段落摊平成一个列表，
/// 每 N 段一页，用 `PageView` 翻 —— 这样在线读和本地读的手感是同一个。
///
/// （原来是一整条 `ListView` 长滚动，和 EPUB 完全不一样，用户会觉得像两个应用。）
///
/// ## 速度
///
/// 三处优化：
/// 1. `toDocument` 改成**并发抓**（默认 4 路），顺序按章节下标保持不乱；
/// 2. 正文按 URL **缓存**在本页，翻窗口回来不重复请求；
/// 3. 窗口先小后大：先抓 6 章把第一屏显示出来，其余在后台补。
/// 在线阅读分页：给定段落数与每页段数，算页数
///
/// 抽成顶层函数是为了能离线单测边界：`perPage` 取 0 时必须**退化成 1**，
/// 否则 `(n + 0 - 1) ~/ 0` 直接除零崩掉（设置项是用户可以改的，不能假设它一定 > 0）。
int onlinePageCount(int blocks, int perPage) {
  if (blocks <= 0) return 1;
  final int per = perPage <= 0 ? 1 : perPage;
  return (blocks + per - 1) ~/ per;
}

/// 按**章节**分页：返回每一页的起始段落下标
///
/// 规则（用户要求「目录按章节分页」）：
/// * 每一章**一定从新的一页开始**（章之间不挤在同一页）
/// * 章内部再按 `perPage` 切页
///
/// 这样每个章节都有确定的起始页，目录里就能标「P12」这种页码，
/// 点目录也能精确跳到那一页 —— 而不是像之前那样两章共用一页、页码算不清。
///
/// [chapterStart] 与段落一一对应：true 表示这一段的上面是一个新章的开头。
List<int> onlinePageStarts({
  required List<bool> chapterStart,
  required int perPage,
}) {
  final int per = perPage <= 0 ? 1 : perPage;
  if (chapterStart.isEmpty) return <int>[0];
  final List<int> starts = <int>[0];
  var currentStart = 0;
  for (var i = 1; i < chapterStart.length; i++) {
    final bool newChapter = chapterStart[i];
    final bool full = (i - currentStart) >= per;
    if (newChapter || full) {
      starts.add(i);
      currentStart = i;
    }
  }
  return starts;
}

class LegadoReadPage extends StatefulWidget {
  const LegadoReadPage({
    super.key,
    required this.source,
    required this.book,
    this.initialChapter = 0,
  });

  final SourceRule source;
  final OnlineBook book;

  /// 从第几章开始（书架续读）
  final int initialChapter;

  /// 一次装载的章数（窗口大小）
  static const int windowSize = 20;

  /// 首屏先抓几章（先把界面显示出来，剩下的接着补）
  static const int firstPaintChapters = 6;

  /// 并发路数（书源站点多半扛不住太高）
  static const int concurrency = 4;

  @override
  State<LegadoReadPage> createState() => _LegadoReadPageState();
}

/// 摊平后的一个段落（分页与朗读定位都用它）
class _Block {
  const _Block({
    required this.chapter,
    required this.paragraph,
    required this.title,
    required this.text,
    this.showChapterTitle = false,
  });

  final int chapter;
  final int paragraph;
  final String title;
  final String text;

  /// 这一段的上面要不要画章标题
  final bool showChapterTitle;
}

class _LegadoReadPageState extends State<LegadoReadPage> {
  late final SourceClient _client = SourceClient(rule: widget.source);

  List<OnlineChapter> _chapters = const <OnlineChapter>[];
  StructuredDocument? _document;

  /// 正文缓存：chapterUrl → 正文（翻窗口回来不重复请求）
  final Map<String, String> _contentCache = <String, String>{};

  final PageController _pageController = PageController();

  bool _loadingToc = true;
  bool _loadingContent = false;
  String? _error;
  int _windowStart = 0;
  String _status = '';
  int _pageIndex = 0;

  /// 摊平后的段落表（整窗）
  List<_Block> _blocks = const <_Block>[];

  /// 每一页的起始段落下标（按章节分页）
  List<int> _pageStarts = const <int>[0];

  /// 句子的点击识别器（Text.rich 里做「点句子切到那句」）
  ///
  /// 必须自己**持有并释放**：`TapGestureRecognizer` 不释放会一直挂在手势表里。
  final Map<String, TapGestureRecognizer> _sentenceTaps =
      <String, TapGestureRecognizer>{};

  /// 每页段落数（跟随本地阅读器的设置；非法值退化成 1，别除零）
  int get _perPage {
    final int value = StorageService.instance.paragraphsPerPage;
    return value <= 0 ? 1 : value;
  }

  int get _pageCount => _pageStarts.isEmpty ? 1 : _pageStarts.length;

  /// 第 [blockIndex] 段在第几页
  int _pageOfBlock(int blockIndex) {
    if (_pageStarts.isEmpty) return 0;
    var page = 0;
    for (var i = 0; i < _pageStarts.length; i++) {
      if (_pageStarts[i] <= blockIndex) {
        page = i;
      } else {
        break;
      }
    }
    return page;
  }

  @override
  void initState() {
    super.initState();
    // 朗读游标一变就检查要不要跟着翻页（在线读也要像本地那样自动跟随）
    TtsManager.instance.addListener(_onTtsChanged);
    _loadToc();
  }

  @override
  void dispose() {
    TtsManager.instance.removeListener(_onTtsChanged);
    for (final TapGestureRecognizer r in _sentenceTaps.values) {
      r.dispose();
    }
    _sentenceTaps.clear();
    _pageController.dispose();
    _client.dispose();
    super.dispose();
  }

  /// 朗读推进 → 当前页不是朗读所在页就翻过去
  ///
  /// 只在**正在播**时跟随：用户自己左右翻页时不去抢。
  void _onTtsChanged() {
    if (!mounted) return;
    final TtsManager tts = TtsManager.instance;
    if (!tts.playing || !tts.holdsDocument(widget.book.url)) return;
    final int page = _pageOfCursor(tts.cursor.$1, tts.cursor.$2);
    if (page < 0 || page == _pageIndex) return;
    if (!_pageController.hasClients) return;
    _pageController.jumpToPage(page);
  }

  /// 某段落在第几页（找不到返回 -1）
  int _pageOfCursor(int chapter, int paragraph) {
    final int index = _blocks.indexWhere(
      (_Block b) => b.chapter == chapter && b.paragraph == paragraph,
    );
    if (index < 0) return -1;
    return _pageOfBlock(index);
  }

  /// 某一章（窗口内下标）从第几页开始（找不到返回 -1）
  int _pageOfChapter(int localChapter) {
    final int index = _blocks.indexWhere(
      (_Block b) => b.chapter == localChapter && b.paragraph == 0,
    );
    if (index < 0) return -1;
    return _pageOfBlock(index);
  }

  Future<void> _loadToc() async {
    setState(() {
      _loadingToc = true;
      _error = null;
    });
    try {
      final List<OnlineChapter> toc = await _client.toc(widget.book.url);
      if (!mounted) return;
      setState(() {
        _chapters = toc;
        _loadingToc = false;
      });
      if (toc.isEmpty) {
        setState(() => _error = '没取到目录（书源规则可能已失效）');
        return;
      }
      await _loadWindow(widget.initialChapter);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingToc = false;
        _error = e.toString();
      });
    }
  }

  /// 装载一窗章节（从 [start] 开始，向后 [windowSize] 章）
  ///
  /// 分两步：先抓前 [firstPaintChapters] 章立刻显示，再补剩下的 ——
  /// 用户不用等 20 章全到才看见字。
  Future<void> _loadWindow(int start) async {
    if (_chapters.isEmpty) return;

    final int safeStart = start.clamp(0, _chapters.length - 1);
    final int end = (safeStart + LegadoReadPage.windowSize) > _chapters.length
        ? _chapters.length
        : safeStart + LegadoReadPage.windowSize;
    final List<OnlineChapter> window = _chapters.sublist(safeStart, end);

    setState(() {
      _loadingContent = true;
      _windowStart = safeStart;
      _status = '正在取正文 0/${window.length}';
    });

    try {
      final List<OnlineChapter> head =
          window.length > LegadoReadPage.firstPaintChapters
          ? window.sublist(0, LegadoReadPage.firstPaintChapters)
          : window;

      final StructuredDocument first = await _client.toDocument(
        head,
        chapterLoader: (OnlineChapter c) => _client.content(c.url),
        concurrency: LegadoReadPage.concurrency,
        cache: _contentCache,
      );
      if (!mounted) return;
      _applyDocument(first, safeStart, loadingMore: window.length > head.length);
      if (window.length == head.length) return;

      // 剩余章节后台补：拼到同一份文档里，页码往后长，但**当前页不动**
      final StructuredDocument rest = await _client.toDocument(
        window.sublist(head.length),
        chapterLoader: (OnlineChapter c) => _client.content(c.url),
        concurrency: LegadoReadPage.concurrency,
        cache: _contentCache,
      );
      if (!mounted) return;
      _applyDocument(
        StructuredDocument(
          chapters: <Chapter>[...first.chapters, ...rest.chapters],
        ),
        safeStart,
        loadingMore: false,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingContent = false;
        _status = '';
        _error = '取正文失败：$e';
      });
    }
  }

  /// 把一份文档装进页面：摊平段落 → 算页数 → 绑定朗读
  ///
  /// ⚠️ **必须带位置**：这个函数会被调两次（首屏 6 章 → 补满 20 章）。
  /// 真机日志（2026-10-19 10:05）就是漏了位置导致的：
  /// ```
  /// 10:05:36 位置[载入文档] at=null 章数=6      ← 首屏
  /// 10:05:38 位置[载入文档] at=null 章数=20     ← 补章节，游标被重置成 (0,0,0)
  /// ```
  /// 用户正读到第几段会被拉回开头。现在把当前游标一起传下去。
  void _applyDocument(
    StructuredDocument doc,
    int windowStart, {
    required bool loadingMore,
  }) {
    final List<_Block> blocks = <_Block>[];
    for (var c = 0; c < doc.chapters.length; c++) {
      final Chapter chapter = doc.chapters[c];
      for (var p = 0; p < chapter.paragraphs.length; p++) {
        blocks.add(
          _Block(
            chapter: c,
            paragraph: p,
            title: chapter.title,
            text: chapter.paragraphs[p].text,
            showChapterTitle: p == 0,
          ),
        );
      }
    }
    // 按章节分页：每章从新页开始，章内再按每页段数切
    final List<int> starts = onlinePageStarts(
      chapterStart: <bool>[
        for (final _Block b in blocks) b.paragraph == 0,
      ],
      perPage: _perPage,
    );
    // 记住朗读位置对应的段落（补章节后页数会变，要按段落重新算页）
    final TtsManager tts = TtsManager.instance;
    final bool sameDoc = tts.holdsDocument(widget.book.url);
    final (int, int, int)? cursor = sameDoc ? tts.cursor : null;

    setState(() {
      _document = doc;
      _blocks = blocks;
      _pageStarts = starts;
      _loadingContent = false;
      _status = loadingMore ? '正在补后面的章节…' : '';
    });
    // 同一本已经在读：把游标原样带过去，别把位置冲掉
    tts.loadDocument(
      doc,
      at: cursor,
      title: widget.book.name,
      documentId: widget.book.url,
    );
    if (cursor != null) {
      final int page = _pageOfCursor(cursor.$1, cursor.$2);
      if (page >= 0 && _pageController.hasClients) {
        _pageController.jumpToPage(page);
        setState(() => _pageIndex = page);
      }
    }
    // ⚠️ 不自动加入书架：在线阅读 ≠ 收藏。
    // 只对**已经在书架里**的那本更新进度；不在就不写。
    LegadoSourceStore.instance.updateBookProgress(
      url: widget.book.url,
      chapterIndex: windowStart,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          if (_chapters.isNotEmpty)
            IconButton(
              tooltip: '目录',
              icon: const Icon(Icons.list),
              onPressed: _showToc,
            ),
          IconButton(
            tooltip: '刷新目录',
            icon: const Icon(Icons.refresh),
            onPressed: _loadingToc ? null : _loadToc,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (_loadingToc) {
      // 齿轮慢转（与文档库迷你条同一个造型、同样 6 秒一圈）
      return const Center(child: GearLoading(label: '正在取目录…'));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline, color: theme.colorScheme.error, size: 40),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _loadToc, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    // 首屏还没出来才挡；补后面章节时已经能读了
    if (_loadingContent && _blocks.isEmpty) {
      return Center(
        child: GearLoading(label: _status.isEmpty ? '正在取正文…' : _status),
      );
    }
    if (_blocks.isEmpty) {
      return Center(child: Text('没有内容', style: theme.textTheme.bodyMedium));
    }

    return Column(
      children: <Widget>[
        // 文档已经出来了 → 补后面章节的提示用**进度条**（用户要求），
        // 齿轮只留给「还没有正文可看」的初始加载。
        if (_status.isNotEmpty)
          LinearWavyProgressIndicator(semanticsLabel: _status),
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: _pageCount,
            onPageChanged: (int i) {
              setState(() => _pageIndex = i);
              // 翻到本窗最后一页 → 自动接下一批（读长书不用手动点"下一批"）
              final bool lastPage = i >= _pageCount - 1;
              if (lastPage &&
                  !_loadingContent &&
                  _windowStart + (_document?.chapters.length ?? 0) <
                      _chapters.length) {
                _loadWindow(_windowStart + (_document?.chapters.length ?? 0));
              }
            },
            itemBuilder: (BuildContext context, int page) {
              // 页边界来自 `_pageStarts`（按章节分页），不是 page*perPage
              if (page < 0 || page >= _pageStarts.length) {
                return const SizedBox.shrink();
              }
              final int from = _pageStarts[page];
              final int to = page + 1 < _pageStarts.length
                  ? _pageStarts[page + 1]
                  : _blocks.length;
              if (from >= _blocks.length || from >= to) {
                return const SizedBox.shrink();
              }
              return _pageView(theme, _blocks.sublist(from, to));
            },
          ),
        ),
        _bottomBar(theme),
      ],
    );
  }

  /// 一页的内容（段落按页切开，与本地阅读器一致）
  Widget _pageView(ThemeData theme, List<_Block> blocks) {
    // 朗读高亮：跟着 TTS 游标走（用户要求「正文朗读到哪要显示高亮文本框」）。
    // 用 ListenableBuilder 只重建这一页，不触发整页 setState。
    return ListenableBuilder(
      listenable: TtsManager.instance,
      builder: (BuildContext context, Widget? _) {
        final TtsManager tts = TtsManager.instance;
        final bool highlight = tts.holdsDocument(widget.book.url);
        final (int, int, int) cursor = tts.cursor;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final _Block b in blocks) ...<Widget>[
                if (b.showChapterTitle)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 10),
                    child: Text(b.title, style: theme.textTheme.titleSmall),
                  ),
                InkWell(
                  onTap: () => _speakAt(b),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _paragraphBody(
                      theme,
                      b,
                      active: highlight &&
                          cursor.$1 == b.chapter &&
                          cursor.$2 == b.paragraph,
                      activeSentence: cursor.$3,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// 给某段第 [sentence] 句取一个点击识别器（复用，避免每帧新建泄漏）
  TapGestureRecognizer _tapFor(_Block block, int sentence) {
    final String key = '${block.chapter}:${block.paragraph}:$sentence';
    return _sentenceTaps.putIfAbsent(
      key,
      () => TapGestureRecognizer()
        ..onTap = () => _speakAt(block, sentence: sentence),
    );
  }

  /// 一段正文：朗读中的段落套高亮框，其中**当前那句**再有底色
  ///
  /// 为什么精确到句：只框整段太粗，用户看不出读到哪一行；
  /// 而整句高亮与本地阅读器的行为一致（那边也是句子级）。
  Widget _paragraphBody(
    ThemeData theme,
    _Block block, {
    required bool active,
    required int activeSentence,
  }) {
    final TextStyle base = theme.textTheme.bodyLarge?.copyWith(height: 1.7) ??
        const TextStyle(height: 1.7);

    // 句子切开：优先用文档里的句子结构，拿不到就整段当一句
    List<String> sentences = const <String>[];
    final StructuredDocument? doc = _document;
    if (doc != null &&
        block.chapter < doc.chapters.length &&
        block.paragraph < doc.chapters[block.chapter].paragraphs.length) {
      sentences = doc.chapters[block.chapter].paragraphs[block.paragraph]
          .sentences
          .map((Sentence s) => s.text)
          .toList();
    }
    if (sentences.isEmpty) sentences = <String>[block.text];

    final ColorScheme scheme = theme.colorScheme;
    final List<InlineSpan> spans = <InlineSpan>[];
    for (var i = 0; i < sentences.length; i++) {
      final bool lit = active && i == activeSentence;
      spans.add(
        TextSpan(
          text: sentences[i],
          // ★句子可点：点哪句就从那句开始读（用户要求「页面句子要可点击切换」）
          recognizer: _tapFor(block, i),
          style: base.copyWith(
            backgroundColor: lit ? scheme.primary.withAlpha(72) : null,
            color: lit ? scheme.onSurface : null,
            fontWeight: lit ? FontWeight.w600 : null,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        // 朗读中的段落给一圈淡边框，像本地阅读器的"高亮文本框"
        border: active
            ? Border.all(color: scheme.primary.withAlpha(140), width: 1.2)
            : null,
        color: active ? scheme.primary.withAlpha(15) : null,
      ),
      child: Text.rich(TextSpan(children: spans)),
    );
  }

  Widget _bottomBar(ThemeData theme) {
    final TtsManager tts = TtsManager.instance;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '第 ${_pageIndex + 1} / $_pageCount 页 · '
                '第 ${_windowStart + 1}–${_windowStart + (_document?.chapters.length ?? 0)} 章 / '
                '共 ${_chapters.length} 章',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            // 顺序：上一句 → 播放/暂停 → 下一句（用户要求：暂停夹在快退快进中间）
            IconButton(
              key: const ValueKey<String>('online-prev-sentence'),
              tooltip: '上一句',
              icon: const Icon(Icons.skip_previous),
              onPressed: () => tts.skipSentenceBackward(),
            ),
            IconButton(
              key: const ValueKey<String>('online-play-pause'),
              tooltip: tts.playing ? '暂停' : '继续朗读',
              icon: Icon(tts.playing ? Icons.pause : Icons.play_arrow),
              onPressed: () {
                if (tts.playing) {
                  tts.pause();
                } else if (_blocks.isNotEmpty) {
                  // 从当前页第一段开始（页边界按章节算，不能用 pageIndex*perPage）
                  final int from = _pageStarts.isEmpty
                      ? 0
                      : _pageStarts[_pageIndex.clamp(0, _pageStarts.length - 1)];
                  final _Block b = _blocks[from.clamp(0, _blocks.length - 1)];
                  _speakAt(b);
                }
              },
            ),
            IconButton(
              key: const ValueKey<String>('online-next-sentence'),
              tooltip: '下一句',
              icon: const Icon(Icons.skip_next),
              onPressed: () => tts.skipSentenceForward(),
            ),
            IconButton(
              tooltip: '停止朗读',
              icon: const Icon(Icons.stop),
              onPressed: () => tts.stopByUser(),
            ),
          ],
        ),
      ),
    );
  }

  /// 点某一段 → 从那里开始读
  ///
  /// 文档**已经在读**时只调 `speakFrom`，不再整份 `loadDocument`：
  /// 每次点都重绑文档会白白走一遍「换文档」的收尾（真机日志里每点一次
  /// 就出现一条 `位置[载入文档]`，纯属浪费，还可能闪一下状态）。
  void _speakAt(_Block block, {int sentence = 0}) {
    final StructuredDocument? doc = _document;
    if (doc == null || doc.isEmpty) return;
    final TtsManager tts = TtsManager.instance;
    if (!tts.holdsDocument(widget.book.url)) {
      tts.loadDocument(
        doc,
        at: (block.chapter, block.paragraph, sentence),
        title: widget.book.name,
        documentId: widget.book.url,
      );
    }
    tts.speakFrom(block.chapter, block.paragraph, sentence);
  }

  Future<void> _showToc() async {
    final int? pick = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (BuildContext ctx, ScrollController controller) =>
            ListView.builder(
              controller: controller,
              itemCount: _chapters.length,
              itemBuilder: (BuildContext ctx, int i) {
                final OnlineChapter c = _chapters[i];
                final int windowLen = _document?.chapters.length ?? 0;
                final bool inWindow =
                    i >= _windowStart && i < _windowStart + windowLen;
                return ListTile(
                  dense: true,
                  leading: Text('${i + 1}'),
                  title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  // 目录里标出这一章从第几页开始（分页按章节，页码是确定的）
                  trailing: inWindow
                      ? Text(
                          'P${(_pageOfChapter(i - _windowStart) + 1).clamp(1, 99999)}',
                          style: Theme.of(ctx).textTheme.bodySmall,
                        )
                      : null,
                  onTap: () => Navigator.pop(ctx, i),
                );
              },
            ),
      ),
    );
    if (pick == null || !mounted) return;
    // 目录只**跳转**，不开始朗读（用户明确要求：点了就跳，不要读）
    await _jumpToChapter(pick);
  }

  /// 跳到某一章的第一页（**不朗读**）
  ///
  /// 两种情形：
  /// * 目标在本窗内 → 直接翻页；
  /// * 不在本窗 → 先装这一窗，装完再翻（原来这里直接 `jumpToPage`，
  ///   但那一章还没在 `_blocks` 里，`indexWhere` 返回 -1，于是「跳到 0 页」——
  ///   用户看到的正是「目录点了没跳到正确位置」）。
  Future<void> _jumpToChapter(int globalChapter) async {
    final int windowLen = _document?.chapters.length ?? 0;
    final bool inWindow =
        globalChapter >= _windowStart && globalChapter < _windowStart + windowLen;

    if (!inWindow) {
      await _loadWindow(globalChapter);
      if (!mounted) return;
    }

    final int local = globalChapter - _windowStart;
    final int page = _pageOfChapter(local);
    if (page < 0) return;
    if (_pageController.hasClients) {
      _pageController.jumpToPage(page);
    }
    setState(() => _pageIndex = page);
  }
}

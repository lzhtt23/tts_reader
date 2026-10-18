import 'dart:async';

import 'package:flutter/material.dart';

import '../models/source_rule.dart';
import '../services/book_merge.dart';
import '../services/legado_source_store.dart';
import '../services/online_book_downloader.dart';
import '../services/source_client.dart';
import 'legado_read_page.dart';

/// 书籍详情页（对齐阅读 App 的样式）
///
/// ## 版式（用户给的参考图）
///
/// ```
/// ┌──────────────────────────────┐
/// │  [大封面]   书名（可两行）      │
/// │             👤 作者            │
/// │             🌐 来源            │
/// │                              │
/// │  [8.7万字] [分类] [已完结]     │   ← 标签行
/// │                              │
/// │  ♡      ☰      🏷      ⟳      │   ← 四个操作
/// │ 放入书架 查看目录  书源   下载   │
/// │                              │
/// │ 简介正文…                     │
/// │                        [阅读] │   ← 右下角
/// └──────────────────────────────┘
/// ```
///
/// ## 三个「写入」动作的语义（**别合并**）
///
/// | 动作 | 做什么 | 落点 |
/// | --- | --- | --- |
/// | 下载 | 拉全部章节 → 拼 TXT → adopt → upsertDocument | 本地文档库 |
/// | 放入书架 | 只写 `OnlineBookRecord`，不抓正文 | 在线书架 |
/// | 阅读 | 进 `LegadoReadPage`，按窗抓 | 不落盘 |
///
/// 合并掉任何两个都会让常见意图没地方表达（比如「先收藏、以后再下」）。
class BookIntroPage extends StatefulWidget {
  const BookIntroPage({super.key, required this.source, required this.book});

  final SourceRule source;
  final OnlineBook book;

  /// 「下载」
  static const Key downloadKey = ValueKey<String>('intro-download');

  /// 「放入书架」
  static const Key shelfKey = ValueKey<String>('intro-shelf');

  /// 「查看目录」
  static const Key tocKey = ValueKey<String>('intro-toc');

  /// 「阅读」
  static const Key readKey = ValueKey<String>('intro-read');

  @override
  State<BookIntroPage> createState() => _BookIntroPageState();
}

class _BookIntroPageState extends State<BookIntroPage> {
  late final SourceClient _client = SourceClient(rule: widget.source);

  late String _intro = widget.book.intro;
  late String _coverUrl = widget.book.coverUrl;
  late String _author = widget.book.author;

  bool _loadingIntro = true;
  bool _downloading = false;
  int? _downloadDone;
  int? _downloadTotal;
  bool _inShelf = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadIntro());
    unawaited(_loadShelfState());
  }

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }

  Future<void> _loadShelfState() async {
    final List<OnlineBookRecord> books =
        await LegadoSourceStore.instance.loadBooks();
    if (!mounted) return;
    setState(() {
      _inShelf = books.any((OnlineBookRecord b) => b.url == widget.book.url);
    });
  }

  /// 异步补详情页（简介 / 封面 / 作者）
  ///
  /// `ruleSearch` 里通常没有简介，只有详情页才有；补失败就只显示已有字段，
  /// **不阻塞任何操作**。
  Future<void> _loadIntro() async {
    try {
      final OnlineBook detail = await _client.bookInfo(widget.book.url);
      if (!mounted) return;
      setState(() {
        if (detail.intro.trim().isNotEmpty) _intro = detail.intro.trim();
        if (detail.coverUrl.trim().isNotEmpty) _coverUrl = detail.coverUrl.trim();
        if (detail.author.trim().isNotEmpty) _author = detail.author.trim();
        _loadingIntro = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingIntro = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: BookIntroPage.readKey,
        onPressed: _downloading ? null : _read,
        icon: const Icon(Icons.menu_book),
        label: const Text('阅读'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: <Widget>[
          _header(theme),
          const SizedBox(height: 14),
          _tagRow(theme),
          const SizedBox(height: 6),
          _actions(theme),
          const Divider(height: 28),
          if (_downloading) ...<Widget>[_progressBar(theme), const SizedBox(height: 16)],
          _introSection(theme),
        ],
      ),
    );
  }

  /// 大封面 + 书名 + 作者 + 来源
  Widget _header(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _cover(theme),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SizedBox(height: 4),
              Text(
                widget.book.name,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              if (_author.trim().isNotEmpty)
                _metaRow(theme, Icons.person_outline, _author.trim()),
              const SizedBox(height: 6),
              _metaRow(
                theme,
                Icons.public,
                widget.source.displayName,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _metaRow(ThemeData theme, IconData icon, String text) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _cover(ThemeData theme) {
    const double w = 108;
    const double h = 148;
    final Widget placeholder = Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surfaceContainerHighest,
      ),
      child: Icon(Icons.menu_book, size: 40, color: theme.colorScheme.outline),
    );
    final String raw = _coverUrl.trim();
    if (raw.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        raw,
        width: w,
        height: h,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => placeholder,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : placeholder,
      ),
    );
  }

  /// 标签行：分类 / 最新章 / 停用状态
  Widget _tagRow(ThemeData theme) {
    final List<String> tags = <String>[
      if (widget.book.kind.trim().isNotEmpty) widget.book.kind.trim(),
      if (widget.book.lastChapter.trim().isNotEmpty)
        '最新：${widget.book.lastChapter.trim()}',
    ];
    if (tags.isEmpty) return const SizedBox.shrink();
    final ColorScheme scheme = theme.colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final String t in tags)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              t,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  /// 四个操作：放入书架 / 查看目录 / 书源 / 下载
  Widget _actions(ThemeData theme) {
    return Row(
      children: <Widget>[
        Expanded(
          child: _action(
            theme,
            key: BookIntroPage.shelfKey,
            icon: _inShelf ? Icons.favorite : Icons.favorite_border,
            label: _inShelf ? '已在书架' : '放入书架',
            onTap: _inShelf || _downloading ? null : _addToShelf,
          ),
        ),
        Expanded(
          child: _action(
            theme,
            key: BookIntroPage.tocKey,
            icon: Icons.format_list_bulleted,
            label: '查看目录',
            onTap: _downloading ? null : _showToc,
          ),
        ),
        Expanded(
          child: _action(
            theme,
            icon: Icons.layers_outlined,
            label: '书源',
            onTap: _switchSource,
          ),
        ),
        Expanded(
          child: _action(
            theme,
            key: BookIntroPage.downloadKey,
            icon: Icons.download_outlined,
            label: _downloading ? '下载中' : '下载',
            onTap: _downloading ? null : _download,
          ),
        ),
      ],
    );
  }

  Widget _action(
    ThemeData theme, {
    Key? key,
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    final ColorScheme scheme = theme.colorScheme;
    final Color tint = onTap == null ? scheme.outline : scheme.onSurface;
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          children: <Widget>[
            Icon(icon, size: 22, color: tint),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: tint),
            ),
          ],
        ),
      ),
    );
  }

  Widget _progressBar(ThemeData theme) {
    final int total = _downloadTotal ?? 0;
    final int done = _downloadDone ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        LinearProgressIndicator(
          value: total <= 0 ? null : (done / total).clamp(0.0, 1.0),
        ),
        const SizedBox(height: 4),
        Text(
          total <= 0 ? '正在取目录…' : '已下载 $done / $total 章',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _introSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('简介', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        if (_loadingIntro)
          Row(
            children: <Widget>[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text('正在补简介…', style: theme.textTheme.bodySmall),
            ],
          )
        else if (_intro.trim().isEmpty)
          Text('这个书源没给简介', style: theme.textTheme.bodySmall)
        else
          Text(
            _intro.trim(),
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
          ),
      ],
    );
  }

  /// 查看目录：先取目录，列成底部弹层；点某章直接进阅读
  Future<void> _showToc() async {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _TocSheet(
        client: _client,
        book: widget.book,
        onOpenChapter: (int index) {
          Navigator.of(sheetContext).pop();
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => LegadoReadPage(
                source: widget.source,
                book: widget.book,
                initialChapter: index,
              ),
            ),
          );
        },
      ),
    );
  }

  /// 换源：在**其它已启用书源**里找同一本书，选中后换成那个源
  ///
  /// 为什么要这个：一个源缺简介 / 章节不全 / 正文乱码时，用户想的是
  /// 「换一个源读这本」，而不是去看一段 URL。这里直接用书名去各源搜，
  /// 取名字相同（去空白后）的条目；点一条就替换当前页。
  Future<void> _switchSource() async {
    final List<SourceRule> all = await LegadoSourceStore.instance.load();
    final List<SourceRule> others = all
        .where((SourceRule r) => r.isSupported && r.enabled && r.url != widget.source.url)
        .toList();
    if (!mounted) return;
    if (others.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有其它已启用的书源可换')),
      );
      return;
    }

    final _SwitchHit? picked = await showModalBottomSheet<_SwitchHit>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _SwitchSourceSheet(
        currentSourceUrl: widget.source.url,
        bookName: widget.book.name,
        sources: others,
      ),
    );
    if (!mounted || picked == null) return;

    // 换源＝换一本"同名的另一条记录"：重开详情页，让简介/封面/目录都按新源取
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => BookIntroPage(source: picked.source, book: picked.book),
      ),
    );
  }

  Future<void> _addToShelf() async {
    await LegadoSourceStore.instance.upsertBook(
      OnlineBookRecord(
        url: widget.book.url,
        name: widget.book.name,
        sourceUrl: widget.source.url,
        author: _author,
        coverUrl: _coverUrl,
        chapterName: widget.book.lastChapter,
        addedAt: DateTime.now(),
      ),
    );
    if (!mounted) return;
    setState(() => _inShelf = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已放入在线书架')),
    );
  }

  /// 下载：拉全部章节 → 拼 TXT → 收进书库 → 入库
  ///
  /// ⚠️ 拼接必须写「第N章 章节名」标题行，否则 `TxtChapterSplitter` 认不出分章，
  /// 整本会变成一章 —— 朗读目录功能就失效了。
  /// 下载：**就在本页做完**（用户要求不改队列），同时登记到「下载列表」
  ///
  /// 抓章逻辑统一在 [OnlineBookDownloader]，与在线书架那个下载键共用一份。
  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _downloadDone = 0;
      _downloadTotal = 0;
    });
    try {
      await OnlineBookDownloader.download(
        source: widget.source,
        book: widget.book,
        onProgress: (int done, int total) {
          if (!mounted) return;
          setState(() {
            _downloadDone = done;
            _downloadTotal = total;
          });
        },
      );
      if (!mounted) return;
      setState(() => _downloading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已下载 $_downloadDone 章，加入文档库'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _downloading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败：$e')),
      );
    }
  }

  Future<void> _read() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LegadoReadPage(
          source: widget.source,
          book: widget.book,
        ),
      ),
    );
  }
}

/// 目录弹层
class _TocSheet extends StatefulWidget {
  const _TocSheet({
    required this.client,
    required this.book,
    required this.onOpenChapter,
  });

  final SourceClient client;
  final OnlineBook book;
  final void Function(int index) onOpenChapter;

  @override
  State<_TocSheet> createState() => _TocSheetState();
}

class _TocSheetState extends State<_TocSheet> {
  List<OnlineChapter> _chapters = const <OnlineChapter>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<OnlineChapter> toc = await widget.client.toc(widget.book.url);
      if (!mounted) return;
      setState(() {
        _chapters = toc;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _loading
                          ? '目录'
                          : '目录（${_chapters.length} 章）',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: _loading ? null : _load,
                    icon: const Icon(Icons.refresh),
                    tooltip: '刷新目录',
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _body(theme)),
          ],
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('取目录失败', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              FilledButton.tonal(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_chapters.isEmpty) {
      return const Center(child: Text('目录是空的'));
    }
    return ListView.separated(
      itemCount: _chapters.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) => ListTile(
        dense: true,
        title: Text(
          _chapters[index].name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => widget.onOpenChapter(index),
      ),
    );
  }
}

/// 换源命中：某本书在某个源里
class _SwitchHit {
  const _SwitchHit(this.source, this.book);

  final SourceRule source;
  final OnlineBook book;
}

/// 换源弹层：在其它源里搜同名书，让用户挑一个
///
/// 搜的是**书名**，保留「名字互相包含」的条目：
/// 《钢铁是怎样炼成的》要能匹配到《钢铁是怎样炼成的（学生读本）》，
/// 但不能匹配到《飞刀是怎样炼成的》。
class _SwitchSourceSheet extends StatefulWidget {
  const _SwitchSourceSheet({
    required this.currentSourceUrl,
    required this.bookName,
    required this.sources,
  });

  final String currentSourceUrl;
  final String bookName;
  final List<SourceRule> sources;

  @override
  State<_SwitchSourceSheet> createState() => _SwitchSourceSheetState();
}

class _SwitchSourceSheetState extends State<_SwitchSourceSheet> {
  List<_SwitchHit> _hits = const <_SwitchHit>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  Future<void> _search() async {
    final String want = mergeKey(widget.bookName);
    final List<_SwitchHit> hits = <_SwitchHit>[];

    await Future.wait(
      widget.sources.map((SourceRule source) async {
        final SourceClient client = SourceClient(rule: source);
        try {
          final List<OnlineBook> books = await client.search(widget.bookName);
          for (final OnlineBook b in books) {
            final String got = mergeKey(b.name);
            if (got == want || got.contains(want) || want.contains(got)) {
              hits.add(_SwitchHit(source, b));
            }
          }
        } catch (_) {
          // 单个源失败不影响其它源
        } finally {
          client.dispose();
        }
      }),
    );

    if (!mounted) return;
    setState(() {
      _hits = hits;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _loading
                          ? '正在其它书源里找同名书…'
                          : '选一个书源（${_hits.length} 个）',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _body(theme)),
          ],
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_hits.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('其它书源里没找到这本', style: theme.textTheme.bodyMedium),
        ),
      );
    }
    return ListView.separated(
      itemCount: _hits.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final _SwitchHit hit = _hits[index];
        return ListTile(
          title: Text(
            hit.source.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            <String>[
              hit.book.name,
              if (hit.book.lastChapter.trim().isNotEmpty)
                '最新：${hit.book.lastChapter.trim()}',
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          onTap: () => Navigator.of(context).pop(hit),
        );
      },
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/source_rule.dart';
import '../services/book_merge.dart';
import '../services/legado_source_store.dart';
import '../services/source_client.dart';
import '../widgets/wavy_progress.dart';
import 'book_intro_page.dart';

/// 搜索结果页
///
/// ## 三个设计点（都来自实际使用反馈）
///
/// 1. **顶部就是搜索框**，不是纯文字标题 —— 进了结果页还能直接改词重搜，
///    不用退回发现页。
/// 2. 右上角是**筛选**：决定这次搜哪几个书源（几十个源全并发既慢又吵）。
/// 3. 结果**按书名聚合**：同一本书在 21 个源里都命中时，应当显示成一条，
///    点开再选源；并按**名字匹配度**排序 —— 搜「钢铁是怎样炼成的」，
///    《飞刀是怎样炼成的》不该排在正主前面。
class SearchResultsPage extends StatefulWidget {
  const SearchResultsPage({
    super.key,
    required this.keyword,
    required this.sources,
    this.exactMatch = false,
  });

  final String keyword;
  final List<SourceRule> sources;

  /// 精准搜索：只保留书名**包含完整关键词**的条目
  ///
  /// 关掉时会连「只有部分字相同」的书一起列出来（更像模糊搜）。
  final bool exactMatch;

  /// 搜索框
  static const Key searchFieldKey = ValueKey<String>('search-results-field');

  /// 书源筛选
  static const Key filterKey = ValueKey<String>('search-results-filter');

  /// 刷新
  static const Key refreshKey = ValueKey<String>('search-results-refresh');

  @override
  State<SearchResultsPage> createState() => _SearchResultsPageState();
}

class _SearchResultsPageState extends State<SearchResultsPage> {
  late final TextEditingController _input =
      TextEditingController(text: widget.keyword);

  /// 本次参与搜索的源（筛选可改）
  late Set<String> _active = <String>{
    for (final SourceRule s in widget.sources) s.url,
  };

  final Map<String, _SourceResult> _results = <String, _SourceResult>{};
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  List<SourceRule> get _activeSources => widget.sources
      .where((SourceRule s) => _active.contains(s.url))
      .toList();

  Future<void> _search() async {
    final String keyword = _input.text.trim();
    if (keyword.isEmpty) return;
    final List<SourceRule> sources = _activeSources;
    if (sources.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先点右上角筛选，选至少一个书源')),
      );
      return;
    }

    setState(() {
      _searching = true;
      _results
        ..clear()
        ..addEntries(
          sources.map(
            (SourceRule s) => MapEntry<String, _SourceResult>(
              s.url,
              const _SourceResult.loading(),
            ),
          ),
        );
    });

    await Future.wait(
      sources.map((SourceRule source) async {
        final SourceClient client = SourceClient(rule: source);
        try {
          final List<OnlineBook> books = await client.search(keyword);
          if (!mounted) return;
          setState(() => _results[source.url] = _SourceResult.done(books));
        } catch (e) {
          if (!mounted) return;
          setState(() => _results[source.url] = _SourceResult.failed('$e'));
        } finally {
          client.dispose();
        }
      }),
    );

    if (mounted) setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _searchField(),
        actions: <Widget>[
          IconButton(
            key: SearchResultsPage.filterKey,
            tooltip: '筛选书源',
            onPressed: _searching ? null : _showFilter,
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            key: SearchResultsPage.refreshKey,
            tooltip: '重新搜索',
            onPressed: _searching ? null : _search,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _body(),
    );
  }

  /// 顶部搜索框（AppBar 里）
  Widget _searchField() {
    return TextField(
      key: SearchResultsPage.searchFieldKey,
      controller: _input,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _search(),
      decoration: InputDecoration(
        isDense: true,
        hintText: '搜索书名 / 作者',
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: _input.text.isEmpty
            ? null
            : IconButton(
                tooltip: '清空',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  _input.clear();
                  setState(() {});
                },
              ),
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  // ---------------- 结果聚合 ----------------

  /// 把「每源一堆书」聚成「一本书 + 它出现在哪些源」
  List<_MergedBook> _merged(String keyword) {
    final Map<String, _MergedBook> byKey = <String, _MergedBook>{};
    for (final MapEntry<String, _SourceResult> entry in _results.entries) {
      final List<OnlineBook>? books = entry.value.books;
      if (books == null) continue;
      final SourceRule source = _sourceOf(entry.key);
      for (final OnlineBook book in books) {
        final String key = _norm(book.name);
        if (key.isEmpty) continue;
        final _MergedBook? existing = byKey[key];
        if (existing == null) {
          byKey[key] = _MergedBook(book: book, hits: <_Hit>[_Hit(source, book)]);
        } else {
          existing.hits.add(_Hit(source, book));
          existing.absorb(book);
        }
      }
    }
    final List<_MergedBook> out = byKey.values.toList();
    for (final _MergedBook b in out) {
      b.score = nameMatchScore(keyword, b.book.name);
    }
    // 精准搜索：只留书名里**包含完整关键词**的（滤掉「只有个别字相同」的噪音）
    final List<_MergedBook> filtered = widget.exactMatch
        ? out.where((_MergedBook b) => mergeKey(b.book.name).contains(mergeKey(keyword))).toList()
        : out;
    // 匹配度高的靠前；同分时源多的靠前；再同就按名字
    filtered.sort((_MergedBook a, _MergedBook b) => compareByScoreThenCountThenName(
      scoreA: a.score,
      scoreB: b.score,
      countA: a.hits.length,
      countB: b.hits.length,
      nameA: a.book.name,
      nameB: b.book.name,
    ));
    return filtered;
  }

  /// 聚合键：去掉空白、统一大小写（书名里的空格/换行不该造成重复条目）
  static String _norm(String name) => mergeKey(name);


  SourceRule _sourceOf(String url) => widget.sources.firstWhere(
    (SourceRule r) => r.url == url,
    orElse: () => widget.sources.first,
  );

  Widget _body() {
    final ThemeData theme = Theme.of(context);
    final String keyword = _input.text.trim();
    final List<_MergedBook> merged = _merged(keyword);
    final int failed = _results.values.where((_SourceResult r) => r.error != null).length;

    if (merged.isEmpty && _searching) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 聚合搜索加载：MD3 波浪进度
              LinearWavyProgressIndicator(
                semanticsLabel: '正在 ${_active.length} 个书源里找',
              ),
              const SizedBox(height: 14),
              Text(
                '正在 ${_active.length} 个书源里找…',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }

    if (merged.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.search_off, size: 56, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text(
                failed == 0 ? '没有搜到' : '全部 $failed 个书源都失败了',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                failed == 0 ? '换个关键词，或点右上角筛选更多书源' : '可能是网络问题，也可能是书源失效',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: _search,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: merged.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              _searching
                  ? '共 ${merged.length} 本 · 还在等其它书源…'
                  : '共 ${merged.length} 本 · ${_active.length} 个书源',
              style: theme.textTheme.bodySmall,
            ),
          );
        }
        return _mergedTile(merged[index - 1]);
      },
    );
  }

  Widget _mergedTile(_MergedBook item) {
    final ThemeData theme = Theme.of(context);
    final OnlineBook book = item.book;
    final String author = book.author.trim();
    final String intro = book.intro.trim();

    return Card.filled(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _pickSource(item),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _cover(book.coverUrl, theme),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      book.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    if (author.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    if (intro.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        '简介：$intro',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: <Widget>[
                        _tag(theme, '${item.hits.length} 个书源'),
                        if (book.lastChapter.trim().isNotEmpty)
                          _tag(theme, '最新：${book.lastChapter.trim()}', subtle: true),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tag(ThemeData theme, String text, {bool subtle = false}) {
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: subtle ? scheme.surfaceContainerHighest : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: subtle ? scheme.onSurfaceVariant : scheme.onSecondaryContainer,
        ),
      ),
    );
  }

  Widget _cover(String url, ThemeData theme) {
    const double w = 64;
    const double h = 88;
    final Widget placeholder = Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: theme.colorScheme.surfaceContainerHighest,
      ),
      child: Icon(Icons.menu_book, size: 26, color: theme.colorScheme.outline),
    );
    final String raw = url.trim();
    if (raw.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
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

  /// 这本书在多个源里都有：让用户挑一个源再进详情
  Future<void> _pickSource(_MergedBook item) async {
    if (item.hits.length == 1) {
      await _openIntro(item.hits.single.source, item.hits.single.book);
      return;
    }
    final _Hit? picked = await showModalBottomSheet<_Hit>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '选一个书源（${item.hits.length} 个）',
                      style: Theme.of(sheetContext).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: item.hits.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final _Hit hit = item.hits[index];
                  return ListTile(
                    dense: true,
                    title: Text(
                      hit.source.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: hit.book.lastChapter.trim().isEmpty
                        ? null
                        : Text(
                            '最新：${hit.book.lastChapter.trim()}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    onTap: () => Navigator.of(sheetContext).pop(hit),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) return;
    await _openIntro(picked.source, picked.book);
  }

  Future<void> _openIntro(SourceRule source, OnlineBook book) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookIntroPage(source: source, book: book),
      ),
    );
  }

  /// 筛选：勾选这次用哪些书源
  Future<void> _showFilter() async {
    final Set<String> draft = <String>{..._active};
    final bool? ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '筛选书源（${draft.length}/${widget.sources.length}）',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: () => setSheetState(() {
                        if (draft.length == widget.sources.length) {
                          draft.clear();
                        } else {
                          draft
                            ..clear()
                            ..addAll(widget.sources.map((SourceRule s) => s.url));
                        }
                      }),
                      child: Text(
                        draft.length == widget.sources.length ? '取消全选' : '全选',
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.sources.length,
                  itemBuilder: (context, index) {
                    final SourceRule s = widget.sources[index];
                    return CheckboxListTile(
                      dense: true,
                      value: draft.contains(s.url),
                      title: Text(
                        s.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: (s.group ?? '').trim().isEmpty
                          ? null
                          : Text(s.group!.trim()),
                      onChanged: (bool? on) => setSheetState(() {
                        if (on == true) {
                          draft.add(s.url);
                        } else {
                          draft.remove(s.url);
                        }
                      }),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: <Widget>[
                    const Spacer(),
                    OutlinedButton(
                      onPressed: () => Navigator.of(sheetContext).pop(false),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: draft.isEmpty
                          ? null
                          : () => Navigator.of(sheetContext).pop(true),
                      child: const Text('用这些书源搜索'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || ok != true) return;
    setState(() {
      _active = draft;
    });
    // 用户要求：筛选结果**同步到书源库**（以后搜书也按这个来）
    await _persistEnabled(draft);
    if (!mounted) return;
    await _search();
  }

  /// 把「这次只用哪些源」写回书源库的 `enabled`
  ///
  /// 只改本页列出过的这些源（`widget.sources`），其它源（不支持的、别处导入的）不动。
  Future<void> _persistEnabled(Set<String> enabledUrls) async {
    final List<SourceRule> all = await LegadoSourceStore.instance.load();
    var changed = 0;
    final List<SourceRule> updated = <SourceRule>[
      for (final SourceRule r in all)
        if (widget.sources.any((SourceRule s) => s.url == r.url))
          () {
            final bool want = enabledUrls.contains(r.url);
            if (r.enabled == want) return r;
            changed++;
            return r.copyWith(enabled: want);
          }()
        else
          r,
    ];
    if (changed == 0) return;
    await LegadoSourceStore.instance.saveAll(updated);
  }
}

/// 聚合后的一本书
class _MergedBook {
  _MergedBook({required this.book, required this.hits});

  /// 展示用的那本（取信息最全的一本）
  OnlineBook book;
  final List<_Hit> hits;
  int score = 0;

  /// 合并时把更完整的字段补进来（有的源没作者、有的没简介）
  void absorb(OnlineBook other) {
    if (book.author.trim().isEmpty && other.author.trim().isNotEmpty) {
      book = OnlineBook(
        name: book.name,
        url: book.url,
        author: other.author,
        coverUrl: book.coverUrl,
        intro: book.intro,
        lastChapter: book.lastChapter,
        kind: book.kind,
      );
    }
  }
}

/// 一条命中：某本书在某源里
class _Hit {
  const _Hit(this.source, this.book);

  final SourceRule source;
  final OnlineBook book;
}

/// 单个源的搜索状态
class _SourceResult {
  const _SourceResult.loading()
    : loading = true,
      books = null,
      error = null;

  const _SourceResult.done(this.books) : loading = false, error = null;

  const _SourceResult.failed(this.error) : loading = false, books = null;

  final bool loading;
  final List<OnlineBook>? books;
  final String? error;
}

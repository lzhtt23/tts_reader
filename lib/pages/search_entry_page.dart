import 'dart:async';

import 'package:flutter/material.dart';

import '../models/source_rule.dart';
import '../services/legado_source_store.dart';
import '../services/search_history.dart';
import 'search_results_page.dart';

/// 搜索入口页（对齐阅读 App 的搜索页）
///
/// ## 版式
///
/// ```
/// ←  [搜索书名、作者            ]
/// ────────────────────────────
/// [精准搜索] [全部书源]        ← 两个 chip
/// 搜索历史            [删除所有]
/// 国家与革命                ✕
/// 黎明之剑                  ✕
/// …
/// ```
///
/// ## 为什么要有独立入口页
///
/// 搜索结果页需要「关键词 + 用哪些源 + 精不精准」三个输入才能开始搜。
/// 如果都塞在发现页，用户每次都要在发现页里先勾一堆东西；
/// 单独一页还能把**搜索历史**放出来（发现页那个搜索框放不下）。
class SearchEntryPage extends StatefulWidget {
  const SearchEntryPage({super.key, this.initialKeyword = ''});

  final String initialKeyword;

  /// 搜索框
  static const Key fieldKey = ValueKey<String>('search-entry-field');

  /// 「精准搜索」chip
  static const Key exactKey = ValueKey<String>('search-entry-exact');

  /// 「全部书源」chip
  static const Key sourcesKey = ValueKey<String>('search-entry-sources');

  /// 「删除所有」历史
  static const Key clearHistoryKey = ValueKey<String>('search-entry-clear-history');

  @override
  State<SearchEntryPage> createState() => _SearchEntryPageState();
}

class _SearchEntryPageState extends State<SearchEntryPage> {
  late final TextEditingController _input =
      TextEditingController(text: widget.initialKeyword);

  final FocusNode _focus = FocusNode();

  /// 精准搜索：只显示书名**包含完整关键词**的条目
  bool _exact = false;

  /// 全部可用书源
  List<SourceRule> _sources = const <SourceRule>[];

  /// 本次参与搜索的源
  Set<String> _active = <String>{};

  List<String> _history = const <String>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    // 进来就能直接打字
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final List<SourceRule> all = await LegadoSourceStore.instance.load();
    final List<SourceRule> usable = all
        .where((SourceRule r) => r.isSupported && r.enabled)
        .toList();
    final List<String> history = await SearchHistory.instance.load();
    if (!mounted) return;
    setState(() {
      _sources = usable;
      // 默认用全部已启用的源
      _active = <String>{for (final SourceRule r in usable) r.url};
      _history = history;
      _loading = false;
    });
  }

  Future<void> _search(String keyword) async {
    final String k = keyword.trim();
    if (k.isEmpty) return;
    final List<SourceRule> chosen = _sources
        .where((SourceRule s) => _active.contains(s.url))
        .toList();
    if (chosen.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先选至少一个书源（点「全部书源」）')),
      );
      return;
    }

    // 先记历史再跳：用户从结果页返回时历史已经是新的
    final List<String> next = await SearchHistory.instance.add(k);
    if (!mounted) return;
    setState(() => _history = next);

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchResultsPage(
          keyword: k,
          sources: chosen,
          exactMatch: _exact,
        ),
      ),
    );
    if (!mounted) return;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          key: SearchEntryPage.fieldKey,
          controller: _input,
          focusNode: _focus,
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
          decoration: const InputDecoration(
            hintText: '搜索书名、作者',
            border: InputBorder.none,
          ),
          style: theme.textTheme.titleMedium,
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '搜索',
            onPressed: () => _search(_input.text),
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Row(
                    children: <Widget>[
                      // 精准搜索
                      FilterChip(
                        key: SearchEntryPage.exactKey,
                        label: const Text('精准搜索'),
                        selected: _exact,
                        onSelected: (bool v) => setState(() => _exact = v),
                      ),
                      const SizedBox(width: 8),
                      // 全部书源
                      FilterChip(
                        key: SearchEntryPage.sourcesKey,
                        label: Text(
                          _active.length == _sources.length
                              ? '全部书源'
                              : '${_active.length}/${_sources.length} 个书源',
                        ),
                        selected: _active.length != _sources.length,
                        onSelected: (_) => _showSourceFilter(),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text('搜索历史', style: theme.textTheme.titleSmall),
                      ),
                      if (_history.isNotEmpty)
                        TextButton.icon(
                          key: SearchEntryPage.clearHistoryKey,
                          onPressed: _clearHistory,
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('删除所有'),
                        ),
                    ],
                  ),
                ),
                Expanded(child: _historyList(theme)),
              ],
            ),
    );
  }

  Widget _historyList(ThemeData theme) {
    if (_history.isEmpty) {
      return Center(
        child: Text('还没有搜索记录', style: theme.textTheme.bodySmall),
      );
    }
    return ListView.separated(
      itemCount: _history.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final String k = _history[index];
        return ListTile(
          title: Text(k, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => _removeHistory(k),
          ),
          onTap: () {
            _input.text = k;
            _search(k);
          },
        );
      },
    );
  }

  Future<void> _removeHistory(String keyword) async {
    final List<String> next = await SearchHistory.instance.remove(keyword);
    if (!mounted) return;
    setState(() => _history = next);
  }

  Future<void> _clearHistory() async {
    await SearchHistory.instance.clear();
    if (!mounted) return;
    setState(() => _history = const <String>[]);
  }

  /// 选书源（只影响本次搜索，不改书源库）
  Future<void> _showSourceFilter() async {
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
                        '选择书源（${draft.length}/${_sources.length}）',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: () => setSheetState(() {
                        if (draft.length == _sources.length) {
                          draft.clear();
                        } else {
                          draft
                            ..clear()
                            ..addAll(_sources.map((SourceRule s) => s.url));
                        }
                      }),
                      child: Text(
                        draft.length == _sources.length ? '取消全选' : '全选',
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _sources.length,
                  itemBuilder: (context, index) {
                    final SourceRule s = _sources[index];
                    return CheckboxListTile(
                      dense: true,
                      value: draft.contains(s.url),
                      title: Text(
                        s.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
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
                      child: const Text('确定'),
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
    setState(() => _active = draft);
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/source_rule.dart';
import '../services/source_client.dart';
import 'legado_read_page.dart';

/// 用 legado 书源搜书
///
/// 多源并发搜索：每个源一个 `SourceClient`，谁先返回先展示，
/// 单源失败只影响它自己（书源质量参差，一个源挂了不能让整页空着）。
class LegadoSearchPage extends StatefulWidget {
  const LegadoSearchPage({super.key, required this.sources});

  /// 可用书源（`isSupported == true`）
  final List<SourceRule> sources;

  @override
  State<LegadoSearchPage> createState() => _LegadoSearchPageState();
}

class _LegadoSearchPageState extends State<LegadoSearchPage> {
  final TextEditingController _keyword = TextEditingController();

  /// 每个源的状态：null=未搜，true=搜到，false=失败
  final Map<String, _SourceSearchState> _states = <String, _SourceSearchState>{};

  bool _searching = false;

  @override
  void initState() {
    super.initState();
    for (final SourceRule s in widget.sources) {
      _states[s.url] = const _SourceSearchState.loading();
    }
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final String key = _keyword.text.trim();
    if (key.isEmpty) return;

    setState(() {
      _searching = true;
      for (final SourceRule s in widget.sources) {
        _states[s.url] = const _SourceSearchState.loading();
      }
    });

    // 并发：不 await 单个源，谁回来先更新谁
    await Future.wait(
      widget.sources.map((SourceRule source) async {
        final SourceClient client = SourceClient(rule: source);
        try {
          final List<OnlineBook> books = await client.search(key);
          if (!mounted) return;
          setState(() {
            _states[source.url] = _SourceSearchState.done(books: books);
          });
        } catch (e) {
          if (!mounted) return;
          setState(() {
            _states[source.url] = _SourceSearchState.failed(
              reason: e.toString(),
            );
          });
        } finally {
          client.dispose();
        }
      }),
    );

    if (mounted) setState(() => _searching = false);
  }

  int get _totalBooks => _states.values
      .where((_SourceSearchState s) => s.books != null)
      .fold(0, (int sum, _SourceSearchState s) => sum + s.books!.length);

  int get _failedCount =>
      _states.values.where((_SourceSearchState s) => s.error != null).length;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('找书')),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _keyword,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      hintText: '书名或作者',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _searching ? null : _search,
                  child: Text(_searching ? '搜索中' : '搜索'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: <Widget>[
                Text(
                  '${widget.sources.length} 个书源'
                  '${_totalBooks > 0 ? ' · 找到 $_totalBooks 本' : ''}'
                  '${_failedCount > 0 ? ' · $_failedCount 个源失败' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: <Widget>[
                for (final SourceRule source in widget.sources)
                  _sourceSection(source),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sourceSection(SourceRule source) {
    final ThemeData theme = Theme.of(context);
    final _SourceSearchState state =
        _states[source.url] ?? const _SourceSearchState.loading();

    if (state.loading) {
      return Card.filled(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text(source.displayName),
          subtitle: const Text('搜索中…'),
        ),
      );
    }

    if (state.error != null) {
      return Card.filled(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
          title: Text(source.displayName),
          subtitle: Text(
            state.error!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }

    final List<OnlineBook> books = state.books ?? const <OnlineBook>[];
    if (books.isEmpty) {
      return Card.filled(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: const Icon(Icons.search_off),
          title: Text(source.displayName),
          subtitle: const Text('没有结果'),
        ),
      );
    }

    return Card.filled(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Text(
              '${source.displayName}（${books.length}）',
              style: theme.textTheme.titleSmall,
            ),
          ),
          for (final OnlineBook book in books)
            ListTile(
              dense: true,
              title: Text(
                book.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                <String>[
                  if (book.author.isNotEmpty) book.author,
                  if (book.lastChapter.isNotEmpty) '最新：${book.lastChapter}',
                  if (book.kind.isNotEmpty) book.kind,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openBook(source, book),
            ),
        ],
      ),
    );
  }

  Future<void> _openBook(SourceRule source, OnlineBook book) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LegadoReadPage(source: source, book: book),
      ),
    );
  }
}

/// 单个源的搜索结果状态
class _SourceSearchState {
  const _SourceSearchState.loading()
    : loading = true,
      books = null,
      error = null;

  const _SourceSearchState.done({required this.books})
    : loading = false,
      error = null;

  const _SourceSearchState.failed({required String reason})
    : loading = false,
      books = null,
      error = reason;

  final bool loading;
  final List<OnlineBook>? books;
  final String? error;
}

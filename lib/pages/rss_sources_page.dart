import 'dart:async';

import 'package:flutter/material.dart';

import '../models/rss_source.dart';
import '../services/rss_importer.dart';
import '../services/rss_store.dart';
import 'rss_articles_page.dart';

/// 订阅源管理：导入 / 启停 / 删除 / 进文章列表
///
/// 一期范围（按 `docs/v1.21.84-A一键导入与B订阅源-提示词.md`）：
/// 能导入、能列出文章。**不做**正文抓取、定时刷新、未读标记。
class RssSourcesPage extends StatefulWidget {
  const RssSourcesPage({super.key});

  /// 「导入订阅源」按钮
  static const Key importKey = ValueKey<String>('rss-import');

  @override
  State<RssSourcesPage> createState() => _RssSourcesPageState();
}

class _RssSourcesPageState extends State<RssSourcesPage> {
  List<RssSource> _sources = const <RssSource>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final List<RssSource> all = await RssStore.instance.load();
    if (!mounted) return;
    setState(() {
      _sources = all;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('订阅源'),
        actions: <Widget>[
          IconButton(
            key: RssSourcesPage.importKey,
            tooltip: '导入订阅源',
            onPressed: _showImport,
            icon: const Icon(Icons.add_link),
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    final ThemeData theme = Theme.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_sources.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.rss_feed, size: 64, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text('还没有订阅源', style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                '粘贴订阅源 JSON，或填一个订阅地址（http/https）',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: _showImport,
                icon: const Icon(Icons.add_link, size: 18),
                label: const Text('导入订阅源'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: _sources.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final RssSource s = _sources[index];
        return ListTile(
          leading: Icon(
            s.isUsable ? Icons.rss_feed : Icons.warning_amber,
            color: s.isUsable
                ? theme.colorScheme.primary
                : theme.colorScheme.error,
          ),
          title: Text(s.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            <String>[
              if (s.sourceGroup.trim().isNotEmpty) s.sourceGroup.trim(),
              s.isUsable ? '规则齐全' : '缺规则（不能抓取）',
              s.sourceUrl,
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Switch(
                value: s.enabled,
                onChanged: (bool on) => _toggle(s, on),
              ),
              IconButton(
                tooltip: '删除',
                onPressed: () => _remove(s),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          onTap: s.isUsable ? () => _openArticles(s) : null,
        );
      },
    );
  }

  Future<void> _toggle(RssSource source, bool on) async {
    final List<RssSource> all = await RssStore.instance.load();
    final int at = all.indexWhere((RssSource s) => s.sourceUrl == source.sourceUrl);
    if (at < 0) return;
    all[at] = all[at].copyWith(enabled: on);
    await RssStore.instance.saveAll(all);
    await _load();
  }

  Future<void> _remove(RssSource source) async {
    await RssStore.instance.remove(source.sourceUrl);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已删除「${source.displayName}」')),
    );
  }

  Future<void> _openArticles(RssSource source) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RssArticlesPage(source: source),
      ),
    );
  }

  Future<void> _showImport() async {
    final TextEditingController input = TextEditingController();
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入订阅源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: input,
              minLines: 4,
              maxLines: 10,
              decoration: const InputDecoration(
                hintText: '粘贴订阅源 JSON，或填一个订阅地址（http/https）',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    final String text = input.text;
    input.dispose();
    if (confirmed != true || !mounted) return;

    final RssParseOutcome outcome = await RssImporter.parse(text);
    if (!mounted) return;

    if (outcome.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('导入失败'),
          content: Text(
            outcome.errors.isEmpty ? '没解析出任何订阅源' : outcome.errors.join('\n'),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }

    final ({int added, int updated}) result =
        await RssStore.instance.merge(outcome.sources);
    await _load();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入完成'),
        content: Text(
          <String>[
            '新增 ${result.added} 个，更新 ${result.updated} 个',
            if (outcome.errors.isNotEmpty) ...<String>[
              '',
              '有 ${outcome.errors.length} 条需要注意：',
              ...outcome.errors.take(5),
            ],
          ].join('\n'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

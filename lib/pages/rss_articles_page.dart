import 'dart:async';

import 'package:flutter/material.dart';

import '../models/rss_source.dart';
import '../models/source_rule.dart';
import '../services/legado_source_store.dart';
import '../services/rss_client.dart';
import '../services/rss_repair.dart';
import '../services/rss_store.dart';
import '../services/source_importer.dart';
import '../services/source_link_parser.dart';
import 'source_import_confirm_page.dart';

/// 某个订阅源的文章列表
///
/// 只做「列文章」这一期：点文章暂时只提示，不抓正文
/// （RSS 源里通常没有 `ruleContent`，正文抽取是二期的事）。
class RssArticlesPage extends StatefulWidget {
  const RssArticlesPage({super.key, required this.source});

  final RssSource source;

  /// 刷新按钮
  static const Key refreshKey = ValueKey<String>('rss-articles-refresh');

  /// 「自动检测规则」按钮（源失效时出现）
  static const Key repairKey = ValueKey<String>('rss-articles-repair');

  @override
  State<RssArticlesPage> createState() => _RssArticlesPageState();
}

class _RssArticlesPageState extends State<RssArticlesPage> {
  late final RssClient _client = RssClient(source: widget.source);

  List<RssArticle> _articles = const <RssArticle>[];
  bool _loading = true;

  /// 失败原因（与「零结果」分开：源失效要说得明白）
  String? _error;

  /// 是不是「取到页面但选择器一条都没匹配上」
  bool _stale = false;

  /// 正在自动检测规则
  bool _repairing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _stale = false;
    });
    try {
      final List<RssArticle> list = await _client.articles();
      if (!mounted) return;
      setState(() {
        _articles = list;
        _loading = false;
      });
    } on RssSourceStaleException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _stale = true;
        _error = e.reason;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// 自动检测规则并保存
  ///
  /// 站点改版后，源里写死的选择器会全部落空 —— 这时给用户一个「一键重算」，
  /// 而不是让他去手写 CSS 选择器。
  Future<void> _autoRepair() async {
    setState(() => _repairing = true);
    try {
      final String html = await _client.fetchListPage();

      // ⚠️ 这里**不能**直接裸调 parseArticles：它在「容器零匹配」时抛
      // `RssSourceStaleException`，而那正是本按钮要处理的情况 ——
      // 裸调会让整段逻辑一进来就跳进 catch，弹一句「检测失败」，按钮等于没用。
      var live = const <RssArticle>[];
      try {
        live = _client.parseArticles(html);
      } on RssSourceStaleException {
        live = const <RssArticle>[];
      }
      // 能直接解析出来说明规则其实没问题，不用修
      if (!mounted) return;
      if (live.isNotEmpty) {
        setState(() => _repairing = false);
        await _load();
        return;
      }
      final RssRepairSuggestion? suggestion =
          RssRepair.suggest(html, baseUrl: widget.source.sourceUrl);
      if (!mounted) return;
      if (suggestion == null) {
        setState(() => _repairing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没检测到可用规则，这个源可能真的要换了')),
        );
        return;
      }

      final bool? apply = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('检测到可用的规则'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('容器：${suggestion.ruleArticles}'),
              Text('标题：${suggestion.ruleTitle}'),
              Text('链接：${suggestion.ruleLink}'),
              const SizedBox(height: 8),
              Text('能解析出 ${suggestion.count} 条，例如：'),
              const SizedBox(height: 4),
              ...suggestion.articles.take(3).map(
                    (RssArticle a) => Text(
                      '· ${a.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
              child: const Text('应用并保存'),
            ),
          ],
        ),
      );
      if (!mounted) return;

      if (apply == true) {
        final List<RssSource> all = await RssStore.instance.load();
        final int at =
            all.indexWhere((RssSource s) => s.sourceUrl == widget.source.sourceUrl);
        // 源已经被删掉（用户中途去管理页删了）：别用 all[at] 越界崩
        if (at < 0) {
          if (!mounted) return;
          setState(() => _repairing = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('这个订阅源已经不在了')),
          );
          return;
        }
        all[at] = all[at].copyWithRules(
          ruleArticles: suggestion.ruleArticles,
          ruleTitle: suggestion.ruleTitle,
          ruleLink: suggestion.ruleLink,
        );
        await RssStore.instance.saveAll(all);
        if (!mounted) return;
        // 用新规则重新进页面（State 里的 source 是旧的）
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => RssArticlesPage(source: all[at]),
          ),
        );
        return;
      }

      setState(() => _repairing = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _repairing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('检测失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.source.displayName),
        actions: <Widget>[
          IconButton(
            key: RssArticlesPage.refreshKey,
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
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
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                _stale ? Icons.link_off : Icons.error_outline,
                size: 56,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(height: 12),
              Text(
                _stale ? '这个订阅源可能已失效' : '抓取失败',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
              // 站点改版导致的「零匹配」：给一个自动检测规则的入口
              if (_stale) ...<Widget>[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  key: RssArticlesPage.repairKey,
                  onPressed: _repairing ? null : _autoRepair,
                  icon: const Icon(Icons.auto_fix_high, size: 18),
                  label: Text(_repairing ? '检测中…' : '自动检测规则'),
                ),
                const SizedBox(height: 6),
                Text(
                  '会按当前页面重新试算选择器，改完存回这个源',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      );
    }
    if (_articles.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.article_outlined, size: 56, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text('没抓到文章', style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                '容器匹配到了，但标题或链接取不到 —— 可能是规则末级写错',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: _articles.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final RssArticle a = _articles[index];
        // 订阅源里常见「书源合集」：链接本身是 yuedu://...importonline?src=...
        // 这种条目点开应当是**导入书源**，不是显示一串地址
        final bool importable = SourceLinkParser.isBookSourceLink(a.url);
        return ListTile(
          title: Text(a.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: importable
              ? Text(
                  '书源合集 · 点一下导入',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                )
              : (a.desc.isEmpty
                  ? null
                  : Text(
                      a.desc,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    )),
          trailing: Icon(
            importable ? Icons.file_download_outlined : Icons.open_in_new,
            size: 18,
          ),
          onTap: importable
              ? () => _importFromArticle(a)
              : () {
                  // 普通条目（正文抓取是二期）：先把地址显示出来
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(a.url)),
                  );
                },
        );
      },
    );
  }

  /// 从订阅条目里的 `yuedu://` 链接导入书源
  ///
  /// 与浏览器里点「一键导入」走同一条流程：**先确认再导**，不静默改用户书源库。
  Future<void> _importFromArticle(RssArticle article) async {
    final String? src = SourceLinkParser.extractBookSourceUrl(article.url);
    if (!mounted) return;
    if (src == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('这个链接里没有可用的书源地址：${article.url}')),
      );
      return;
    }

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(article.title.isEmpty ? '导入书源' : article.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('要导入这份书源吗？'),
            const SizedBox(height: 8),
            Text(
              src,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(dialogContext).textTheme.bodySmall,
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
    if (ok != true || !mounted) return;

    final ParseOutcome outcome;
    try {
      outcome = await SourceImporter.parse(src);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
      return;
    }
    if (!mounted) return;
    if (outcome.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            outcome.errors.isEmpty ? '没解析出任何书源' : outcome.errors.first,
          ),
        ),
      );
      return;
    }

    // 先让用户勾选（一个合集常带几十条，里面混着失效的/不想要的）
    final List<SourceRule> existing = await LegadoSourceStore.instance.load();
    if (!mounted) return;
    final NavigatorState navigator = Navigator.of(context);
    final List<SourceRule>? picked = await navigator.push<List<SourceRule>>(
      MaterialPageRoute<List<SourceRule>>(
        builder: (_) => SourceImportConfirmPage(
          sources: outcome.rules,
          localUrls: <String>{for (final SourceRule r in existing) r.url},
        ),
      ),
    );
    if (!mounted || picked == null || picked.isEmpty) return;

    final ({int added, int updated}) result = await applySelectedSources(picked);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已导入：新增 ${result.added} 个书源，更新 ${result.updated} 个'),
      ),
    );
  }
}

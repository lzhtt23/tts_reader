import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/rss_source.dart';
import '../models/source_rule.dart';
import '../services/crash_log.dart';
import '../services/legado_source_store.dart';
import '../services/rss_store.dart';
import 'legado_sources_page.dart';
import 'rss_articles_page.dart';
import 'rss_sources_page.dart';
import 'search_entry_page.dart';
import '../widgets/online_downloads_sheet.dart';

/// 发现：用已启用的书源搜书
///
/// 需求（2026-10-18）：
/// - 搜索框搜**书源里的书**（不是本地文档）
/// - 结果点书名 → 简介页（下载 / 加入书架 / 阅读）
/// - 右上角原来是放大镜，改成**导入**（导入书源）
/// - 右上角三点 → **勾选启用的书源**
/// - 页面内提供「下载列表」入口（与浏览器同款弹层）
///
/// ⚠️ 多源并发搜索的写法照抄 `LegadoSearchPage`：谁先回来先显示谁，
/// 单源失败只影响它自己（书源质量参差，一个源挂了不能让整页空着）。
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  /// 搜索框（用例锚点）
  static const Key searchFieldKey = ValueKey<String>('discover-search');

  /// 「书源勾选」按钮
  static const Key sourcePickerKey = ValueKey<String>('discover-source-picker');

  /// 「下载列表」按钮
  static const Key downloadsKey = ValueKey<String>('discover-downloads');

  /// 订阅源列表（搜索栏下方那一段）
  static const Key subscriptionListKey =
      ValueKey<String>('discover-subscriptions');

  /// 「导入订阅源」方形键（与「导入书源」并排）
  static const Key importRssKey = ValueKey<String>('discover-import-rss');

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  final TextEditingController _keyword = TextEditingController();

  /// 全部书源（含已禁用的，勾选面板要显示它们）
  List<SourceRule> _all = const <SourceRule>[];

  bool _loadingSources = true;

  /// 订阅源（搜索栏下方那一段）
  List<RssSource> _rss = const <RssSource>[];

  @override
  void initState() {
    super.initState();
    // 导航探针：发现页被**建出来**的时刻。用户报「点别的 Tab 会先闪一下发现页」，
    // 如果日志里在切换别处时出现这一行，说明 IndexedStack 把它换进来了。
    CrashLog.mark('页面[发现] initState（首次构建）');
    unawaited(_reloadSources());
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  Future<void> _reloadSources() async {
    final List<SourceRule> all = await LegadoSourceStore.instance.load();
    final List<RssSource> rss = await RssStore.instance.load();
    if (!mounted) return;
    setState(() {
      _all = all;
      _rss = rss;
      _loadingSources = false;
    });
  }

  /// 进**专门的搜索页**（搜索历史 / 精准搜索 / 选书源都在那一页）
  ///
  /// 用户要求：点发现页的搜索栏就跳到搜索页，而不是就地开搜。
  /// 这样发现页保持「入口 + 订阅」的定位，搜索那套东西不挤在这里。
  Future<void> _openSearchPage() async {
    FocusScope.of(context).unfocus();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchEntryPage(initialKeyword: _keyword.text.trim()),
      ),
    );
    if (mounted) await _reloadSources();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        _toolbar(),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _toolbar() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              // 假搜索框：点了就跳搜索页（不在这里开搜）
              Expanded(child: _searchBarEntry(theme)),
              const SizedBox(width: 10),
              // 方形「导入订阅源」键（用户指定位置：搜索栏右侧）
              SizedBox(
                width: 56,
                height: 56,
                child: IconButton.filledTonal(
                  key: DiscoverPage.importRssKey,
                  tooltip: '导入订阅源',
                  onPressed: _openRssSourcesPage,
                  iconSize: 24,
                  icon: const Icon(Icons.rss_feed),
                  style: IconButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: DiscoverPage.sourcePickerKey,
                tooltip: '勾选启用的书源',
                onPressed: _loadingSources ? null : _showSourcePicker,
                icon: const Icon(Icons.tune),
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: DiscoverPage.downloadsKey,
            onPressed: _showDownloads,
            icon: const Icon(Icons.download_done, size: 18),
            label: const Text('下载列表'),
          ),
          const SizedBox(height: 6),
          _subscriptionSection(theme),
        ],
      ),
    );
  }

  /// 假搜索框：外观和真搜索框一样，点一下进搜索页
  ///
  /// 用 `InkWell` 而不是只读 `TextField`：只读输入框点了有时只会「聚焦但没反应」，
  /// 这里要的是**明确跳转**，所以做成按钮语义。
  Widget _searchBarEntry(ThemeData theme) {
    final ColorScheme scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: DiscoverPage.searchFieldKey,
        onTap: _openSearchPage,
        child: SizedBox(
          height: 56,
          child: Row(
            children: <Widget>[
              const SizedBox(width: 14),
              Icon(Icons.search, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _keyword.text.trim().isEmpty ? '搜索书名 / 作者' : _keyword.text.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: _keyword.text.trim().isEmpty
                        ? scheme.onSurfaceVariant
                        : scheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ),
      ),
    );
  }

  /// 搜索栏下方的订阅入口：只留一行小标题，网格放到 body 里
  ///
  /// 用户要求：这块空白要像阅读 App 的「订阅」页 —— **图标网格**，
  /// 不是横向长条卡片。所以标题留在工具栏，网格挪进 [_body]。
  Widget _subscriptionSection(ThemeData theme) {
    if (_rss.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 4),
        child: Text(
          '还没有订阅源 —— 点右边的方形键导入',
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    final int usable = _rss.where((RssSource s) => s.isUsable && s.enabled).length;
    return Padding(
      key: DiscoverPage.subscriptionListKey,
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Text(
        '订阅（${_rss.length} 个，可用 $usable）',
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  /// 订阅网格：图标 + 名字（对齐阅读 App 的「订阅」页）
  Widget _subscriptionGrid() {
    final int crossAxisCount =
        (MediaQuery.sizeOf(context).width / 110).floor().clamp(3, 6);

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 8,
        mainAxisSpacing: 16,
        childAspectRatio: 0.72,
      ),
      itemCount: _rss.length,
      itemBuilder: (context, index) => _rssTile(_rss[index]),
    );
  }

  Widget _rssTile(RssSource source) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool ok = source.isUsable && source.enabled;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      // ⚠️ 不能写成 `isUsable ? onTap : null`：规则不齐时点击毫无反馈，
      // 用户只会觉得「点了没反应」。这里始终可点，规则不齐时明确告诉他去哪补。
      onTap: () {
        if (!source.isUsable) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('这个订阅源缺规则（ruleArticles / ruleLink / ruleTitle 之一），点不开'),
            ),
          );
          return;
        }
        _openRssArticles(source);
      },
      child: Column(
        children: <Widget>[
          Expanded(
            child: AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Opacity(
                  opacity: ok ? 1 : 0.45,
                  child: _rssIcon(source, scheme),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            source.displayName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: ok ? null : scheme.onSurfaceVariant,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  /// 订阅图标：`sourceIcon` 可能是 base64 data URI、也可能是普通 URL
  Widget _rssIcon(RssSource source, ColorScheme scheme) {
    final String raw = source.sourceIcon.trim();
    Widget fallback() => Container(
      color: scheme.surfaceContainerHighest,
      child: Icon(Icons.rss_feed, color: scheme.onSurfaceVariant, size: 32),
    );

    if (raw.startsWith('data:image')) {
      final int comma = raw.indexOf(',');
      if (comma > 0 && comma + 1 < raw.length) {
        try {
          final Uint8List bytes = base64Decode(raw.substring(comma + 1));
          return Image.memory(bytes, fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback());
        } catch (_) {
          return fallback();
        }
      }
      return fallback();
    }
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return Image.network(
        raw,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback(),
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : fallback(),
      );
    }
    return fallback();
  }

  Widget _body() {
    if (_loadingSources) {
      return const Center(child: CircularProgressIndicator());
    }
    // 订阅网格占满这块空白（用户要求：像阅读 App 的订阅页）
    if (_rss.isNotEmpty) return _subscriptionGrid();
    return _emptyGuide(
      icon: Icons.rss_feed,
      title: '还没有订阅源',
      hint: '点右上角方形键导入，或先用「搜索」按书名找书',
      action: FilledButton.tonalIcon(
        onPressed: _openRssSourcesPage,
        icon: const Icon(Icons.rss_feed, size: 18),
        label: const Text('导入订阅源'),
      ),
    );
  }

  Widget _emptyGuide({
    required IconData icon,
    required String title,
    required String hint,
    Widget? action,
  }) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(hint, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
            if (action != null) ...<Widget>[const SizedBox(height: 16), action],
          ],
        ),
      ),
    );
  }

  Future<void> _openSourcesPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const LegadoSourcesPage(),
      ),
    );
    if (mounted) await _reloadSources();
  }

  /// 订阅源管理页（导入 / 启停 / 删除）
  Future<void> _openRssSourcesPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const RssSourcesPage(),
      ),
    );
    if (mounted) await _reloadSources();
  }

  /// 打开某个订阅源的文章列表
  Future<void> _openRssArticles(RssSource source) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RssArticlesPage(source: source),
      ),
    );
    if (mounted) await _reloadSources();
  }

  /// 书源勾选：勾上 = 启用，取消 = 禁用。写的是同一份数据，与设置页的管理页互通。
  Future<void> _showSourcePicker() async {
    final List<SourceRule> all = _all;
    final Set<String> enabled = <String>{
      for (final SourceRule r in all)
        if (r.enabled) r.url,
    };

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final List<SourceRule> supported =
                all.where((SourceRule r) => r.isSupported).toList();
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            '启用的书源（${enabled.length}/${supported.length}）',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        TextButton(
                          onPressed: () => setSheetState(() {
                            enabled
                              ..clear()
                              ..addAll(supported.map((SourceRule r) => r.url));
                          }),
                          child: const Text('全选'),
                        ),
                      ],
                    ),
                    if (supported.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text('没有可用的书源（类型不是 text 或规则不全）'),
                      )
                    else
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: supported.length,
                          itemBuilder: (context, index) {
                            final SourceRule r = supported[index];
                            return CheckboxListTile(
                              dense: true,
                              value: enabled.contains(r.url),
                              title: Text(
                                r.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: r.group == null || r.group!.isEmpty
                                  ? null
                                  : Text(r.group!),
                              onChanged: (bool? on) => setSheetState(() {
                                if (on == true) {
                                  enabled.add(r.url);
                                } else {
                                  enabled.remove(r.url);
                                }
                              }),
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Navigator.of(sheetContext).pop();
                              unawaited(_openSourcesPage());
                            },
                            icon: const Icon(Icons.settings, size: 18),
                            label: const Text('管理全部书源'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: () async {
                            final List<SourceRule> updated = <SourceRule>[
                              for (final SourceRule r in all)
                                supported.any((SourceRule s) => s.url == r.url)
                                    ? r.copyWith(enabled: enabled.contains(r.url))
                                    : r,
                            ];
                            await LegadoSourceStore.instance.saveAll(updated);
                            if (!sheetContext.mounted) return;
                            Navigator.of(sheetContext).pop();
                            if (!mounted) return;
                            await _reloadSources();
                          },
                          child: const Text('保存'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 下载列表：与浏览器同款弹层（P5 会把在线书下载也接进这个视图）
  /// 下载列表：**在线书下载的唯一入口**（详情页/在线书架触发的都在这里）
  Future<void> _showDownloads() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => OnlineDownloadsSheet(
        onOpenDocument: (String documentId) {
          Navigator.of(sheetContext).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已加入文档库，去「文档库」里打开')),
          );
        },
      ),
    );
  }
}

/// 单个源的搜索状态在 [SearchResultsPage] 里（搜索已拆成独立页面）

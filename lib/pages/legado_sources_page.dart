import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/source_rule.dart';
import '../services/legado_source_store.dart';
import '../services/source_importer.dart';

/// 书源管理（legado 格式）
///
/// ## 与 `BookSourcesPage` 的区别
///
/// `BookSourcesPage` 管的是**书签式**书源（`WebLink`）：一个网址点开就浏览。
/// 这个页面管的是 **legado 规则书源**：导入 JSON 后能真的搜书、抓目录、读正文。
///
/// 两者数据完全独立（不同 SharedPreferences 键），互不影响。
class LegadoSourcesPage extends StatefulWidget {
  const LegadoSourcesPage({super.key, this.onOpenSearch});

  /// 点「去搜书」时的回调（由外层导航注入）
  final void Function(List<SourceRule> usable)? onOpenSearch;

  /// 右上角「导入书源」按钮
  ///
  /// 右下角那个悬浮键一直在，但用户反馈「在书源管理里找不到导入入口」——
  /// 悬浮键在长列表里容易被当成页面内容忽略，所以右上角再补一个同功能的显式按钮。
  static const Key importKey = ValueKey<String>('sources-import');

  @override
  State<LegadoSourcesPage> createState() => _LegadoSourcesPageState();
}

class _LegadoSourcesPageState extends State<LegadoSourcesPage> {
  List<SourceRule> _sources = const <SourceRule>[];
  bool _loading = true;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final List<SourceRule> all = await LegadoSourceStore.instance.load();
    if (!mounted) return;
    setState(() {
      _sources = all;
      _loading = false;
    });
  }

  List<SourceRule> get _visible {
    final String q = _filter.trim().toLowerCase();
    if (q.isEmpty) return _sources;
    return _sources
        .where(
          (SourceRule r) =>
              r.name.toLowerCase().contains(q) ||
              r.url.toLowerCase().contains(q) ||
              r.groups.any((String g) => g.toLowerCase().contains(q)),
        )
        .toList();
  }

  List<SourceRule> get _usable =>
      _sources.where((SourceRule r) => r.isSupported).toList();

  // ---------------- 导入 ----------------

  Future<void> _importFromClipboard() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String? text = data?.text;
    if (text == null || text.trim().isEmpty) {
      _toast('剪贴板是空的');
      return;
    }
    await _importText(text);
  }

  Future<void> _importFromInput() async {
    final String? text = await showDialog<String>(
      context: context,
      builder: (_) => const _TextImportDialog(),
    );
    if (text == null) return;
    await _importText(text);
  }

  Future<void> _importText(String text) async {
    setState(() => _loading = true);
    try {
      final ParseOutcome outcome = await SourceImporter.parse(text);
      if (!mounted) return;

      if (outcome.rules.isEmpty) {
        setState(() => _loading = false);
        _showResultDialog(
          title: '导入失败',
          lines: <String>[
            if (outcome.errors.isEmpty) '没有解析出任何书源',
            ...outcome.errors.take(10),
          ],
        );
        return;
      }

      final Map<String, SourceRule> local =
          await LegadoSourceStore.instance.loadByUrl();
      final SourceImportResult merged = mergeSourceRules(outcome.rules, local);

      // 新增 + 更新一起写入
      final List<SourceRule> toWrite = <SourceRule>[
        ...merged.added,
        ...merged.updated,
      ];
      if (toWrite.isNotEmpty) {
        await LegadoSourceStore.instance.upsert(toWrite);
      }

      if (!mounted) return;
      setState(() => _loading = false);
      await _reload();

      _showResultDialog(
        title: '导入完成',
        lines: <String>[
          '新增 ${merged.added.length} 条',
          '更新 ${merged.updated.length} 条',
          '已存在 ${merged.existing.length} 条（未覆盖）',
          if (merged.skipped.isNotEmpty)
            '不支持 ${merged.skipped.length} 条（非文本书源或缺规则）',
          if (outcome.errors.isNotEmpty) ...<String>[
            '',
            '解析提示：',
            ...outcome.errors.take(5),
          ],
        ],
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showResultDialog(title: '导入出错', lines: <String>['$e']);
    }
  }

  void _showResultDialog({required String title, required List<String> lines}) {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final String line in lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(line),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------- 单条操作 ----------------

  Future<void> _toggle(SourceRule rule) async {
    final List<SourceRule> all = List<SourceRule>.of(_sources);
    final int i = all.indexWhere((SourceRule r) => r.url == rule.url);
    if (i < 0) return;
    all[i] = all[i].copyWith(enabled: !all[i].enabled);
    await LegadoSourceStore.instance.saveAll(all);
    await _reload();
  }

  Future<void> _remove(SourceRule rule) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除书源'),
        content: Text('确定删除「${rule.displayName}」？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await LegadoSourceStore.instance.remove(rule.url);
    await _reload();
  }

  void _showDetail(SourceRule rule) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (BuildContext ctx, ScrollController controller) =>
            ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: <Widget>[
                Text(
                  rule.displayName,
                  style: Theme.of(ctx).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                _kv(ctx, '地址', rule.url),
                _kv(ctx, '类型', SourceType.label(rule.type)),
                if (rule.groups.isNotEmpty) _kv(ctx, '分组', rule.groups.join('、')),
                _kv(ctx, '搜索', rule.searchUrl ?? '（无）'),
                _kv(ctx, '可执行', rule.isSupported ? '是' : '否'),
                if (rule.comment != null && rule.comment!.isNotEmpty)
                  _kv(ctx, '备注', rule.comment!),
              ],
            ),
      ),
    );
  }

  Widget _kv(BuildContext ctx, String key, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(key, style: Theme.of(ctx).textTheme.labelMedium),
        const SizedBox(height: 2),
        SelectableText(value, style: Theme.of(ctx).textTheme.bodyMedium),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<SourceRule> visible = _visible;

    return Scaffold(
      appBar: AppBar(
        title: const Text('书源（阅读格式）'),
        actions: <Widget>[
          if (_usable.isNotEmpty)
            IconButton(
              tooltip: '用这些书源搜书',
              icon: const Icon(Icons.search),
              onPressed: () => widget.onOpenSearch?.call(_usable),
            ),
          // 导入书源（与右下角悬浮键同功能，放在更容易找到的位置）
          IconButton(
            key: LegadoSourcesPage.importKey,
            tooltip: '导入书源',
            onPressed: _loading ? null : _showImportMenu,
            icon: const Icon(Icons.add_link),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _showImportMenu,
        icon: const Icon(Icons.file_download_outlined),
        label: const Text('导入书源'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: '按名称 / 地址 / 分组筛选',
                      prefixIcon: Icon(Icons.filter_list),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (String v) => setState(() => _filter = v),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: <Widget>[
                      Text(
                        '共 ${_sources.length} 条，可执行 ${_usable.length} 条',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                    itemCount: visible.length,
                    itemBuilder: (BuildContext ctx, int i) {
                      final SourceRule rule = visible[i];
                      return Card.filled(
                        margin: const EdgeInsets.only(bottom: 8),
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          leading: Icon(
                            rule.isSupported
                                ? Icons.menu_book_outlined
                                : Icons.block_outlined,
                            color: rule.isSupported
                                ? null
                                : theme.colorScheme.outline,
                          ),
                          title: Text(
                            rule.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            <String>[
                              SourceType.label(rule.type),
                              if (rule.groups.isNotEmpty) rule.groups.join('、'),
                              if (!rule.isSupported) '不支持',
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Switch(
                                value: rule.enabled,
                                onChanged: (_) => _toggle(rule),
                              ),
                              IconButton(
                                tooltip: '删除',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _remove(rule),
                              ),
                            ],
                          ),
                          onTap: () => _showDetail(rule),
                        ),
                      );
                    },
                  ),
                ),
                if (visible.isEmpty && !_loading)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _sources.isEmpty
                          ? '还没有书源。\n\n点右上角「导入书源」（或右下角那个键），可以：\n'
                                '· 粘贴阅读（legado）书源 JSON\n'
                                '· 粘贴 yuedu:// 一键导入链接\n'
                                '· 从剪贴板导入\n'
                                '· 填一个书源订阅地址'
                          : '没有匹配的书源',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
              ],
            ),
    );
  }

  void _showImportMenu() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('从剪贴板导入'),
              subtitle: const Text('复制书源 JSON 后点这里'),
              onTap: () {
                Navigator.pop(ctx);
                _importFromClipboard();
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: const Text('粘贴 / 输入地址'),
              subtitle: const Text('可直接贴 JSON，或填订阅地址'),
              onTap: () {
                Navigator.pop(ctx);
                _importFromInput();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// 输入书源 JSON 或订阅地址
class _TextImportDialog extends StatefulWidget {
  const _TextImportDialog();

  @override
  State<_TextImportDialog> createState() => _TextImportDialogState();
}

class _TextImportDialogState extends State<_TextImportDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导入书源'),
      content: SizedBox(
        width: 520,
        child: TextField(
          controller: _controller,
          maxLines: 12,
          minLines: 6,
          decoration: const InputDecoration(
            hintText: '粘贴书源 JSON，或填一个订阅地址（http/https）',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final String text = _controller.text.trim();
            if (text.isEmpty) return;
            Navigator.pop(context, text);
          },
          child: const Text('导入'),
        ),
      ],
    );
  }
}

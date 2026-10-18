import 'package:flutter/material.dart';

import '../models/source_rule.dart';
import '../services/legado_source_store.dart';

/// 导入书源前的**勾选页**（对齐阅读 App 的「导入书源」确认页）
///
/// 为什么要有这一页，而不是「一键导入」直接写库：
/// 一个书源合集会带几十条源，里面经常混着失效的、重复的、不想要的。
/// 直接全量写进去，用户就得事后一条条删 —— 比当初不导入还麻烦。
///
/// 页面行为：
/// - 默认**全选**
/// - 每条显示「新增 / 更新 / 已有」，让用户知道哪些会真正改变本地数据
/// - 底部「取消全选 (n/m)」「取消」「确认」
///
/// 返回值：确认时返回**选中的规则**；取消返回 null。
class SourceImportConfirmPage extends StatefulWidget {
  const SourceImportConfirmPage({
    super.key,
    required this.sources,
    required this.localUrls,
  });

  /// 解析出来的全部规则
  final List<SourceRule> sources;

  /// 本地已有的 url（用来标「新增 / 更新」）
  final Set<String> localUrls;

  /// 「全选 / 取消全选」按钮
  static const Key toggleAllKey = ValueKey<String>('import-confirm-toggle-all');

  /// 「确认」按钮
  static const Key confirmKey = ValueKey<String>('import-confirm-ok');

  /// 「取消」按钮
  static const Key cancelKey = ValueKey<String>('import-confirm-cancel');

  @override
  State<SourceImportConfirmPage> createState() =>
      _SourceImportConfirmPageState();
}

class _SourceImportConfirmPageState extends State<SourceImportConfirmPage> {
  /// 已选中的 url
  late final Set<String> _selected = <String>{
    for (final SourceRule r in widget.sources) r.url,
  };

  bool get _allSelected => _selected.length == widget.sources.length;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('导入书源'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: Text(
                '共 ${widget.sources.length} 个',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
      body: widget.sources.isEmpty
          ? const Center(child: Text('没有可导入的书源'))
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: widget.sources.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final SourceRule r = widget.sources[index];
                final bool selected = _selected.contains(r.url);
                final bool exists = widget.localUrls.contains(r.url);
                return CheckboxListTile(
                  value: selected,
                  onChanged: (bool? on) => setState(() {
                    if (on == true) {
                      _selected.add(r.url);
                    } else {
                      _selected.remove(r.url);
                    }
                  }),
                  title: Text(
                    r.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    exists ? '更新' : '新增',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: exists
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.primary,
                    ),
                  ),
                );
              },
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: <Widget>[
              // 阅读 App 同款：显示「取消全选 (13/13)」/「全选 (0/13)」
              TextButton(
                key: SourceImportConfirmPage.toggleAllKey,
                onPressed: () => setState(() {
                  if (_allSelected) {
                    _selected.clear();
                  } else {
                    _selected
                      ..clear()
                      ..addAll(widget.sources.map((SourceRule r) => r.url));
                  }
                }),
                child: Text(
                  _allSelected
                      ? '取消全选 (${_selected.length}/${widget.sources.length})'
                      : '全选 (${_selected.length}/${widget.sources.length})',
                ),
              ),
              const Spacer(),
              OutlinedButton(
                key: SourceImportConfirmPage.cancelKey,
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: 10),
              FilledButton(
                key: SourceImportConfirmPage.confirmKey,
                onPressed: _selected.isEmpty
                    ? null
                    : () {
                        final List<SourceRule> picked = widget.sources
                            .where((SourceRule r) => _selected.contains(r.url))
                            .toList();
                        Navigator.of(context).pop(picked);
                      },
                child: const Text('确认'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 把选中的规则写进书源库，返回 `(added, updated)`
///
/// 抽成独立函数是为了能离线单测：不碰 UI、不碰网络，只做「读 → 合并 → 写」。
Future<({int added, int updated})> applySelectedSources(
  List<SourceRule> selected, {
  LegadoSourceStore? store,
}) async {
  final LegadoSourceStore target = store ?? LegadoSourceStore.instance;
  final List<SourceRule> existing = await target.load();
  final Map<String, SourceRule> byUrl = <String, SourceRule>{
    for (final SourceRule r in existing) r.url: r,
  };
  var added = 0;
  var updated = 0;
  for (final SourceRule r in selected) {
    if (byUrl.containsKey(r.url)) {
      updated++;
    } else {
      added++;
    }
    byUrl[r.url] = r;
  }
  await target.saveAll(byUrl.values.toList());
  return (added: added, updated: updated);
}

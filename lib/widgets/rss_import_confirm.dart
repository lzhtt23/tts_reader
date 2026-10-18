import 'package:flutter/material.dart';

import '../models/rss_source.dart';

/// 「导入订阅源」确认窗（对齐阅读 App 的那个弹窗）
///
/// ```
/// ┌──────────────────────────────┐
/// │ 导入订阅源          自定义源分组 ⋮ │
/// │ ☐ 喵公子书源管理        [已有] ✎ │
/// │                              │
/// │ [全选 (0/1)]                  │
/// │            [取消]  [确认]     │
/// └──────────────────────────────┘
/// ```
///
/// ## 为什么必须先给这一屏，而不是直接写库
///
/// 深链是从**别的应用**拉起来的：用户可能只是误点，也可能这个订阅源他早就有了。
/// 直接写库等于「点一下链接就改了别人的数据」，而且没法撤销。
/// 所以默认**不全选**（与书源那次不同：书源是用户主动点的搜索页，这里是被拉起）。
///
/// 返回：确认时返回选中的订阅源；取消返回 null。
Future<List<RssSource>?> showRssImportConfirm(
  BuildContext context, {
  required List<RssSource> sources,
  required Set<String> existingUrls,
}) {
  return showDialog<List<RssSource>>(
    context: context,
    builder: (dialogContext) => _RssImportDialog(
      sources: sources,
      existingUrls: existingUrls,
    ),
  );
}

class _RssImportDialog extends StatefulWidget {
  const _RssImportDialog({required this.sources, required this.existingUrls});

  final List<RssSource> sources;
  final Set<String> existingUrls;

  @override
  State<_RssImportDialog> createState() => _RssImportDialogState();
}

class _RssImportDialogState extends State<_RssImportDialog> {
  /// 默认**不选中**：这是被别的应用拉起来的，不该替用户做决定
  final Set<String> _picked = <String>{};

  bool get _allPicked => _picked.length == widget.sources.length;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: <Widget>[
          const Expanded(child: Text('导入订阅源')),
          IconButton(
            tooltip: '全部选中',
            onPressed: _toggleAll,
            icon: const Icon(Icons.list_alt, size: 20),
          ),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.sources.length,
                itemBuilder: (context, index) {
                  final RssSource s = widget.sources[index];
                  final bool exists = widget.existingUrls.contains(s.sourceUrl);
                  return CheckboxListTile(
                    dense: true,
                    value: _picked.contains(s.sourceUrl),
                    title: Text(
                      s.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    secondary: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (exists)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant,
                              ),
                            ),
                            child: Text(
                              '已有',
                              style: theme.textTheme.labelSmall,
                            ),
                          ),
                      ],
                    ),
                    onChanged: (bool? on) => setState(() {
                      if (on == true) {
                        _picked.add(s.sourceUrl);
                      } else {
                        _picked.remove(s.sourceUrl);
                      }
                    }),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: <Widget>[
                  TextButton(
                    onPressed: _toggleAll,
                    child: Text(
                      _allPicked
                          ? '取消全选 (${_picked.length}/${widget.sources.length})'
                          : '全选 (${_picked.length}/${widget.sources.length})',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _picked.isEmpty
              ? null
              : () {
                  final List<RssSource> chosen = widget.sources
                      .where((RssSource s) => _picked.contains(s.sourceUrl))
                      .toList();
                  Navigator.of(context).pop(chosen);
                },
          child: const Text('确认'),
        ),
      ],
    );
  }

  void _toggleAll() {
    setState(() {
      if (_allPicked) {
        _picked.clear();
      } else {
        _picked
          ..clear()
          ..addAll(widget.sources.map((RssSource s) => s.sourceUrl));
      }
    });
  }
}

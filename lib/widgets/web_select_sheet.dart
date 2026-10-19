import 'package:flutter/material.dart';

/// 网页 `<select>` 的选择面板
///
/// 由 [WebSelectBridge] 的 JS 把选项传上来，用户在这里点一项，
/// 结果回传给页面（写 `selectedIndex` 并派发 `change`）。
///
/// 选项多的时候（语言列表常见几十项）顶上带一个筛选框 —— 一屏翻不完。
class WebSelectSheet extends StatefulWidget {
  const WebSelectSheet({
    super.key,
    required this.label,
    required this.options,
    required this.multiple,
    this.currentIndex,
    this.currentIndexes,
  });

  final String label;

  /// 选项文字（顺序与页面一致）
  final List<String> options;

  final bool multiple;
  final int? currentIndex;
  final List<int>? currentIndexes;

  /// 超过这个数量就给筛选框
  static const int filterThreshold = 12;

  @override
  State<WebSelectSheet> createState() => _WebSelectSheetState();
}

class _WebSelectSheetState extends State<WebSelectSheet> {
  late final TextEditingController _filter = TextEditingController();
  late Set<int> _picked;
  int? _single;

  @override
  void initState() {
    super.initState();
    _single = widget.currentIndex;
    _picked = <int>{...?widget.currentIndexes};
    _filter.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  List<int> get _visible {
    final String q = _filter.text.trim().toLowerCase();
    if (q.isEmpty) {
      return <int>[for (var i = 0; i < widget.options.length; i++) i];
    }
    return <int>[
      for (var i = 0; i < widget.options.length; i++)
        if (widget.options[i].toLowerCase().contains(q)) i,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<int> visible = _visible;
    final bool showFilter = widget.options.length > WebSelectSheet.filterThreshold;

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.label.trim().isEmpty ? '请选择' : widget.label.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (widget.multiple)
                    TextButton(
                      key: const ValueKey<String>('web-select-done'),
                      onPressed: _confirmMultiple,
                      child: const Text('确定'),
                    ),
                ],
              ),
            ),
            if (showFilter)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  key: const ValueKey<String>('web-select-filter'),
                  controller: _filter,
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: '筛选…',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Text('没有匹配项', style: theme.textTheme.bodySmall),
                    )
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (BuildContext context, int i) {
                        final int index = visible[i];
                        final String text = widget.options[index];
                        if (widget.multiple) {
                          return CheckboxListTile(
                            dense: true,
                            value: _picked.contains(index),
                            title: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
                            onChanged: (bool? on) => setState(() {
                              if (on == true) {
                                _picked.add(index);
                              } else {
                                _picked.remove(index);
                              }
                            }),
                          );
                        }
                        final bool selected = index == _single;
                        return ListTile(
                          dense: true,
                          title: Text(
                            text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: selected ? FontWeight.w600 : null,
                            ),
                          ),
                          trailing: selected
                              ? Icon(Icons.check, size: 18, color: theme.colorScheme.primary)
                              : null,
                          onTap: () => Navigator.of(context).pop(<int>[index]),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmMultiple() {
    final List<int> sorted = _picked.toList()..sort();
    Navigator.of(context).pop(sorted);
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/text_rule.dart';
import '../models/text_rule_presets.dart';
import '../services/crash_log.dart';
import '../services/text_processor.dart';

/// 朗读文本预处理规则页（对应 T2S 的 Text Process Rules）
///
/// 朗读前按顺序改写文本：`△` 读成「三角形」、去掉方括号内容、跳过参考文献编号……
/// 规则只影响送去合成的字符串，文档本身与阅读页显示不变。
/// 页面顶部有预览框：改完立刻能看到样例文本被改成了什么样。
class TextRulesPage extends StatefulWidget {
  const TextRulesPage({super.key});

  /// 预设库入口（用例据此点开面板）
  static const Key presetLibraryKey = ValueKey<String>('text-rules-preset-library');

  /// 预览用的默认样例（覆盖内置预设会命中的几种情况）
  static const String defaultSample = '地球上最大的洋是太平洋[1]。△ 表示三角形，→ 表示方向。\n'
      '详见 https://example.com/a_b 与 **重点** 内容。';

  @override
  State<TextRulesPage> createState() => _TextRulesPageState();
}

class _TextRulesPageState extends State<TextRulesPage> {
  late final TextEditingController _sample = TextEditingController(
    text: TextRulesPage.defaultSample,
  );

  List<TextRule> get _rules => TextProcessor.instance.rules;

  @override
  void dispose() {
    _sample.dispose();
    super.dispose();
  }

  Future<void> _save(List<TextRule> rules) async {
    await TextProcessor.instance.setRules(rules);
    if (mounted) setState(() {});
  }

  void _onReorder(int oldIndex, int newIndex) {
    final rules = List<TextRule>.of(_rules);
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex < 0 || oldIndex >= rules.length) return;
    if (newIndex < 0) newIndex = 0;
    if (newIndex > rules.length - 1) newIndex = rules.length - 1;
    final rule = rules.removeAt(oldIndex);
    rules.insert(newIndex, rule);
    unawaited(_save(rules));
  }

  Future<void> _edit(TextRule? rule) async {
    final result = await showDialog<_RuleEditResult>(
      context: context,
      builder: (_) => _RuleEditDialog(rule: rule, sample: _sample.text),
    );
    if (result == null) return;
    if (result.deleted) {
      if (rule != null) await TextProcessor.instance.remove(rule.id);
    } else if (result.rule != null) {
      await TextProcessor.instance.upsert(result.rule!);
    }
    if (mounted) setState(() {});
  }

  Future<void> _restoreDefaults() async {
    await TextProcessor.instance.restoreDefaults();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已补回内置预设规则（自建规则与开关状态保留）')),
    );
  }

  /// 打开预设库：按组列出候选规则，勾选后一次性加入（v1.22.75）
  ///
  /// 为什么做成"勾选面板"而不是"一键全加"：页码/页眉这类规则只对某些书成立，
  /// 无条件全开会把正文里的年份、编号一起删掉。让用户看着说明挑。
  Future<void> _openPresetLibrary() async {
    final Set<String> picked = <String>{};
    final int added = await showModalBottomSheet<int>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (BuildContext ctx) {
            return StatefulBuilder(
              builder: (BuildContext ctx, StateSetter setSheet) {
                final ThemeData theme = Theme.of(ctx);
                return SafeArea(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(ctx).height * 0.85,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text('预设库',
                                  style: theme.textTheme.titleMedium),
                              const SizedBox(height: 4),
                              Text(
                                '按你的书挑。页码、页眉这类规则只对部分书成立 —— '
                                '勾之前看一眼说明，加错了可以随时删。',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Flexible(
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                            children: <Widget>[
                              for (final String group
                                  in TextRulePreset.groups) ...<Widget>[
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(8, 12, 8, 4),
                                  child: Text(
                                    group,
                                    style:
                                        theme.textTheme.labelLarge?.copyWith(
                                      color: theme.colorScheme.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                for (final TextRulePreset preset
                                    in TextRulePreset.ofGroup(group))
                                  _presetTile(
                                    ctx,
                                    preset,
                                    picked: picked,
                                    onChanged: (bool? on) {
                                      setSheet(() {
                                        if (on == true) {
                                          picked.add(preset.id);
                                        } else {
                                          picked.remove(preset.id);
                                        }
                                      });
                                    },
                                  ),
                              ],
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  picked.isEmpty
                                      ? '还没选任何规则'
                                      : '已选 ${picked.length} 条',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                              FilledButton(
                                onPressed: picked.isEmpty
                                    ? null
                                    : () => Navigator.of(ctx).pop(picked.length),
                                child: const Text('添加'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ) ??
        0;
    if (added == 0 || !mounted) return;
    final List<TextRulePreset> chosen = picked
        .map(TextRulePreset.byId)
        .whereType<TextRulePreset>()
        .toList();
    final int real = await TextProcessor.instance.addPresets(chosen);
    CrashLog.mark('预设库[添加] ${chosen.map((TextRulePreset p) => p.id).join(",")} '
        '→ 实际新增 $real 条');
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          real == 0 ? '这些规则已经在了' : '已添加 $real 条规则（下面预览能看到效果）',
        ),
      ),
    );
  }

  /// 预设库里的一行：已添加的显示成不可勾选
  Widget _presetTile(
    BuildContext ctx,
    TextRulePreset preset, {
    required Set<String> picked,
    required ValueChanged<bool?> onChanged,
  }) {
    final ThemeData theme = Theme.of(ctx);
    final bool already = TextProcessor.instance.hasPreset(preset.id);
    return CheckboxListTile(
      key: ValueKey<String>('preset-${preset.id}'),
      dense: true,
      value: already || picked.contains(preset.id),
      // 已经在表里的不让再勾（再勾也没意义，addPresets 会跳过）
      onChanged: already ? null : onChanged,
      title: Row(
        children: <Widget>[
          Flexible(child: Text(preset.name)),
          if (preset.cautious) ...<Widget>[
            const SizedBox(width: 6),
            Tooltip(
              message: '可能影响正文，建议先预览',
              child: Icon(Icons.warning_amber_rounded,
                  size: 16, color: theme.colorScheme.error),
            ),
          ],
          if (already) ...<Widget>[
            const SizedBox(width: 6),
            Text('已添加',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ],
        ],
      ),
      subtitle: Text(preset.hint, style: theme.textTheme.bodySmall),
      controlAffinity: ListTileControlAffinity.leading,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rules = _rules;
    final sample = _sample.text;
    final processed = TextProcessor.instance.apply(sample);
    final active = TextProcessor.instance.activeCount;

    return Scaffold(
      appBar: AppBar(
        title: const Text('朗读文本预处理'),
        actions: <Widget>[
          IconButton(
            key: TextRulesPage.presetLibraryKey,
            tooltip: '预设库（页眉页脚 / 页码 / 注释）',
            icon: const Icon(Icons.library_add_check_outlined),
            onPressed: () => unawaited(_openPresetLibrary()),
          ),
          IconButton(
            tooltip: '恢复内置预设',
            icon: const Icon(Icons.settings_backup_restore),
            onPressed: _restoreDefaults,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add),
        label: const Text('新增规则'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
        children: <Widget>[
          Card.filled(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '预览（$active / ${rules.length} 条规则生效）',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _sample,
                    maxLines: 3,
                    minLines: 2,
                    decoration: const InputDecoration(
                      labelText: '样例文本',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  Text('实际朗读：', style: theme.textTheme.labelMedium),
                  const SizedBox(height: 4),
                  SelectableText(
                    processed.trim().isEmpty ? '（全部被规则删除，这段不会朗读）' : processed,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (rules.isEmpty)
            const Card.filled(
              margin: EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('还没有任何规则。点右下角「新增规则」，或用右上角恢复内置预设。'),
              ),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: rules.length,
              onReorder: _onReorder,
              itemBuilder: (context, index) {
                final rule = rules[index];
                final error = TextProcessor.validate(rule);
                return Card.filled(
                  key: ValueKey<String>(rule.id),
                  margin: const EdgeInsets.only(bottom: 8),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    leading: ReorderableDragStartListener(
                      index: index,
                      child: const Icon(Icons.drag_handle),
                    ),
                    title: Text(rule.name.isEmpty ? '未命名规则' : rule.name),
                    subtitle: Text(
                      error ?? rule.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: error == null
                          ? null
                          : TextStyle(color: theme.colorScheme.error),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Switch(
                          value: rule.enabled && error == null,
                          onChanged: error == null
                              ? (value) => unawaited(
                                  TextProcessor.instance
                                      .setEnabled(rule.id, value)
                                      .then((_) {
                                        if (mounted) setState(() {});
                                      }),
                                )
                              : null,
                        ),
                      ],
                    ),
                    onTap: () => _edit(rule),
                  ),
                );
              },
            ),
          const SizedBox(height: 4),
          Text(
            '· 规则按从上到下的顺序依次生效，前一条的结果是后一条的输入。\n'
            '· 拖动手柄可以调整顺序；关闭开关可临时停用某条规则做对比。\n'
            '· 「替换为」留空表示删除匹配到的内容；正则模式支持 \$1~\$9 与 \$& 回填分组。\n'
            '· 规则只影响朗读，阅读页显示的仍是原文。',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// 编辑 / 新增一条规则的结果
class _RuleEditResult {
  const _RuleEditResult.save(this.rule) : deleted = false;

  const _RuleEditResult.delete() : rule = null, deleted = true;

  final TextRule? rule;
  final bool deleted;
}

class _RuleEditDialog extends StatefulWidget {
  const _RuleEditDialog({required this.rule, required this.sample});

  /// null 表示新增
  final TextRule? rule;
  final String sample;

  @override
  State<_RuleEditDialog> createState() => _RuleEditDialogState();
}

class _RuleEditDialogState extends State<_RuleEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.rule?.name ?? '',
  );
  late final TextEditingController _pattern = TextEditingController(
    text: widget.rule?.pattern ?? '',
  );
  late final TextEditingController _replacement = TextEditingController(
    text: widget.rule?.replacement ?? '',
  );
  late bool _isRegex = widget.rule?.isRegex ?? true;

  @override
  void dispose() {
    _name.dispose();
    _pattern.dispose();
    _replacement.dispose();
    super.dispose();
  }

  TextRule get _draft => TextRule(
    id: widget.rule?.id ?? '',
    name: _name.text.trim(),
    pattern: _pattern.text,
    replacement: _replacement.text,
    enabled: widget.rule?.enabled ?? true,
    isRegex: _isRegex,
    builtin: widget.rule?.builtin ?? false,
  );

  void _submit() {
    final draft = _draft;
    if (TextProcessor.validate(draft) != null) return;
    final rule = draft.copyWith(
      id: draft.id.isEmpty ? 'user.${DateTime.now().microsecondsSinceEpoch}' : draft.id,
      name: draft.name.isEmpty ? '未命名规则' : draft.name,
    );
    Navigator.pop(context, _RuleEditResult.save(rule));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final draft = _draft;
    final error = TextProcessor.validate(draft);
    final hits = TextProcessor.countMatches(draft, widget.sample);
    final preview = TextProcessor.applyOne(draft, widget.sample);

    return AlertDialog(
      title: Text(widget.rule == null ? '新增规则' : '编辑规则'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '例如：去掉方括号内容',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pattern,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: '查找',
                  hintText: r'例如：\[[^\]]*\]',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _replacement,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: '替换为（留空 = 删除）',
                  hintText: '例如：三角形',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _isRegex,
                title: const Text('按正则表达式匹配'),
                subtitle: Text(_isRegex ? r'支持 \b \d \s 等，替换串支持 $1 / $&' : '按纯文本字面量匹配'),
                onChanged: (value) => setState(() => _isRegex = value),
              ),
              const Divider(),
              if (error != null)
                Text(error, style: TextStyle(color: theme.colorScheme.error))
              else ...<Widget>[
                Text('在样例文本里命中 $hits 处', style: theme.textTheme.labelMedium),
                const SizedBox(height: 4),
                Text(
                  preview,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        if (widget.rule != null)
          TextButton(
            onPressed: () => Navigator.pop(context, const _RuleEditResult.delete()),
            child: const Text('删除'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: error == null ? _submit : null,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

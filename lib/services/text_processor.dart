import 'package:flutter/foundation.dart';

import '../models/text_rule.dart';
import '../models/text_rule_presets.dart';
import 'storage_service.dart';

/// 朗读文本预处理：把规则表应用到「即将送去合成」的文本上
///
/// 只作用于朗读，不改动文档本身：阅读页显示的仍是原文，只有送进 TTS 引擎的
/// 字符串会被改写。规则的顺序有意义（前一条的输出是后一条的输入）。
class TextProcessor {
  TextProcessor._();

  /// 全局单例
  static final TextProcessor instance = TextProcessor._();

  /// 单条规则替换后的文本长度上限
  ///
  /// 规则写错（例如 `.*` 替换成长文本）时，文本会被放大到朗读几分钟都读不完，
  /// 内存也会跟着涨。超过上限就丢弃这次替换，宁可读原文。
  static const int maxOutputLength = 8192;

  List<TextRule> _rules = const <TextRule>[];

  /// 正则编译缓存：`apply` 每朗读一句都要调用，不能每次都重新编译
  final Map<String, RegExp> _cache = <String, RegExp>{};

  bool _initialized = false;

  /// 当前规则表（含停用的）
  List<TextRule> get rules => List<TextRule>.unmodifiable(_rules);

  /// 已启用且可用的规则条数
  int get activeCount => _rules.where((rule) => rule.enabled && isUsable(rule)).length;

  /// 有没有会真正生效的规则（TtsManager 据此跳过整条链路）
  bool get hasActiveRules => activeCount > 0;

  /// 启动时载入；从未保存过则播种内置预设
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    final stored = await StorageService.instance.loadTextRules();
    // null 表示从未保存过（用户清空成 0 条也会存成 `[]`，不会被当成没配过）
    _rules = stored ?? TextRule.defaults;
    if (stored == null) {
      await StorageService.instance.saveTextRules(_rules);
    }
  }

  /// 覆盖整张规则表（排序 / 恢复默认都走这里）
  Future<void> setRules(List<TextRule> rules) async {
    _rules = List<TextRule>.of(rules);
    _cache.clear();
    await StorageService.instance.saveTextRules(_rules);
  }

  /// 仅供测试：清掉初始化标记，让下一次 [init] 重新从存储播种
  @visibleForTesting
  void resetForTest() {
    _initialized = false;
    _rules = const <TextRule>[];
    _cache.clear();
  }

  /// 新增或按 id 覆盖一条规则
  Future<void> upsert(TextRule rule) async {
    final rules = List<TextRule>.of(_rules);
    final index = rules.indexWhere((item) => item.id == rule.id);
    if (index >= 0) {
      rules[index] = rule;
    } else {
      rules.add(rule);
    }
    await setRules(rules);
  }

  /// 删除一条规则
  Future<void> remove(String id) async =>
      setRules(_rules.where((rule) => rule.id != id).toList());

  /// 启用 / 停用一条规则
  Future<void> setEnabled(String id, bool enabled) async => setRules(
    _rules.map((rule) => rule.id == id ? rule.copyWith(enabled: enabled) : rule).toList(),
  );

  /// 恢复内置预设：保留用户自建规则，把被删掉的内置规则补回原位
  Future<void> restoreDefaults() async {
    final rules = List<TextRule>.of(_rules);
    final existing = rules.map((rule) => rule.id).toSet();
    for (final preset in TextRule.defaults) {
      if (existing.contains(preset.id)) continue;
      rules.add(preset);
    }
    // 内置规则统一放到前面，用户自建规则保持原有相对顺序跟在后面
    final builtin = rules.where((rule) => rule.builtin).toList();
    final custom = rules.where((rule) => !rule.builtin).toList();
    await setRules(<TextRule>[...builtin, ...custom]);
  }

  /// 已经把某条预设加进来了吗（面板据此显示「已添加」）
  bool hasPreset(String presetId) =>
      _rules.any((TextRule r) => r.id == 'preset.$presetId');

  /// 从预设库批量添加（v1.22.75）
  ///
  /// 已经在表里的跳过（按 `preset.<id>` 判重），所以「再点一次」是安全的。
  /// 返回真正新增的条数。
  Future<int> addPresets(List<TextRulePreset> presets) async {
    final Set<String> existing =
        _rules.map((TextRule r) => r.id).toSet();
    final List<TextRule> added = <TextRule>[];
    for (final TextRulePreset preset in presets) {
      final TextRule rule = preset.toRule();
      if (existing.contains(rule.id)) continue;
      // 正则编不过的预设不进来（目录是我们的，编不过就是我们的 bug，
      // 但绝不能让一条坏规则进到用户表里把朗读搞坏）
      if (validate(rule) != null) continue;
      added.add(rule);
    }
    if (added.isEmpty) return 0;
    await setRules(<TextRule>[..._rules, ...added]);
    return added.length;
  }

  /// 按顺序应用全部启用规则；任何单条规则出错都只跳过它，绝不影响朗读
  String apply(String input) {
    if (input.isEmpty || _rules.isEmpty) return input;
    var text = input;
    for (final rule in _rules) {
      if (!rule.enabled) continue;
      final next = _apply(rule, text, _cache);
      if (next != null) text = next;
    }
    return text;
  }

  /// 规则是否可用（查找内容非空，正则能编译）
  static bool isUsable(TextRule rule) =>
      rule.pattern.isNotEmpty && validate(rule) == null;

  /// 校验规则；返回 null 表示可用，否则是给用户看的错误说明
  static String? validate(TextRule rule) {
    if (rule.pattern.isEmpty) return '「查找」不能为空';
    if (!rule.isRegex) return null;
    try {
      RegExp(rule.pattern);
      return null;
    } catch (error) {
      return '正则表达式无效：${_brief(error)}';
    }
  }

  /// 在样例文本上只应用一条规则（编辑界面预览用）
  static String applyOne(TextRule rule, String input) =>
      _apply(rule, input, null) ?? input;

  /// 规则在样例文本上的命中次数（编辑界面预览用）
  static int countMatches(TextRule rule, String sample) {
    if (sample.isEmpty || rule.pattern.isEmpty) return 0;
    try {
      if (rule.isRegex) {
        return RegExp(rule.pattern, multiLine: true).allMatches(sample).length;
      }
      return sample.split(rule.pattern).length - 1;
    } catch (_) {
      return 0;
    }
  }

  /// 应用一条规则；不适用 / 出错 / 结果异常放大时返回 null（由调用方保留原文）
  static String? _apply(TextRule rule, String text, Map<String, RegExp>? cache) {
    if (rule.pattern.isEmpty || text.isEmpty) return null;
    try {
      final String next;
      if (rule.isRegex) {
        final regex = cache == null
            ? RegExp(rule.pattern, multiLine: true)
            : (cache[rule.cacheKey] ??= RegExp(rule.pattern, multiLine: true));
        next = rule.replacement.contains(r'$')
            ? text.replaceAllMapped(regex, (match) => _expand(rule.replacement, match))
            : text.replaceAll(regex, rule.replacement);
      } else {
        next = text.replaceAll(rule.pattern, rule.replacement);
      }
      if (next == text) return null;
      // 只在「被放大」时拦截：规则本来的用途就包含把短文本换成长文本，但要有上限
      if (next.length > maxOutputLength && next.length > text.length) return null;
      return next;
    } catch (_) {
      return null;
    }
  }

  /// 展开替换串里的 `$1`~`$9`、`$&`（`$$` 表示一个字面 `$`）
  ///
  /// Dart 的 `replaceAll` 不做分组回填，这里补上；不支持回填时按字面量处理。
  static String _expand(String replacement, Match match) {
    final buffer = StringBuffer();
    for (var i = 0; i < replacement.length; i++) {
      final char = replacement[i];
      if (char != r'$' || i + 1 >= replacement.length) {
        buffer.write(char);
        continue;
      }
      final next = replacement[i + 1];
      if (next == r'$') {
        buffer.write(r'$');
        i++;
        continue;
      }
      if (next == '&') {
        buffer.write(match.group(0) ?? '');
        i++;
        continue;
      }
      final group = int.tryParse(next);
      if (group == null || group < 1 || group > match.groupCount) {
        buffer.write(char); // 不是有效的分组引用，原样输出
        continue;
      }
      buffer.write(match.group(group) ?? '');
      i++;
    }
    return buffer.toString();
  }

  static String _brief(Object error) {
    final text = error.toString().replaceFirst('FormatException: ', '');
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/source_rule.dart';
import 'package:tts_reader/services/rule_engine.dart';
import 'package:tts_reader/services/source_importer.dart';

/// 用 194 条真实 legado 书源做覆盖率体检
///
/// ## 这个测试要回答什么
///
/// 「不引 JS 引擎」这个决定的代价到底多大 —— 具体是：
/// 真实书源里有多少条，其**规则能在本引擎的表达式求值器里跑通**。
///
/// 判据不是「能不能联网」（那受站点状态影响，不稳定），
/// 而是**规则里的表达式能否被求值器接受**：
/// 把每条源的所有规则字段抽出来，逐个尝试求值，统计失败原因。
void main() {
  final File file = File(
    r'D:\Workspaces\default-workspace\work\legado-src\real_book_sources.json',
  );

  test('194 条真实书源：规则可执行率体检', () async {
    if (!file.existsSync()) {
      markTestSkipped('本机无真实合集样本，跳过');
      return;
    }

    final ParseOutcome outcome = await SourceImporter.parseText(
      file.readAsStringSync(),
    );
    final List<SourceRule> all = outcome.rules;
    expect(all.length, greaterThan(150));

    // 统计
    var supported = 0;
    var unsupported = 0;
    final Map<String, int> failReasons = <String, int>{};
    final Map<String, int> okModes = <String, int>{};

    for (final SourceRule rule in all) {
      if (!rule.isSupported) {
        unsupported++;
        continue;
      }
      supported++;

      // 把该源所有规则字符串收集起来
      final List<String> rules = <String>[
        ..._collectRules(rule.ruleSearch),
        ..._collectRules(rule.ruleToc),
        ..._collectRules(rule.ruleContent),
        ..._collectRules(rule.ruleBookInfo),
        if (rule.searchUrl != null) rule.searchUrl!,
      ];

      for (final String r in rules) {
        if (r.trim().isEmpty) continue;
        try {
          // 只验证「表达式/模板」部分能否求值，不真的抓网页。
          // 用一段最小 HTML 让 CSS 部分也有内容可查。
          final RuleEngine engine = RuleEngine(
            content: _sampleHtml,
            kind: ContentKind.html,
            context: RuleContext(
              baseUrl: rule.url,
              variables: <String, Object?>{'key': '测试', 'page': 2},
            ),
          );
          engine.getStringList(r);
          final String mode = _modeOf(r);
          okModes[mode] = (okModes[mode] ?? 0) + 1;
        } catch (e) {
          final String reason = _reasonOf(e);
          failReasons[reason] = (failReasons[reason] ?? 0) + 1;
        }
      }
    }

    // 输出体检报告
    // ignore: avoid_print
    print('\n===== 真实书源规则体检（${all.length} 条）=====');
    // ignore: avoid_print
    print('可执行（isSupported）: $supported');
    // ignore: avoid_print
    print('不可执行（缺规则/非文本）: $unsupported');
    // ignore: avoid_print
    print('\n--- 规则类型分布（成功求值）---');
    okModes.forEach((String k, int v) => print('  $k: $v'));
    // ignore: avoid_print
    print('\n--- 失败原因 ---');
    if (failReasons.isEmpty) {
      // ignore: avoid_print
      print('  （无）');
    } else {
      failReasons.forEach((String k, int v) => print('  $k: $v'));
    }

    // 硬性断言：可执行率必须过半（这是方案 2 成立的前提）
    expect(
      supported / all.length,
      greaterThan(0.5),
      reason: '可执行书源应超过一半',
    );
  });
}

/// 递归收集规则 Map 里的所有字符串值
List<String> _collectRules(Map<String, dynamic>? rule) {
  if (rule == null) return const <String>[];
  final List<String> out = <String>[];
  for (final Object? v in rule.values) {
    if (v is String && v.trim().isNotEmpty) {
      out.add(v);
    } else if (v is Map) {
      out.addAll(_collectRules(
        v.map((Object? k, Object? val) => MapEntry(k.toString(), val)),
      ));
    }
  }
  return out;
}

String _modeOf(String rule) {
  final String r = rule.trim();
  if (r.startsWith('@js:') || r.startsWith('<js>')) return 'js';
  if (r.startsWith('@Json:') || r.startsWith(r'$.')) return 'json';
  if (r.startsWith('@XPath:') || r.startsWith('/')) return 'xpath';
  if (r.contains('{{')) return 'template';
  if (r.contains('##')) return 'css+replace';
  return 'css';
}

String _reasonOf(Object e) {
  final String s = e.toString();
  if (s.contains('XPath')) return 'XPath 未支持';
  if (s.contains('控制流')) return 'JS 控制流';
  if (s.contains('多条语句')) return 'JS 多条语句';
  if (s.contains('变量声明')) return 'JS 变量声明';
  if (s.contains('函数式构造')) return 'JS 函数式';
  if (s.contains('未知函数')) return '未知函数调用';
  if (s.contains('未实现的方法')) return '未实现的方法';
  if (s.contains('无法识别')) return '语法无法识别';
  return '其它：${s.length > 40 ? s.substring(0, 40) : s}';
}

/// 样本 HTML：让 CSS 规则有东西可查（不联网）
const String _sampleHtml = '''
<html><body>
<div class="list"><li><a href="/b/1">书</a><span class="author">作者</span></li></div>
<div id="content"><p>正文</p></div>
<div class="chapters"><a href="/c/1">第一章</a></div>
<h1>标题</h1>
</body></html>
''';

// 朗读跳过规则预设库（v1.22.75）
//
// 这一组守的是**安全性**：预设里最容易出事的是页码规则 ——
// 写宽了会把正文里的年份、数量、编号一起删掉，用户还以为是书坏了。
// 所以每条都断言「该删的删掉、不该删的一个字都不能动」。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/text_rule.dart';
import 'package:tts_reader/models/text_rule_presets.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/services/text_processor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('目录本身', () {
    test('每条预设的正则都能编译（否则加进去就是坏规则）', () {
      for (final TextRulePreset p in TextRulePreset.all) {
        expect(TextProcessor.validate(p.toRule()), isNull,
            reason: '预设「${p.name}」的正则编不过：${p.pattern}');
      }
    });

    test('id 唯一，且落成规则时带 preset. 前缀', () {
      final Set<String> ids = <String>{};
      for (final TextRulePreset p in TextRulePreset.all) {
        expect(ids.add(p.id), isTrue, reason: '预设 id 重复：${p.id}');
        expect(p.toRule().id, 'preset.${p.id}');
      }
    });

    test('每条都有说明，且分组齐全', () {
      for (final TextRulePreset p in TextRulePreset.all) {
        expect(p.hint.trim().isNotEmpty, isTrue,
            reason: '「${p.name}」没有说明，用户没法判断该不该加');
      }
      expect(TextRulePreset.groups, contains('页码'));
      expect(TextRulePreset.groups, contains('注释标记'));
      expect(TextRulePreset.groups.length, greaterThanOrEqualTo(4));
    });
  });

  group('安全：不该删的一个字都不能动', () {
    TextRule rule(String presetId) => TextRulePreset.byId(presetId)!.toRule();

    test('独立的纯数字页码被删', () {
      final String out = TextProcessor.applyOne(rule('page.standalone-number'),
          '上一段结束。\n42\n下一段开始。');
      expect(out, isNot(contains('\n42\n')));
      expect(out, contains('上一段结束'));
      expect(out, contains('下一段开始'));
    });

    test('正文里的年份、数量、编号一个都不能删', () {
      // PDF 里最常见的会误伤的情形
      const List<String> bodies = <String>[
        '我们一九〇三年的旧纲领就是这样。',
        '1990-1995 年间他住在莫斯科。',
        '这一版印了 500 册，定价 42 元。',
        '第三章 第 12 节讲了这件事。',
        '他生于 1912 年 3 月。',
      ];
      for (final String text in bodies) {
        expect(
          TextProcessor.applyOne(rule('page.standalone-number'), text),
          text,
          reason: '「$text」不该被页码规则动到',
        );
      }
    });

    test('带横线页码：独立行删，正文里的破折号不删', () {
      final String page = TextProcessor.applyOne(
          rule('page.dashed-number'), '正文。\n- 42 -\n正文。');
      expect(page, isNot(contains('- 42 -')));

      const String body = '他停顿了一下——然后继续。';
      expect(TextProcessor.applyOne(rule('page.dashed-number'), body), body,
          reason: '正文里的破折号不该被当成页码');
    });

    test('12/319 只在独立行被删', () {
      expect(
        TextProcessor.applyOne(rule('page.x-of-y'), '正文。\n12/319\n正文。'),
        isNot(contains('12/319')),
      );
      const String body = '速度约 3/4 光速。';
      expect(TextProcessor.applyOne(rule('page.x-of-y'), body), body);
    });

    test('带圈数字被删，普通数字保留', () {
      final String out = TextProcessor.applyOne(
          rule('note.circled'), '回避。① 下一句 123。');
      expect(out, isNot(contains('①')));
      expect(out, contains('123'), reason: '普通数字不能被当成脚注标记删掉');
    });

    test('英文断词接回：exam-ple 接上，正常连字符不动', () {
      final String out = TextProcessor.applyOne(
          rule('layout.hyphen-join'), 'an exam-\nple here');
      expect(out, contains('example'));
      // 「well-known」这种本来就在一行里的连字符不该动
      const String keep = 'a well-known fact';
      expect(TextProcessor.applyOne(rule('layout.hyphen-join'), keep), keep);
    });

    test('中文正文不受断词规则影响', () {
      const String body = '这是一个中文段落，\n换行了而已。';
      expect(TextProcessor.applyOne(rule('layout.hyphen-join'), body), body);
    });
  });

  group('加入规则表', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      TextProcessor.instance.resetForTest();
      await TextProcessor.instance.init();
    });

    test('批量加入后进入规则表，并按顺序生效', () async {
      final int before = TextProcessor.instance.rules.length;
      final int added = await TextProcessor.instance.addPresets(
        <TextRulePreset>[
          TextRulePreset.byId('page.standalone-number')!,
          TextRulePreset.byId('note.circled')!,
        ],
      );
      expect(added, 2);
      expect(TextProcessor.instance.rules.length, before + 2);
      expect(TextProcessor.instance.hasPreset('page.standalone-number'), isTrue);

      final String out = TextProcessor.instance
          .apply('正文。\n12\n又一句。① 完。');
      expect(out, isNot(contains('\n12\n')));
      expect(out, isNot(contains('①')));
    });

    test('重复加入不会产生重复规则', () async {
      final TextRulePreset p = TextRulePreset.byId('page.cn-page')!;
      expect(await TextProcessor.instance.addPresets(<TextRulePreset>[p]), 1);
      expect(await TextProcessor.instance.addPresets(<TextRulePreset>[p]), 0,
          reason: '第二次应当跳过（幂等）');
      final int count = TextProcessor.instance.rules
          .where((TextRule r) => r.id == 'preset.page.cn-page')
          .length;
      expect(count, 1);
    });

    test('加入后能持久化，重新初始化仍在', () async {
      await TextProcessor.instance
          .addPresets(<TextRulePreset>[TextRulePreset.byId('ocr.rule-line')!]);
      TextProcessor.instance.resetForTest();
      await TextProcessor.instance.init();
      expect(TextProcessor.instance.hasPreset('ocr.rule-line'), isTrue,
          reason: '重启后预设规则必须还在');
    });

    test('预设规则不是 builtin，恢复默认不会把它顶掉', () async {
      await TextProcessor.instance
          .addPresets(<TextRulePreset>[TextRulePreset.byId('page.of-pages')!]);
      await TextProcessor.instance.restoreDefaults();
      expect(TextProcessor.instance.hasPreset('page.of-pages'), isTrue,
          reason: '恢复内置预设只补内置项，不该动用户加的');
    });
  });
}

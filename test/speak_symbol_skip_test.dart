// 回归：① 这类「排版编号符」不能被单独送去朗读；单句卡死要能跳过继续读
//
// 真实故障（2026-10-30 用户真机 + 截图）：
//   书页第 14/252 页有一句「批孔就是批周总理，所以都要回避。①」
//   分句后 `①` 自成一句 → 送去 multitts → 15 秒无响应 → 整段朗读中止：
//   ```
//   位置[PDF起读] ref=13/18
//   朗读失败：本地 TTS · multitts 超时（15000ms）
//   PDF 朗读中止：…（停在第 13/18 句，位置不推进）
//   ```
//   之后反复在同一页重试，用户看到的就是「一个符号读很长时间」。
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/tts/tts_manager.dart';


void main() {
  // TtsManager.instance 构造时会创建 SystemTtsEngine → FlutterTts → MethodChannel，
  // 必须先初始化 Binding，否则 setMethodCallHandler 断言失败
  TestWidgetsFlutterBinding.ensureInitialized();

  group('排版编号符不应单独送去朗读（v1.22.64）', () {
    test('带圈数字 ①-⑳ 全部跳过', () {
      final TtsManager m = TtsManager.instance;
      for (final String ch in <String>['①', '②', '⑩', '⑳', '⓪', '㉑']) {
        expect(
          m.debugSpeakable(ch),
          isNull,
          reason: '「$ch」是脚注编号，引擎读不出，必须跳过',
        );
      }
    });

    test('带括号 / 带点数字也跳过', () {
      final TtsManager m = TtsManager.instance;
      for (final String ch in <String>['⑴', '⒈', '❶', '➀']) {
        expect(m.debugSpeakable(ch), isNull, reason: '「$ch」应跳过');
      }
    });

    test('罗马数字 / 上标 / 下标跳过', () {
      final TtsManager m = TtsManager.instance;
      for (final String ch in <String>['Ⅰ', 'Ⅻ', '¹', '²', '₀']) {
        expect(m.debugSpeakable(ch), isNull, reason: '「$ch」应跳过');
      }
    });

    test('句尾挂编号的正常句子照常读（不能误伤正文）', () {
      final TtsManager m = TtsManager.instance;
      const String sentence = '所以都要回避。①';
      final String? got = m.debugSpeakable(sentence);
      expect(got, isNotNull, reason: '整句有正文，必须照读');
      expect(got, contains('回避'), reason: '原文不能被改掉');
    });

    test('普通数字与汉字照常读（既有行为不退化）', () {
      final TtsManager m = TtsManager.instance;
      expect(m.debugSpeakable('3'), isNotNull);
      expect(m.debugSpeakable('第 3 章'), isNotNull);
      expect(m.debugSpeakable('字'), isNotNull);
    });

    test('〇 与 々 是真正的字，必须照常读', () {
      final TtsManager m = TtsManager.instance;
      expect(m.debugSpeakable('一九〇〇年'), isNotNull, reason: '〇 是中文字，不是编号符');
      expect(m.debugSpeakable('人々'), isNotNull, reason: '々 是叠字符号，要读');
    });

    test('纯标点仍被挡掉（v1.21.38 的既有防护不退化）', () {
      final TtsManager m = TtsManager.instance;
      for (final String p in <String>['”', '。', '——', '，', '（）']) {
        expect(m.debugSpeakable(p), isNull, reason: '纯标点「$p」必须挡掉');
      }
    });
  });

  // ───────────────────────────────────────────────────────────
  // v1.22.66：罕见字（CJK 扩展 A/B、兼容表意、私用区）的第二道防线
  //
  // 背景：黑名单只能挡**已知**的排版编号符（①）。长句里混入罕见字时，
  // 它是 \p{Lo}、能通过 _hasMeaningfulChar，而引擎读不出 → 超时；
  // 上层又因「去掉符号后仍有一大段正文」不跳过 → 整段朗读中止。
  // 这里补的是「超时后剥掉罕见字重发一次，别整段停住」。
  // ───────────────────────────────────────────────────────────
  group('罕见字应在超时后剥离重试（v1.22.66）', () {
    test('CJK 扩展 A（U+3400-4DBF）被剥离', () {
      final TtsManager m = TtsManager.instance;
      // U+3421 是扩展 A 里的字，正常引擎读不出
      const String text = '前面正文\u3421后面正文';
      expect(m.debugSanitizeForEngine(text), '前面正文后面正文');
    });

    test('CJK 扩展 B（U+20000 起，代理对）被剥离', () {
      final TtsManager m = TtsManager.instance;
      const String text = '正文\u{20000}正文';
      expect(m.debugSanitizeForEngine(text), '正文正文');
    });

    test('兼容表意字（U+FA00 附近）被剥离', () {
      final TtsManager m = TtsManager.instance;
      expect(m.debugSanitizeForEngine('a\uFA0Cb'), 'ab');
    });

    test('私用区（U+E000-F8FF）被剥离', () {
      final TtsManager m = TtsManager.instance;
      expect(m.debugSanitizeForEngine('x\uE123y'), 'xy');
    });

    test('常用汉字 / 标点 / 英文数字一个都不动', () {
      final TtsManager m = TtsManager.instance;
      const String normal = '第 3 章：桃花源记。ABC 123';
      expect(m.debugSanitizeForEngine(normal), normal);
    });

    test('〇 与 々 不在剥离范围（它们是中文字，要读）', () {
      final TtsManager m = TtsManager.instance;
      for (final String t in <String>['一九〇〇年', '人々', '第々三']) {
        expect(m.debugSanitizeForEngine(t), t, reason: '「$t」不该被剥离');
      }
    });

    test('整句都是罕见字时净化后为空（调用方据此放弃重试）', () {
      final TtsManager m = TtsManager.instance;
      expect(m.debugSanitizeForEngine('\u3421\u3422\u3423').trim(), '');
    });

    test('长句正文里夹一个罕见字：只少一个字，正文完整', () {
      final TtsManager m = TtsManager.instance;
      const String sentence =
          '这是一段足够长的正文，用来验证罕见字被剥掉之后其余内容仍然完整保留下来。';
      final String withRare = sentence.replaceFirst('验证', '验\u3421证');
      final String cleaned = m.debugSanitizeForEngine(withRare);
      expect(cleaned, sentence, reason: '除罕见字外的每个字都必须保留');
    });
  });
}

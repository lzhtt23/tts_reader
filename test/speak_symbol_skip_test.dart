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
}

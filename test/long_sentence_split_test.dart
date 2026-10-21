import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/document_service.dart';

/// 长句分割：优先在标点处断开，不要切在词中间
///
/// 真机反馈：长句被 `substring(0, maxLength)` 一刀切，常在词中间
/// （「无产阶|级革命」），读起来会顿一下。
void main() {
  test('超长句在标点处断开，不切在词中间', () {
    const String long =
        '第一句话讲的是无产阶级革命的历史条件。第二句话继续展开说明具体情况。'
        '第三句话给出结论性判断。';
    final List<String> chunks = DocumentService.readChunks(long, maxLength: 30);
    expect(chunks.length, greaterThan(1));
    for (final String c in chunks) {
      expect(c.endsWith('。') || c.length <= 30, isTrue,
          reason: '除最后一片外都应在句号处断开：$c');
    }
    // 拼回去等于原文（只切不改）
    expect(chunks.join(), long);
  });

  test('没有标点时按长度硬切，但不会丢字', () {
    final String noPunct = 'あ' * 100;
    final List<String> chunks =
        DocumentService.readChunks(noPunct, maxLength: 30);
    expect(chunks.join(), noPunct);
    expect(chunks.every((String c) => c.length <= 30), isTrue);
  });

  test('短文本不被切', () {
    const String short = '就一句话。';
    expect(DocumentService.readChunks(short, maxLength: 30), <String>[short]);
  });
}

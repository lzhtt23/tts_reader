import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/features/pdf_reading/sentence_centering.dart';

/// 「首次进入 PDF」必须把朗读句**强制居中**
///
/// 真机（平板 2026-10-19）：从文档库进 PDF，页面停在 15% 位置，
/// 朗读句常在页面下半部分 → 开屏看不到在读哪句（日志 `死区=内 → 不滚`）。
/// 约定见 `sentence_centering.dart` 的场景表：首次进入 = forceCenter: true。
void main() {
  const double viewport = 800;

  test('首次进入（forceCenter）即便已在死区内也要滚到目标位', () {
    final bool scroll = SentenceCentering.shouldScroll(
      sentenceY: viewport * 0.25,
      viewportHeight: viewport,
      alignment: 0.25,
      targetOffsetValue: 120,
      currentScrollOffset: 0,
      forceCenter: true,
    );
    expect(scroll, isTrue, reason: '进场这一拍必须无条件对齐');
  });

  test('首次进入但已经在目标位：不重复滚', () {
    final bool scroll = SentenceCentering.shouldScroll(
      sentenceY: viewport * 0.25,
      viewportHeight: viewport,
      alignment: 0.25,
      targetOffsetValue: 120,
      currentScrollOffset: 120.2,
      forceCenter: true,
    );
    expect(scroll, isFalse);
  });

  test('日常跟读（不强制）落在死区内不滚', () {
    final bool scroll = SentenceCentering.shouldScroll(
      sentenceY: viewport * 0.25,
      viewportHeight: viewport,
      alignment: 0.25,
      targetOffsetValue: 120,
      currentScrollOffset: 0,
    );
    expect(scroll, isFalse, reason: '日常跟读要保持安静，不能在死区内反复微调');
  });
}

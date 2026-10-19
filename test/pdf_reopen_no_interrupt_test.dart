import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';

/// 点文档卡片回到 PDF 页时**不能打断自己的朗读**
///
/// 真机（用户 2026-10-19）：PDF 正在文档库里朗读，点卡片进 PDF 页 → 朗读停了。
/// 原因：PDF 是借 TtsManager 的声音读的，`playing == true`，
/// 旧代码只看这一条就 `terminateForDocumentSwitch` —— 等于把自己掐了。
void main() {
  test('正在借声读这本 → 不终止（这就是那个 bug）', () {
    expect(
      shouldTerminateOnReopen(
        playing: true,
        borrowed: true,
        activeDocumentId: null,
        documentId: 'pdf-1',
      ),
      isFalse,
    );
  });

  test('正在读的就是这本 → 不终止', () {
    expect(
      shouldTerminateOnReopen(
        playing: true,
        borrowed: false,
        activeDocumentId: 'pdf-1',
        documentId: 'pdf-1',
      ),
      isFalse,
    );
  });

  test('正在读别的书 → 终止（换歌语义）', () {
    expect(
      shouldTerminateOnReopen(
        playing: true,
        borrowed: false,
        activeDocumentId: 'book-b',
        documentId: 'pdf-1',
      ),
      isTrue,
    );
  });

  test('没在读 → 不终止', () {
    expect(
      shouldTerminateOnReopen(
        playing: false,
        borrowed: false,
        activeDocumentId: 'book-b',
        documentId: 'pdf-1',
      ),
      isFalse,
    );
  });
}

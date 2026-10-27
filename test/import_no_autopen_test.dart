import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/pages/home_page.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// **朗读进行中导入文档：不自动打开，避免打断朗读**（v1.22.61）
///
/// ## 需求（用户 2026-10-25，拍板方案①）
///
/// > 「在朗读时将其他文档导入文档库，不立即打开导入的文档，以防朗读出现问题」
///
/// ## 原来为什么会打断朗读
///
/// `_import()` 末尾**无条件** `await _open(stored)` → 进阅读页 →
/// `TtsManager.loadDocument()`（`tts_manager.dart:528`）或
/// `PdfReadSession.open()` 的第一步都是 `terminateForDocumentSwitch(新书 id)`，
/// 按"换歌"语义**终止正在进行的朗读**。
///
/// 所以「朗读中导入」必然打断朗读 —— 不是偶发，是确定行为。
///
/// ## 判据
///
/// 有朗读在进行（含**暂停**：暂停的会话一样会被换书终止）→ 只入库不打开；
/// 没有朗读 → 保持原样「导入即打开」，不改既有手感。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('★导入后要不要自动打开', () {
    test('★核心：TTS 正在朗读 → 不自动打开（新书只入库）', () {
      expect(
        HomePage.shouldAutoOpenAfterImport(
          ttsSpeaking: true,
          pdfPlaybackActive: false,
        ),
        isFalse,
        reason: '朗读中自动打开会 terminateForDocumentSwitch → 朗读被终止，'
            '正是用户要避免的"朗读出现问题"',
      );
    });

    test('★核心：PDF 正在朗读 → 不自动打开', () {
      expect(
        HomePage.shouldAutoOpenAfterImport(
          ttsSpeaking: false,
          pdfPlaybackActive: true,
        ),
        isFalse,
        reason: 'PDF 走的是另一套会话，必须单独判 —— 只判 TtsManager.speaking 会漏掉它',
      );
    });

    test('两个来源都在读 → 不自动打开', () {
      expect(
        HomePage.shouldAutoOpenAfterImport(
          ttsSpeaking: true,
          pdfPlaybackActive: true,
        ),
        isFalse,
      );
    });

    test('★没在朗读 → 保持原来的「导入即打开」', () {
      expect(
        HomePage.shouldAutoOpenAfterImport(
          ttsSpeaking: false,
          pdfPlaybackActive: false,
        ),
        isTrue,
        reason: '不该顺手改掉非朗读场景的手感 —— 那会让"导入后要点两下"成为新抱怨',
      );
    });
  });

  group('★对照：旧行为（无条件打开）会被这条判据拦下', () {
    test('朗读中：新判据与旧行为不同（否则用例抓不到 bug）', () {
      // 复现修前：`_import()` 末尾无条件 `_open(stored)`
      bool legacyAutoOpen() => true;

      expect(legacyAutoOpen(), isTrue, reason: '前提：旧行为确实是"总是打开"');
      final bool fixed = HomePage.shouldAutoOpenAfterImport(
        ttsSpeaking: true,
        pdfPlaybackActive: false,
      );
      expect(fixed, isNot(legacyAutoOpen()),
          reason: '★修复后必须与旧行为不同，否则这条改动等于没生效');
    });

    test('非朗读态：新判据与旧行为一致（保证没误伤）', () {
      expect(
        HomePage.shouldAutoOpenAfterImport(
          ttsSpeaking: false,
          pdfPlaybackActive: false,
        ),
        isTrue,
        reason: '非朗读态行为必须与旧实现一致',
      );
    });
  });

  group('readingInProgress：从真实单例读状态', () {
    setUp(() {
      TtsManager.instance.resetSessionForTest();
      PdfReadSession.instance.resetForTest();
    });

    test('刚重置（没读任何书）→ 不算忙 → 允许自动打开', () {
      expect(
        HomePage.readingInProgress(
          pdf: PdfReadSession.instance,
          tts: TtsManager.instance,
        ),
        isFalse,
      );
    });
  });
}

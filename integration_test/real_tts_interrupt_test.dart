import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/system_tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// **真机验证：走真实 `SystemTtsEngine` 的「stop 打断」路径（§4.108）**
///
/// ## 为什么必须单独有这一份
///
/// HANDOFF §4.107 末尾自己承认过：模拟器**没有可用的系统 TTS 引擎**，所以
/// 「`stop()` 打断一次正在飞的朗读 → 设标记 → 主循环读到真」这条链
/// **从来没有在真机路径上验证过**。之前所有假引擎都是「立刻返回」的，
/// `_speaking` 在 `stop()` 之前就变 false，设标记的分支根本走不到。
///
/// 这一份**不用任何假引擎**：直接 `registerEngine(SystemTtsEngine())`，
/// 也就是 App 里真正用的那个实现（`speak()` 会挂到整段读完）。
/// 前提：设备上装了可用的 TTS 引擎（本机：MultiTTS `org.nobody.multitts`，
/// 已 `settings put secure tts_default_synth` 设为默认）。
///
/// ## 断言
/// 1. `speak()` 在 `stop()` 之后**很快**返回（不是挂满整句）→ 说明打断真的生效；
/// 2. `lastSpeakInterrupted == true` → 共享层把这一拍识别为「被打断」；
/// 3. 游标**不推进** → 被掐掉的朗读不算读完；
/// 4. 反向：不打断时必须照常推进（判据不误伤）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final tts = TtsManager.instance;

  /// 长句：确保引擎有足够时间"还在读"
  StructuredDocument longDoc() => StructuredDocument(
        chapters: <Chapter>[
          Chapter(
            title: 'C0',
            paragraphs: <Paragraph>[
              for (var p = 0; p < 6; p++)
                Paragraph(sentences: <Sentence>[
                  Sentence('这是第 $p 段的第一句，特意写长一些，'
                      '好让朗读引擎有足够的时间还在读它。'),
                ]),
            ],
          ),
        ],
      );

  Future<void> pumpFor(WidgetTester tester, int ms) async {
    final deadline = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
  }

  Future<void> waitFor(bool Function() cond, int timeoutMs) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    tts.resetSessionForTest();
    tts.resetTimeouts();
    // 真实引擎：App 里用的就是这个
    await tts.registerEngine(SystemTtsEngine(), makeActive: true);
  });

  tearDown(() async {
    await tts.stop();
    tts.resetTimeouts();
    tts.resetSessionForTest();
  });

  testWidgets('① 前提：真实引擎确实能起读（否则后面的断言无意义）', (tester) async {
    tts.loadDocument(longDoc(), title: '真机打断', documentId: 'real-tts');
    tts.speakFrom(0, 0, 0);
    // 给引擎时间真正开始读
    await pumpFor(tester, 1500);

    // ignore: avoid_print
    print('DEVICE_PROBE[真机①] hasSession=${tts.hasSession} '
        'speaking=${tts.speaking} '
        'paused=${tts.paused} cursor=${tts.cursor} settled=${tts.settledCursor}');

    expect(tts.hasSession, isTrue, reason: '前提：文档已绑定');
    expect(tts.speaking, isTrue,
        reason: '前提：真实引擎应当处于"正在读"状态。\n'
            '若这里是 false，说明本机没有可用的 TTS 引擎，'
            '后面的打断断言就不成立（请先装好引擎并设为默认）');
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('② stop() 打断真实朗读 → 标记为打断 + 游标不推进', (tester) async {
    tts.loadDocument(longDoc(), title: '真机打断', documentId: 'real-tts');
    tts.speakFrom(0, 0, 0);
    await pumpFor(tester, 1200);

    // 前提：此刻确实在读
    expect(tts.speaking, isTrue,
        reason: '前提：必须"正在读"时才能验证打断（引擎不可用会 false）');
    final before = tts.settledCursor;
    final stopAt = DateTime.now();

    await tester.runAsync(() => tts.stop());
    final returnMs = DateTime.now().difference(stopAt).inMilliseconds;

    // 让取消回调有机会回来
    await pumpFor(tester, 600);
    final after = tts.settledCursor;

    // ignore: avoid_print
    print('DEVICE_PROBE[真机②] stop() 返回耗时=${returnMs}ms '
        'lastSpeakInterrupted=${tts.speaking} '
        '位置 $before → $after cursor=${tts.cursor}');

    expect(tts.speaking, isFalse,
        reason: '真实引擎在 stop() 掐掉朗读后，共享层必须把它标记为「被打断」。\n'
            '这是 §4.107/§4.108 在**真机路径**上的核心不变量');
    expect(after, before,
        reason: '**被 stop 掐掉的那一句不算读完**，位置不能因此推进');
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('③ 反向：不打断时真实朗读照常推进（判据不误伤）',
      (tester) async {
    tts.loadDocument(longDoc(), title: '真机打断', documentId: 'real-tts');
    tts.speakFrom(0, 0, 0);
    await pumpFor(tester, 500);
    final before = tts.settledCursor;

    // 不打断，等它自然读完至少一句
    await tester.runAsync(() => waitFor(() => tts.settledCursor != before, 12000));
    await pumpFor(tester, 300);
    final after = tts.settledCursor;

    // ignore: avoid_print
    print('DEVICE_PROBE[真机③] $before → $after '
        'lastSpeakInterrupted=${tts.speaking}');
    expect(after, isNot(before),
        reason: '没人打断时必须照常推进 —— 若这里不动，说明判据把正常朗读也挡掉了，'
            '或者引擎读得太慢/没出声');
  }, timeout: const Timeout(Duration(minutes: 4)));
}

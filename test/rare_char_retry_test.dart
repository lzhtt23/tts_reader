// 端到端：长句里混入罕见字导致超时 → **净化重试**，朗读不中止（v1.22.66）
//
// 这是 v1.22.64 那个「① 卡死」修复留下的缺口：
//   · 黑名单只挡已知的排版编号符；
//   · 长句里混入 CJK 扩展字时，`_shouldSkipStuckUnit` 因「还有一大段正文」
//     不会跳过 → `_fail()` → 整段朗读中止；
//   · 用户看到的就是「读到这里停了」。
//
// 本用例用一个「遇到扩展 A 就永不回应、其余立刻读完」的假引擎，
// 断言两件事：
//   1. 引擎确实收到了**剥掉罕见字之后**的文本（说明重试发生了）；
//   2. 这一句之后还能继续读下一句（说明没有被当成致命错误中止）。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 扩展 A 里的一个字：假引擎读到它就不回应（模拟真实引擎读不出罕见字）
const String kRare = '\u3421';

/// 遇到罕见字就挂住、其余立即完成的假引擎
class _RareCharEngine with SyntheticTtsEngine implements TtsEngine {
  final List<String> spoken = <String>[];

  /// **当前**挂起的那次合成。注意不能用一个全局 Completer：
  /// `_runBody` 开头会先 stop 一次，那次就能把它提前放行，
  /// 于是第一次 speak 立刻返回、超时根本不会发生（踩过一次）。
  Completer<void>? _pending;

  @override
  String get id => 'rare-char';

  @override
  String get displayName => '假引擎（罕见字不回应）';

  @override
  bool get isAvailable => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<TtsVoice>> getVoices() async => const <TtsVoice>[];

  @override
  Future<void> setVoice(String voiceId) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    if (text.contains(kRare)) {
      // 模拟「引擎读不出这个字」：不回调完成，直到上层 stop
      final Completer<void> c = Completer<void>();
      _pending = c;
      await c.future;
    }
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {
    // 真引擎 stop 会中止挂起的合成；只放行**当前**这次，
    // 不能影响后续（尤其是超时后的净化重试要能正常发出去）。
    final Completer<void>? p = _pending;
    _pending = null;
    if (p != null && !p.isCompleted) p.complete();
  }

  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    final TtsManager tts = TtsManager.instance;
    tts.resetTimeouts();
    tts.resetSessionForTest();
    tts
      ..speakTimeout = const Duration(milliseconds: 250)
      ..initTimeout = const Duration(milliseconds: 300)
      ..voiceTimeout = const Duration(milliseconds: 300)
      ..controlTimeout = const Duration(milliseconds: 300);
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
  });

  test('长句含罕见字超时后，剥掉罕见字重试并继续读下一句', () async {
    final TtsManager tts = TtsManager.instance;
    final _RareCharEngine engine = _RareCharEngine();
    await tts.registerEngine(engine, makeActive: true);

    const String longSentence =
        '这是一段足够长的正文用来确保兜底判据不会直接把它当成可跳过的小碎片，'
        '里面夹着一个引擎读不出的罕见字$kRare在中间。';

    tts.speakLines(<String>[longSentence, '第二句正常内容']);
    await tts.whenSessionFinished().timeout(
          const Duration(seconds: 20),
          onTimeout: () => fail('朗读没有收尾：净化重试链路可能卡死'),
        );

    // 1) 第一次发的是原文（含罕见字）
    expect(
      engine.spoken.first,
      contains(kRare),
      reason: '第一次当然先按原文发，不能一上来就擅自改内容',
    );

    // 2) 超时后重试的那次，罕见字已被剥掉
    expect(
      engine.spoken.length,
      greaterThanOrEqualTo(2),
      reason: '超时后必须发生一次净化重试，实际只发过 ${engine.spoken.length} 次',
    );
    final String retried = engine.spoken[1];
    expect(retried.contains(kRare), isFalse, reason: '重试文本里不该再有罕见字');
    expect(retried, contains('这是一段足够长的正文'), reason: '正文必须完整保留');

    // 3) 没有因为这一句就把整段朗读判死
    expect(
      engine.spoken.any((String t) => t.contains('第二句正常内容')),
      isTrue,
      reason: '罕见字那句应当被救回来，然后继续读下一句',
    );
    expect(tts.error, isNull, reason: '救回来之后不该留下「朗读失败」');
  });

  test('本来就没有罕见字时，不发第二次请求（不做无谓重试）', () async {
    final TtsManager tts = TtsManager.instance;
    final _RareCharEngine engine = _RareCharEngine();
    await tts.registerEngine(engine, makeActive: true);

    tts.speakLines(<String>['一句正常的中文，没有任何罕见字。']);
    await tts.whenSessionFinished().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('正常朗读没有收尾'),
        );

    expect(engine.spoken, <String>['一句正常的中文，没有任何罕见字。'],
        reason: '正常句子只该发一次');
  });
}

// 词级高亮：引擎 → Manager → UI 的转报链路（v1.22.69）
//
// 设计要点（改之前先看）：
//   · 词级进度是**可选能力**（WordProgressCapable），不做进 TtsEngine 抽象，
//     否则所有测试替身都要跟着实现一遍；
//   · Manager 只负责把「当前生效引擎」的区间转报成一个稳定 notifier，
//     UI 不用关心现在用哪个引擎、它支不支持；
//   · 引擎不支持 → wordHighlight 恒为 null → 阅读页自动退化为句级高亮。
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 支持词级进度的假引擎
class _WordEngine with SyntheticTtsEngine implements TtsEngine, WordProgressCapable {
  final ValueNotifier<({int start, int end})?> _range =
      ValueNotifier<({int start, int end})?>(null);

  @override
  ValueListenable<({int start, int end})?> get wordRange => _range;

  void emit(int start, int end) => _range.value = (start: start, end: end);

  @override
  String get id => 'word-engine';
  @override
  String get displayName => '假引擎（报词级）';
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
  Future<void> speak(String text) async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  void setCompletionHandler(void Function()? handler) {}
  @override
  Future<void> dispose() async {}
}

/// 不支持词级进度的假引擎（绝大多数现有替身就是这种）
class _PlainEngine with SyntheticTtsEngine implements TtsEngine {
  @override
  String get id => 'plain-engine';
  @override
  String get displayName => '假引擎（不报词级）';
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
  Future<void> speak(String text) async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  void setCompletionHandler(void Function()? handler) {}
  @override
  Future<void> dispose() async {}
}

/// 读得慢、不报词级的假引擎（验证「按语速推算」兜底）
class _SlowPlainEngine with SyntheticTtsEngine implements TtsEngine {
  @override
  String get id => 'slow-plain';
  @override
  String get displayName => '假引擎（慢读、不报词级）';
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
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
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
    TtsManager.instance.resetSessionForTest();
    TtsManager.instance.wordHighlight.value = null;
  });

  test('支持词级的引擎：区间被转报到 Manager', () async {
    final TtsManager tts = TtsManager.instance;
    final _WordEngine engine = _WordEngine();
    await tts.registerEngine(engine, makeActive: true);

    expect(tts.wordHighlight.value, isNull, reason: '还没开口，不该有区间');

    engine.emit(3, 5);
    expect(tts.wordHighlight.value, (start: 3, end: 5));

    engine.emit(6, 9);
    expect(tts.wordHighlight.value, (start: 6, end: 9),
        reason: '引擎每报一次都要跟着更新');
  });

  test('不支持词级的引擎：Manager 恒为 null（界面自动退化句级）', () async {
    final TtsManager tts = TtsManager.instance;
    await tts.registerEngine(_PlainEngine(), makeActive: true);
    expect(tts.wordHighlight.value, isNull);
  });

  test('换引擎：旧引擎的区间不再影响界面', () async {
    final TtsManager tts = TtsManager.instance;
    final _WordEngine word = _WordEngine();
    await tts.registerEngine(word, makeActive: true);
    word.emit(1, 4);
    expect(tts.wordHighlight.value, (start: 1, end: 4));

    // 换到不支持词级的引擎
    await tts.registerEngine(_PlainEngine(), makeActive: true);
    expect(tts.wordHighlight.value, isNull,
        reason: '换成不报词级的引擎后必须清空，不能留着上一句的区间');

    // 旧引擎之后再报，也不该影响界面（监听应当已摘掉）
    word.emit(7, 8);
    expect(tts.wordHighlight.value, isNull,
        reason: '旧引擎的监听必须解绑，否则会出现「随机一个字被点亮」');
  });

  test('换回支持词级的引擎：重新接上', () async {
    final TtsManager tts = TtsManager.instance;
    final _WordEngine word = _WordEngine();
    await tts.registerEngine(word, makeActive: true);
    await tts.registerEngine(_PlainEngine(), makeActive: true);
    await tts.setActiveEngine('word-engine');
    word.emit(2, 6);
    expect(tts.wordHighlight.value, (start: 2, end: 6));
  });

  group('引擎不报词级时按语速推算（v1.22.69 兜底）', () {
    test('不报词级的引擎也会让高亮往前走', () async {
      final TtsManager tts = TtsManager.instance;
      await tts.registerEngine(_SlowPlainEngine(), makeActive: true);

      tts.speakLines(<String>['一二三四五六七八九十一二三四五六七八九十']);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final a = tts.wordHighlight.value;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final b = tts.wordHighlight.value;

      expect(a, isNotNull, reason: '引擎不报词级时也要有推算区间，否则功能等于没做');
      expect(b, isNotNull);
      expect(b!.start, greaterThanOrEqualTo(a!.start),
          reason: '推算只会往前，不能倒退');
      expect(b.start, greaterThan(0),
          reason: '念了 400ms 以上，不该还停在第 0 个字');

      await tts.stop();
    });

    test('暂停后清空词级高亮，不会继续往前跳', () async {
      final TtsManager tts = TtsManager.instance;
      await tts.registerEngine(_SlowPlainEngine(), makeActive: true);
      tts.speakLines(<String>['一二三四五六七八九十一二三四五六七八九十']);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(tts.wordHighlight.value, isNotNull);

      await tts.pause();
      expect(tts.wordHighlight.value, isNull, reason: '暂停后不该还亮着词');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(tts.wordHighlight.value, isNull, reason: '停表之后不能再冒出来');
      await tts.stop();
    });
  });
}

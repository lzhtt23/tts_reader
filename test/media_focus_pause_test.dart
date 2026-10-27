import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/device_info.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/audio_session_source.dart';
import 'package:tts_reader/tts/media_interruption.dart';
import 'package:tts_reader/tts/tts_audio_handler.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 音频焦点策略测试（v1.21.15）
///
/// 需求背景：ColorOS / Android 13+ 上，暂停时 `setActive(false)` 交出音频焦点之后，
/// 耳机 / 通知栏的「播放」键可能**不再被路由到本应用**（用户报「按了没反应」）。
/// 所以：**暂停不释放焦点**，只在停止 / 会话结束时释放。
///
/// 这两条链都要守：
///   1. 通知栏 / 耳机 → `TtsAudioHandler.pause()`
///   2. 阅读页控制栏 → `TtsManager.pause()`

/// 假引擎：只记调用，不真的出声
class _SilentEngine with SyntheticTtsEngine implements TtsEngine {
  final List<String> spoken = <String>[];
  void Function()? _onComplete;

  @override
  String get id => 'silent-engine';

  @override
  String get displayName => '假引擎（不出声）';

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
    await Future<void>.delayed(const Duration(milliseconds: 150));
    _onComplete?.call();
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) {
    _onComplete = handler;
  }

  @override
  Future<void> dispose() async {}
}

/// 假来源：模拟一个通知栏来源（播放 / 暂停状态可切）
class _FakeSource implements AudioSessionSource {
  bool pauseCalled = false;
  bool playCalled = false;

  /// 让用例可以摆出「正在播」「已暂停」两种状态
  bool playingValue = true;
  bool pausedValue = false;

  @override
  String get sourceId => 'fake-source';

  @override
  bool get hasSession => true;

  @override
  void onStop() {}

  @override
  bool get playing => playingValue;

  @override
  bool get paused => pausedValue;

  @override
  String get documentTitle => '焦点用例';

  @override
  String get positionLabel => '第 1 页';

  @override
  double get rate => 1.0;

  @override
  int get progressTotal => 10;

  @override
  int get progressIndex => 1;

  @override
  bool get canSeek => false;

  @override
  void playFromCursor() => playCalled = true;

  @override
  Future<void> pause() async => pauseCalled = true;

  @override
  void seekToProgress(double fraction) {}

  @override
  void skipChapter(int delta) {}

  @override
  void skipSentenceForward() {}

  @override
  void skipSentenceBackward() {}

  @override
  void skipPageForward() {}

  @override
  void skipPageBackward() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    MediaInterruptionController.instance.resetForTest();
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    MediaInterruptionController.instance.resetForTest();
  });

  test('通知栏/耳机 pause()：不释放音频焦点（只有 stop 才释放）', () async {
    // 纯单测里 `AudioService.init` 起不来（要 path_provider 等平台插件），
    // 但 handler 本体可以直接构造 —— 这一层测的只是焦点策略，不需要通知栏。
    final TtsAudioHandler handler = TtsAudioHandler(TtsManager.instance);
    final _FakeSource source = _FakeSource();
    handler.activate(source);

    final int before = MediaInterruptionController.instance.debugReleaseFocusCount;
    await handler.pause();
    expect(source.pauseCalled, isTrue, reason: '暂停必须真的传到来源');
    expect(MediaInterruptionController.instance.debugReleaseFocusCount, before,
        reason: '暂停**不能**释放音频焦点：ColorOS 上释放后媒体键可能不再路由给我们'
            '（实际释放次数 ${MediaInterruptionController.instance.debugReleaseFocusCount}）');

    // 停止仍然释放（否则别的应用一直被压着）
    await handler.stop();
    expect(MediaInterruptionController.instance.debugReleaseFocusCount,
        greaterThan(before),
        reason: '停止必须释放焦点');
  });

  test('ColorOS ROM 兼容：正在播放时来的 play() 必须当暂停', () async {
    // 真机日志（设备 PKG110 / ColorOS）：9 次按键全是 `媒体控制[play]`，
    // 其中三次发生在 `playing=true paused=false`（用户按的是"暂停"）——
    // 于是 play() → playFromCursor() → **重播当前句**，用户看到"按暂停反而重播"。
    //
    // ★v1.22.58：这条兼容逻辑现在**只在 ColorOS 系生效**（`DeviceInfo.isColorOsSync`），
    // 因为它无条件执行时会让联想平板（ZUI）"按播放永远恢复不了"。
    // 所以这里必须显式声明设备是 ColorOS，否则测的是另一条分支。
    DeviceInfo.debugSetColorOs(true);
    addTearDown(DeviceInfo.debugReset);

    final TtsAudioHandler handler = TtsAudioHandler(TtsManager.instance);
    final _FakeSource source = _FakeSource()
      ..playingValue = true
      ..pausedValue = false;
    handler.activate(source);

    await handler.play();
    expect(source.pauseCalled, isTrue,
        reason: 'ROM 把媒体键发成 KEYCODE_MEDIA_PLAY，play() 要承担"切换"职责：'
            '正在播 → 当暂停');
    expect(source.playCalled, isFalse,
        reason: '正在播时**不能**再 playFromCursor（那就是"按暂停反而重播"）');
  });

  test('ColorOS ROM 兼容：暂停态来的 play() 仍然正常播放', () async {
    DeviceInfo.debugSetColorOs(true);
    addTearDown(DeviceInfo.debugReset);

    final TtsAudioHandler handler = TtsAudioHandler(TtsManager.instance);
    final _FakeSource source = _FakeSource()
      ..playingValue = false
      ..pausedValue = true;
    handler.activate(source);

    await handler.play();
    expect(source.playCalled, isTrue, reason: '暂停态必须能恢复播放');
    expect(source.pauseCalled, isFalse);
  });

  // ★v1.22.58 回归用例：**非 ColorOS 设备不得走上面那条兼容分支**
  //
  // 真机事实：联想平板（ZUI / ZUXOS）上耳机键发的是标准 `MEDIA_PLAY_PAUSE`，
  // 暂停后按播放 → 系统给 `play()`。旧代码无条件把"正在播时的 play()"当暂停，
  // 结果平板上"按播放永远恢复不了"。这条用例把新默认钉死：
  // 只有 ColorOS 才当暂停，其它 ROM 的 play() 必须是**真的播放**。
  test('非 ColorOS：正在播放时来的 play() 必须真的恢复播放（不能当暂停）', () async {
    DeviceInfo.debugSetColorOs(false);
    addTearDown(DeviceInfo.debugReset);

    final TtsAudioHandler handler = TtsAudioHandler(TtsManager.instance);
    final _FakeSource source = _FakeSource()
      ..playingValue = true
      ..pausedValue = false;
    handler.activate(source);

    await handler.play();
    expect(source.pauseCalled, isFalse,
        reason: '非 ColorOS 上不能把 play() 当暂停 —— 那会让"按播放"永远没反应');
    expect(source.playCalled, isTrue, reason: '非 ColorOS 上 play() 就是播放');
  });

  test('阅读页 pause()：同样不释放音频焦点', () async {
    final _SilentEngine engine = _SilentEngine();
    await TtsManager.instance.registerEngine(engine, makeActive: true);
    TtsManager.instance.speakLines(<String>['焦点用例第一句，用来把会话跑起来。']);
    // 等它真的进入播放态
    for (var i = 0; i < 60 && !TtsManager.instance.playing; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(TtsManager.instance.playing, isTrue, reason: '会话必须跑起来，否则测不到暂停');

    final int before = MediaInterruptionController.instance.debugReleaseFocusCount;
    await TtsManager.instance.pause();
    expect(TtsManager.instance.paused, isTrue);
    expect(MediaInterruptionController.instance.debugReleaseFocusCount, before,
        reason: '阅读页暂停也不能释放焦点（同一条策略）');

    await TtsManager.instance.stop();
    expect(MediaInterruptionController.instance.debugReleaseFocusCount,
        greaterThan(before),
        reason: '停止必须释放焦点');
  });

  // ★v1.21.52：播放恢复后必须清掉"已让位"标志（真机日志暴露的 bug）
  //
  // 日志原文（2026-10-15 00:25）：
  // ```
  // 00:25:39  视频 → 让位暂停（pausedForIt=true）
  // 00:25:55  用户手动点播放恢复            ← 标志没被清
  // 00:26:30  通知来了 → "已经让位暂停过了 → 不重复处理"（用的还是旧标志）
  // ```
  // 若用户恢复后**紧接着再放一个视频**，就会走"已经让位过 → 不重复处理"
  // → **视频不再让位**。这里把"恢复播放就清标志"钉在 handler 这一层，
  // 因为它是 TtsManager 与 PDF 会话**唯一**的公共出口。
  test('★恢复播放（pushState playing=true）必须清掉"已让位"标志', () async {
    final TtsAudioHandler handler = TtsAudioHandler(TtsManager.instance);
    final _FakeSource source = _FakeSource()
      ..playingValue = true
      ..pausedValue = false;
    handler.activate(source);

    // 先制造一个"已让位"状态（模拟视频打断）
    MediaInterruptionController.instance
        .debugInterrupt(AudioInterruptionType.unknown);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(MediaInterruptionController.instance.debugPausedForInterruption, isTrue,
        reason: '前提：永久失去焦点 → 已让位');

    // 用户恢复播放：来源报 playing=true，handler 推状态
    handler.notifyFromSource();
    await Future<void>.delayed(Duration.zero);
    // ignore: avoid_print
    print('DEVICE_VERIFY[handler-clear] '
        'pausedForIt=${MediaInterruptionController.instance.debugPausedForInterruption}');
    expect(MediaInterruptionController.instance.debugPausedForInterruption, isFalse,
        reason: '★正在播就说明那次打断翻篇了 —— 标志必须清掉，'
            '否则下一个视频不再让位');
  });
}

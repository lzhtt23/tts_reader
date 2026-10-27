import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/device_info.dart';
import 'package:tts_reader/tts/audio_session_source.dart';
import 'package:tts_reader/tts/media_interruption.dart';
import 'package:tts_reader/tts/tts_audio_handler.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// **耳机 / 通知栏操作之后，通知栏状态必须跟上**（v1.21.39）
///
/// 用户报：「耳机暂停和恢复，通知栏的图标不能同步」。
///
/// 根因是**两条推送路径不一致**：
/// - `TtsManager`（TXT / EPUB）挂在它的 listener 上 → 状态变了会走 `_sync()`；
/// - `PdfReadSession` **不挂 listener**，只能靠自己的 `_notifyAudio()` 推。
///
/// 而 `_sync()` 开头有一道闸门：**当前来源不是 `TtsManager` 就直接返回**
/// （防"两本书抢一条通知"）。于是「来源不是 TtsManager 且状态变了」这条路上，
/// 只要来源漏推一次，通知栏就停在旧状态 —— 图标与实际播放态不同步。
///
/// 修法：在**媒体键出口**（[TtsAudioHandler.play] / [TtsAudioHandler.pause]）
/// 补一道兜底 `syncAfterUserCommand()`：状态真变了就推一次。
class _StubSource implements AudioSessionSource {
  _StubSource({required this.id});

  final String id;

  bool session = true;
  bool isPlaying = false;
  bool isPaused = false;

  /// 这个来源**故意不推通知栏** —— 模拟"漏推"的来源（PDF 会话那条路径）。
  /// 修好之后，即使它不推，handler 也该把状态推出去。
  int pauseCalls = 0;
  int playCalls = 0;

  @override
  String get sourceId => id;

  @override
  bool get hasSession => session;

  @override
  bool get playing => isPlaying && !isPaused;

  @override
  bool get paused => isPaused;

  @override
  String get documentTitle => '测试文档';

  @override
  String get positionLabel => '第 1 句';

  @override
  double get rate => 1.0;

  @override
  int get progressTotal => 10;

  @override
  int get progressIndex => 1;

  @override
  bool get canSeek => false;

  @override
  void playFromCursor() {
    playCalls++;
    isPlaying = true;
    isPaused = false;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    isPlaying = false;
    isPaused = true;
  }

  @override
  void onStop() {}

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

  setUp(() {
    MediaInterruptionController.instance.resetForTest();
  });

  tearDown(() {
    MediaInterruptionController.instance.resetForTest();
    TtsManager.instance.resetSessionForTest();
  });

  /// 最近一次推给通知栏的状态
  PlaybackState? lastState(TtsAudioHandler handler) {
    final state = handler.playbackState.valueOrNull;
    return state;
  }

  // ⚠️ v1.21.43 记录一次**被证伪的修法**，避免以后有人再走一遍：
  //
  // 「PDF 朗读时媒体无法打断」曾被我判断成 `activate()` 短路导致 `_source`
  // 指向旧实例，于是把 `_source = source` 挪到短路之前。**那是错的**：
  // · 真根因是 PDF 借声路径（`TtsManager._speakLinesInternal`）**从不申请
  //   音频焦点**（`requestFocus()` 只写在 `_restart()` 里）——
  //   没有焦点就不会收到系统"焦点丢失"事件，打断自然无从触发；
  // · 而那个"挪赋值"的改动**会让 5 条既有用例变红**
  //   （`borrow_audio_session_test.dart` 4 条 + `cross_session_source_test.dart` 1 条），
  //   却**一条新用例都没修好**（退化实验：改回旧写法，新用例照样绿）。
  // 结论：改 `activate` 是无用且有害的改动，已撤销；真正修法见
  // `tts_manager.dart` 里 `_speakLinesInternal` 的 `requestFocus`。

  test('耳机「暂停」后，通知栏收到 playing=false（图标要变播放）', () async {
    final handler = TtsAudioHandler(TtsManager.instance);
    final source = _StubSource(id: 'stub-pdf')..isPlaying = true;
    handler.activate(source);
    // 确认起点：激活时推的是"正在播放"
    expect(lastState(handler)?.playing, isTrue);

    // 模拟耳机键（ColorOS 把暂停也发成 play，所以这里直接调 pause 验证出口）
    await handler.pause();

    expect(source.pauseCalls, 1, reason: '暂停必须传到来源');
    expect(source.paused, isTrue);
    expect(lastState(handler)?.playing, isFalse,
        reason: '暂停之后通知栏必须收到 playing=false，否则图标停在"暂停"样式');
    // ignore: avoid_print
    print('DEVICE_VERIFY[media-sync] pause → playing=${lastState(handler)?.playing}');
  });

  test('耳机「恢复」后，通知栏收到 playing=true', () async {
    final handler = TtsAudioHandler(TtsManager.instance);
    final source = _StubSource(id: 'stub-pdf')..isPaused = true;
    handler.activate(source);

    await handler.play();

    expect(source.playCalls, 1, reason: '恢复必须传到来源');
    expect(source.isPlaying, isTrue);
    expect(lastState(handler)?.playing, isTrue,
        reason: '恢复之后通知栏必须收到 playing=true');
    // ignore: avoid_print
    print('DEVICE_VERIFY[media-sync] play → playing=${lastState(handler)?.playing}');
  });

  test('ColorOS ROM 兼容：正在播时收到 play 当暂停，且状态同步', () async {
    // ★v1.22.58：该兼容逻辑已限定在 ColorOS 系（见 `DeviceInfo.isColorOsSync`），
    // 否则联想平板（ZUI）上"按播放"会被当成"暂停"，永远恢复不了。
    DeviceInfo.debugSetColorOs(true);
    addTearDown(DeviceInfo.debugReset);

    final handler = TtsAudioHandler(TtsManager.instance);
    // ROM 恒发 KEYCODE_MEDIA_PLAY：正在播时这一下其实是"暂停"
    final source = _StubSource(id: 'stub-pdf')..isPlaying = true;
    handler.activate(source);
    expect(lastState(handler)?.playing, isTrue);

    await handler.play();

    expect(source.pauseCalls, 1, reason: '正在播时来的 play 必须当暂停');
    expect(source.playCalls, 0, reason: '不能重播');
    expect(lastState(handler)?.playing, isFalse,
        reason: '当暂停处理之后，通知栏也要跟着变成"播放"样式');
  });

  test('状态没变时不重复推（否则每句都重建通知卡片）', () async {
    final handler = TtsAudioHandler(TtsManager.instance);
    final source = _StubSource(id: 'stub-pdf')..isPlaying = true;
    handler.activate(source);

    var pushes = 0;
    final sub = handler.playbackState.listen((_) => pushes++);
    addTearDown(sub.cancel);
    // ⚠️ `playbackState` 是 BehaviorSubject：**订阅时会立刻重放当前值**，
    // 所以要先等这一拍到达，再开始数增量（否则初始值就被算成一次推送）。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final base = pushes;

    // 播放态没变 → 不该推
    handler.syncAfterUserCommand();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(pushes - base, 0, reason: '播放态没变时不该重复推状态');

    // 变成暂停 → 必须推一次
    source.isPlaying = false;
    source.isPaused = true;
    handler.syncAfterUserCommand();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(pushes - base, 1, reason: '播放态真的变了就必须推一次');
  });
}

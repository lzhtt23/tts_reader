import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/media_key_channel.dart';
import 'package:tts_reader/services/media_key_state.dart';

/// 平板耳机键兜底：**绝不能影响手机**
///
/// 设计要点（用户明确要求）：
/// * 按键**从不被我们消费**（原生侧永远返回 false，原样放行给系统）；
/// * 只有「正在朗读」时才转发给 Dart；
/// * Dart 收到后等 150ms，如果这期间 MediaSession 已经处理过，就**自己放弃**。
///
/// 所以手机上：MediaSession 立刻处理 → 记账 → 我们的兜底 150ms 后发现有人做了 → 不动。
/// 平板上：没人处理 → 兜底才动手。
void main() {
  setUp(() {
    MediaKeyChannel.resetForTest();
    MediaKeyState.resetForTest();
  });

  test('白名单：认识的媒体键才会被接受', () {
    expect(MediaKeyChannel.accept('play_pause'), isTrue);
    MediaKeyChannel.resetForTest();
    expect(MediaKeyChannel.accept('pause'), isTrue);
    MediaKeyChannel.resetForTest();
    expect(MediaKeyChannel.accept('next'), isTrue);
    MediaKeyChannel.resetForTest();
    expect(MediaKeyChannel.accept('previous'), isTrue);
    MediaKeyChannel.resetForTest();
    expect(MediaKeyChannel.accept('stop'), isTrue);
  });

  test('空洞/不认识的动作丢弃', () {
    expect(MediaKeyChannel.accept(''), isFalse);
    expect(MediaKeyChannel.accept('volume_up'), isFalse);
  });

  test('同一动作 300ms 内只接受一次（翻转键连击去重）', () {
    expect(MediaKeyChannel.accept('play_pause'), isTrue);
    expect(MediaKeyChannel.accept('play_pause'), isFalse);
  });

  test('MediaSession 记账时间点能被记录（兜底据此让路）', () {
    expect(MediaKeyState.lastSessionActionAt, isNull);
    MediaKeyState.noteSessionAction();
    expect(MediaKeyState.lastSessionActionAt, isNotNull);
  });
}

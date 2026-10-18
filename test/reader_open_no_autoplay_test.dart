import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/pages/reader_page.dart';

/// 打开文档不自动朗读（用户要求）
///
/// 真机日志（2026-10-18 22:01）每次进入阅读页都会自己开始播：
/// ```
/// 位置[进入阅读页] ...
/// 媒体控制[activate（换源）tts-manager] hasSession=true playing=false
/// 媒体控制[pushState] playing=true
/// 开始朗读：本地 TTS - multitts 起于 28/12/1
/// ```
/// 根因在 TTS 层的状态回推，风险高；页面侧用 [shouldPauseAfterOpen] 兜住。
void main() {
  group('shouldPauseAfterOpen', () {
    test('进页面前没在播、进页面后播了 -> 要暂停（这就是要拦的情况）', () {
      expect(
        shouldPauseAfterOpen(wasPlayingBeforeLoad: false, nowPlaying: true),
        isTrue,
      );
    });

    test('本来就在播 -> 放行（换书继续朗读是正常功能）', () {
      expect(
        shouldPauseAfterOpen(wasPlayingBeforeLoad: true, nowPlaying: true),
        isFalse,
      );
    });

    test('没在播也没播 -> 什么都不用做', () {
      expect(
        shouldPauseAfterOpen(wasPlayingBeforeLoad: false, nowPlaying: false),
        isFalse,
      );
    });

    test('本来在播、进页面后停了 -> 不插手（可能是用户自己停的）', () {
      expect(
        shouldPauseAfterOpen(wasPlayingBeforeLoad: true, nowPlaying: false),
        isFalse,
      );
    });
  });
}

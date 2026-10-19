import 'package:flutter/foundation.dart';

import 'media_key_diagnostics.dart';

/// 媒体键的「谁处理了」记账
///
/// ## 为什么要有这个文件
///
/// 平板 bug 的修法是：原生侧把媒体键**转发**给 Dart 补一手。
/// 但手机本来就能用 MediaSession 处理同一个键 —— 如果两边都动，
/// 用户按一次会**切两句 / 暂停又播放**。
///
/// 所以这里记一笔：「MediaSession 路径最后一次动作发生在什么时候」。
/// 原生转发过来的那条路会**等 150ms**，一看这期间 MediaSession 动过，
/// 就说明手机这条路已经处理了，自己直接放弃。
///
/// 好处：**按键从不被我们消费** —— 手机上的行为一个字都没变，
/// 只是多了一个"确认没人处理才动手"的兜底。
class MediaKeyState {
  MediaKeyState._();

  /// MediaSession 路径最后一次触发动作的时间
  static DateTime? lastSessionActionAt;

  /// `TtsAudioHandler` 的 play/pause/skip 方法入口调用
  ///
  /// [what] 只用于诊断页展示（play / pause / next / previous / stop）。
  static void noteSessionAction([String what = '']) {
    lastSessionActionAt = DateTime.now();
    if (what.isNotEmpty) {
      // 这条能证明「MediaSession 那条路是通的」——
      // 排查时如果只有这一种记录，说明按键走的是 MediaSession。
      MediaKeyDiagnostics.add('MediaSession $what');
    }
  }

  @visibleForTesting
  static void resetForTest() {
    lastSessionActionAt = null;
  }
}

import 'package:flutter/foundation.dart';

/// 媒体键诊断记录（最近 N 条）
///
/// ## 为什么要有这个页面数据
///
/// 平板「耳机键不生效」这种问题，光看代码是查不出来的 ——
/// 必须分清两种情况，而这两者在日志里长得完全不一样：
///
/// ① **按键根本没到我们**（系统把媒体键路由给了别人）→ 一条记录都没有
/// ② **到了但没认出来 / 没接管** → 有记录，但动作不对
///
/// 所以把原生 `dispatchKeyEvent` 收到的每个键、以及 MediaSession 那条路
/// （`TtsAudioHandler.play/pause/skip`）触发的动作，都记进这个环形缓冲，
/// 用户打开设置里的「媒体键诊断」就能直接看到，不用再导日志。
class MediaKeyDiagnostics {
  MediaKeyDiagnostics._();

  /// 最多留多少条
  static const int capacity = 30;

  /// 最新的在最前面
  static final ValueNotifier<List<String>> entries =
      ValueNotifier<List<String>>(<String>[]);

  static void add(String text) {
    final String stamp = _time();
    final List<String> next = <String>['$stamp  $text', ...entries.value];
    if (next.length > capacity) next.removeRange(capacity, next.length);
    entries.value = next;
  }

  static void clear() {
    entries.value = <String>[];
  }

  static String _time() {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }
}

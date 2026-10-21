import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import '../tts/tts_audio_handler.dart';
import '../tts/tts_manager.dart';
import 'crash_log.dart';
import 'media_key_diagnostics.dart';
import 'media_key_state.dart';

/// 耳机 / 蓝牙 / 车机的媒体键（Android 原生侧转发过来的）
///
/// ## 链路
///
/// ```
/// 耳机 → 系统 → ACTION_MEDIA_BUTTON 广播
///      → TtsMediaButtonReceiver（无条件转发）
///      → MediaKeyChannel（Kotlin，只翻译不改判）
///      → 这里
/// ```
///
/// ## 为什么判断全部放在这一侧
///
/// 旧实现让原生持有一个 `active` 标记，由 Dart 异步通知。那个设计会**静默丢键**：
/// 一旦通知丢了（通道未就绪 / Dart 以为状态没变就不再发），原生会永远停在
/// `active=false`，按键被直接丢弃，连一行日志都不留。
///
/// 现在原生不做任何判断，本类根据**真实的播放状态**决定动作：
/// * 会话不存在 → 忽略（不打扰别的应用）
/// * 正在播 + 收到 play_pause → 暂停
/// * 已暂停 + 收到 play_pause → 继续／从游标恢复
///
/// ## 去重
///
/// 同一物理按键可能既走广播又被 MediaSession 收到，300ms 内的同种动作只执行一次。
class MediaKeyChannel {
  MediaKeyChannel._();

  static const MethodChannel _channel = MethodChannel('tts_reader/media_keys');

  static const Duration _debounce = Duration(milliseconds: 300);

  /// 等这么久确认「MediaSession 有没有先动手」
  static const Duration _grace = Duration(milliseconds: 150);

  static String _lastAction = '';
  static DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  static bool _attached = false;

  /// 装上监听（应用启动时调一次即可）
  static void attach() {
    if (_attached) return;
    _attached = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'mediaKey') return null;
      final String action = call.arguments is String ? call.arguments as String : '';
      handle(action);
      return null;
    });
    CrashLog.mark('媒体键[已挂载]');
  }

  /// 处理一个动作（也便于测试直接调用）
  ///
  /// 时序：收到后先记时间，等 150ms —— 若这期间 MediaSession 已经处理过
  /// （手机上正常情况），就让位；没人处理才由我们动手。
  static void handle(String action) {
    if (!accept(action)) return;
    final DateTime receivedAt = DateTime.now();
    unawaited(
      Future<void>.delayed(_grace, () {
        final DateTime? session = MediaKeyState.lastSessionActionAt;
        if (session != null && session.isAfter(receivedAt)) {
          CrashLog.mark('媒体键[让给系统] $action（MediaSession 已处理）');
          return;
        }
        _act(action);
      }),
    );
  }

  /// 真正执行动作
  ///
  /// 优先走 `audio_service` 的 handler：与 MediaSession 收到媒体键时**完全同一条路**，
  /// 语义一致（例如「上一首/下一首切句」仍按设置来）。
  static void _act(String action) {
    final TtsAudioHandler? handler = audioHandler;
    if (handler != null) {
      switch (action) {
        case 'play_pause':
          unawaited(handler.play());
        case 'pause':
          unawaited(handler.pause());
        case 'next':
          unawaited(handler.skipToNext());
        case 'previous':
          unawaited(handler.skipToPrevious());
        case 'stop':
          unawaited(handler.stop());
      }
      return;
    }

    // 没有后台音频服务（桌面 / 测试环境）：直接操作朗读器
    final TtsManager tts = TtsManager.instance;
    switch (action) {
      case 'play_pause':
        if (tts.playing) {
          tts.pause();
        } else {
          tts.resume();
        }
      case 'pause':
        if (tts.playing) tts.pause();
      case 'next':
        tts.skipSentenceForward();
      case 'previous':
        tts.skipSentenceBackward();
      case 'stop':
        tts.stopByUser();
    }
  }

  /// 去重 + 认不认识的判断（**纯逻辑，不碰 TTS**，便于单测）
  ///
  /// 返回 true 表示这个动作应该被执行。
  static bool accept(String action) {
    if (action.isEmpty) return false;
    const Set<String> known = <String>{
      'play_pause',
      'pause',
      'next',
      'previous',
      'stop',
    };
    if (!known.contains(action)) {
      CrashLog.mark('媒体键[忽略] 不认识的动作：$action');
      return false;
    }
    final DateTime now = DateTime.now();
    if (action == _lastAction && now.difference(_lastAt) < _debounce) {
      CrashLog.mark('媒体键[去重] $action');
      MediaKeyDiagnostics.add('去重 $action');
      return false;
    }
    _lastAction = action;
    _lastAt = now;
    CrashLog.mark('媒体键[收到] $action');
    MediaKeyDiagnostics.add('收到 $action');
    return true;
  }

  /// 测试用：清掉去重状态
  @visibleForTesting
  static void resetForTest() {
    _lastAction = '';
    _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// 测试用：重置挂载标记
  @visibleForTesting
  static void resetAttachForTest() {
    _attached = false;
  }
}

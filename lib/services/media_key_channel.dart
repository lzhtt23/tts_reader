import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import '../features/pdf_reading/pdf_read_session.dart';
import '../tts/tts_audio_handler.dart';
import '../tts/tts_manager.dart';
import 'audio_anchor.dart';
import 'crash_log.dart';
import 'media_key_diagnostics.dart';
import 'media_key_state.dart';
import 'storage_service.dart';

/// 耳机 / 平板的媒体键（Android 原生侧转发过来的）
///
/// ## 为什么要自己接一道
///
/// 正常路径是 `audio_service` 的 MediaSession 接媒体键。但真机反馈
/// 「平板按耳机键没反应」—— 平板 / 部分 ROM 会把媒体键**当普通按键**
/// 直接派给前台 Activity，根本不进 MediaSession。
///
/// 所以原生侧 `dispatchKeyEvent` 里也接一道，把键名发过来，这里翻译成动作：
/// * `play_pause` / `pause` → 播放/暂停
/// * `next` / `previous` → 下一句 / 上一句（与耳机上一首/下一首一致）
/// * `stop` → 停止
///
/// ## 去重
///
/// 同一个物理按键可能既走 MediaSession 又被这里收到（原生侧已尽量消费，
/// 但仍可能有 ROM 差异），所以 300ms 内的同一种动作只执行一次。
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
  ///
  /// 同时订阅朗读状态，把「是否正在朗读」告诉原生侧：
  /// **只在朗读中**才由我们接媒体键，空闲时完全不碰（手机原有行为不变）。
  static void attach() {
    if (_attached) return;
    _attached = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'log') {
        // 原生侧的按键诊断（平板排查：按键到底有没有到 Activity）
        final String text = '${call.arguments}';
        CrashLog.mark('媒体键[原生] $text');
        MediaKeyDiagnostics.add('原生 $text');
        return null;
      }
      if (call.method != 'mediaKey') return null;
      final String action = call.arguments is String ? call.arguments as String : '';
      handle(action);
      return null;
    });
    TtsManager.instance.addListener(_syncActive);
    // PDF 借声时 `TtsManager.hasSession == false`，只看它会漏掉整段朗读；
    // 播放状态的**唯一真相**是 audio_service 的 playbackState（PDF 会话也往那里推）。
    audioHandler?.playbackState.listen((_) => _syncActive());
    // 音量键长按切句的开关：改了设置要立刻同步给原生
    StorageService.instance.appearance.addListener(_syncVolumeKeys);
    _syncVolumeKeys();
    _syncActive();
  }

  static bool _lastVolumeKeys = false;

  /// 把「音量键长按切句」的开关同步给原生
  static void _syncVolumeKeys() {
    final bool want = StorageService.instance.volumeKeySkip;
    if (want == _lastVolumeKeys) return;
    _lastVolumeKeys = want;
    unawaited(
      _channel.invokeMethod<bool>('setVolumeKeySkip', want).catchError((Object _) {
        return null;
      }),
    );
    CrashLog.mark('媒体键[音量键切句=$want]');
  }

  static bool _lastActive = false;

  /// 最后一次「确实在朗读」的时间（用于滞回）
  static DateTime? _lastBusyAt;

  /// 朗读结束后仍然保持接管的时长
  ///
  /// 为什么要滞回：PDF 借声是**一句一次**开关的（`借声[进入]/[退出]`），
  /// 逐句判定会让"接管"每几秒翻一次，日志刷屏、兜底也时灵时不灵。
  /// 停手 60 秒内继续算"在朗读"，足够覆盖句间停顿与短暂缓冲。
  static const Duration _busyHold = Duration(seconds: 60);

  /// 把"是否正在朗读"同步给原生
  ///
  /// 判据（任一成立即为"在朗读"）：
  /// * `TtsManager.playing` —— 正常朗读
  /// * `TtsManager.hasSession` —— 暂停着但会话还在
  /// * `TtsManager.isBorrowedForOther` —— PDF 借声期间（此时 hasSession 恒为 false）
  /// * `audioHandler.playbackState.playing` —— 通知栏/媒体会话认为在播
  /// 另外加 60 秒滞回，避免逐句开关导致"接管"抖动。
  static void _syncActive() {
    final TtsManager tts = TtsManager.instance;
    final bool sessionPlaying =
        audioHandler?.playbackState.value.playing ?? false;
    // ★v1.22.32：PDF 会话"已打开但还没播"也要算进 busy ——
    // 用户要求"刚进播放页就能用耳机启停"，那就得从这一刻起占住 A2DP。
    final bool busy = tts.playing ||
        tts.hasSession ||
        tts.isBorrowedForOther ||
        sessionPlaying ||
        PdfReadSession.instance.isActive;
    final DateTime now = DateTime.now();
    if (busy) _lastBusyAt = now;
    final bool hold = _lastBusyAt != null &&
        now.difference(_lastBusyAt!) < _busyHold;
    final bool active = busy || hold;
    if (active == _lastActive) return;
    _lastActive = active;
    unawaited(
      _channel.invokeMethod<bool>('setActive', active).catchError((Object _) {
        // 桌面 / 测试环境没有这个通道：忽略
        return null;
      }),
    );
    // 试验：开始朗读时主动向系统"认领"媒体按钮（老 API，部分平板固件仍认）
    if (active) {
      unawaited(
        _channel.invokeMethod<bool>('claimButtons', true).catchError((Object _) {
          return null;
        }),
      );
    }
    // 试验：让**本进程**持有一个静音音频输出。
    // ColorOS 那种 ROM 认为"出声的是 TTS 引擎"，不是我们，于是把媒体键派给别人；
    // 我们自己占一条音频轨，才有机会被当成正在播放的媒体应用。
    if (StorageService.instance.audioAnchorEnabled) {
      if (active) {
        unawaited(AudioAnchor.instance.start());
      } else {
        unawaited(AudioAnchor.instance.stop());
      }
    }
    CrashLog.mark('媒体键[接管=$active]');
  }

  /// 处理一个动作（也便于测试直接调用）
  ///
  /// ## 时序（保证不影响手机）
  ///
  /// 1. 收到原生转发时先记下**当前时间**；
  /// 2. 等 150ms —— 这期间如果 MediaSession 已经处理过（手机上正常情况），
  ///    [MediaKeyState.lastSessionActionAt] 就会比记下的时间新，于是**直接放弃**；
  /// 3. 没人处理（平板那种不走 MediaSession 的 ROM）才动手。
  ///
  /// 动手时优先走 `audio_service` 的 handler（`play()/pause()/skipToNext()/…`），
  /// 与 MediaSession 收到媒体键时**完全同一条路**，语义一致
  /// （例如「上一首/下一首切句还是切章」仍按设置来）。
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
  static void _act(String action) {
    final TtsAudioHandler? handler = audioHandler;
    // ★v1.22.36 端到端取证：一次按钮点击在这条链路上到底走到哪一步。
    // 平板实测「耳机键/通知按钮都无效、重启应用才好」，怀疑 handler 被系统抢占后
    // 不再响应 —— 先证明它到底有没有被调用、调用时来源是什么状态。
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
}

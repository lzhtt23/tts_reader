import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'crash_log.dart';

/// 朗读控制通知（自定义样式，**不走 MediaStyle / 媒体会话**）
///
/// ## 为什么要有第二条通知
///
/// `audio_service` 的媒体卡片依赖「媒体会话」，而真机（平板 TB335FC / ZUX OS）
/// 上这套路由不稳定：蓝牙耳机打断后 `a2dp suspend`，按键在蓝牙栈就被丢掉，
/// 媒体会话也不再被系统当作按键接收方。
///
/// 参考同类应用 T2S 的做法：**不做耳机键**，用一条 `NotificationCompat`
/// 自定义通知 + 按钮当主控制入口。按钮是 `PendingIntent` 直投广播，
/// 与媒体会话无关，所以不受上述问题影响。
///
/// ## 动作语义
///
/// 按钮点击 → 原生广播 → `tts_reader/media_keys` 通道 → `MediaKeyChannel.handle`，
/// 动作名与耳机键完全一致（`play_pause` / `next` / `previous` / `stop`），
/// 因此这里只负责显示/收起，不引入新的动作分支。
class ReadingNotice {
  ReadingNotice._();

  static const MethodChannel _channel =
      MethodChannel('tts_reader/media_keys');

  static String _lastKey = '';

  /// 通知权限只在第一次显示时问一次（Android 13+ 必须，否则普通通知会被静默丢弃）
  ///
  /// 为什么以前没发现：`audio_service` 的媒体卡是**前台服务通知**，系统豁免该权限，
  /// 所以"媒体卡能显示"造成了"通知权限没问题"的错觉；我们自己发的普通通知
  /// 没有权限就会被直接丢掉（`dumpsys` 里连记录都不留）。
  static bool _permissionAsked = false;

  static Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final PermissionStatus status = await Permission.notification.status;
      if (status.isGranted) return true;
      if (status.isPermanentlyDenied) return false;
      if (_permissionAsked) return false;
      _permissionAsked = true;
      final PermissionStatus asked = await Permission.notification.request();
      return asked.isGranted;
    } catch (_) {
      return true; // 老系统没有这个权限，视为可用
    }
  }

  /// 显示 / 更新通知（同一状态重复调用会被忽略，避免刷屏）
  static Future<void> show({
    required String title,
    required String detail,
    required bool playing,
  }) async {
    final String key = '$title|$detail|$playing';
    if (key == _lastKey) return;
    _lastKey = key;
    try {
      if (!await _ensurePermission()) {
        CrashLog.mark('朗读通知[无权限] 已跳过（Android 13+ 需通知权限）');
        return;
      }
      await _channel.invokeMethod<bool>('showNotice', <String, Object?>{
        'title': title,
        'detail': detail,
        'playing': playing,
      });
    } catch (e) {
      // 桌面 / 测试环境没有这个通道：忽略
      CrashLog.mark('朗读通知[失败] $e');
    }
  }

  /// 收起通知
  static Future<void> hide() async {
    if (_lastKey.isEmpty) return;
    _lastKey = '';
    try {
      await _channel.invokeMethod<bool>('hideNotice');
    } catch (_) {
      // 忽略
    }
  }
}

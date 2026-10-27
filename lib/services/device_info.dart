import 'package:flutter/services.dart';

/// 设备/ROM 能力查询
///
/// 目前只有一个用途：判断当前是不是 **ColorOS 系**（一加 / OPPO / realme）。
///
/// ## 为什么要这个判断
///
/// `TtsAudioHandler.play()` 里有一段「正在播时按播放键 → 当成暂停」的兼容逻辑，
/// 依据是 **ColorOS 把媒体键统一发成 `KEYCODE_MEDIA_PLAY`**（不发给标准的
/// `MEDIA_PLAY_PAUSE`）。这段逻辑原先无条件执行，导致在别的 ROM 上
/// （联想平板 ZUI）**按播放永远恢复不了** —— 被当成暂停了。
///
/// ## 失败策略
///
/// 原生通道拿不到 / 抛异常 → 返回 **false**（不启用兼容分支）。
/// 宁可让 ColorOS 少一次兼容，也不要让其它设备误走这条分支。
class DeviceInfo {
  DeviceInfo._();

  static const MethodChannel _channel = MethodChannel('tts_reader/device');

  /// 缓存：一个进程内 ROM 不会变，只查一次
  static bool? _isColorOs;

  /// **同步**读取上次查询的结果（未查询过时返回 false）
  ///
  /// 给 `TtsAudioHandler.play()` 用：那里不能 `await`（焦点/网络往返会挡住出声），
  /// 所以必须在启动时先 [`warmUp`] 一次，把结果放进缓存。
  static bool get isColorOsSync => _isColorOs ?? false;

  /// 启动时预热一次（`main()` 里调，失败不影响任何功能）
  static Future<void> warmUp() async {
    await isColorOs();
  }

  /// 当前 ROM 是否属于 ColorOS 系
  static Future<bool> isColorOs() async {
    final bool? cached = _isColorOs;
    if (cached != null) return cached;
    try {
      final dynamic raw = await _channel.invokeMethod<dynamic>('isColorOs');
      final bool value = raw == true;
      _isColorOs = value;
      return value;
    } catch (_) {
      // 桌面 / 测试环境没有这个通道：按"不是 ColorOS"处理
      _isColorOs = false;
      return false;
    }
  }

  /// 测试用：注入判定结果
  static void debugSetColorOs(bool? value) => _isColorOs = value;

  /// 测试用：清掉缓存
  static void debugReset() => _isColorOs = null;
}

import 'package:flutter/services.dart';

/// 启动图标的内置样式。
///
/// 只能在内置样式之间切换 —— **不支持自定义图片**：Android 的启动图标是
/// 清单里写死的资源，运行时换图只能靠多个 `activity-alias`，
/// 而自定义图片没法预先声明到清单里。
enum AppIconStyle {
  /// 经典：原来的猫猫图
  classic('classic', '经典', 'assets/icons/classic.png'),

  /// 镰锤 + 书（当前默认）
  sickle('sickle', '镰锤与书', 'assets/icons/sickle.png'),

  /// 一排竖放的书 + 左上红星
  books('books', '一摞书', 'assets/icons/books.png');

  const AppIconStyle(this.id, this.label, this.asset);

  final String id;
  final String label;
  final String asset;

  static AppIconStyle fromId(String? id) {
    for (final style in AppIconStyle.values) {
      if (style.id == id) return style;
    }
    return AppIconStyle.sickle;
  }
}

/// 切换启动图标（Android 侧切 `activity-alias`）
///
/// ⚠️ 已知限制（不同 ROM 不一致）：
/// - 切换后桌面图标可能不立刻刷新（启动器缓存），需要等一会儿或重启启动器；
/// - 桌面上已有的快捷方式指向旧的 alias，切换后会消失。
///
/// 非 Android 平台 / 通道不可用时安静失败（返回 false），不影响任何其它功能。
class AppIcon {
  const AppIcon._();

  static const MethodChannel _channel = MethodChannel('tts_reader/icon');

  /// 当前样式；拿不到就返回默认（sickle）
  static Future<AppIconStyle> current() async {
    try {
      final id = await _channel.invokeMethod<String>('get');
      return AppIconStyle.fromId(id);
    } catch (_) {
      return AppIconStyle.sickle;
    }
  }

  /// 切到 [style]；成功返回 true
  static Future<bool> apply(AppIconStyle style) async {
    try {
      final ok = await _channel.invokeMethod<bool>('set', <String, Object?>{
        'style': style.id,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}

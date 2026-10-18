import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'deep_link_intake.dart';

/// 文本进入朗读功能的来源（对应 T2S 的几个朗读入口）
enum SpeakSource {
  /// 打字朗读：用户在应用里手动输入
  type('打字朗读'),

  /// 剪贴板朗读：读当前剪贴板内容
  clipboard('剪贴板朗读'),

  /// 分享即朗读：其它应用点「分享」送进来
  share('分享朗读'),

  /// 划词朗读：文本选择菜单里的「朗读」
  processText('划词朗读'),

  /// 打开文本：用本应用打开 text/plain 文件
  view('打开文本朗读'),

  /// 复制即朗读（C2S 悬浮球 / 快捷磁贴）
  c2s('复制即朗读');

  const SpeakSource(this.label);

  /// 界面展示名
  final String label;

  /// 从原生侧传来的名字解析，未知名字按「分享」处理（至少不会丢文本）
  static SpeakSource fromName(String? name) => values.firstWhere(
        (SpeakSource value) => value.name == name,
        orElse: () => SpeakSource.share,
      );
}

/// 一条待朗读的外部文本
@immutable
class SpeakRequest {
  const SpeakRequest({required this.text, required this.source});

  final String text;
  final SpeakSource source;

  /// 从原生 MethodChannel 的 Map 解析；文本为空 / 结构不对返回 null
  static SpeakRequest? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final Object? text = raw['text'];
    if (text is! String || text.trim().isEmpty) return null;
    return SpeakRequest(
      text: text,
      source: SpeakSource.fromName(raw['source'] as String?),
    );
  }
}

/// 外部文本入口：接收 Android intent（分享 / 划词 / 打开文本）送进来的文本，
/// 也接收界面内部的「打字朗读 / 剪贴板朗读」提交，统一用一条流交给界面处理。
///
/// 原生侧（`MainActivity`）在两种时机交付：
/// - 应用已在运行：`onNewIntent` 直接 `invokeMethod('onText', …)`；
/// - 冷启动：文本先存在原生侧，Dart 启动后调 `getPending` 取走
///   （audio_service 会让 Flutter 引擎比 Activity 活得久，所以恢复前台时也会再取一次）。
class SpeakIntake {
  SpeakIntake._();

  /// 全局单例
  static final SpeakIntake instance = SpeakIntake._();

  /// 与 `MainActivity` 约定的通道名
  static const String channelName = 'tts_reader/intents';

  /// 测试可替换的通道（默认就是上面的真实通道）
  @visibleForTesting
  static MethodChannel channel = const MethodChannel(channelName);

  /// 单次入口文本的长度上限：超大文本直接截断，避免界面与队列被拖死
  static const int maxTextLength = 100000;

  final StreamController<SpeakRequest> _controller =
      StreamController<SpeakRequest>.broadcast();

  SpeakRequest? _pending;
  bool _initialized = false;

  /// 外部文本流（应用级监听一次即可）
  Stream<SpeakRequest> get stream => _controller.stream;

  /// 是否有界面在监听（没有监听者时文本先存起来，等界面起来再取）
  bool get hasListener => _controller.hasListener;

  /// 启动时调用：挂上方法调用处理器，并取一次冷启动携带的文本
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    channel.setMethodCallHandler(_handleCall);
    await pullPending();
  }

  /// 主动向原生侧要一次「待处理文本」（冷启动 / 恢复前台时都有用）
  Future<void> pullPending() async {
    try {
      final Object? raw = await channel.invokeMethod<Object?>('getPending');
      // 冷启动时可能是一条深链（用户在浏览器点了「一键导入」）
      if (raw is Map && raw['source'] == 'deeplink') {
        DeepLinkIntake.instance.fromNative(raw['text'] as String?);
        return;
      }
      final SpeakRequest? request = SpeakRequest.fromMap(raw);
      if (request != null) _emit(request);
    } on MissingPluginException {
      // 桌面 / 测试环境没有原生实现，忽略
    } catch (_) {
      // 取不到就算了：入口是附加能力，绝不能影响启动
    }
  }

  /// 取走启动时留下的文本（取走即清空）
  SpeakRequest? takePending() {
    final SpeakRequest? request = _pending;
    _pending = null;
    return request;
  }

  /// 界面内部提交文本（打字朗读 / 剪贴板朗读）
  void submit(String text, SpeakSource source) {
    final SpeakRequest? request = _normalize(text, source);
    if (request != null) _emit(request);
  }

  /// 单测 / 收尾用：清掉挂起文本与监听
  @visibleForTesting
  void reset() {
    _pending = null;
  }

  @visibleForTesting
  void disposeForTest() {
    _pending = null;
    _initialized = false;
    channel.setMethodCallHandler(null);
  }

  Future<void> _handleCall(MethodCall call) async {
    if (call.method != 'onText') return;
    // 深链（yuedu:// / legado:// 书源导入）走同一条原生通道，但语义不同：
    // 它要的是「导入书源」，不是「朗读这段文字」。先在类型上分掉。
    final Object? args = call.arguments;
    if (args is Map && args['source'] == 'deeplink') {
      DeepLinkIntake.instance.fromNative(args['text'] as String?);
      return;
    }
    final SpeakRequest? request = SpeakRequest.fromMap(call.arguments);
    if (request != null) _emit(request);
  }

  void _emit(SpeakRequest request) {
    if (_controller.hasListener && !_controller.isClosed) {
      _controller.add(request);
      return;
    }
    // 没有界面在听：先留着，界面起来后 takePending() 取走
    _pending = request;
  }

  static SpeakRequest? _normalize(String text, SpeakSource source) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final String value = trimmed.length > maxTextLength
        ? trimmed.substring(0, maxTextLength)
        : trimmed;
    return SpeakRequest(text: value, source: source);
  }
}

import 'package:flutter/foundation.dart';

/// 语音（系统引擎由平台提供，云端引擎为内置音色表）
class TtsVoice {
  const TtsVoice({required this.id, required this.name, required this.locale});

  final String id;
  final String name;
  final String locale;

  /// 界面展示：名称（语言）
  String get display => locale.isEmpty || locale == 'cloud' ? name : '$name（$locale）';

  @override
  String toString() => display;
}

/// 设备上安装的本地 TTS 引擎（Android 的 `TextToSpeech` 引擎，一个应用一个包名）
///
/// 与 [TtsVoice]（同一个引擎里的音色）是两层：这里选的是**用哪个本地引擎**，
/// 常见的有 Google 语音服务、三星 TTS、讯飞语记、华为/小米自带的语音引擎等。
class LocalTtsEngine {
  const LocalTtsEngine({
    required this.package,
    required this.label,
    this.isDefault = false,
    this.isCurrent = false,
  });

  /// 引擎包名（要交给 `setEngine` 的就是它）
  final String package;

  /// 界面上显示的名字
  final String label;

  /// 是不是系统默认引擎
  final bool isDefault;

  /// 是不是当前正在用的
  final bool isCurrent;

  LocalTtsEngine copyWith({bool? isDefault, bool? isCurrent}) => LocalTtsEngine(
    package: package,
    label: label,
    isDefault: isDefault ?? this.isDefault,
    isCurrent: isCurrent ?? this.isCurrent,
  );

  /// 常见引擎包名 → 友好名称；认不出来就退回包名的末段
  ///
  /// 纯函数，便于单测。Android 上 `getEngines()` 只给包名，直接显示
  /// `com.google.android.tts` 这种字符串对用户没有意义。
  static String labelOf(String package) {
    final known = _knownLabels[package];
    if (known != null) return known;
    if (package.isEmpty) return '未知引擎';
    // 认不出来就用包名末段，至少比整串短
    final parts = package.split('.');
    final tail = parts.isEmpty ? package : parts.last;
    return tail.isEmpty ? package : tail;
  }

  static const Map<String, String> _knownLabels = <String, String>{
    'com.google.android.tts': 'Google 语音服务',
    'com.google.android.tts.service': 'Google 语音服务',
    'com.samsung.android.tts': '三星 TTS',
    'com.samsung.SMT': '三星 TTS',
    'com.iflytek.speechcloud': '讯飞语音',
    'com.iflytek.tts': '讯飞语音',
    'com.baidu.duersdk.opensdk': '百度语音',
    'com.baidu.tts': '百度语音',
    'com.xiaomi.tts': '小米语音',
    'com.miui.tts': '小米语音',
    'com.huawei.tts': '华为语音',
    'com.huawei.android.tts': '华为语音',
    'com.huawei.hiai': '华为语音',
    'com.oppo.tts': 'OPPO 语音',
    'com.coloros.tts': 'OPPO 语音',
    'com.vivo.tts': 'vivo 语音',
    'com.unisound.tts': '云知声',
    'com.sohu.tts': '搜狗语音',
    'com.tencent.tts': '腾讯语音',
    'org.ispeech': 'iSpeech',
    'com.acapelagroup.android.tts': 'Acapela',
    'com.svox.pico': 'Pico TTS',
  };

  @override
  String toString() => '$label($package)';
}

/// 「合成语义」测试替身的显式声明。
///
/// 共享层（`TtsManager._speakUnit`）有一条**时长判据**：`speak` 在 100ms 内
/// 就"读完"、而文本超过 5 个字 → 判为假完成、按失败处理（真机根因见
/// `system_tts_engine.dart` 的 `speak()` 注释）。
///
/// 测试里的假引擎按「立刻返回 / 永不返回」等**合成语义**构造，它们并不是在
/// 模拟"真实朗读完"，所以**显式** `with SyntheticTtsEngine` 声明跳过该判据 ——
/// 让测试装置表达自己的语义，而不是让实现为了测试放宽判据。
///
/// 真引擎（`SystemTtsEngine` / `CloudTtsEngine`）**不**实现它，判据对它们一律生效。
mixin SyntheticTtsEngine {
  /// 本引擎的完成回调不表示「真实朗读结束」。
  bool get syntheticCompletion => true;
}

/// **可选能力**：引擎能报「当前念到第几个字」（v1.22.69）
///
/// 为什么不直接塞进 [TtsEngine]：那会让所有测试替身跟着实现一遍，
/// 而绝大多数替身根本不关心词级进度。做成独立接口，谁支持谁实现，
/// UI 侧用 `engine is WordProgressCapable` 探测，**不支持就退化为句级高亮**。
///
/// 区间是**相对于这一次送进引擎的字符串**的字符下标（含头不含尾），
/// 与 flutter_tts 的 `onRangeStart(text, start, end, word)` 一致。
abstract class WordProgressCapable {
  /// 当前词区间；null 表示「没有词级信息」（未开始 / 已停止 / 引擎不报）
  ValueListenable<({int start, int end})?> get wordRange;
}

/// TTS 引擎统一抽象：系统引擎与云端引擎共用同一套朗读调度
abstract class TtsEngine {
  /// 唯一标识，如 system / cloud
  String get id;

  /// 界面展示名
  String get displayName;

  /// 当前配置下是否可用
  bool get isAvailable;

  /// 初始化（可重复调用，实现需幂等）
  Future<void> initialize();

  /// 可用语音列表
  Future<List<TtsVoice>> getVoices();

  /// 设置音色（传 id）
  Future<void> setVoice(String voiceId);

  /// 语速 0.5 ~ 2.0
  Future<void> setRate(double rate);

  /// 音调 0.5 ~ 2.0
  Future<void> setPitch(double pitch);

  /// 朗读一段文本；Future 在该段朗读结束后完成（被打断时也应尽快完成）
  Future<void> speak(String text);

  /// 暂停当前朗读
  Future<void> pause();

  /// 停止并清空待朗读内容
  Future<void> stop();

  /// 注册朗读结束回调（引擎侧触发，可为 null 取消注册）
  void setCompletionHandler(void Function()? handler);

  /// 释放资源
  Future<void> dispose();
}

/// 「本地引擎可选」的引擎能力（只有系统 TTS 引擎实现）
///
/// 单独拆一个接口而不是塞进 [TtsEngine]：云端引擎没有这个概念，
/// 而 Dart 的 `implements` 要求实现所有成员 —— 塞进去会让每个测试假引擎
/// 都得补三个用不上的方法。
abstract class LocalEngineHost {
  /// 当前本地引擎包名（跟随系统默认时返回 null）
  String? get enginePackage;

  /// 设备上安装的本地 TTS 引擎
  Future<List<LocalTtsEngine>> listLocalEngines();

  /// 切换到指定本地引擎
  Future<void> useLocalEngine(String package);
}

import 'package:flutter/foundation.dart';

import 'crash_log.dart';
import 'source_link_parser.dart';

/// 被别的 App「拉起」的书源导入链接
///
/// ## 一键导入在 legado 生态里是怎么实现的
///
/// 网页上那个「一键导入」按钮本质是一个深链：
/// `yuedu://booksource/importonline?src=<书源地址>`。
/// 浏览器打不开自定义 scheme，于是交给系统：谁声明了这个 scheme 就交给谁 ——
/// 这就是「拉起」，**不是**那个网页直接调用别的 App。
///
/// ## 我们也能被拉起，但有两条限制（必须说清）
///
/// 1. **会和阅读 App 抢同一个 scheme**：两个应用都声明 `yuedu://`，
///    系统会弹「用哪个应用打开」，用户选「总是」才固定。这不能绕过，
///    也不该绕过 —— 静默劫持别人的 scheme 是坏行为。
/// 2. **必须先确认再导入**：用户可能只是误点。
///
/// 本类只负责「把系统给的链接收下来、解析、放进 [pendingSourceUrl]」，
/// 弹确认与写库交给页面（与浏览器里点一键导入走同一条路）。
///
/// ## 为什么不自己开 MethodChannel
///
/// 原生侧只有一个 `tts_reader/intents` 通道，而 `SpeakIntake` 已经在上面
/// 装了 handler。再装一个会**把它的覆盖掉**（Flutter 一个通道只有一个 handler）。
/// 所以深链复用它：原生侧把 `source` 打成 `"deeplink"`，由 [SpeakIntake] 转发进来。
class DeepLinkIntake {
  DeepLinkIntake._();

  static final DeepLinkIntake instance = DeepLinkIntake._();

  /// 解析出来的书源地址；null = 没有待导入的书源
  final ValueNotifier<String?> pendingSourceUrl = ValueNotifier<String?>(null);

  /// 解析出来的**订阅源（RSS）**地址
  ///
  /// 与书源分开两个通知器：两套库、两套确认弹窗，混在一起就得在 UI 层再判类型。
  final ValueNotifier<String?> pendingRssSourceUrl = ValueNotifier<String?>(null);

  /// 原生侧收到 `yuedu://` / `legado://` 后调这里
  void fromNative(String? rawText) {
    if (rawText == null || rawText.trim().isEmpty) return;
    // 先判订阅源：`legado://import/rssSource` 里也含 "import"，不能先让书源规则吃掉
    final String? rss = SourceLinkParser.extractRssSourceUrl(rawText);
    if (rss != null) {
      CrashLog.mark('深链[收到·订阅源] $rss');
      pendingRssSourceUrl.value = rss;
      return;
    }
    final String? url = SourceLinkParser.extractBookSourceUrl(rawText);
    if (url == null) {
      CrashLog.mark('深链[忽略] 不是书源/订阅源链接：$rawText');
      return;
    }
    CrashLog.mark('深链[收到·书源] $url');
    pendingSourceUrl.value = url;
  }

  /// 页面取走后清空（避免重复弹确认框）
  void consume() {
    pendingSourceUrl.value = null;
  }

  /// 订阅源那条取走后清空
  void consumeRss() {
    pendingRssSourceUrl.value = null;
  }

  /// 测试用：直接喂一条链接
  @visibleForTesting
  void submitForTest(String rawText) => fromNative(rawText);
}

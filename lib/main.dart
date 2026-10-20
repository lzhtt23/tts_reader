import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'models/rss_source.dart';
import 'models/source_rule.dart';
import 'pages/home_page.dart';
import 'pages/source_import_confirm_page.dart';
import 'pages/speak_now_page.dart';
import 'services/c2s.dart';
import 'services/crash_log.dart';
import 'services/deep_link_intake.dart';
import 'services/document_service.dart';
import 'services/download_watcher.dart';
import 'services/gbk_decoder.dart';
import 'services/legado_source_store.dart';
import 'services/rss_importer.dart';
import 'services/rss_store.dart';
import 'services/source_importer.dart';
import 'widgets/rss_import_confirm.dart';
import 'services/speak_intake.dart';
import 'services/storage_service.dart';
import 'services/third_party_licenses.dart';
import 'theme/app_theme.dart';
import 'tts/media_interruption.dart';
import 'tts/tts_audio_handler.dart';
import 'tts/tts_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 手工引入的原生库（LAME，LGPL-2.0）不在 pub 依赖清单里，
  // 得自己注册到「开源许可」页 —— 见 registerThirdPartyLicenses 的说明
  registerThirdPartyLicenses();
  // 兜底：任何未捕获异常都落盘（logcat 重启就没，文件能留下来）
  await CrashLog.install();
  CrashLog.mark('main() 开始');
  // 书源抓取：把 GBK 解码器接到 SourceHttpClient 的钩子上（P0）
  // 不装的话，声明 charset=gbk 的中文站点会被当 UTF-8 解码 → 整页乱码
  GbkDecoderInstaller.install();
  // 本地设置（文档库、TTS 配置、主题）与朗读调度中心
  await StorageService.instance.init();
  // ★v1.22.23（低性能设备优化）：这三件事**互不依赖**，并行做
  //
  // 原来是一个接一个 await：StorageService → TtsManager → 解析缓存目录 → 下载器，
  // 每步都有平台通道往返。低端平板上串起来就是好几百毫秒的首屏白屏。
  await Future.wait(<Future<void>>[
    TtsManager.instance.init(),
    // 解析缓存目录先求出来：等第一次打开文档时，用户正等着解析出结果，
    // 那时再做平台通道往返等于把耗时直接加到首屏
    // （见 DocumentService.warmUpCacheDirectory）
    DocumentService.warmUpCacheDirectory(),
    _initDownloader(),
  ]);
  CrashLog.mark('存储与朗读管理器初始化完成');
  // ★v1.22.23：音频服务/媒体键/外部文本**不挡首屏**
  //
  // 它们只影响"开始朗读"和"分享进来的文本"，首屏列表根本用不到。
  // 放到第一帧之后再做：用户看到列表的时间早了，实际功能一点没少
  // （点书 → 阅读页 → 点朗读，至少几百毫秒之后，那时早就装好了）。
  runApp(const TtsReaderApp());
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_initDeferredServices());
  });
  // 后台下载收尾扫描（v1.21.40）：用户可能在浏览器页发起下载后就退到桌面 /
  // 杀掉应用 —— 那时页面前台轮询已经停了，下载跑完不会入库。
  // 启动时扫一遍，配合回前台那一次（见 didChangeAppLifecycleState）。
  unawaited(DownloadWatcher.instance.sweep());
}

/// 下载器初始化（Android / iOS 才有；桌面 / 测试环境忽略）
Future<void> _initDownloader() async {
  try {
    await FlutterDownloader.initialize(debug: false);
  } catch (_) {
    // 桌面 / Web 无对应实现，忽略
  }
}

/// 首帧之后才需要的东西：后台音频服务、媒体键、外部文本入口、复制即朗读
Future<void> _initDeferredServices() async {
  // 后台朗读 + 通知栏控制：注册前台服务与媒体通知
  await TtsAudioHandler.init();
  // 耳机 / 平板媒体键兜底：平板有些 ROM 不走 MediaSession，
  // 音频属性 + 打断监听：**必须在这里单独做一次**，不能只靠 init() 里那句 ——
  // 桌面 / 测试环境里 audio_service 会初始化失败，那时也要按当前设置
  // （是否允许其它媒体打断）把音频会话配好，否则开关形同虚设。
  await MediaInterruptionController.instance.applySettings();
  // 外部文本入口（分享 / 划词 / 打开文本 / C2S）：冷启动携带的文本在这里取走
  await SpeakIntake.instance.init();
  // 复制即朗读：读一次配置；开关开着但悬浮球没跑起来时补拉一次
  // （同时兜住「开机自启被系统拦掉」的情况：打开一次应用就恢复）
  unawaited(C2sController.instance.bootstrap());
  CrashLog.mark('音频服务与外部文本入口初始化完成');
}

/// 桃花源阅读器：Material 3 + 动态取色种子 0xFF6750A4，支持亮 / 暗色
class TtsReaderApp extends StatefulWidget {
  const TtsReaderApp({super.key});

  /// Material 3 种子色
  static const Color seedColor = Color(0xFF6750A4);

  @override
  State<TtsReaderApp> createState() => _TtsReaderAppState();
}

class _TtsReaderAppState extends State<TtsReaderApp> with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<SpeakRequest>? _subscription;

  /// Navigator 还没就绪时的重试次数（避免每帧空转）
  int _pendingRetries = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 外部文本（分享 / 划词 / C2S）一进来就打开即读页并开始朗读
    _subscription = SpeakIntake.instance.stream.listen(_openSpeakNow);
    // 深链进来的书源 / 订阅源导入链接（系统把我们拉起来的那条路）
    DeepLinkIntake.instance.pendingSourceUrl.addListener(_onDeepLink);
    DeepLinkIntake.instance.pendingRssSourceUrl.addListener(_onRssDeepLink);
    // 冷启动时文本可能已经躺在原生侧，首帧后再取一次（拿不到就算了）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final SpeakRequest? pending = SpeakIntake.instance.takePending();
      if (pending != null) {
        _openSpeakNow(pending);
      } else {
        unawaited(SpeakIntake.instance.pullPending());
      }
    });
  }

  /// 深链监听（`pendingSourceUrl` 一变就处理一次）
  void _onDeepLink() {
    final String? src = DeepLinkIntake.instance.pendingSourceUrl.value;
    if (src == null) return;
    unawaited(_openSourceImport(src));
  }

  /// 订阅源深链：解析 → **勾选弹窗**（与阅读 App 同款）→ 写订阅源库
  void _onRssDeepLink() {
    final String? src = DeepLinkIntake.instance.pendingRssSourceUrl.value;
    if (src == null) return;
    unawaited(_openRssImport(src));
  }

  Future<void> _openRssImport(String src) async {
    final NavigatorState? navigator = _navigatorKey.currentState;
    if (navigator == null) {
      if (_pendingRetries < 10) {
        _pendingRetries++;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final String? again =
              DeepLinkIntake.instance.pendingRssSourceUrl.value;
          if (again != null) _openRssImport(again);
        });
      }
      return;
    }
    _pendingRetries = 0;
    DeepLinkIntake.instance.consumeRss();
    CrashLog.mark('深链[处理·订阅源] $src');
    final ScaffoldMessengerState? messenger =
        ScaffoldMessenger.maybeOf(navigator.context);
    try {
      final RssParseOutcome outcome = await RssImporter.parse(src);
      if (outcome.isEmpty) {
        messenger?.showSnackBar(
          SnackBar(
            content: Text(
              outcome.errors.isEmpty ? '没解析出任何订阅源' : outcome.errors.first,
            ),
          ),
        );
        return;
      }
      final List<RssSource> existingAll = await RssStore.instance.load();
      // 先取根 Navigator 的 context 再进对话框构造：`navigator` 在函数开头
      // 已做过 null 检查，且根 Navigator 的生命周期等于进程，不存在被销毁的情况。
      // ignore: use_build_context_synchronously
      final BuildContext rootContext = navigator.context;
      final List<RssSource>? picked = await showRssImportConfirm(
        // ignore: use_build_context_synchronously
        rootContext,
        sources: outcome.sources,
        existingUrls: <String>{
          for (final RssSource s in existingAll) s.sourceUrl,
        },
      );
      if (picked == null || picked.isEmpty) return;
      final ({int added, int updated}) result =
          await RssStore.instance.merge(picked);
      messenger?.showSnackBar(
        SnackBar(
          content: Text('已导入订阅源：新增 ${result.added} 个，更新 ${result.updated} 个'),
        ),
      );
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('导入订阅源失败：$e')));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DeepLinkIntake.instance.pendingSourceUrl.removeListener(_onDeepLink);
    DeepLinkIntake.instance.pendingRssSourceUrl.removeListener(_onRssDeepLink);
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 引擎比 Activity 活得久（audio_service 常驻）时，新 intent 只能靠回前台时来取
    if (state == AppLifecycleState.resumed) {
      unawaited(SpeakIntake.instance.pullPending());
      // 后台下载收尾扫描（v1.21.40）：用户是"切出去等下载"，回来时正好在这里补上
      // —— 页面前台轮询在他切走那一刻就停了。
      unawaited(DownloadWatcher.instance.sweep());
    }
  }

  /// 打开即读页；带文本的外部入口自动开始朗读
  void _openSpeakNow(SpeakRequest request) {
    final NavigatorState? navigator = _navigatorKey.currentState;
    if (navigator == null) {
      // 首帧之前还没有 Navigator：等下一帧再试（最多几次，避免空转）
      if (_pendingRetries < 10) {
        _pendingRetries++;
        WidgetsBinding.instance.addPostFrameCallback((_) => _openSpeakNow(request));
      }
      return;
    }
    _pendingRetries = 0;
    CrashLog.mark('外部文本入口：${request.source.label}，${request.text.length} 字');
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => SpeakNowPage(
          initialText: request.text,
          source: request.source,
          autoSpeak: true,
          fromExternalApp: true,
        ),
      ),
    );
  }

  /// 深链进来一条书源链接：弹确认 → 勾选页 → 导入
  ///
  /// 和浏览器里点「一键导入」走同一条路（`_offerBookSourceImport` 那套），
  /// 区别只是触发源不同：那边是网页点击，这里是系统把我们拉起来。
  Future<void> _openSourceImport(String src) async {
    final NavigatorState? navigator = _navigatorKey.currentState;
    if (navigator == null) {
      if (_pendingRetries < 10) {
        _pendingRetries++;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final String? again = DeepLinkIntake.instance.pendingSourceUrl.value;
          if (again != null) _openSourceImport(again);
        });
      }
      return;
    }
    _pendingRetries = 0;
    DeepLinkIntake.instance.consume();
    CrashLog.mark('深链[处理] 书源地址=$src');

    // 句柄在第一个 await 之前取：后面跨 await 再用 context 会被 lint 拦，
    // 而且 Navigator 重挂时也不该拿旧 context 去弹提示。
    final ScaffoldMessengerState? messenger =
        ScaffoldMessenger.maybeOf(navigator.context);

    final bool? ok = await showDialog<bool>(
      context: navigator.context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('发现书源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('这个链接包含一份书源，要导入吗？'),
            const SizedBox(height: 8),
            Text(
              src,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final ParseOutcome outcome;
    try {
      outcome = await SourceImporter.parse(src);
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('导入失败：$e')));
      return;
    }
    if (outcome.isEmpty) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(outcome.errors.isEmpty ? '没解析出任何书源' : outcome.errors.first),
        ),
      );
      return;
    }

    final List<SourceRule> existing = await LegadoSourceStore.instance.load();
    final List<SourceRule>? picked =
        await navigator.push<List<SourceRule>>(
      MaterialPageRoute<List<SourceRule>>(
        builder: (_) => SourceImportConfirmPage(
          sources: outcome.rules,
          localUrls: <String>{for (final SourceRule r in existing) r.url},
        ),
      ),
    );
    if (picked == null || picked.isEmpty) return;
    final ({int added, int updated}) result = await applySelectedSources(picked);
    messenger?.showSnackBar(
      SnackBar(
        content: Text('已导入：新增 ${result.added} 个书源，更新 ${result.updated} 个'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final storage = StorageService.instance;
    return ChangeNotifierProvider<TtsManager>.value(
      value: TtsManager.instance,
      // 主题模式 / 取色来源 / 背景图 任一变化都要重建（外观设置是三个独立的通知源）
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: storage.themeMode,
        builder: (context, mode, _) => ValueListenableBuilder<int>(
          valueListenable: storage.appearance,
          builder: (context, _, __) => AppTheme.build(
            builder: (light, dark) => MaterialApp(
              title: '桃花源阅读器',
              debugShowCheckedModeBanner: false,
              navigatorKey: _navigatorKey,
              themeMode: mode,
              theme: light,
              darkTheme: dark,
              // 自定义背景图铺在所有界面下面（页面背景已设为透明）
              builder: (context, child) => AppTheme.backgroundLayer(
                context: context,
                child: child ?? const SizedBox.shrink(),
              ),
              locale: const Locale('zh', 'CN'),
              localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en', 'US')],
              home: const HomePage(),
            ),
          ),
        ),
      ),
    );
  }
}

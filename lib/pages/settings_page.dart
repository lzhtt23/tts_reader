import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/reader_style.dart';
import '../services/app_icon.dart';
import '../services/appearance_service.dart';
import '../services/auto_sleep.dart';
import '../services/c2s.dart';
import '../services/crash_log.dart';
import '../services/keep_alive.dart';
import '../services/speech_diag_export.dart';
import '../services/speech_diagnostics.dart';
import '../services/storage_service.dart';
import '../services/text_processor.dart';
import '../tts/media_interruption.dart';
import '../tts/tts_engine.dart';
import '../tts/tts_manager.dart';
import '../widgets/adaptive.dart';
import '../widgets/speech_diag_export_dialog.dart';
import 'book_sources_page.dart';
import 'legado_search_page.dart';
import 'legado_sources_page.dart';
import '../models/source_rule.dart';
import 'text_rules_page.dart';

/// 设置页：外观、朗读引擎、云端配置、语音、语速与音调
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.onOpenUrl});

  /// 「项目主页」这类外链的打开方式（由 [HomePage] 注入：切到浏览器 Tab 再打开）
  ///
  /// ⚠️ 之所以走**应用内浏览器**而不是 `url_launcher`：本工程没有那个依赖
  /// （也不打算为一个按钮加依赖），而应用自带一个完整浏览器 ——
  /// 点一下就切到浏览器 Tab 打开，用户还能顺手收藏 / 复制。
  final void Function(String url)? onOpenUrl;

  /// 项目在 GitHub 上的主页（设置页底部那个按钮的目标）
  ///
  /// ⚠️ 2026-10-14：主页地址换过一次（换了新的主页地址），这里跟着更新。
  /// 旧地址会 301 重定向，但界面里显示的应该是**现在**的地址。
  static const String projectHomeUrl = 'https://github.com/lzhtt23/tts_reader';

  /// 显示用的短地址（去掉 `https://`）——**由 [projectHomeUrl] 推导**，
  /// 两处不会各写一份然后漂移。
  static String get projectHomeShortUrl =>
      projectHomeUrl.replaceFirst('https://', '');

  /// 外观设置里的关键控件（用例据此定位）
  static const Key dynamicColorKey = ValueKey<String>('settings-dynamic-color');
  static const Key pickBackgroundKey = ValueKey<String>('settings-pick-background');
  static const Key clearBackgroundKey = ValueKey<String>('settings-clear-background');
  static const Key imageOpacityKey = ValueKey<String>('settings-image-opacity');

  /// 「允许其它媒体打断朗读」开关
  static const Key mediaInterruptKey = ValueKey<String>('settings-media-interrupt');

  @override
  State<SettingsPage> createState() => _SettingsPageState();

  /// 这个路径是不是**存储根目录 / 公共存储根**（用户没点进具体文件夹就选了）
  ///
  /// 放在公开的 [SettingsPage] 上（不是 State 里）**是为了能单测** ——
  /// `_SettingsPageState` 是私有类，测试库引用不到。
  ///
  /// 单独判这一种，是因为它的提示语完全不同：该说「请先进入具体文件夹」，
  /// 而不是「这个位置不支持」—— 后者会让人以为换个文件夹就行。
  @visibleForTesting
  static bool isPublicStorageRoot(String path) {
    var p = path.replaceAll('\\', '/').trim();
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p.isEmpty ||
        p == '/' ||
        p == '/storage' ||
        p == '/storage/emulated' ||
        p == '/storage/emulated/0' ||
        p == '/sdcard' ||
        p == '/mnt/sdcard';
  }

  /// 「保存位置」卡下方那段说明文案（**纯函数，可单测**）
  ///
  /// ## 为什么抽出来
  ///
  /// 本轮（需求一）修的就是这行字里的一处**路径重复**：
  /// 调用点传进来的 [inboxPath] 已经是
  /// `StorageService.downloadInboxPath`（**本身就含"桃花源阅读器"这一层**），
  /// 而原来在 widget 里又拼了一次 `/${StorageService.downloadInboxFolder}`，
  /// 界面上显示成 `…/Download/桃花源阅读器/桃花源阅读器/`。
  ///
  /// 文案改错一次不容易被发现（要滚到设置页底部才看得到），
  /// 所以把它抽成公开纯函数，让用例能直接钉住"子文件夹名只出现一次"。
  @visibleForTesting
  static String downloadPathHint(String inboxPath, {String customPath = ''}) {
    // ★v1.21.44：选了自定义文件夹时，下面那段"都放在系统下载目录下的专属文件夹"
    // 就是**错的**（文件会落到用户自选的目录）—— 说明文案必须跟着落点变。
    //
    // 方案 B：自定义生效时说明**两件事** —— ① 现在用的是自定义位置
    // ② 不再走"下完再挪进专属子文件夹"那一步（那是公共「下载」目录特有的流程）。
    if (customPath.isNotEmpty) {
      return '当前使用自定义保存位置：$customPath/\n'
          '文件直接下载到这里，不再收纳到软件专属子文件夹。\n'
          '卸载本应用不会删掉这个文件夹里的书；'
          '若该文件夹被删除或不可写，下载会自动回退到应用私有目录并提示。';
    }
    return '网页下载的书都放在：$inboxPath/\n'
        '这是系统公共「下载」目录下的一个专属文件夹，'
        '文件管理器里直接能看到，卸载本应用也不会删掉。\n'
        '（下载器只能先下到「下载」根目录，下完再挪进这个子文件夹；'
        '同一存储区内的移动是瞬间完成的，不会多占一份空间。）';
  }

  /// 「恢复默认」按钮的 tooltip（**纯函数，可单测**）
  ///
  /// ⚠️ 本轮（需求一）修：原来写的是「恢复默认（`publicDownloadPath`）」=
  /// `/storage/emulated/0/Download`（**根目录**），但恢复默认之后文件并不待在根目录 ——
  /// 会被挪进专属子文件夹。tooltip 说的是"默认去哪"，就该显示 [inboxPath]。
  @visibleForTesting
  static String downloadResetTooltip(String inboxPath) => '恢复默认（$inboxPath）';
}

class _SettingsPageState extends State<SettingsPage> {
  // 拖动中的临时值，松手后才写入管理器（避免每次滑动都落盘）
  double? _rate;
  double? _pitch;

  /// 本次进入设置页时**解析出来的**下载路径（绝对路径，面板上直接显示）
  ///
  /// 为什么单独存一份：`StorageService.downloadPath` 要读缓存，而真实路径
  /// （`getApplicationDocumentsDirectory`）得走平台通道 —— 进页面时异步算一次，
  /// 算完 `setState` 显示；算之前先显示近似值，避免闪一下空白。
  String? _downloadPath;

  bool _downloadPathLoading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDownloadPath());
  }

  /// 解析下载路径（进页面时调一次，改过设置后也会再调）
  ///
  /// 显示的是「**文件最终待的地方**」，按当前生效的保存位置二选一：
  /// * 设过自定义文件夹 → **显示自定义路径**（否则用户看不出自定义有没有生效）；
  /// * 否则 → `downloadInboxPath`（公共「下载」+ 软件专属子文件夹），
  ///   那也是 📂 面板会导航到的位置。
  ///
  /// ⚠️ 这里**不**显示 `StorageService.downloadPath`：它是"下载器直写位置"
  /// （公共下载时等于「下载」根目录），与"书最终在哪"不是一回事，别混用。
  Future<void> _loadDownloadPath() async {
    if (!mounted || _downloadPathLoading) return;
    _downloadPathLoading = true;
    final storage = StorageService.instance;
    String shown() => storage.hasCustomDownloadPath
        ? storage.customDownloadPath
        : storage.downloadInboxPath;
    setState(() => _downloadPath ??= shown());
    try {
      // 路径都是现成的字符串，不需要真的去解析；保留这个 await 是为了
      // 让"加载中"状态与既有调用点（进页面时 unawaited）保持一致。
      final resolved = shown();
      if (!mounted) return;
      setState(() => _downloadPath = resolved);
    } finally {
      _downloadPathLoading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tts = context.watch<TtsManager>();
    final rate = _rate ?? tts.rate;
    final pitch = _pitch ?? tts.pitch;
    // 平板横屏下设置项限宽居中，避免标题与开关被拉得很远
    return ContentWidth(
      maxWidth: 760,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
        children: <Widget>[
          _themeCard(),
          _appIconCard(),
          _readerStyleCard(),
          _mediaInterruptCard(),
          _engineCard(tts),
          _voiceCard(tts),
          _audioCard(tts, rate, pitch),
          _textProcessCard(),
          _autoSleepCard(),
          _c2sCard(),
          _keepAliveCard(),
          _downloadCard(),
          _speechDiagCard(),
          _bookSourcesCard(),
          _legadoSourcesCard(),
          _browseCard(),
          _tipsCard(tts),
          _diagnosticsCard(),
          // ★项目主页放在**最底部、居中**（用户要求：诊断日志提示的下方）
          _projectEntry(),
        ],
      ),
    );
  }

  Widget _groupTitle(String text) => Text(
    text,
    style: Theme.of(context).textTheme.titleSmall?.copyWith(
      color: Theme.of(context).colorScheme.primary,
      fontWeight: FontWeight.w600,
    ),
  );

  // ---------------- 外观 ----------------

  /// 启动图标样式（内置三种，不支持自定义图片）
  Widget _appIconCard() {
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _groupTitle('应用图标'),
            const SizedBox(height: 4),
            Text(
              '只支持内置样式。切换后桌面图标可能要等一会儿才刷新，'
              '桌面上已有的快捷方式会消失——这是 Android 的机制，不是 bug。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            FutureBuilder<AppIconStyle>(
              future: _iconStyleFuture ??= AppIcon.current().then((s) => _iconStyle = s),
              builder: (context, snapshot) {
                final current = _iconStyle ?? snapshot.data ?? AppIconStyle.sickle;
                return Row(
                  children: <Widget>[
                    for (final style in AppIconStyle.values)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _iconChoice(style, current),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<AppIconStyle>? _iconStyleFuture;
  AppIconStyle? _iconStyle;
  bool _iconSwitching = false;

  Widget _iconChoice(AppIconStyle style, AppIconStyle current) {
    final selected = style == current;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _iconSwitching || selected ? null : () => _pickIcon(style),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset(style.asset, width: 48, height: 48),
            ),
            const SizedBox(height: 6),
            Text(
              style.label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: selected ? scheme.primary : null,
                    fontWeight: selected ? FontWeight.w600 : null,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickIcon(AppIconStyle style) async {
    setState(() => _iconSwitching = true);
    final ok = await AppIcon.apply(style);
    if (!mounted) return;
    setState(() {
      _iconSwitching = false;
      if (ok) _iconStyle = style;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? '已切换到「${style.label}」；桌面图标可能要等一会儿才刷新'
            : '切换失败：这个系统不支持运行时换图标'),
      ),
    );
  }

  Widget _themeCard() {
    final storage = StorageService.instance;
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _groupTitle('外观'),
            const SizedBox(height: 12),
            ValueListenableBuilder<ThemeMode>(
              valueListenable: storage.themeMode,
              builder: (context, mode, _) => SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const <ButtonSegment<ThemeMode>>[
                  ButtonSegment<ThemeMode>(value: ThemeMode.system, label: Text('系统')),
                  ButtonSegment<ThemeMode>(value: ThemeMode.light, label: Text('亮色')),
                  ButtonSegment<ThemeMode>(value: ThemeMode.dark, label: Text('暗色')),
                ],
                selected: <ThemeMode>{mode},
                onSelectionChanged: (selection) => storage.setThemeMode(selection.first),
              ),
            ),
            const Divider(height: 24),
            // 手机动态取色（Material You，Android 12+）
            ValueListenableBuilder<int>(
              valueListenable: storage.appearance,
              builder: (context, _, __) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SwitchListTile(
                    key: SettingsPage.dynamicColorKey,
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.palette_outlined),
                    title: const Text('手机动态取色'),
                    subtitle: Text(
                      _dynamicColorSupported
                          ? '用系统壁纸取的色（Material You）：按钮、高亮等强调色会跟着变'
                          : '这台设备 / 系统版本不支持动态取色，开启后仍是默认配色',
                    ),
                    value: storage.useDynamicColor,
                    onChanged: (value) async {
                      // 先取好 messenger 再 await：跨过 await 后用 context 会被 lint 拦
                      final messenger = ScaffoldMessenger.of(context);
                      await storage.setUseDynamicColor(value);
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(value ? '已开启动态取色' : '已切回默认配色'),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 4),
                  _groupTitle('自定义背景图片'),
                  const SizedBox(height: 6),
                  if (storage.hasBackgroundImage) ...<Widget>[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(
                        File(storage.backgroundImage),
                        height: 96,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stack) => Container(
                          height: 96,
                          alignment: Alignment.center,
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          child: const Text('图片已失效，请重新选择'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        const Icon(Icons.opacity, size: 18),
                        const SizedBox(width: 4),
                        Text('背景透明度 ${(storage.backgroundImageOpacity * 100).round()}%'),
                      ],
                    ),
                    Slider(
                      key: SettingsPage.imageOpacityKey,
                      value: storage.backgroundImageOpacity,
                      // 0 = 图完全被主题色盖住（等于没有），1 = 图最清楚
                      onChanged: (value) =>
                          storage.setBackgroundImageOpacity(value),
                    ),
                    Text(
                      '调高图更清楚、文字对比会降低；调低文字更清楚。'
                      '背景会铺在整个界面上（含阅读页）。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ] else
                    Text(
                      '选一张图作为整个界面的背景（可随时调透明度或清除）。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: <Widget>[
                      FilledButton.tonalIcon(
                        key: SettingsPage.pickBackgroundKey,
                        onPressed: _pickBackgroundImage,
                        icon: const Icon(Icons.image_outlined),
                        label: Text(storage.hasBackgroundImage ? '更换图片' : '选择图片'),
                      ),
                      if (storage.hasBackgroundImage)
                        OutlinedButton.icon(
                          key: SettingsPage.clearBackgroundKey,
                          onPressed: _clearBackgroundImage,
                          icon: const Icon(Icons.close),
                          label: const Text('清除背景'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 这台设备是否支持动态取色
  ///
  /// `dynamic_color` 在 Android 12+ 才拿得到系统色；拿不到时开关仍可打开，
  /// 只是配色回退到默认种子色 —— 这里据此给出说明文案，别让用户以为坏了。
  bool get _dynamicColorSupported {
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  Future<void> _pickBackgroundImage() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await AppearanceService.instance.pickBackgroundImage();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(path == null ? '没有选择图片' : '背景已设置')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('选择图片失败：$e')));
    }
  }

  Future<void> _clearBackgroundImage() async {
    final messenger = ScaffoldMessenger.of(context);
    await AppearanceService.instance.clearBackgroundImage();
    if (!mounted) return;
    messenger.showSnackBar(const SnackBar(content: Text('已清除背景图片')));
  }

  // ---------------- 音频打断与耳机控制 ----------------

  /// 让其它媒体打断我们 + 耳机按键接到朗读上
  Widget _mediaInterruptCard() {
    final storage = StorageService.instance;
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: <Widget>[
                const Icon(Icons.headphones_outlined),
                const SizedBox(width: 12),
                Expanded(child: _groupTitle('朗读被打断与耳机控制')),
              ],
            ),
          ),
          SwitchListTile(
            key: SettingsPage.mediaInterruptKey,
            secondary: const Icon(Icons.compare_arrows),
            value: storage.allowMediaInterrupt,
            title: const Text('允许其它媒体打断朗读'),
            subtitle: const Text(
              '打开后：音乐 / 视频 / 导航播报 / 来电能暂停朗读（导航只压低音量），'
              '对方结束后自动接着读。关闭后各放各的，互不打扰。',
            ),
            onChanged: (value) async {
              await storage.setAllowMediaInterrupt(value);
              // 立即按新设置重新配置音频属性（不用重启应用）
              await MediaInterruptionController.instance.applySettings();
              if (mounted) setState(() {});
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '耳机按键（蓝牙 / 有线）',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                // ⚠️ v1.21.43 需求三：原来这里是「按句 / 按章」两个单选
                // （`MediaKeyAction` 的 `RadioListTile`），现已**删除**，
                // 耳机键固定为**按句**。文案必须如实说明，
                // 不能让用户以为还能选（那是"删了 UI 却骗人"）。
                '播放 / 暂停键：暂停或继续朗读。'
                '上一首 / 下一首键：上一句 / 下一句。'
                '注意 Android 把耳机按键固定映射成媒体键，应用无法任意重映射。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          const Divider(height: 1),
          // ★v1.22.62：耳机键兼容模式（静音音轨托底）
          //
          // 默认关：多数设备靠 MediaSession 就能收到耳机键，关掉后**完全没有爆音**
          // （那条静音音轨是爆音的唯一来源）。
          // 少数系统夺走媒体键归属时才需要打开，代价是首次会"啪"一声。
          ValueListenableBuilder<bool>(
            valueListenable: storage.mediaButtonCompat,
            builder: (BuildContext context, bool compat, Widget? _) {
              return SwitchListTile(
                secondary: const Icon(Icons.headphones_outlined),
                value: compat,
                title: const Text('耳机键兼容模式（开启会有爆音）'),
                subtitle: Text(
                  compat
                      ? '⚠️ 已开启：耳机键最稳，但每个进程首次朗读时会有一声「啪」。'
                          '这条静音音轨通电时的瞬态无法消除，只能选择它响在什么时候。'
                      : '默认关闭：没有任何额外声响。多数设备不开它耳机键也正常。'
                          '如果耳机键时灵时不灵（尤其被别的音乐打断后失效），'
                          '再打开它——注意开启后会有爆音。',
                ),
                onChanged: (bool v) => unawaited(storage.setMediaButtonCompat(v)),
              );
            },
          ),
        ],
      ),
    );
  }

  // ---------------- 引擎 ----------------

  Widget _engineCard(TtsManager tts) {
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.record_voice_over_outlined),
            title: const Text('朗读引擎'),
            subtitle: Text(tts.activeEngineName),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickEngine(tts),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.phone_android_outlined),
            title: const Text('本地 TTS 引擎'),
            subtitle: Text(
              tts.localEngines.isEmpty
                  ? '这台设备只报告了一个可用本地引擎'
                  : '当前：${tts.localEngineLabel} · 共 ${tts.localEngines.length} 个可选',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: tts.localEngines.isEmpty ? null : () => _pickLocalEngine(tts),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('云端 TTS 配置'),
            subtitle: Text(
              tts.cloudConfigured ? '已配置：${tts.cloudBaseUrl}' : '未配置（兼容 OpenAI 语音接口）',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _configureCloud(tts),
          ),
        ],
      ),
    );
  }
  /// 选择本地 TTS 引擎（设备上装了多个语音引擎时）
  Future<void> _pickLocalEngine(TtsManager tts) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('选择本地 TTS 引擎'),
        children: <Widget>[
          for (final engine in tts.localEngines)
            RadioListTile<String>(
              value: engine.package,
              groupValue: engine.isCurrent ? engine.package : tts.localEnginePackage,
              title: Text(engine.label),
              subtitle: Text(
                engine.isDefault ? '${engine.package} · 系统默认' : engine.package,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onChanged: (value) => Navigator.pop(dialogContext, value),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 4, 24, 8),
            child: Text(
              '切换后会自动重新套用语速、音调与音色（每个引擎的音色列表不同）。'
              '系统里没装别的语音引擎时，这里就只有一条。',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
    if (selected == null) return;
    await tts.setLocalEngine(selected);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('本地引擎：${tts.localEngineLabel}')));
  }

  Future<void> _pickEngine(TtsManager tts) async {
    final engines = tts.engines;
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('选择朗读引擎'),
        children: <Widget>[
          for (final engine in engines)
            RadioListTile<String>(
              value: engine.id,
              groupValue: tts.activeEngineId,
              title: Text(engine.displayName),
              subtitle: Text(engine.isAvailable ? '可用' : '未配置或不可用'),
              onChanged: (value) => Navigator.pop(dialogContext, value),
            ),
        ],
      ),
    );
    if (selected == null) return;
    await tts.setActiveEngine(selected);
  }

  Future<void> _configureCloud(TtsManager tts) async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _CloudConfigDialog(baseUrl: tts.cloudBaseUrl, apiKey: tts.cloudApiKey),
    );
    if (result == null) return;
    await tts.configureCloud(result.$1, result.$2);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.$1.isEmpty || result.$2.isEmpty ? '已清除云端配置' : '云端 TTS 配置已保存')),
    );
  }

  // ---------------- 语音 ----------------

  Widget _voiceCard(TtsManager tts) {
    final current = tts.voices.where((v) => v.id == tts.voiceId).toList();
    final label = tts.voiceId.isEmpty
        ? '默认语音（可选 ${tts.voices.length} 个）'
        : (current.isEmpty ? tts.voiceId : current.first.display);
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: const Icon(Icons.graphic_eq),
        title: const Text('语音'),
        subtitle: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _pickVoice(tts),
      ),
    );
  }

  Future<void> _pickVoice(TtsManager tts) async {
    final future = tts.refreshVoices();
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择语音'),
        content: SizedBox(
          width: double.maxFinite,
          height: 360,
          child: FutureBuilder<List<TtsVoice>>(
            future: future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final voices = snapshot.data ?? const <TtsVoice>[];
              if (voices.isEmpty) {
                return const Center(child: Text('当前引擎没有返回可用语音'));
              }
              return ListView.builder(
                itemCount: voices.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return RadioListTile<String>(
                      value: '',
                      groupValue: tts.voiceId,
                      title: const Text('跟随系统默认'),
                      onChanged: (value) => Navigator.pop(dialogContext, value),
                    );
                  }
                  final voice = voices[index - 1];
                  return RadioListTile<String>(
                    value: voice.id,
                    groupValue: tts.voiceId,
                    title: Text(voice.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: voice.locale.isEmpty ? null : Text(voice.locale),
                    onChanged: (value) => Navigator.pop(dialogContext, value),
                  );
                },
              );
            },
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('关闭')),
        ],
      ),
    );
    if (selected == null) return;
    await tts.setVoice(selected);
  }

  // ---------------- 语速与音调 ----------------

  Widget _audioCard(TtsManager tts, double rate, double pitch) {
    final theme = Theme.of(context);
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _groupTitle('语速与音调'),
            Row(
              children: <Widget>[
                const Icon(Icons.speed, size: 20),
                Expanded(
                  child: Slider(
                    value: rate,
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    label: '${(rate * 100).round()}%',
                    onChanged: (value) => setState(() => _rate = value),
                    onChangeEnd: (value) async {
                      await tts.setRate(value);
                      if (mounted) setState(() => _rate = null);
                    },
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text('${(rate * 100).round()}%', textAlign: TextAlign.end, style: theme.textTheme.labelMedium),
                ),
              ],
            ),
            Row(
              children: <Widget>[
                const Icon(Icons.tune, size: 20),
                Expanded(
                  child: Slider(
                    value: pitch,
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    label: pitch.toStringAsFixed(2),
                    onChanged: (value) => setState(() => _pitch = value),
                    onChangeEnd: (value) async {
                      await tts.setPitch(value);
                      if (mounted) setState(() => _pitch = null);
                    },
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(pitch.toStringAsFixed(2), textAlign: TextAlign.end, style: theme.textTheme.labelMedium),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 阅读排版 ----------------

  /// 字号 / 行距 / 字距 / 页边距 / 字体 / 阅读底色（T2S 的 ThemeSettings）
  Widget _readerStyleCard() {
    final storage = StorageService.instance;
    return ValueListenableBuilder<ReaderStyle>(
      valueListenable: storage.readerStyle,
      builder: (context, style, _) => Card.filled(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(child: _groupTitle('阅读排版')),
                  TextButton(
                    onPressed: style.isDefault
                        ? null
                        : () => storage.setReaderStyle(ReaderStyle.defaults),
                    child: const Text('恢复默认'),
                  ),
                ],
              ),
              _readingPreview(style),
              const SizedBox(height: 8),
              _styleSlider(
                label: '字号',
                value: style.fontSize,
                min: ReaderStyle.minFontSize,
                max: ReaderStyle.maxFontSize,
                divisions: 18,
                display: '${style.fontSize.round()}',
                onChanged: (value) => storage.setReaderStyle(style.copyWith(fontSize: value)),
              ),
              _styleSlider(
                label: '行距',
                value: style.lineHeight,
                min: ReaderStyle.minLineHeight,
                max: ReaderStyle.maxLineHeight,
                divisions: 12,
                display: style.lineHeight.toStringAsFixed(1),
                onChanged: (value) => storage.setReaderStyle(style.copyWith(lineHeight: value)),
              ),
              _styleSlider(
                label: '字距',
                value: style.letterSpacing,
                min: 0,
                max: ReaderStyle.maxLetterSpacing,
                divisions: 12,
                display: style.letterSpacing.toStringAsFixed(1),
                onChanged: (value) =>
                    storage.setReaderStyle(style.copyWith(letterSpacing: value)),
              ),
              _styleSlider(
                label: '页边距',
                value: style.pageMargin,
                min: 0,
                max: ReaderStyle.maxPageMargin,
                divisions: 16,
                display: '${style.pageMargin.round()}',
                onChanged: (value) => storage.setReaderStyle(style.copyWith(pageMargin: value)),
              ),
              _styleSlider(
                label: '段间距',
                value: style.paragraphSpacing,
                min: 0,
                max: ReaderStyle.maxParagraphSpacing,
                divisions: 12,
                display: '${style.paragraphSpacing.round()}',
                onChanged: (value) =>
                    storage.setReaderStyle(style.copyWith(paragraphSpacing: value)),
              ),
              const SizedBox(height: 4),
              Text('字体', style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: <Widget>[
                  for (final choice in ReaderStyle.fontChoices)
                    ChoiceChip(
                      label: Text(choice.$2),
                      selected: style.fontFamily == choice.$1,
                      onSelected: (_) =>
                          storage.setReaderStyle(style.copyWith(fontFamily: choice.$1)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text('阅读底色', style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: <Widget>[
                  for (final item in ReadingTheme.values)
                    ChoiceChip(
                      avatar: item.background == null
                          ? null
                          : CircleAvatar(backgroundColor: item.background),
                      label: Text(item.label),
                      selected: style.theme == item,
                      onSelected: (_) =>
                          storage.setReaderStyle(style.copyWith(theme: item)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 所见即所得的样例正文
  Widget _readingPreview(ReaderStyle style) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final background = style.background ?? scheme.surfaceContainerHighest;
    final highlight = style.highlightColors(scheme);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: style.pageMargin / 2 + 8,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            const TextSpan(text: '正在朗读的这一句会高亮。'),
            TextSpan(
              text: '这一句就是高亮的样子。',
              style: TextStyle(backgroundColor: highlight.$1, color: highlight.$2),
            ),
          ],
        ),
        style: style.apply(theme.textTheme.bodyMedium ?? const TextStyle()),
      ),
    );
  }

  Widget _styleSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        SizedBox(width: 52, child: Text(label, style: theme.textTheme.labelMedium)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            display,
            textAlign: TextAlign.end,
            style: theme.textTheme.labelMedium,
          ),
        ),
      ],
    );
  }

  // ---------------- 朗读文本预处理 ----------------

  /// 朗读前改写文本的规则（T2S 的 Text Process Rules）
  Widget _textProcessCard() {
    final processor = TextProcessor.instance;
    final active = processor.activeCount;
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: const Icon(Icons.find_replace_outlined),
        title: const Text('朗读文本预处理'),
        subtitle: Text(
          processor.rules.isEmpty
              ? '未配置规则（可把 △ 读成「三角形」、跳过 [1] 这类参考文献编号）'
              : '共 ${processor.rules.length} 条规则，$active 条生效',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.push<void>(
            context,
            MaterialPageRoute<void>(builder: (_) => const TextRulesPage()),
          );
          if (mounted) setState(() {});
        },
      ),
    );
  }

  // ---------------- 自动休眠 ----------------

  /// 空闲自动暂停 + 定时停止（T2S 的 tts.autosleep.settings）
  Widget _autoSleepCard() {
    final auto = AutoSleepController.instance;
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.bedtime_outlined),
            title: const Text('空闲自动暂停'),
            subtitle: Text(
              auto.idleMinutes > 0
                  ? '无操作 ${auto.idleMinutes} 分钟后自动暂停朗读'
                  : '已关闭（朗读时一直读下去）',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickAutoSleep(idle: true),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: const Text('定时停止'),
            subtitle: Text(
              auto.stopMinutes > 0
                  ? '一次朗读满 ${auto.stopMinutes} 分钟后自动停止'
                  : '已关闭（听书定时用）',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickAutoSleep(idle: false),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAutoSleep({required bool idle}) async {
    final auto = AutoSleepController.instance;
    const idleOptions = <int>[0, 1, 3, 5, 10, 15, 30, 60];
    const stopOptions = <int>[0, 15, 30, 45, 60, 90, 120];
    final options = idle ? idleOptions : stopOptions;
    final current = idle ? auto.idleMinutes : auto.stopMinutes;
    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(idle ? '无操作多久后自动暂停' : '一次朗读多久后自动停止'),
        children: <Widget>[
          for (final value in options)
            RadioListTile<int>(
              value: value,
              groupValue: current,
              title: Text(value == 0 ? '关闭' : '$value 分钟'),
              onChanged: (v) => Navigator.pop(dialogContext, v),
            ),
        ],
      ),
    );
    if (selected == null) return;
    await auto.configure(idle: idle ? selected : null, stop: idle ? null : selected);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('自动休眠：${auto.summary}')));
  }

  // ---------------- 复制即朗读（C2S） ----------------

  /// 悬浮朗读按钮 + 快捷磁贴 + 开机自启（T2S 的 copy2speak）
  Widget _c2sCard() {
    final c2s = C2sController.instance;
    final config = c2s.config;
    final scheme = Theme.of(context).colorScheme;
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          SwitchListTile(
            secondary: const Icon(Icons.bubble_chart_outlined),
            value: config.enabled,
            title: const Text('复制即朗读（悬浮按钮）'),
            subtitle: Text(
              !c2s.supported
                  ? '当前平台不支持（仅 Android）'
                  : (config.enabled
                        ? (config.running ? '悬浮球正在运行，点一下即可朗读剪贴板' : '已开启，等待系统允许显示悬浮窗')
                        : '在其他应用里复制文字后，点悬浮球直接朗读'),
            ),
            onChanged: !c2s.supported ? null : (value) => _toggleC2s(value),
          ),
          if (config.needsPermission) ...<Widget>[
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.warning_amber_outlined, color: scheme.error),
              title: const Text('还缺「显示在其他应用上层」权限'),
              subtitle: const Text('点这里去系统设置里打开，返回后会自动生效'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await c2s.requestOverlayPermission();
                if (!mounted) return;
                await c2s.refresh();
                if (!mounted) return;
                setState(() {});
              },
            ),
          ],
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.auto_awesome_outlined),
            value: config.autoShow,
            title: const Text('复制后弹出悬浮球'),
            subtitle: const Text('在别的应用里复制文字时，悬浮球会跳一下提示可以朗读'),
            onChanged: !c2s.supported
                ? null
                : (value) async {
                    await c2s.apply(autoShow: value);
                    if (mounted) setState(() {});
                  },
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: <Widget>[
                const Icon(Icons.photo_size_select_small, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Slider(
                    value: config.sizeDp.toDouble().clamp(
                      config.minSizeDp.toDouble(),
                      config.maxSizeDp.toDouble(),
                    ),
                    min: config.minSizeDp.toDouble(),
                    max: config.maxSizeDp.toDouble(),
                    divisions: config.maxSizeDp - config.minSizeDp,
                    label: '${config.sizeDp} dp',
                    onChanged: !c2s.supported
                        ? null
                        : (value) => c2s.apply(sizeDp: value.round()).then((_) {
                            if (mounted) setState(() {});
                          }),
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(
                    '${config.sizeDp} dp',
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              '· 悬浮球可以拖着换位置，位置会被记住。\n'
              '· 快捷设置磁贴：下拉通知栏 → 编辑 → 添加「朗读剪贴板」与「悬浮朗读」两个磁贴，'
              '不打开应用也能朗读剪贴板。\n'
              '· 开机自启：开启后重启手机悬浮球会自动回来；'
              '部分系统限制后台启动，打开一次应用即可恢复。\n'
              '· Android 10 及以上系统只允许有焦点的应用读剪贴板，'
              '所以点悬浮球时会有一个几乎看不见的透明界面闪一下。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleC2s(bool value) async {
    final c2s = C2sController.instance;
    final messenger = ScaffoldMessenger.of(context);
    if (value) {
      final granted = await c2s.hasOverlayPermission();
      if (!granted) {
        // 先要权限：授权回来后用户再点一次开关即可
        await c2s.apply(enabled: true);
        await c2s.requestOverlayPermission();
        if (!mounted) return;
        setState(() {});
        messenger.showSnackBar(
          const SnackBar(content: Text('请在系统设置里打开「显示在其他应用上层」，返回后自动生效')),
        );
        return;
      }
    }
    final running = await c2s.apply(enabled: value);
    if (!mounted) return;
    setState(() {});
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          value
              ? (running ? '悬浮朗读按钮已开启' : '已开启，但悬浮球没能启动（可能被系统拦了）')
              : '已关闭悬浮朗读按钮',
        ),
      ),
    );
  }

  // ---------------- 后台朗读保活 ----------------

  /// 熄屏继续读 + 电池优化白名单
  Widget _keepAliveCard() {
    final storage = StorageService.instance;
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          const ListTile(
            leading: Icon(Icons.nightlight_outlined),
            title: Text('熄屏继续朗读'),
            subtitle: Text('朗读期间持有 CPU 唤醒锁与前台服务，关屏后继续读；暂停或停止立刻释放'),
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.screen_lock_portrait_outlined),
            value: storage.keepScreenOn,
            title: const Text('朗读时保持屏幕常亮'),
            subtitle: const Text('默认关：开着会一直亮屏，很费电（想盯着屏幕跟读时再打开）'),
            onChanged: (value) async {
              await context.read<TtsManager>().setKeepScreenOn(value);
              if (mounted) setState(() {});
            },
          ),
          // ★v1.22.62：PDF 控制栏展开形态（默认横胶囊，可切换成扇形逐键展开）
          ValueListenableBuilder<bool>(
            valueListenable: storage.pdfRadialControl,
            builder: (BuildContext context, bool radial, Widget? _) {
              return SwitchListTile(
                secondary: const Icon(Icons.control_point_duplicate_outlined),
                value: radial,
                title: const Text('PDF 控制栏用扇形展开'),
                subtitle: Text(
                  radial
                      ? '当前：扇形 —— 主键不动，其余按键依次弹出'
                      : '当前：横胶囊（默认）—— 一行图标，MD3 风格',
                ),
                onChanged: (bool v) => unawaited(storage.setPdfRadialControl(v)),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.battery_saver_outlined),
            title: const Text('允许后台运行（忽略电池优化）'),
            subtitle: Text(_batteryHint),
            trailing: const Icon(Icons.chevron_right),
            onTap: _requestIgnoreBatteryOptimizations,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              '· 小米 / 华为 / OPPO / vivo 等系统还需要在「设置 → 应用管理」里允许本应用'
              '「后台运行 / 自启动 / 省电策略：无限制」，否则锁屏久了仍可能被系统清掉。\n'
              '· 熄屏保活对系统 TTS 与云端 TTS 都生效；云端 TTS 另外持 WifiLock，避免关屏后网络被挂起。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  String _batteryHint = '点这里授权，避免锁屏后朗读被系统掐断';

  Future<void> _requestIgnoreBatteryOptimizations() async {
    final keepAlive = KeepAliveService.instance;
    if (await keepAlive.isIgnoringBatteryOptimizations()) {
      if (!mounted) return;
      setState(() => _batteryHint = '已加入白名单（后台朗读不会被电池优化掐断）');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已经在电池优化白名单里了')));
      return;
    }
    await keepAlive.requestIgnoreBatteryOptimizations();
    if (!mounted) return;
    // 授权在系统页里完成，回来再看一次状态
    final granted = await keepAlive.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() {
      _batteryHint = granted ? '已加入白名单（后台朗读不会被电池优化掐断）' : '点这里授权，避免锁屏后朗读被系统掐断';
    });
  }

  // ---------------- 朗读诊断（诊断系统，默认关） ----------------

  /// 跳动检测开关 + 导出入口。
  ///
  /// 默认关：发布包里用户看不见阅读页的指示灯，也不会产生任何文件。
  Widget _speechDiagCard() {
    final storage = StorageService.instance;
    final SpeechDiagReport report = SpeechDiagnostics.instance.analyze();
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          ValueListenableBuilder<bool>(
            valueListenable: storage.speechDiagEnabled,
            builder: (context, enabled, _) => SwitchListTile(
              secondary: const Icon(Icons.monitor_heart_outlined),
              title: const Text('朗读诊断（跳动检测）'),
              subtitle: Text(
                enabled
                    ? '已开启：阅读页右下角显示 🟢 / 🟡 / 🔴 指示灯，出现 🔴 时自动落盘'
                    : '默认关闭。开启后记录「朗读推进 / 翻页」事件，用于定位位置乱跳',
              ),
              value: enabled,
              // B-P1：开启前必须先确认（**每次都弹**，不做「首次只弹一次」优化）；
              // 关闭不弹窗（关掉永远安全）。
              onChanged: (bool value) => unawaited(_toggleSpeechDiag(value)),
            ),
          ),
          const Divider(height: 1),
          // v1.21.28：诊断文件的保存位置二选一（系统可见 ⇄ 应用私有）。
          // 系统可见那条同时修掉了「分享闪退」（在 share_plus 的 FileProvider 白名单内）。
          ValueListenableBuilder<bool>(
            valueListenable: storage.speechDiagEnabled,
            builder: (BuildContext context, bool enabled, Widget? _) {
              if (!enabled) return const SizedBox.shrink();
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SwitchListTile(
                    secondary: const Icon(Icons.folder_shared_outlined),
                    title: const Text('保存到系统可见目录'),
                    subtitle: Text(
                      storage.speechDiagToExternal
                          ? '路径：Android/data/com.example.tts_reader/files/speech_diag\n'
                              '（系统文件管理器可见；部分机型需打开"显示隐藏/系统文件"）'
                          : '路径：应用私有目录\n'
                              '（文件管理器看不到，只能 `adb shell run-as` 取）',
                      style: const TextStyle(fontSize: 12),
                    ),
                    value: storage.speechDiagToExternal,
                    onChanged: (bool value) async {
                      await storage.setSpeechDiagToExternal(value);
                      if (context.mounted) setState(() {});
                    },
                  ),
                  const Divider(height: 1),
                ],
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.ios_share_outlined),
            title: const Text('导出朗读诊断'),
            subtitle: Text(
              '事件 ${SpeechDiagnostics.instance.eventCount} 条'
              '${report.hitsSummary.isEmpty ? '' : ' · 命中 ${report.hitsSummary}'}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => unawaited(showSpeechDiagExportDialog(context)),
          ),
          const Divider(height: 1),
          // B-P2：诊断文件的落点改成子目录后，给它一个可查 / 可复制的入口。
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('打开诊断目录'),
            subtitle: const Text('查看路径 / 文件清单，或直接分享最近一份'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => unawaited(_showSpeechDiagDir()),
          ),
        ],
      ),
    );
  }

  /// B-P2：诊断目录入口。
  ///
  /// 为什么不是「唤起系统文件管理器」：本工程没有引 `open_filex` / `url_launcher`
  /// （新插件的 AGP / Kotlin 版本会和现有 AGP 8.3 / Kotlin 1.9 打架，
  /// 见 pubspec 里 `wakelock_plus` 的同类注释），所以这里给三件事：
  /// ① 绝对路径（可复制，adb 用）② 目录里的文件清单 ③ 分享最近一份。
  Future<void> _showSpeechDiagDir() async {
    final String path = await SpeechDiagExport.dirPath();
    final List<File> files = await SpeechDiagExport.files();
    int totalBytes = 0;
    final List<String> rows = <String>[];
    for (final File f in files) {
      final int size = await f.length();
      totalBytes += size;
      rows.add('${f.uri.pathSegments.last} · ${_sizeText(size)}');
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final String summary = files.isEmpty
        ? '目录是空的（还没导出过，也没出现过 🔴）'
        : '${files.length} 个文件 · 共 ${_sizeText(totalBytes)}';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('诊断目录'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SelectableText(
                  path,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
                const SizedBox(height: 8),
                Text(summary, style: Theme.of(dialogContext).textTheme.bodySmall),
                if (rows.isNotEmpty) const SizedBox(height: 8),
                for (final String row in rows)
                  Text(
                    row,
                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  ),
                const SizedBox(height: 12),
                Text(
                  StorageService.instance.speechDiagToExternal
                      // v1.21.28：系统可见目录——文件管理器能进去，adb 也直读
                      ? '这是**系统可见**的应用外部目录。\n'
                          '取文件：①点「复制路径」，在系统文件管理器里粘贴进入；'
                          '②或 `adb shell ls /storage/emulated/0/Android/data/com.example.tts_reader/files/speech_diag/`；'
                          '③或点「分享最近一份」走系统分享面板。\n\n'
                          '部分机型（如小米）的"文件管理"默认隐藏 Android/data/，'
                          '需要在设置里打开「显示系统隐藏文件」。'
                      // 私有目录：只能 run-as 或分享
                      : '这是应用私有目录，系统文件管理器看不到。\n'
                          '取文件：①点「复制路径」，用 `adb shell run-as com.example.tts_reader cat <路径>`；'
                          '②或点「分享最近一份」走系统分享面板。',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: path));
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              messenger.showSnackBar(const SnackBar(content: Text('诊断目录路径已复制')));
            },
            child: const Text('复制路径'),
          ),
          TextButton(
            onPressed: files.isEmpty
                ? null
                : () async {
                    Navigator.pop(dialogContext);
                    final File? latest = await SpeechDiagExport.shareLatest();
                    if (latest == null) {
                      messenger.showSnackBar(
                        const SnackBar(content: Text('目录里还没有诊断文件')),
                      );
                    }
                  },
            child: const Text('分享最近一份'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 人类可读体积（诊断目录清单用）。
  static String _sizeText(int bytes) => bytes < 1024
      ? '$bytes B'
      : '${(bytes / 1024).toStringAsFixed(1)} KB';

  /// B-P1：开关确认弹窗。
  ///
  /// 规则（任务书 B-P1）：**每次打开都弹**，用户在弹窗里点「开启」才真正生效；
  /// 点「取消」/点外部关掉 → **回退到关**。关掉时**不弹**（关闭永远安全）。
  ///
  /// 开关的视觉状态由 `storage.speechDiagEnabled` 这个 ValueNotifier 驱动，
  /// 因此「未确认」时不需要额外 `setState` —— 但显式写一次 `false`，
  /// 保证「未确认 = 关」这条不变量在任何进入路径下都成立。
  Future<void> _toggleSpeechDiag(bool value) async {
    final storage = StorageService.instance;
    if (!value) {
      await storage.setSpeechDiagEnabled(false);
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('开启朗读诊断？'),
        content: const Text(
          '开启后会在阅读时记录「朗读推进 / 翻页」事件（只在内存里保留最近一批，'
          '约 450 条），阅读页右下角出现 🟢 / 🟡 / 🔴 指示灯，'
          '出现 🔴 时自动落盘一份诊断日志。\n\n'
          '诊断只用于定位「朗读位置乱跳」，平时请保持关闭（关闭时零开销）。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('开启'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      await storage.setSpeechDiagEnabled(false);
      return;
    }
    await storage.setSpeechDiagEnabled(true);
  }

  // ---------------- 下载 ----------------

  /// 下载保存位置：**完整路径 + 🔄 恢复默认 + 📂 选文件夹**
  ///
  /// UI（用户给的参考图）：
  /// ```
  /// 保存位置
  /// /storage/emulated/0/Download/Turrit/Books        [🔄]  [📂]
  /// ```
  /// - 整行也可点 = 等价于点 📂
  ///
  /// ## ⚠️ 为什么自定义路径只认应用私有目录
  ///
  /// `flutter_downloader` 只有两条落盘路：
  /// - `saveInPublicStorage: false` → 严格落在 `savedDir`，**任意子路径都行**，
  ///   但**只在应用私有目录内**（第三方应用没有任意路径的写权限）；
  /// - `saveInPublicStorage: true` → 走 MediaStore，**`savedDir` 被忽略**，
  ///   固定落 `Download/` **根目录**。
  ///
  /// 所以「公共下载目录下的自定义子路径」（`Download/Turrit/Books`）**写不进去**。
  /// 本版本按**方案 A**：选到公共目录时**明确提示并退回默认**，不静默降级。
  /// 要做到真的任意子路径需要**方案 B**（自己写 SAF +
  /// `takePersistableUriPermission` + `ContentResolver`，并换掉 `flutter_downloader`），
  /// **本轮不做**。
  Widget _downloadCard() {
    final storage = StorageService.instance;
    final String path = _downloadPath ?? storage.downloadPath;
    final bool custom = storage.hasCustomDownloadPath;
    // tooltip 与说明文案说的是「默认 / 最终落点」= 公共「下载」+ 专属子文件夹；
    // 与上面 [path]（面板显示用的路径）分开取，避免两处各拼一次又拼错。
    final String inbox = storage.downloadInboxPath;
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.download_outlined),
            // ★v1.21.44：把「当前来源」显示出来（自定义文件夹 / 系统下载目录 / 应用私有目录）
            title: Text('保存位置（${storage.downloadTarget.label}）'),
            // 路径可能很长：等宽字体 + 自动换行，别被 ellipsis 截成看不出是哪个目录
            subtitle: Text(
              path,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  key: const ValueKey<String>('download-path-reset'),
                  icon: const Icon(Icons.refresh),
                  // ⚠️ 本轮（需求一）修文案：默认落点是**公共「下载」+ 专属子文件夹**
                  // （= `downloadInboxPath`），不是「下载」根目录 ——
                  // 原来那个 tooltip 写"恢复默认（/storage/emulated/0/Download）"，
                  // 与文件实际去哪儿不符（文件会被挪进子文件夹）。
                  tooltip: SettingsPage.downloadResetTooltip(inbox),
                  onPressed: custom ? () => unawaited(_resetDownloadPath()) : null,
                ),
                IconButton(
                  key: const ValueKey<String>('download-path-pick'),
                  icon: const Icon(Icons.folder_open),
                  tooltip: '选择文件夹',
                  onPressed: () => unawaited(_pickDownloadFolder()),
                ),
              ],
            ),
            onTap: () => unawaited(_pickDownloadFolder()),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            // ⚠️ 这里是**纯文本** `Text`，不是 Markdown 渲染器：
            // 写 `**强调**` 会原样把星号显示给用户（v1.21.40 修）。
            //
            // ⚠️ v1.21.41 修正一处**事实错误**：原来写"能自定义的只有本应用自己的
            // 目录，而那个目录在系统文件选择器里进不去"—— 这是错的。
            // **应用的外部私有目录**（`/storage/emulated/0/Android/data/<包名>/files/`）
            // 在多数机型上**能**在系统文件管理器 / 选择器里进去（用户截图证实）。
            // 因此下面加了"存到外部存储"的一键入口。
            child: Text(
              // ⚠️ 纯文本 `Text`，不能写 Markdown 星号（会原样显示给用户）。
              // 这段必须说清三件事（用户踩过的坑）：
              //   · 文件落在哪（含那个软件专属子文件夹）
              //   · 为什么是"下完再挪"而不是"直接下进去"
              //   · 卸载软件**不会**删掉这些书（这是用户最关心的）
              //
              // 文案本身在 [SettingsPage.downloadPathHint]（纯函数、可单测）：
              // 本轮（需求一）修的就是它原来把子文件夹名拼了两遍的问题。
              SettingsPage.downloadPathHint(inbox,
                  customPath: storage.customDownloadPath),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }


  /// 🔄 恢复默认：清掉自定义路径，退回系统「下载」目录
  Future<void> _resetDownloadPath() async {    await StorageService.instance.resetDownloadPath();
    if (!mounted) return;
    setState(() => _downloadPath = null);
    await _loadDownloadPath();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已恢复默认保存位置')),
    );
  }

  /// 📂 拉起系统文件夹选择器（Android = `ACTION_OPEN_DOCUMENT_TREE`，即「使用此文件夹」）
  ///
  /// ## Android 11+ 的「所有文件访问」前置流程（v1.21.44）
  ///
  /// 想选应用私有目录 / 系统「下载」目录**之外**的任意文件夹，系统要求本应用先拿到
  /// 「所有文件访问」权限（`MANAGE_EXTERNAL_STORAGE`）。而这个权限**没有弹窗申请**
  /// 这条路 —— 只能：
  ///
  /// 1. 先查（[StorageService.hasAllFilesAccess]）；
  /// 2. 没授权 → 弹一段说明，让用户明白为什么要授权；
  /// 3. 点「去授权」→ 跳系统设置页（[StorageService.requestAllFilesAccess]）；
  /// 4. 用户回来 → **重新查一次**（不能假设他一定开了）；
  /// 5. 拿到了才拉文件夹选择器。
  ///
  /// Android 10 及以下没有这个开关（`hasAllFilesAccess` 恒为 true），流程自动跳过。
  Future<void> _pickDownloadFolder() async {
    // ① 权限检查（Android 11+）—— 没权限就别拉选择器，否则用户选完也是白选
    if (!await StorageService.hasAllFilesAccess()) {
      if (!mounted) return;
      final bool? agreed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('需要「所有文件访问」权限'),
          content: const Text(
            '要自选下载文件夹（内部存储或 SD 卡上的任意目录），'
            '系统要求本应用获得「所有文件访问」权限。\n\n'
            '点「去授权」会跳到系统设置页，在里面打开开关即可；'
            '返回本应用后会自动继续。\n\n'
            '授权后本应用可以读写整个存储空间。'
            '不想授权就继续用「应用私有目录」或「系统下载目录」。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('去授权'),
            ),
          ],
        ),
      );
      if (agreed != true || !mounted) return;

      // ② 跳系统设置页
      await StorageService.requestAllFilesAccess();
      if (!mounted) return;

      // ③ 回来重新查（用户可能没开就返回了）
      if (!await StorageService.hasAllFilesAccess()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未获得权限，无法自选文件夹')),
        );
        return;
      }
      if (!mounted) return;
    }

    String? picked;
    try {
      picked = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择下载保存位置',
      );
    } catch (e) {
      if (!mounted) return;
      // 部分 ROM 没有 DocumentsUI（文件夹选择器）→ 明确告诉用户，不静默失败
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('这个系统没有文件夹选择器：$e')),
      );
      return;
    }
    if (picked == null || picked.trim().isEmpty) return; // 用户取消：什么都不改
    if (!mounted) return;

    // ★v1.21.44：判据放开 —— 只要**是文件系统路径**就接受，能不能写**当场实测**。
    //
    // 以前这里只认"应用私有目录之内"（[StorageService.isUnderAnyBase]），
    // 而系统文件选择器进不去应用私有目录（它在 `/data/user/0/…` 下）——
    // 于是"自定义文件夹"实际上永远选不成，文案只能写"只有部分机型可用"。
    // 现在：`content://` 这类 URI 仍然拒（下载器只吃真实路径）；普通路径交给
    // [StorageService.isUsableCustomDir]（基准内直接过 / 外部路径真写探针实测）。
    final bool isFsPath = StorageService.isFilesystemPath(picked);
    final bool usable = isFsPath && await StorageService.isUsableCustomDir(picked);
    if (!usable) {
      if (!mounted) return;
      // ⚠️ 不静默接受：写不进去的目录必须当场说清楚（否则用户只会在下载时看到"失败"）
      final bool atStorageRoot = SettingsPage.isPublicStorageRoot(picked);
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            !isFsPath
                ? '这个位置用不了'
                : (atStorageRoot ? '请先进入具体文件夹' : '系统不允许写这个位置'),
          ),
          content: Text(
            !isFsPath
                ? '选中的是：\n$picked\n\n'
                    '系统文件选择器返回了特殊地址，无法作为下载位置。\n\n'
                    '请改选「内部存储」或「SD 卡」上的具体文件夹。'
                : (atStorageRoot
                    ? '你选的是存储根目录：\n$picked\n\n'
                        '请点进一个具体的文件夹（或者先新建一个）再点「使用此文件夹」。'
                    : '选中的是：\n$picked\n\n'
                        '应用往这里写文件被系统拒绝了。\n\n'
                        '常见原因：\n'
                        '· 「所有文件访问」权限被关掉了（系统设置里可以重新打开）；\n'
                        '· 这个文件夹是只读的（例如 SD 卡的某些分区）或已被删除。\n\n'
                        '也可以先改用下面两个位置之一：\n'
                        '· 系统下载目录（文件管理器可见）\n'
                        '· 应用私有目录（免权限，但文件管理器看不到）'),
          ),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('好'),
            ),
          ],
        ),
      );
      return;
    }

    await StorageService.instance.setCustomDownloadPath(picked);
    if (!mounted) return;
    setState(() => _downloadPath = null);
    await _loadDownloadPath();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('下载保存位置已更新')),
    );
  }



  // ---------------- 书源 ----------------

  /// 浏览器「书源」菜单的快捷入口（Z-Library 等）
  Widget _bookSourcesCard() {
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: const Icon(Icons.auto_stories_outlined),
        title: const Text('书源（浏览器快捷入口）'),
        subtitle: const Text('Z-Library 等站点；镜像域名常变，在这里换源'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const BookSourcesPage()),
        ),
      ),
    );
  }

  /// 阅读（legado）格式书源：导入后能真的搜书、抓目录、读正文
  ///
  /// 与上面那张卡是**两套独立数据**：
  /// - 上面那张只存网址（书签），点了用内置浏览器打开
  /// - 这张存解析规则，由本工程的规则引擎执行
  Widget _legadoSourcesCard() {
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: const Icon(Icons.auto_stories),
        title: const Text('书源（阅读格式）'),
        subtitle: const Text('导入 legado 书源，直接搜书并朗读正文'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => LegadoSourcesPage(
              onOpenSearch: (List<SourceRule> usable) {
                if (usable.isEmpty) return;
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LegadoSearchPage(sources: usable),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // ---------------- 项目 ----------------

  /// 项目主页（GitHub）入口 —— **居中**放在设置页最底部（诊断日志提示的下方）
  ///
  /// 用户要求：位置在「诊断日志」那张卡**下面**，并且**居中**（不是整行卡片）。
  /// 所以这里用 `Center` + `TextButton.icon`，并在按钮下面把网址小字显示出来 ——
  /// 用户想手动复制也有得抄。
  Widget _projectEntry() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextButton.icon(
              key: const ValueKey<String>('project-home'),
              onPressed: _openProjectHome,
              icon: const Icon(Icons.code, size: 18),
              label: const Text('项目主页（GitHub）'),
            ),
            Text(
              SettingsPage.projectHomeShortUrl,
              style: theme.textTheme.labelSmall,
            ),
            // ★v1.21.45：开源许可入口（LAME 是 LGPL-2.0，应用内要有声明处）
            TextButton.icon(
              key: const ValueKey<String>('open-source-licenses'),
              onPressed: () => showLicensePage(
                context: context,
                applicationName: '桃花源阅读器',
                applicationVersion: '1.21.45',
              ),
              icon: const Icon(Icons.article_outlined, size: 18),
              label: const Text('开源许可'),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开项目主页
  ///
  /// ⚠️ 由 [HomePage] 注入的 [SettingsPage.onOpenUrl] 负责"切 Tab + 打开"。
  /// 万一没有注入（例如单元测试直接 pump 本页），退一步把网址**显示出来**，
  /// 让用户能自己复制 —— 不能点了没反应。
  void _openProjectHome() {
    const String url = SettingsPage.projectHomeUrl;
    final void Function(String)? open = widget.onOpenUrl;
    if (open != null) {
      open(url);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('项目主页：$url')),
    );
  }

  // ---------------- 浏览器与目录 ----------------

  Widget _browseCard() {
    final storage = StorageService.instance;
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.home_work_outlined),
            title: const Text('默认首页'),
            subtitle: Text(storage.homeUrl, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editHomeUrl,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.list_alt),
            title: const Text('目录每页段数'),
            subtitle: Text('当前每 ${storage.paragraphsPerPage} 段算一页（影响阅读页的「选择页数」）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickParagraphsPerPage,
          ),
        ],
      ),
    );
  }

  Future<void> _editHomeUrl() async {
    final storage = StorageService.instance;
    final controller = TextEditingController(text: storage.homeUrl);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('默认首页'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 常用入口一键切换（默认是 Edge 系的 Bing 起始页）
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                for (final preset in StorageService.homePresets)
                  ActionChip(
                    label: Text(preset.$1),
                    onPressed: () => controller.text = preset.$2,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '网址',
                hintText: StorageService.defaultHomeUrl,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) => Navigator.pop(dialogContext, value),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, StorageService.defaultHomeUrl),
            child: const Text('恢复默认'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    await storage.setHomeUrl(result);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('默认首页：${storage.homeUrl}')));
  }

  Future<void> _pickParagraphsPerPage() async {
    final storage = StorageService.instance;
    final current = storage.paragraphsPerPage;
    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('每页段数'),
        children: <Widget>[
          for (final value in const <int>[20, 40, 80, 120, 200])
            RadioListTile<int>(
              value: value,
              groupValue: current,
              title: Text('$value 段 / 页'),
              onChanged: (v) => Navigator.pop(dialogContext, v),
            ),
        ],
      ),
    );
    if (selected == null) return;
    await storage.setParagraphsPerPage(selected);
    if (!mounted) return;
    setState(() {});
  }

  Widget _tipsCard(TtsManager tts) {
    final theme = Theme.of(context);
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _groupTitle('说明'),
            const SizedBox(height: 8),
            Text(
              '· 系统 TTS 使用设备内置引擎，离线可用。\n'
              '· 云端 TTS 走 OpenAI 兼容接口：POST JSON {model, input, voice, speed}，'
              '返回音频二进制；接口地址填到 /v1 即可，应用会自动补 /audio/speech。\n'
              '· 云端失败（网络异常、额度不足等）会自动降级为系统引擎，继续朗读同一段落。\n'
              '· 语速范围 0.5 ~ 2.0，当前 ${(tts.rate * 100).round()}%。',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
  // ---------------- 诊断日志 ----------------

  /// 崩溃 / 异常日志：闪退后靠它定位（logcat 重启就没了，这个是落盘的）
  Widget _diagnosticsCard() {
    final theme = Theme.of(context);
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('诊断日志'),
            subtitle: const Text('闪退 / 朗读异常会记录在这里，可复制发给开发者'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showDiagnostics,
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              '提示：如果朗读时闪退，请重新打开应用后进这里复制日志；'
              '也可以直接 `adb shell run-as com.example.tts_reader cat files/crash.log`。',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showDiagnostics() async {
    final text = await CrashLog.read();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          title: const Text('诊断日志'),
          content: SizedBox(
            width: double.maxFinite,
            height: 380,
            child: text.trim().isEmpty
                ? const Center(child: Text('暂无记录'))
                : SingleChildScrollView(
                    child: SelectableText(
                      text,
                      style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                    ),
                  ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () async {
                await CrashLog.clear();
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child: const Text('清空'),
            ),
            // v1.21.19：导出成**文件**（不走剪贴板）——
            // 贴到聊天软件里日志会被换行截断，尾部参数全丢，导出文件才能原样发。
            TextButton(
              onPressed: () async {
                final SpeechDiagWriteResult? result =
                    await SpeechDiagExport.exportCrashLog();
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (result == null) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('导出失败：日志为空或目录不可写')),
                  );
                  return;
                }
                messenger.showSnackBar(
                  SnackBar(
                    content: Text('已导出 ${result.sizeText}：${result.path}'),
                    duration: const Duration(seconds: 8),
                    action: SnackBarAction(
                      label: '分享',
                      onPressed: () =>
                          unawaited(SpeechDiagExport.sharePath(result.path)),
                    ),
                  ),
                );
              },
              child: const Text('导出文件'),
            ),
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                messenger.showSnackBar(const SnackBar(content: Text('日志已复制到剪贴板')));
              },
              child: const Text('复制全部'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }
}
class _CloudConfigDialog extends StatefulWidget {
  const _CloudConfigDialog({required this.baseUrl, required this.apiKey});

  final String baseUrl;
  final String apiKey;

  @override
  State<_CloudConfigDialog> createState() => _CloudConfigDialogState();
}

class _CloudConfigDialogState extends State<_CloudConfigDialog> {
  late final TextEditingController _url = TextEditingController(text: widget.baseUrl);
  late final TextEditingController _key = TextEditingController(text: widget.apiKey);
  bool _obscure = true;

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('云端 TTS 配置'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '接口地址 Base URL',
              hintText: 'https://api.openai.com/v1',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'API Key',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示' : '隐藏',
                icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '两项都留空表示关闭云端引擎。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(context, (_url.text.trim(), _key.text.trim())),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

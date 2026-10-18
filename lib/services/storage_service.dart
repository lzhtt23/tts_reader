import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/bookmark.dart';
import '../models/document.dart';
import '../models/reader_style.dart';
import '../models/text_rule.dart';
import '../models/web_link.dart';
import 'book_source_directory.dart';
import 'crash_log.dart';
import 'lame_encoder.dart';

/// 耳机（蓝牙 / 有线）按键的行为
///
/// 背景：Android 把耳机上的按键统一映射成固定的媒体键（播放/暂停、上一首、
/// 下一首），**应用无法任意重映射**。所以「耳机控制」就是把这三个键
/// 接到朗读动作上。
///
/// ⚠️ **v1.21.43 需求三（删干净）**：原来这里还有一个 `MediaKeyAction` 枚举，
/// 让用户选「上一首 / 下一首」是**换句**还是**换章**。
/// **该能力已整体删除** —— 枚举、设置项、UI 单选、`chapter` 分支、
/// 存档键（`audio_headset_next_action`）全部移除，耳机键**固定按句**。
/// 删掉的理由（用户拍板）：一个设置项只为省几次按键，却带来"两种行为分叉"，
/// 且真机上几乎没人改过它（存档里长期是默认值）。

/// 下载保存位置
///
/// Android 的存储模型决定了只有这两种选择（第三方应用写不了任意路径）：
/// - 应用私有目录：免权限、始终可读（自动导入文档库靠它）；
/// - 系统下载目录：公共「下载」目录，文件管理器可见（Android 10+ 走 MediaStore）。
///
/// ⚠️ v1.21.44 起多了第三项 [custom]：**它只是"当前用的是自定义文件夹"这个来源标记**，
/// 路径本身仍然存在 [StorageService.customDownloadPath] 里（唯一一份，不另开字段）。
enum DownloadTarget {
  appPrivate('应用私有目录', '应用专属目录，免存储权限；卸载应用会一起清掉'),
  publicDownloads('系统下载目录', '公共「下载」目录，文件管理器里能看到（需要 Android 10 及以上）'),
  // ⚠️ **新增项必须放最后**：老数据是按 `name` 存的，但任何以 `index` 为判据的
  // 地方（历史版本 / 外部脚本）都不能被这一项挪位。
  custom(
    '自定义文件夹',
    '自选一个文件夹。\n'
        '· 首次使用需在系统设置里开启「所有文件访问」权限；\n'
        '· 授权后可选内部存储或 SD 卡上的任意文件夹；\n'
        '· 若该文件夹日后被删除或不可写，下载会自动回退到应用私有目录并提示。',
  );

  const DownloadTarget(this.label, this.description);

  final String label;
  final String description;

  /// 从落盘的名字还原（v1.21.39 起**默认是系统下载目录**）
  ///
  /// ⚠️ 不能写成「不是 publicDownloads 就当 appPrivate」：那样
  /// `null`（全新安装，从没选过）与坏数据都会落到 appPrivate，
  /// **默认值改了也等于没改**。这里显式：只有确实存过 `appPrivate` 才用它，
  /// 其余（null / 坏数据 / 未来新增值）一律回默认的 [publicDownloads]。
  ///
  /// v1.21.44：[custom] 必须显式认出来 —— 否则用户选完自定义文件夹，
  /// **重启后就被兜底吃成「系统下载目录」**（功能等于没做）。
  /// ⚠️ 兜底本身**不动**（仍然是 publicDownloads）：改兜底是行为变更，与本次任务无关。
  static DownloadTarget fromName(Object? name) {
    if (name == appPrivate.name) return appPrivate;
    if (name == custom.name) return custom;
    return publicDownloads;
  }
}

/// 一个搜索引擎：把查询串拼成搜索 URL
class SearchEngine {
  const SearchEngine({required this.name, required this.urlTemplate});

  /// 显示名（按钮 / 菜单里用）
  final String name;

  /// URL 模板，`%s` 会被替换成 URL 编码后的查询串
  final String urlTemplate;

  /// 把查询词拼成完整 URL
  String urlFor(String query) =>
      urlTemplate.replaceFirst('%s', Uri.encodeComponent(query.trim()));

  @override
  String toString() => name;

  @override
  bool operator ==(Object other) =>
      other is SearchEngine && other.urlTemplate == urlTemplate;

  @override
  int get hashCode => urlTemplate.hashCode;
}

/// 本地持久化：文档库列表、TTS 设置、主题模式、浏览器收藏 / 记录
class StorageService {
  StorageService._();

  /// 全局单例
  static final StorageService instance = StorageService._();

  static const String _kDocuments = 'documents';
  static const String _kTtsSettings = 'tts_settings';
  static const String _kThemeMode = 'theme_mode';
  static const String _kBrowserHome = 'browser_home';
  static const String _kSearchEngine = 'browser_search_engine';
  static const String _kBookmarks = 'browser_bookmarks';
  static const String _kHistory = 'browser_history';
  static const String _kParagraphsPerPage = 'reader_paragraphs_per_page';
  static const String _kAutoFormatDocs = 'reader_auto_format_docs';
  static const String _kTextModeDocs = 'reader_text_mode_docs';
  static const String _kPdfReadingSpots = 'pdf_reading_spots';
  static const String _kTextRules = 'text_process_rules';
  static const String _kAutoSleepIdle = 'auto_sleep_idle_minutes';
  static const String _kAutoSleepStop = 'auto_sleep_stop_minutes';
  static const String _kReaderStyle = 'reader_style';
  static const String _kDocBookmarks = 'document_bookmarks';
  static const String _kDownloadTarget = 'download_target';
  static const String _kDownloadFolder = 'download_folder';
  static const String _kDownloadCustomPath = 'download_custom_path';
  static const String _kSaveCopyTree = 'download_save_copy_tree';
  static const String _kSaveCopyFolderName = 'download_save_copy_folder_name';
  static const String _kBookSources = 'book_sources';
  static const String _kKeepScreenOn = 'keep_screen_on';
  static const String _kTutorialDone = 'tutorial_done';
  static const String _kTutorialContentVersion = 'tutorial_content_version';
  static const String _kColorSource = 'theme_color_source';
  static const String _kBackgroundImage = 'theme_background_image';
  static const String _kBackgroundImageOpacity = 'theme_bg_opacity';
  static const String _kAllowMediaInterrupt = 'audio_allow_media_interrupt';

  /// 导出朗读音频的格式（★v1.21.45 改动 5）：`mp3`（默认）或 `wav`
  ///
  /// 存字符串而不是 bool，是为了以后加格式（比如 m4a）不用改数据类型。
  static const String _kAudioExportFormat = 'audio_export_format';

  /// PDF 朗读句纵向位置档位（0.35 / 0.5 / 0.65）
  static const String _kPdfSentenceAlignment = 'pdf_sentence_alignment';
  static const String _kSpeechDiagEnabled = 'speech_diag_enabled';
  static const String _kSpeechDiagToExternal = 'speech_diag_to_external';
  /// 浏览器默认首页
  ///
  /// 默认用 Edge 系的起始页（Bing）：`edge://newtab` 这类内部地址 WebView 打不开，
  /// Bing 是 Edge 的默认搜索/主页，也是能在内置浏览器里正常加载的最接近的入口。
  static const String defaultHomeUrl = 'https://www.bing.com/';

  /// 默认首页预设（设置页一键切换）
  static const List<(String, String)> homePresets = <(String, String)>[
    ('Edge（Bing）', defaultHomeUrl),
    ('微软资讯', 'https://www.msn.com/zh-cn'),
    ('百度', 'https://www.baidu.com'),
    ('Google', 'https://www.google.com'),
    ('DuckDuckGo', 'https://duckduckgo.com'),
  ];

  /// 搜索引军：地址栏输入的不是网址时用它搜
  ///
  /// 默认**必应**（与默认首页一致）：国内可直连，结果质量也比百度干净些。
  /// `%s` 是查询串的占位符（已做过 URL 编码）。
  static const List<SearchEngine> searchEngines = <SearchEngine>[
    SearchEngine(name: '必应', urlTemplate: 'https://www.bing.com/search?q=%s'),
    SearchEngine(name: '百度', urlTemplate: 'https://www.baidu.com/s?wd=%s'),
    SearchEngine(name: 'Google', urlTemplate: 'https://www.google.com/search?q=%s'),
    SearchEngine(name: 'DuckDuckGo', urlTemplate: 'https://duckduckgo.com/?q=%s'),
    SearchEngine(name: '搜狗', urlTemplate: 'https://www.sogou.com/web?query=%s'),
  ];

  /// 默认搜索引擎（列表第一项）
  static const SearchEngine defaultSearchEngine = SearchEngine(
    name: '必应',
    urlTemplate: 'https://www.bing.com/search?q=%s',
  );

  /// 目录分页默认值：每页段数
  static const int defaultParagraphsPerPage = 40;

  /// 浏览记录上限（超出后丢弃最旧的）
  static const int maxHistory = 200;

  SharedPreferences? _prefs;

  /// 主题模式（亮 / 暗 / 跟随系统），供 MaterialApp 监听
  final ValueNotifier<ThemeMode> themeMode = ValueNotifier<ThemeMode>(ThemeMode.system);

  String _homeUrl = defaultHomeUrl;
  int _paragraphsPerPage = defaultParagraphsPerPage;
  SearchEngine _searchEngine = defaultSearchEngine;

  /// 浏览器默认首页
  String get homeUrl => _homeUrl;

  /// 当前搜索引擎（地址栏输入的不是网址时用它搜）
  SearchEngine get searchEngine => _searchEngine;

  /// 阅读页每页段数（目录「选择页数」用）
  int get paragraphsPerPage => _paragraphsPerPage;

  // ---------------- 外观：取色、背景图、应用图标 ----------------

  /// 配色来源变化时通知界面重建（换取色 / 换背景图都要立刻生效）
  final ValueNotifier<int> appearance = ValueNotifier<int>(0);

  /// 朗读跳动检测（诊断系统）开关：默认关，发布包里用户看不见指示灯与导出入口。
  final ValueNotifier<bool> speechDiagEnabled = ValueNotifier<bool>(false);

  /// 诊断文件是否保存到**系统可见**的应用外部目录（v1.21.28）。
  ///
  /// - `true`（默认）：`/storage/emulated/0/Android/data/<pkg>/files/speech_diag/`
  ///   —— 系统文件管理器可见（部分 ROM 需显示 `Android/data/`）、adb 直接可读、
  ///   卸载时随应用清理；也在 `share_plus` 的 FileProvider 白名单里（分享不会崩）；
  /// - `false`：`/data/user/0/<pkg>/files/speech_diag/`
  ///   —— 只能 `adb shell run-as <包名> cat` 取，文件管理器看不到；
  ///   给"不想让别人从文件管理器翻到诊断日志"的用户。
  bool _speechDiagToExternal = true;

  bool get speechDiagToExternal => _speechDiagToExternal;

  Future<void> setSpeechDiagToExternal(bool value) async {
    if (_speechDiagToExternal == value) return;
    _speechDiagToExternal = value;
    await (await _sp).setBool(_kSpeechDiagToExternal, value);
  }

  /// 配色来源：跟随内置种子色，还是取手机的动态色（Android 12+ 的 Material You）
  bool _useDynamicColor = false;

  /// 自定义背景图（已复制到应用目录；空串表示没设）
  String _backgroundImage = '';

  /// 背景图透明度 0~1（越大越明显；文字可读性靠它调）
  double _backgroundImageOpacity = 0.35;

  /// 允许其它媒体（音乐 / 视频 / 来电）打断朗读
  ///
  /// 为真时朗读会**申请音频焦点**：别的应用出声时我们会被压低或暂停，
  /// 对方结束 / 来电挂断后自动继续。默认开 —— 这是用户要的行为。
  bool _allowMediaInterrupt = true;

  /// 导出音频格式（存扩展名字符串；默认 mp3 —— 见 [audioExportFormat]）
  String _audioExportFormat = 'mp3';

  /// 耳机「下一首」按键的行为

  bool get useDynamicColor => _useDynamicColor;

  String get backgroundImage => _backgroundImage;

  bool get hasBackgroundImage => _backgroundImage.trim().isNotEmpty;

  double get backgroundImageOpacity => _backgroundImageOpacity;

  bool get allowMediaInterrupt => _allowMediaInterrupt;

  /// 导出朗读音频用的格式（★v1.21.45 改动 5）：默认 **MP3**
  ///
  /// 默认 MP3 的理由很实在：30 万字的书出 WAV 是几百 MB，出 MP3 只有几十 MB，
  /// 而听书内容对码率不敏感。想留无损的可以在导出页选 WAV。
  AudioExportFormat get audioExportFormat =>
      AudioExportFormat.fromName(_audioExportFormat);

  /// 记住用户选的导出格式（导出页选择后落盘，下次打开还是它）
  ///
  /// ⚠️ `StorageService` 不是 `ChangeNotifier`（它靠各处主动读），
  /// 所以这里**不能** `notifyListeners()` —— 导出页自己 setState 就够了。
  Future<void> setAudioExportFormat(AudioExportFormat value) async {
    if (_audioExportFormat == value.extension) return;
    _audioExportFormat = value.extension;
    await (await _sp).setString(_kAudioExportFormat, _audioExportFormat);
  }


  /// **PDF 朗读句在屏幕上的纵向位置**（v1.21.43 · 模型 A）
  ///
  /// 0 = 贴顶、0.5 = 居中、1 = 贴底。三档可选：0.35 / 0.5 / 0.65。
  ///
  /// 默认 **0.35（靠上）** —— 用户真机拍板：0.5 在平板上偏低，
  /// 加上控制条展开会占掉底部，句子容易被挤到边上。0.35 留出下方余量。
  /// 用户可再改（三档保留 0.35）。
  ///
  /// ⚠️ 控制条**展开**时会自动切到 0.25（更靠上），见阅读页的
  /// `effectivePdfSentenceAlignment`。
  double get pdfSentenceAlignment => _pdfSentenceAlignment;
  double _pdfSentenceAlignment = 0.35;

  /// 三档可选值（设置页用它渲染选项）
  static const List<double> pdfSentenceAlignments = <double>[0.35, 0.5, 0.65];

  /// 档位的显示名（设置页用）
  static String pdfSentenceAlignmentLabel(double v) {
    if (v <= 0.4) return '靠上';
    if (v >= 0.6) return '靠下';
    return '居中';
  }

  Future<void> setPdfSentenceAlignment(double value) async {
    if (_pdfSentenceAlignment == value) return;
    _pdfSentenceAlignment = value;
    appearance.value++;
    await (await _sp).setDouble(_kPdfSentenceAlignment, value);
  }

  /// 允许 / 禁止其它媒体打断朗读
  Future<void> setAllowMediaInterrupt(bool value) async {
    if (_allowMediaInterrupt == value) return;
    _allowMediaInterrupt = value;
    appearance.value++;
    await (await _sp).setBool(_kAllowMediaInterrupt, value);
  }

  /// 切换配色来源（true = 手机动态取色）
  Future<void> setUseDynamicColor(bool value) async {
    if (_useDynamicColor == value) return;
    _useDynamicColor = value;
    appearance.value++;
    await (await _sp).setBool(_kColorSource, value);
  }

  /// **清掉需求三删除的旧存档键**（耳机「按句 / 按章」）
  ///
  /// 那个键已经**没有任何读取点**了，但会永远留在用户设备上 ——
  /// 将来若有人把枚举加回来，会读到一个"幽灵选择"（用户从没设过的值）。
  /// 所以启动时主动删一次。失败也不影响功能。
  Future<void> _purgeRemovedHeadsetKey() async {
    try {
      final sp = await _sp;
      await sp.remove('audio_headset_next_action');
    } catch (_) {
      // 清不掉也无害：没有读取点
    }
  }

  /// 设置 / 清除自定义背景图
  Future<void> setBackgroundImage(String path) async {
    _backgroundImage = path;
    appearance.value++;
    await (await _sp).setString(_kBackgroundImage, path);
  }

  /// 调节背景图透明度（0~1 夹取）
  Future<void> setBackgroundImageOpacity(double value) async {
    final safe = value.isNaN ? 0.35 : value.clamp(0.0, 1.0);
    if ((_backgroundImageOpacity - safe).abs() < 0.001) return;
    _backgroundImageOpacity = safe;
    appearance.value++;
    await (await _sp).setDouble(_kBackgroundImageOpacity, safe);
  }

  Future<SharedPreferences> get _sp async => _prefs ??= await SharedPreferences.getInstance();

  /// 仅供测试：丢弃缓存的实例与内存设置
  ///
  /// `SharedPreferences.setMockInitialValues` 只换底层存储，实例内部还留着上一份缓存，
  /// 测试之间会互相串数据（第二个用例会读到第一个用例写进去的设置）。
  @visibleForTesting
  void resetForTest() {
    _prefs = null;
    themeMode.value = ThemeMode.system;
    _homeUrl = defaultHomeUrl;
    _paragraphsPerPage = defaultParagraphsPerPage;
    _searchEngine = defaultSearchEngine;
    readerStyle.value = ReaderStyle.defaults;
    _autoFormatDocs = <String>{};
    _textModeDocs = <String>{};
    _pdfReadingSpots = <String, Map<String, int>>{};
    _useDynamicColor = false;
    _backgroundImage = '';
    _backgroundImageOpacity = 0.35;
    _allowMediaInterrupt = true;
    _audioExportFormat = 'mp3';
    _pdfSentenceAlignment = 0.35;
    _tutorialDone = false;
    _tutorialContentVersion = 0;
    speechDiagEnabled.value = false;
    _speechDiagToExternal = true;
    _downloadTarget = DownloadTarget.publicDownloads;
    _downloadFolder = defaultDownloadFolder;
    _customDownloadPath = '';
    _resolvedDefaultPath = '';
    _saveCopyTreeUri = '';
    _saveCopyFolderName = '';
  }

  /// 启动时读取轻量设置
  Future<void> init() async {
    final sp = await _sp;
    // ★v1.21.43 需求三：清掉已删除的耳机按键存档键（详见方法注释）
    await _purgeRemovedHeadsetKey();
    themeMode.value = switch (sp.getString(_kThemeMode)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    final home = sp.getString(_kBrowserHome);
    if (home != null && home.trim().isNotEmpty) _homeUrl = home.trim();
    final engine = sp.getString(_kSearchEngine);
    if (engine != null && engine.trim().isNotEmpty) {
      // 按 URL 模板反查：只认内置的那几个，存了怪值就退回默认
      for (final candidate in searchEngines) {
        if (candidate.urlTemplate == engine) {
          _searchEngine = candidate;
          break;
        }
      }
    }
    final perPage = sp.getInt(_kParagraphsPerPage);
    if (perPage != null && perPage >= 5) _paragraphsPerPage = perPage;
    speechDiagEnabled.value = sp.getBool(_kSpeechDiagEnabled) ?? false;
    _speechDiagToExternal = sp.getBool(_kSpeechDiagToExternal) ?? true;
    _autoFormatDocs = (sp.getStringList(_kAutoFormatDocs) ?? const <String>[]).toSet();
    _textModeDocs = (sp.getStringList(_kTextModeDocs) ?? const <String>[]).toSet();
    try {
      final spotsRaw = sp.getString(_kPdfReadingSpots);
      if (spotsRaw != null && spotsRaw.isNotEmpty) {
        final decoded = jsonDecode(spotsRaw);
        if (decoded is Map<String, dynamic>) {
          _pdfReadingSpots = decoded.map((key, value) {
            if (value is! Map<String, dynamic>) {
              return MapEntry(key, <String, int>{});
            }
            return MapEntry(
              key,
              <String, int>{
                if (value['page'] is num) 'page': (value['page'] as num).toInt(),
                if (value['sentence'] is num)
                  'sentence': (value['sentence'] as num).toInt(),
              },
            );
          });
        }
      }
    } catch (_) {
      _pdfReadingSpots = <String, Map<String, int>>{}; // 损坏不阻塞启动
    }
    _downloadTarget = DownloadTarget.fromName(sp.getString(_kDownloadTarget));
    final folder = sp.getString(_kDownloadFolder);
    if (folder != null && folder.trim().isNotEmpty) {
      _downloadFolder = sanitizeFolderName(folder);
    }
    _customDownloadPath = sp.getString(_kDownloadCustomPath) ?? '';
    _saveCopyTreeUri = sp.getString(_kSaveCopyTree) ?? '';
    _saveCopyFolderName = sp.getString(_kSaveCopyFolderName) ?? '';
    _keepScreenOn = sp.getBool(_kKeepScreenOn) ?? false;
    _tutorialDone = sp.getBool(_kTutorialDone) ?? false;
    _tutorialContentVersion = sp.getInt(_kTutorialContentVersion) ?? 0;
    // 外观设置
    _useDynamicColor = sp.getBool(_kColorSource) ?? false;
    _backgroundImage = sp.getString(_kBackgroundImage) ?? '';
    _backgroundImageOpacity = sp.getDouble(_kBackgroundImageOpacity) ?? 0.35;
    // 音频 / 耳机控制
    _allowMediaInterrupt = sp.getBool(_kAllowMediaInterrupt) ?? true;
    _audioExportFormat = sp.getString(_kAudioExportFormat) ?? 'mp3';
    _pdfSentenceAlignment = sp.getDouble(_kPdfSentenceAlignment) ?? 0.35;
    await loadReaderStyle();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    await (await _sp).setString(_kThemeMode, mode.name);
  }

  Future<void> setHomeUrl(String url) async {
    final value = url.trim();
    _homeUrl = value.isEmpty ? defaultHomeUrl : value;
    await (await _sp).setString(_kBrowserHome, _homeUrl);
  }

  /// 换搜索引擎（浏览器主界面的切换按钮 / 设置页）
  Future<void> setSearchEngine(SearchEngine engine) async {
    _searchEngine = engine;
    await (await _sp).setString(_kSearchEngine, engine.urlTemplate);
  }

  Future<void> setParagraphsPerPage(int value) async {
    _paragraphsPerPage = value < 5 ? defaultParagraphsPerPage : value;
    await (await _sp).setInt(_kParagraphsPerPage, _paragraphsPerPage);
  }

  /// 哪些文档开着「自动排版」（可读文本层的 PDF）
  ///
  /// 用户要求：**排版选择要固化** —— 点一次是排版、再点是恢复原排版，
  /// 不点就不改当前生效的排版，退出重进也保持这个选择。
  /// 所以这个开关必须落盘（按文档 id 记），而不是只活在阅读页的内存里。
  Set<String> _autoFormatDocs = <String>{};

  bool isAutoFormat(String documentId) => _autoFormatDocs.contains(documentId);

  Future<void> setAutoFormat(String documentId, bool value) async {
    if (value) {
      _autoFormatDocs.add(documentId);
    } else {
      _autoFormatDocs.remove(documentId);
    }
    await (await _sp).setStringList(
      _kAutoFormatDocs,
      _autoFormatDocs.toList(),
    );
  }

  /// 哪些 PDF 上次是用**文本模式**看的
  ///
  /// 用户要求：「文档库控制栏的返回朗读位置按钮，要识别从文档中退出时是 PDF 模式
  /// 还是文档模式，返回时要返回对应界面」。所以阅读模式必须按文档落盘 ——
  /// 否则从原版式退出、再点「返回朗读页」会进到文本模式（或反过来）。
  Set<String> _textModeDocs = <String>{};

  bool isTextMode(String documentId) => _textModeDocs.contains(documentId);

  Future<void> setTextMode(String documentId, bool value) async {
    if (value) {
      _textModeDocs.add(documentId);
    } else {
      _textModeDocs.remove(documentId);
    }
    await (await _sp).setStringList(
      _kTextModeDocs,
      _textModeDocs.toList(),
    );
  }

  // ---------------- PDF 朗读位置（§4.100 任务 D） ----------------

  /// 每本书**上次朗读到哪**（documentId → 位置）。
  ///
  /// 与 `PdfReadSession.current` 分开存：`clear()`（方块键 / 换书终止）
  /// 会清 current，但用户「结束朗读后重新进来要回到上次位置」——
  /// 这需要一份**独立于会话生命周期**的落盘记录（§4.65 的 _lastSpot
  /// 思路在 PDF 新实现里的落地方式）。只落磁盘 + 一份内存缓存，
  /// 不改动朗读游标本身的语义。
  Map<String, Map<String, int>> _pdfReadingSpots =
      <String, Map<String, int>>{};

  /// 某文档上次朗读的位置（页下标 + 句下标，都是 0 起）；没有返回 null
  ({int pageIndex, int sentenceIndex})? pdfReadingSpot(String documentId) {
    final spot = _pdfReadingSpots[documentId];
    if (spot == null) return null;
    final page = spot['page'];
    final sentence = spot['sentence'];
    if (page == null || sentence == null || page < 0 || sentence < 0) {
      return null;
    }
    return (pageIndex: page, sentenceIndex: sentence);
  }

  Future<void> setPdfReadingSpot(
    String documentId, {
    required int pageIndex,
    required int sentenceIndex,
  }) async {
    _pdfReadingSpots[documentId] = <String, int>{
      'page': pageIndex,
      'sentence': sentenceIndex,
    };
    await (await _sp).setString(_kPdfReadingSpots, jsonEncode(
      _pdfReadingSpots.map(
        (key, value) => MapEntry<String, dynamic>(key, value),
      ),
    ));
  }

  Future<void> removePdfReadingSpot(String documentId) async {
    if (_pdfReadingSpots.remove(documentId) == null) return;
    await (await _sp).setString(_kPdfReadingSpots, jsonEncode(
      _pdfReadingSpots.map(
        (key, value) => MapEntry<String, dynamic>(key, value),
      ),
    ));
  }

  // ---------------- 文档库 ----------------

  Future<List<Document>> loadDocuments() async {
    final raw = (await _sp).getString(_kDocuments);
    if (raw == null || raw.isEmpty) return <Document>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.whereType<Map<String, dynamic>>().map(Document.fromJson).toList();
    } catch (_) {
      return <Document>[]; // 数据损坏时不阻塞启动
    }
  }

  Future<void> saveDocuments(List<Document> documents) async =>
      (await _sp).setString(_kDocuments, jsonEncode(documents.map((d) => d.toJson()).toList()));

  /// 写入 / 更新一条文档记录，返回最新列表
  ///
  /// ## 三层判重（v1.21.43 重写版 · 块1）
  ///
  /// 治的真机症状：**一本书记两条**。根因是导入时
  /// `id = DateTime.now().microsecondsSinceEpoch` —— **每次都不同**，
  /// 而这里原来**只按 `id` 判重** → 同一个文件导入两次必然新增两条
  /// （一条坏的半截文件 + 一条好的）。
  ///
  /// 判重逐层放宽：
  /// 1. **按 `id`** —— 原有行为（进度 / 封面回写走这条）；
  /// 2. **按 `path`**（trim 后）—— 同一个文件被导入两次；
  /// 3. **按「书名去掉结尾 ` (n)`」+ 扩展名相同** —— 同名副本。
  ///    ` (n)` 是本应用"收纳时重名让开"自己加的，不是服务端原名的一部分。
  ///
  /// 命中时**保留原记录的 `id`**：它被阅读页位置记录、封面文件名引用着，
  /// 换 id 会让那些引用失联。同时**封面 / 文本层 / 最后阅读时间在新的为空时沿用旧的**
  /// —— 去重不能让已有封面丢掉（下载导入那条路不带封面）。
  ///
  /// ⚠️ 本实现是 v1.21.42 丢失版本的**重写**，不是"恢复"。
  Future<List<Document>> upsertDocument(Document document) async {
    final documents = await loadDocuments();
    var index = documents.indexWhere((d) => d.id == document.id);
    String? hitReason;

    // 第 2 层：同 path
    if (index < 0) {
      final path = document.path.trim();
      if (path.isNotEmpty) {
        final byPath = documents.indexWhere((d) => d.path.trim() == path);
        if (byPath >= 0) {
          index = byPath;
          hitReason = '同路径';
        }
      }
    }

    // 第 3 层：同名副本（书名去掉结尾 (n) 后相同 + 扩展名相同）
    if (index < 0) {
      final key = titleDedupeKey(document.title);
      if (key.isNotEmpty) {
        final ext = extensionOf(document.path);
        final byTitle = documents.indexWhere((d) =>
            titleDedupeKey(d.title) == key && extensionOf(d.path) == ext);
        if (byTitle >= 0) {
          index = byTitle;
          hitReason = '同名副本';
        }
      }
    }

    if (index >= 0 && hitReason != null) {
      final old = documents[index];
      CrashLog.mark('文档库去重[$hitReason] → 覆盖而不是新增'
          '（旧id=${old.id} 新id=${document.id} 书名=${document.title}）');
    }

    // 位置记忆埋点 G（落盘）：真正写进文档库的进度
    CrashLog.mark('位置[落盘] id=${document.id} progress=${document.progress} '
        '${index >= 0 ? "覆盖" : "新增"}');

    if (index >= 0) {
      final old = documents[index];
      documents[index] = Document(
        id: old.id, // 保留原 id（被位置记录 / 封面文件名引用着）
        title: document.title,
        path: document.path,
        type: document.type,
        importedAt: old.importedAt,
        progress: document.progress,
        // 封面 / 文本层 / 最后阅读时间：**新的为空时沿用旧的**，别丢
        coverPath: (document.coverPath ?? '').isEmpty
            ? old.coverPath
            : document.coverPath,
        hasTextLayer: document.hasTextLayer ?? old.hasTextLayer,
        lastReadAt: document.lastReadAt ?? old.lastReadAt,
      );
    } else {
      documents.insert(0, document);
    }
    await saveDocuments(documents);
    return documents;
  }

  /// 书名去重键：去掉结尾的 ` (数字)`（可有多个），再去空白 + 小写
  ///
  /// 例：`某书 (肖威主编) (1)` → `某书 (肖威主编)`
  ///
  /// ⚠️ 只去**结尾**那一处，不动书名中间的括号 —— 那可能是原名的一部分
  /// （作者名 `(肖威主编)`）。用 `$` 锚定结尾就是为此。
  @visibleForTesting
  static String titleDedupeKey(String title) {
    var t = title.trim();
    final trailing = RegExp(r'\s*\(\d+\)$');
    while (trailing.hasMatch(t)) {
      t = t.replaceFirst(trailing, '').trim();
    }
    return t.toLowerCase();
  }

  /// 扩展名（含点、小写；没有则空串）
  @visibleForTesting
  static String extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot <= 0 || dot >= path.length - 1) return '';
    return path.substring(dot).toLowerCase();
  }

  /// 删除文档，返回最新列表
  Future<List<Document>> removeDocument(String id) async {
    final documents = await loadDocuments();
    documents.removeWhere((d) => d.id == id);
    await saveDocuments(documents);
    return documents;
  }

  // ---------------- TTS 设置 ----------------

  Future<Map<String, dynamic>> loadTtsSettings() async {
    final raw = (await _sp).getString(_kTtsSettings);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      return (jsonDecode(raw) as Map<dynamic, dynamic>).cast<String, dynamic>();
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> saveTtsSettings(Map<String, dynamic> settings) async =>
      (await _sp).setString(_kTtsSettings, jsonEncode(settings));

  /// 朗读跳动检测开关（诊断系统；默认关）
  Future<void> setSpeechDiagEnabled(bool value) async {
    speechDiagEnabled.value = value;
    await (await _sp).setBool(_kSpeechDiagEnabled, value);
  }

  // ---------------- 朗读文本预处理规则 ----------------

  /// 读取规则表；返回 null 表示「从未保存过」（由 TextProcessor 播种内置预设）
  Future<List<TextRule>?> loadTextRules() async {
    final raw = (await _sp).getString(_kTextRules);
    if (raw == null) return null;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.whereType<Map<String, dynamic>>().map(TextRule.fromJson).toList();
    } catch (_) {
      return null; // 数据损坏按「没配过」处理，不至于让预处理整条链路失效
    }
  }

  Future<void> saveTextRules(List<TextRule> rules) async => (await _sp).setString(
    _kTextRules,
    jsonEncode(rules.map((rule) => rule.toJson()).toList()),
  );

  // ---------------- 自动休眠 ----------------

  /// (空闲暂停分钟数, 定时停止分钟数)，0 表示关闭
  Future<(int, int)> loadAutoSleep() async {
    final sp = await _sp;
    return (
      _nonNegative(sp.getInt(_kAutoSleepIdle)),
      _nonNegative(sp.getInt(_kAutoSleepStop)),
    );
  }

  Future<void> saveAutoSleep(int idleMinutes, int stopMinutes) async {
    final sp = await _sp;
    await sp.setInt(_kAutoSleepIdle, _nonNegative(idleMinutes));
    await sp.setInt(_kAutoSleepStop, _nonNegative(stopMinutes));
  }

  static int _nonNegative(int? value) => value == null || value < 0 ? 0 : value;

  // ---------------- 文档书签 ----------------

  /// 书签总量上限（超出后丢弃最旧的，避免无限膨胀）
  static const int maxDocBookmarks = 500;

  /// 全部文档的书签，按创建时间倒序
  Future<List<Bookmark>> loadDocBookmarks() async {
    final raw = (await _sp).getString(_kDocBookmarks);
    if (raw == null || raw.isEmpty) return <Bookmark>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final bookmarks = list
          .whereType<Map<String, dynamic>>()
          .map(Bookmark.fromJson)
          .where((bookmark) => bookmark.id.isNotEmpty)
          .toList();
      bookmarks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return bookmarks;
    } catch (_) {
      return <Bookmark>[]; // 数据损坏当作没有书签，不影响打开文档
    }
  }

  Future<void> saveDocBookmarks(List<Bookmark> bookmarks) async => (await _sp).setString(
    _kDocBookmarks,
    jsonEncode(bookmarks.map((bookmark) => bookmark.toJson()).toList()),
  );

  /// 新增书签；同位置已存在时直接返回原书签（不产生重复）
  Future<List<Bookmark>> addDocBookmark(Bookmark bookmark) async {
    final bookmarks = await loadDocBookmarks();
    for (final existing in bookmarks) {
      if (existing.sameSpot(bookmark)) return bookmarks;
    }
    bookmarks.insert(0, bookmark);
    if (bookmarks.length > maxDocBookmarks) {
      bookmarks.removeRange(maxDocBookmarks, bookmarks.length);
    }
    await saveDocBookmarks(bookmarks);
    return bookmarks;
  }

  /// 删除一个书签
  Future<List<Bookmark>> removeDocBookmark(String id) async {
    final bookmarks = await loadDocBookmarks();
    bookmarks.removeWhere((bookmark) => bookmark.id == id);
    await saveDocBookmarks(bookmarks);
    return bookmarks;
  }

  /// 删除某个文档的全部书签（文档被移出文档库时调用）
  Future<List<Bookmark>> removeDocBookmarksOf(String documentId) async {
    final bookmarks = await loadDocBookmarks();
    bookmarks.removeWhere((bookmark) => bookmark.documentId == documentId);
    await saveDocBookmarks(bookmarks);
    return bookmarks;
  }

  // ---------------- 阅读排版（字号 / 行距 / 底色） ----------------

  /// 阅读排版设置，供阅读页监听（改完立刻生效，不用退出重进）
  final ValueNotifier<ReaderStyle> readerStyle = ValueNotifier<ReaderStyle>(
    ReaderStyle.defaults,
  );

  Future<void> setReaderStyle(ReaderStyle style) async {
    readerStyle.value = style;
    await (await _sp).setString(_kReaderStyle, jsonEncode(style.toJson()));
  }

  Future<void> loadReaderStyle() async {
    final raw = (await _sp).getString(_kReaderStyle);
    if (raw == null || raw.isEmpty) return;
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) readerStyle.value = ReaderStyle.fromJson(json);
    } catch (_) {
      // 数据损坏就用默认排版，不影响打开文档
    }
  }

  // ---------------- 浏览器收藏 / 浏览记录 ----------------

  Future<List<WebLink>> _loadLinks(String key) async {
    final raw = (await _sp).getString(key);
    if (raw == null || raw.isEmpty) return <WebLink>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.whereType<Map<String, dynamic>>().map(WebLink.fromJson).toList();
    } catch (_) {
      return <WebLink>[];
    }
  }

  Future<List<WebLink>> loadBookmarks() => _loadLinks(_kBookmarks);

  Future<List<WebLink>> loadHistory() => _loadLinks(_kHistory);

  /// 用户手动添加的快捷方式（起始页格子只显示这些）
  ///
  /// 过滤两件事：
  /// - **搜索页**（`bing.com/search?q=…` 这类）不显示 —— 一次搜索留一个格子，
  ///   起始页很快就满屏都是「Search - Microsoft Bing」；
  /// - **同一站点只留一个**（按去掉 `www.` 的主机名去重，保留较新的那条）。
  Future<List<WebLink>> loadShortcuts() async {
    final all = await loadBookmarks();
    final marked = all.where((link) => link.isShortcut).toList();
    // 用户明确加过快捷方式：只认这些；没有标记时退回全部收藏（旧版本兼容）
    final source = marked.isNotEmpty ? marked : all;
    return dedupeByHost(
      source.where((link) => !link.isSearchResult).toList(growable: false),
    );
  }

  /// 按主机名去重，保留列表里靠前的那条（收藏列表本身就是最新在前）
  @visibleForTesting
  static List<WebLink> dedupeByHost(List<WebLink> links) {
    final seen = <String>{};
    final result = <WebLink>[];
    for (final link in links) {
      final key = link.bareHost.isEmpty ? link.url : link.bareHost;
      if (!seen.add(key)) continue;
      result.add(link);
    }
    return result;
  }

  /// 加一个快捷方式（已存在则只把标记补上）
  Future<List<WebLink>> addShortcut(WebLink link) async {
    final bookmarks = await loadBookmarks();
    final index = bookmarks.indexWhere((b) => b.url == link.url);
    if (index >= 0) {
      bookmarks[index] = bookmarks[index].copyWith(
        title: link.title.isNotEmpty ? link.title : bookmarks[index].title,
        isShortcut: true,
      );
    } else {
      bookmarks.insert(0, link);
    }
    await _saveBookmarks(bookmarks);
    return bookmarks;
  }

  /// 删掉一个快捷方式（同时从收藏里移除，避免残留看不见的条目）
  Future<List<WebLink>> removeShortcut(String url) => removeBookmark(url);

  /// 清空全部快捷方式（保留非快捷方式的收藏）
  Future<List<WebLink>> clearShortcuts() async {
    final bookmarks = await loadBookmarks();
    bookmarks.removeWhere((b) => b.isShortcut);
    await _saveBookmarks(bookmarks);
    return bookmarks;
  }

  Future<void> _saveBookmarks(List<WebLink> bookmarks) async => (await _sp).setString(
        _kBookmarks,
        jsonEncode(bookmarks.map((b) => b.toJson()).toList()),
      );

  /// 收藏 / 取消收藏，返回操作后的收藏列表
  Future<List<WebLink>> toggleBookmark(WebLink link) async {
    final bookmarks = await loadBookmarks();
    final index = bookmarks.indexWhere((b) => b.url == link.url);
    if (index >= 0) {
      bookmarks.removeAt(index);
    } else {
      bookmarks.insert(0, link);
    }
    await (await _sp).setString(_kBookmarks, jsonEncode(bookmarks.map((b) => b.toJson()).toList()));
    return bookmarks;
  }

  Future<List<WebLink>> removeBookmark(String url) async {
    final bookmarks = await loadBookmarks();
    bookmarks.removeWhere((b) => b.url == url);
    await _saveBookmarks(bookmarks);
    return bookmarks;
  }

  /// 追加浏览记录：同一网址只保留最新一条，并裁剪到上限
  Future<List<WebLink>> addHistory(WebLink link) async {
    final history = await loadHistory();
    history.removeWhere((h) => h.url == link.url);
    history.insert(0, link);
    if (history.length > maxHistory) history.removeRange(maxHistory, history.length);
    await (await _sp).setString(_kHistory, jsonEncode(history.map((h) => h.toJson()).toList()));
    return history;
  }

  Future<void> clearHistory() async => (await _sp).remove(_kHistory);

  // ---------------- 下载设置 ----------------

  /// 下载文件夹默认名（应用私有目录下的子目录）
  static const String defaultDownloadFolder = '下载';

  /// 系统公共「下载」目录的绝对路径（🔄 恢复默认的目标）
  ///
  /// ⚠️ 这是 Android 的公有目录约定路径，**不是**本应用能随意写的目录：
  /// 往这里写必须走 MediaStore（见 [_kDownloadCustomPath] 的说明）。
  static const String publicDownloadPath = '/storage/emulated/0/Download';

  /// 公共「下载」目录下的**应用专属子文件夹**名（v1.21.41）
  ///
  /// 下载完的文件会从「下载」根目录**挪进**这里（同卷改名，瞬间完成、不是两份）。
  /// 好处：分类清楚 + **卸载应用不删**（它属于公共目录，不属于本应用）。
  ///
  /// 为什么不是"直接下进这个子文件夹"：`flutter_downloader` 写公共目录时
  /// `RELATIVE_PATH` 写死成 `Download`，我们给的子路径会被忽略（源码为证，
  /// 见 `download_watcher.inboxDownloadedFile` 的注释）。
  static const String downloadInboxFolder = '桃花源阅读器';

  /// 下载文件的**实际落点**：公共「下载」下的软件专属子文件夹（v1.21.43 · 块3）
  ///
  /// 与 [downloadPath] 的区别（两者**语义不同，别混用**）：
  /// - [downloadPath] = 下载器**直写**的位置 = 公共「下载」**根目录**
  ///   （插件 `RELATIVE_PATH` 写死，给子路径也没用）；
  /// - [downloadInboxPath] = 文件**最终待的地方** = 根目录 + 专属子文件夹。
  ///   设置页显示它、📂 导航到它、`inboxDownloadedFile` 把文件挪进它。
  ///
  /// 两者都在**公共目录**下 —— 这是"卸载软件不删"的唯一位置
  /// （应用私有目录卸载必删，已实测：连 `/storage/emulated/0/Android/data/<包名>/`
  /// 都被系统整个删掉）。
  String get downloadInboxPath => '$publicDownloadPath/$downloadInboxFolder';

  DownloadTarget _downloadTarget = DownloadTarget.publicDownloads;
  String _downloadFolder = defaultDownloadFolder;

  /// 用户自定义的下载**绝对路径**（空 = 用默认）
  ///
  /// ## ⚠️ 底层限制（**必须知道，别按"任意路径都能写"来用**）
  ///
  /// `flutter_downloader` 只有两条落盘路：
  /// - `saveInPublicStorage: false` → 严格落在 `savedDir`，**任意子路径都行**，
  ///   但**只在应用私有目录内**（第三方应用没有任意路径的写权限）；
  /// - `saveInPublicStorage: true` → 走 MediaStore，**`savedDir` 被忽略**，
  ///   固定落 `Download/` **根目录**。
  ///
  /// 所以「公共下载目录下的自定义子路径」（如 `Download/Turrit/Books`）
  /// **写不进去**。本版本采取**方案 A**：
  /// - 自定义路径**只在应用私有目录内生效**；
  /// - 用户选到公共目录时给提示，并退回默认。
  ///
  /// 真要做到"公共目录下的任意子路径"需要**方案 B**：自己写 SAF
  /// （`ACTION_OPEN_DOCUMENT_TREE` + `takePersistableUriPermission` +
  /// `ContentResolver.openOutputStream`），并**换掉 `flutter_downloader`**。
  /// 本轮不做。
  String _customDownloadPath = '';

  /// 页面显示用的下载完整路径（同步 getter，读缓存）
  ///
  /// ⚠️ 必须是**纯路径字符串**：不能把 `Directory` 对象拿去插值。
  /// `'$dir'` 会调 `toString()` → 得到 `Directory: '/data/...'`
  /// （带前缀 + 单引号），既难看又会把后面的 `Directory(path)` 弄成不存在的路径。
  /// v1.21.40 修的就是这个（截图上路径显示成 `Directory: '/data/user/0/...`）。
  String get downloadPath => _customDownloadPath.isNotEmpty
      ? _customDownloadPath
      : (_downloadTarget == DownloadTarget.publicDownloads
          ? publicDownloadPath
          : _privateDownloadPath);

  /// 用户是否设过自定义下载路径
  bool get hasCustomDownloadPath => _customDownloadPath.isNotEmpty;

  /// 用户自定义的下载路径（未设置时为空串）
  String get customDownloadPath => _customDownloadPath;

  /// 应用私有目录下的下载路径（平台相关，需要 `path_provider`）
  ///
  /// ⚠️ 用 `base.path` 而**不是** `$base`（后者是 `Directory: '...'`，见 [downloadPath]）。
  String get _privateDownloadPath => _resolvedDefaultPath.isNotEmpty
      ? _resolvedDefaultPath
      : '/data/user/0/<应用私有目录>/downloads/$_downloadFolder'; // 未解析前的占位

  String _resolvedDefaultPath = '';

  /// 算一次真实私有路径并缓存（`getApplicationDocumentsDirectory` 要走平台通道）
  ///
  /// 返回的是**当前实际生效**的 [downloadPath]（可能是公共「下载」目录常量）。
  Future<String> refreshDownloadPath() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      _resolvedDefaultPath = '${base.path}/downloads/$_downloadFolder';
    } catch (_) {
      // 拿不到就沿用上一次算出来的（或近似值），不让设置页显示成空
    }
    return downloadPath;
  }

  Future<void> setCustomDownloadPath(String path) async {
    _customDownloadPath = path.trim();
    await (await _sp).setString(_kDownloadCustomPath, _customDownloadPath);
    // ★v1.21.44：选过自定义文件夹就把目标标成 [DownloadTarget.custom]，
    // 让设置页能如实显示"当前来源"（路径仍只存上面那一份，不另开字段）。
    if (_customDownloadPath.isNotEmpty &&
        _downloadTarget != DownloadTarget.custom) {
      await setDownloadTarget(DownloadTarget.custom);
    }
  }

  /// 🔄 恢复默认：清掉自定义路径，并把来源标记放回默认的 [DownloadTarget.publicDownloads]
  ///
  /// ⚠️ v1.21.44 起**会动 [downloadTarget]**（原来不动）。理由：来源标记与路径
  /// 必须一起变，否则会留下"标记说自定义、路径却已经清掉"的半态；
  /// 而"恢复默认"的落点本来就该是默认目标（公共「下载」+ 专属子文件夹）。
  Future<void> resetDownloadPath() async {
    _customDownloadPath = '';
    await (await _sp).remove(_kDownloadCustomPath);
    if (_downloadTarget == DownloadTarget.custom) {
      await setDownloadTarget(DownloadTarget.publicDownloads);
    }
  }

  // ---------------- 「另存文件夹」（SAF，v1.21.41） ----------------
  //
  // 用户要「下载的书放进公共目录里的自建子文件夹，而且卸载软件不删」。
  // 这三件事只有 SAF 一条路：让用户授权一个文件夹（系统那个能新建文件夹的选择器），
  // 再把下载好的文件**复制**进去 —— 副本属于"用户授权的文件夹"，与 App 无关，
  // 所以卸载不删、文件管理器里直接能看。

  String _saveCopyTreeUri = '';
  String _saveCopyFolderName = '';

  /// 已授权的「另存文件夹」tree URI（空 = 没设）
  String get saveCopyTreeUri => _saveCopyTreeUri;

  /// 已授权文件夹的显示名（给用户看的，如"书籍"）
  String get saveCopyFolderName => _saveCopyFolderName;

  /// 是否设了「另存文件夹」
  bool get hasSaveCopyFolder => _saveCopyTreeUri.isNotEmpty;

  Future<void> setSaveCopyFolder(String treeUri, String name) async {
    _saveCopyTreeUri = treeUri.trim();
    _saveCopyFolderName = name.trim();
    final sp = await _sp;
    await sp.setString(_kSaveCopyTree, _saveCopyTreeUri);
    await sp.setString(_kSaveCopyFolderName, _saveCopyFolderName);
  }

  /// 清掉「另存文件夹」（用户在设置里取消）
  Future<void> clearSaveCopyFolder() async {
    _saveCopyTreeUri = '';
    _saveCopyFolderName = '';
    final sp = await _sp;
    await sp.remove(_kSaveCopyTree);
    await sp.remove(_kSaveCopyFolderName);
  }

  /// 本应用**能直接写**的基准目录（应用私有目录，平台相关）
  ///
  /// 判据**不能**只看"路径里含 `/Android/data/`"：**设备存储根**本身就叫
  /// `/storage/emulated/0/Android/data/...`，用子串判断会让根目录被误判成私有。
  /// 正确做法是拿 `path_provider` 的真实基准目录比前缀 —— 见 [isUnderAnyBase]。
  static Future<List<String>> writableBaseDirs() async {
    final List<String> bases = <String>[];
    for (final Future<Directory?> Function() probe
        in <Future<Directory?> Function()>[
      getApplicationDocumentsDirectory,
      getApplicationSupportDirectory,
      getExternalStorageDirectory,
    ]) {
      try {
        final Directory? dir = await probe();
        if (dir != null && dir.path.isNotEmpty) bases.add(dir.path);
      } catch (_) {
        // 该 ROM 没有这类目录：跳过
      }
    }
    return bases;
  }

  /// 这个路径是不是**文件系统路径**（而不是 SAF 的 `content://` URI 等）
  ///
  /// ## 为什么需要它（v1.21.44：放开自定义文件夹的判据）
  ///
  /// 原来自定义路径的唯一判据是 [isUnderAnyBase]（必须是应用私有基准目录之内），
  /// 而系统文件选择器**进不去**应用私有目录 —— 于是"自定义文件夹"实际上永远选不成
  /// （设置页那段"只有部分机型可用"的弹窗就是当时留下的）。
  ///
  /// 现在放开到"以 `/` 开头的真实路径"：能不能写**由 [isWritableDir] 实测**决定，
  /// 而不是靠猜。⚠️ 边界仍然明确：**只接受文件系统路径**，
  /// `content://`（系统文件选择器给出的 URI）一律不接受 —— `flutter_downloader`
  /// 只吃文件系统路径，强行支持要换整套存储方案（本轮不做）。
  static bool isFilesystemPath(String path) {
    final String p = path.trim();
    if (p.length <= 1) return false;
    if (p.startsWith('/')) return true; // Android / Linux / macOS 的绝对路径
    // Windows 盘符（`C:\…` / `C:/…`）：本工程的单元测试跑在 Windows 宿主机上，
    // 不认它就等于 [isWritableDir] 的正向路径**在宿主机上没法验**（只能验负向）。
    // Android 上永远见不到这种形状，所以放宽这一条不影响真机行为。
    return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p);
  }

  /// **实测**这个目录现在能不能写（外部路径唯一可靠的判据）
  ///
  /// 为什么不能靠猜：Android 10+ 的分区存储下，应用私有目录之外能不能写，
  /// 取决于系统版本、目录归属（MediaStore 集合 / 厂商目录）、SD 卡挂载状态，
  /// 没有一个静态判据能覆盖。所以直接**建目录 + 写一个 2 字节探针 + 删掉**。
  ///
  /// 返回 `false` 时调用方必须**降级并提示**（不能把文件丢进一个写不进去的目录）。
  static Future<bool> isWritableDir(String path) async {
    if (!isFilesystemPath(path)) return false;
    try {
      final Directory dir = Directory(path.trim());
      if (!await dir.exists()) await dir.create(recursive: true);
      final File probe = File(
        '${dir.path}${Platform.pathSeparator}.taohuayuan-write-probe',
      );
      await probe.writeAsString('ok', flush: true);
      if (await probe.exists()) await probe.delete();
      return true;
    } catch (_) {
      // 权限被拒 / 只读挂载 / 目录被删 / SD 卡拔出 —— 都归"写不进去"
      return false;
    }
  }

  /// **这个路径能不能当自定义下载目录**（v1.21.44 放开后的唯一判据）
  ///
  /// 设置页「选文件夹」与浏览器页落盘**共用这一份**（不许各写一套，否则迟早漂移）：
  ///
  /// 1. 不是文件系统路径（`content://` 这类 URI）→ 否；
  /// 2. 落在应用可写基准目录之内（[isUnderAnyBase]）→ **是**，纯字符串比对，不必探测；
  /// 3. 其余（内部存储 / SD 卡上的任意文件夹）→ 用 [isWritableDir] **真写一个探针**实测：
  ///    这类位置能不能写取决于系统版本与权限（Android 11+ 要 [hasAllFilesAccess]），
  ///    只有实测才说得准。
  static Future<bool> isUsableCustomDir(String path) async {
    if (!isFilesystemPath(path)) return false;
    final String p = path.trim();
    if (isUnderAnyBase(p, await writableBaseDirs())) return true;
    return isWritableDir(p);
  }

  /// 单元测试用的权限开关（**只给测试**：桌面/CI 上永远拿不到真实 Android 权限）
  ///
  /// `null` = 按真实平台判断；`true/false` = 强制当成已授权 / 未授权。
  @visibleForTesting
  static bool? debugAllFilesAccessOverride;

  /// 是否拥有「所有文件访问权限」（Android 11+ 才有这个概念）
  ///
  /// * Android 11+（API 30+）：`Environment.isExternalStorageManager()` 的等价物，
  ///   即 `Permission.manageExternalStorage.isGranted`；
  /// * Android 10 及以下：**恒为 true** —— 那会儿靠 `WRITE_EXTERNAL_STORAGE`
  ///   就能写公共存储，没有"所有文件访问"这个开关；
  /// * 非 Android（桌面测试）：恒为 true，免得测试环境误报"没权限"。
  ///
  /// ⚠️ 这个权限**不能**用普通弹窗申请，必须跳系统设置页让用户手动开 ——
  /// 所以"查询"（本方法）与"跳转"（[requestAllFilesAccess]）是两件事，
  /// 调用方跳完回来必须**重新查一次**。
  static Future<bool> hasAllFilesAccess() async {
    final bool? forced = debugAllFilesAccessOverride;
    if (forced != null) return forced;
    if (!Platform.isAndroid) return true;
    try {
      return await Permission.manageExternalStorage.isGranted;
    } catch (_) {
      // 个别 ROM 的权限插件会抛异常：按"没授权"处理（用户还能用另外两个位置）
      return false;
    }
  }

  /// 跳到系统的「所有文件访问」授权页
  ///
  /// ⚠️ Android 11+ 的系统限制：这个权限没有"弹窗申请"这条路，
  /// `permission_handler` 内部做的就是跳到
  /// `Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION`。
  /// 用户从设置页返回后，调用方**必须重新查** [hasAllFilesAccess]。
  ///
  /// 实测要点（国产 ROM 可能不同）：跳过去之后要能看见本应用的开关；
  /// 若某个 ROM 上跳转不生效，退一步的方案是自己写 MethodChannel 发那个 Intent
  /// （见交接文档「未闭环」）。
  static Future<void> requestAllFilesAccess() async {
    if (debugAllFilesAccessOverride != null) return; // 测试里不真跳
    if (!Platform.isAndroid) return;
    try {
      await Permission.manageExternalStorage.request();
    } catch (_) {
      // 抛异常也算"没拿到"：调用方重新查一次即可
    }
  }

  /// 这个路径是不是应用能直接写的私有目录（**纯字符串逻辑，便于单测**）
  static bool isUnderAnyBase(String path, List<String> bases) {
    String norm(String p) {
      var s = p.replaceAll('\\', '/');
      while (s.length > 1 && s.endsWith('/')) {
        s = s.substring(0, s.length - 1);
      }
      return s;
    }

    final String target = norm(path.trim());
    if (target.isEmpty) return false;
    for (final String base in bases) {
      final String b = norm(base);
      if (b.isEmpty) continue;
      if (target == b || target.startsWith('$b/')) return true;
    }
    return false;
  }

  /// 下载保存位置
  DownloadTarget get downloadTarget => _downloadTarget;

  /// 应用私有目录下的子文件夹名（公共下载目录由系统决定，不用它）
  String get downloadFolder => _downloadFolder;

  Future<void> setDownloadTarget(DownloadTarget target) async {
    _downloadTarget = target;
    await (await _sp).setString(_kDownloadTarget, target.name);
  }

  Future<void> setDownloadFolder(String folder) async {
    final cleaned = sanitizeFolderName(folder);
    _downloadFolder = cleaned;
    await (await _sp).setString(_kDownloadFolder, cleaned);
  }

  /// 清洗文件夹名：去掉路径分隔符与非法字符，空则回默认
  static String sanitizeFolderName(String value) {
    var name = value.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_').trim();
    name = name.replaceAll(RegExp(r'^[._]+|[._]+$'), '');
    if (name.isEmpty) return defaultDownloadFolder;
    return name.length > 40 ? name.substring(0, 40) : name;
  }

  // ---------------- 后台朗读 ----------------

  bool _keepScreenOn = false;

  /// 朗读时是否保持屏幕常亮（默认关：熄屏继续读更省电）
  bool get keepScreenOn => _keepScreenOn;

  Future<void> setKeepScreenOn(bool value) async {
    _keepScreenOn = value;
    await (await _sp).setBool(_kKeepScreenOn, value);
  }

  // ---------------- 首次使用教程 ----------------

  bool _tutorialDone = false;

  /// 是否已经看过首次使用教程（看过后不再自动弹）
  bool get tutorialDone => _tutorialDone;

  Future<void> setTutorialDone(bool value) async {
    if (_tutorialDone == value) return;
    _tutorialDone = value;
    await (await _sp).setBool(_kTutorialDone, value);
  }

  /// 用户看过的教程**内容版本号**
  ///
  /// 光有 `tutorialDone` 不够：教程内容大改之后（v1.22 加了发现页/订阅源那一大批），
  /// 老用户已经勾过「不再显示」，永远看不到新内容。
  /// 所以再记一个版本号：内容版本变高就**再弹一次**。
  int _tutorialContentVersion = 0;

  int get tutorialContentVersion => _tutorialContentVersion;

  Future<void> setTutorialContentVersion(int value) async {
    if (_tutorialContentVersion == value) return;
    _tutorialContentVersion = value;
    await (await _sp).setInt(_kTutorialContentVersion, value);
  }

  // ---------------- 书源（浏览器快捷入口） ----------------

  /// 默认书源（v1.21.24 重建）
  ///
  /// 只放**入口**，不放具体镜像域名 —— 镜像域名几周就换一轮，写死等于埋雷；
  /// 具体域名由运行时「检索可用域名」（多源并行 + 2 小时缓存）决定。
  /// 前三条是 Z-Library 的三个入口，其中两条是应用内可直接拉列表的源。
  static const List<(String, String)> defaultBookSources = <(String, String)>[
    // 主入口：应用内「检索可用域名」会从这里拉列表
    ('Z-Library 可用域名（open-slum.org）', BookSourceDirectory.directoryUrl),
    // 社区维护的镜像列表（GitHub 上的 Markdown，连不上不会拖累其它源）
    (
      'Z-Library 镜像列表（Awesome-Zlibrary）',
      'https://raw.githubusercontent.com/dongyubin/Awesome-Zlibrary/main/README.md'
    ),
    // getzlib 的域名指引页
    ('Z-Library 域名指引（getzlib.com）', 'https://getzlib.com/'),
    // 其它站点
    ('Anna\'s Archive 可用域名', '${BookSourceDirectory.directoryUrl}annas.html'),
    ('Library Genesis 可用域名', '${BookSourceDirectory.directoryUrl}libgen.html'),
    ('Project Gutenberg（公共领域）', 'https://www.gutenberg.org/'),
    ('维基文库', 'https://zh.wikisource.org/'),
  ];

  /// 旧版本内置过的那几条 —— **只用于一次性清理老设备上的存量数据**
  ///
  /// 判据是「标题 + 地址都对得上」：用户改过名或自己另加的条目不会被误删。
  static const List<(String, String)> _legacyDefaultBookSources =
      <(String, String)>[
    ('Z-Library 可用域名（open-slum.org）', BookSourceDirectory.directoryUrl),
    ('Anna\'s Archive 可用域名', '${BookSourceDirectory.directoryUrl}annas.html'),
    ('Library Genesis 可用域名', '${BookSourceDirectory.directoryUrl}libgen.html'),
    ('Project Gutenberg（公共领域）', 'https://www.gutenberg.org/'),
    ('维基文库', 'https://zh.wikisource.org/'),
  ];

  /// 一次性清理的标记（做过就不再动用户的书源列表）
  static const String _kBookSourcesPurged = 'book_sources_defaults_purged_v1';

  static bool _isLegacyDefault(WebLink link) => _legacyDefaultBookSources
      .any((item) => item.$1 == link.title && item.$2 == link.url);

  /// 书源列表；从未保存过（或清空后）返回 [defaultBookSources]
  Future<List<WebLink>> loadBookSources() async {
    List<WebLink> stored = await _loadLinks(_kBookSources);
    // 一次性清理老设备存量里的内置条目（只在第一次读时做，用户事后手动
    // 把同一个地址加回来不会再被删 —— 那时标题是他自己写的）
    final sp = await _sp;
    if (!(sp.getBool(_kBookSourcesPurged) ?? false)) {
      await sp.setBool(_kBookSourcesPurged, true);
      final kept = stored.where((link) => !_isLegacyDefault(link)).toList();
      if (kept.length != stored.length) {
        await saveBookSources(kept);
        stored = kept; // 清完可能变空 → 下面统一回落到默认入口
      }
    }
    if (stored.isNotEmpty) return stored;
    final now = DateTime.now();
    return <WebLink>[
      for (final item in defaultBookSources)
        WebLink(title: item.$1, url: item.$2, createdAt: now),
    ];
  }

  Future<void> saveBookSources(List<WebLink> sources) async => (await _sp).setString(
    _kBookSources,
    jsonEncode(sources.map((source) => source.toJson()).toList()),
  );
}

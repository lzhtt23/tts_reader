import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../features/pdf_reading/open_reading_screen.dart';
import '../models/document.dart';
import '../models/rss_source.dart';
import '../models/source_rule.dart';
import '../models/web_link.dart';
import '../services/auto_sleep.dart';
import '../services/crash_log.dart';
import '../services/document_service.dart';
import '../services/download_list_model.dart';
import '../services/download_watcher.dart';
import '../services/file_naming.dart';
import '../services/legado_source_store.dart';
import '../services/rss_importer.dart';
import '../services/rss_store.dart';
import '../services/source_importer.dart';
import '../services/source_link_parser.dart';
import '../services/storage_service.dart';
import '../widgets/download_done_card.dart';
import '../widgets/rss_import_confirm.dart';
import '../widgets/web_select_sheet.dart';
import '../pages/source_import_confirm_page.dart';
import '../services/web_speak_script.dart';
import '../services/web_theme_script.dart';
import '../services/web_select_bridge.dart';
import '../services/web_translate.dart';
import '../services/yuedu_link_script.dart';
import '../tts/tts_manager.dart';
import 'mirror_picker.dart';

/// 内置浏览器：网页下载 PDF / EPUB / TXT 后自动导入文档库并朗读，
/// 同时支持收藏、浏览记录、自定义默认首页、书源与「朗读本页」。
///
/// 界面与应用一体化：
/// - 地址栏与导航按钮收成一条紧凑工具栏，跟在应用 AppBar 下面；
/// - **主界面**（没打开网页时）是自带起始页：搜索框 + 搜索引擎切换 +
///   历史 / 收藏夹 / 新增快捷方式；
/// - 页面底色 / 滚动条跟随应用主题，系统返回键先退网页历史。
class BrowserPage extends StatefulWidget {
  const BrowserPage({
    super.key,
    this.addressController,
    this.startPageRequest = 0,
    this.onReady,
    this.onStartPageChanged,
    this.onNavigated,
  });

  /// 书源面板里「检索可用域名」这一项的哨兵值（与真实网址区分开）
  static const String lookupMirrors = '__lookup_mirrors__';

  /// 📂 **不再走"请系统文件管理器打开这个目录"那条原生路**（本轮 · 需求二）
  ///
  /// ## 为什么删掉原生分支（用户拍板）
  ///
  /// 真机（TB335FC）点 📂 **崩溃**，而崩的正是**原生那条 `ACTION_VIEW` Intent 路**
  /// （见 `FolderChannel.kt`）—— **不是按钮本身**。根因始终没有 logcat 佐证，
  /// 而"点一下就可能闪退"不能带着进正式版，所以本轮把那条分支整条删掉：
  /// 📂 现在**直接弹面板**（绝对路径 + 文件清单 + 「复制路径」）。
  ///
  /// 能力没有减少：面板里给出绝对路径，复制后粘进文件管理器一样能进去。
  ///
  /// ## ⚠️ 这里曾经发生过什么（留档，别再犯）
  ///
  /// v1.21.43 我**自作主张**把它关掉过（改成"只弹面板"）并当成"修复"报上去 ——
  /// 那是越权：📂 的语义就是"跳转到文件夹"，降级成"复制地址"是功能退步，
  /// 必须由用户拍板。这次不同：**用户明确同意**后才删的，
  /// 而且删的是那条会崩的原生路径，**按钮本身保留**。
  ///
  /// 这个常量现在只是**一条可查的结论**（设备用例仍在读它）：
  /// `false` = 本版本不再尝试原生跳转。它**不再是开关**。
  @visibleForTesting
  static const bool tryNativeFolderOpen = false;

  /// 每次下载的超时（毫秒）—— 见 `_handleDownload` 里 enqueue 处的长注释
  ///
  /// ## 为什么必须显式给
  ///
  /// `flutter_downloader` 的 `enqueue` 里 `timeout` 默认 **15000ms**
  /// （`downloader.dart:104`），它同时被用作 `connectTimeout` 与
  /// **`readTimeout`**（`DownloadWorker.kt:310-311`）—— 后者是
  /// **相邻数据包的最大间隔**。
  ///
  /// 真机症状（用户报「**下载还是无法下全**」，日志为证）：
  /// ```
  /// 19:41:57  progress=0%      19:42:12  progress=6%
  /// 19:42:13  status=failed progress=6%     ← 入队到失败仅 16 秒
  /// ```
  /// 几十 MB 的书从慢速 CDN 下，15 秒的包间隔是常态 → 必然"下到百分之几就 failed"。
  ///
  /// 提到 **2 分钟**；**不要**改成"不设超时"：真断线时需要有个头。
  @visibleForTesting
  static const int downloadTimeoutMs = 120000;

  /// 加载进度条的高度
  static const double progressBarHeight = 2;

  /// 地址栏 / 导航按钮那条工具栏
  static const Key toolbarKey = ValueKey<String>('browser-toolbar');

  /// 地址输入框
  static const Key addressFieldKey = ValueKey<String>('browser-address');

  /// 顶部地址栏那一行（含两侧按钮）
  static const Key addressRowKey = ValueKey<String>('browser-address-row');

  /// 起始页（搜索框 + 快捷入口那一屏）
  static const Key startPageKey = ValueKey<String>('browser-start-page');

  /// 起始页的搜索框
  static const Key searchFieldKey = ValueKey<String>('browser-search');

  /// 搜索引擎切换按钮
  static const Key engineButtonKey = ValueKey<String>('browser-engine');

  /// 起始页底部三个入口
  static const Key historyButtonKey = ValueKey<String>('browser-history');
  static const Key bookmarksButtonKey = ValueKey<String>('browser-bookmarks');
  static const Key shortcutButtonKey = ValueKey<String>('browser-shortcut');

  /// 快捷方式「管理」按钮（逐个删除 / 清空全部）
  static const Key manageShortcutsKey = ValueKey<String>('browser-shortcut-manage');

  /// 「自定义首页」入口（只在设过自定义首页时出现）
  static const Key customHomeKey = ValueKey<String>('browser-custom-home');

  /// 下载列表里的「下载文件夹」按钮（v1.21.39）
  static const Key downloadFolderKey = ValueKey<String>('browser-download-folder');

  /// 地址栏那一行的「标签页」按钮（v1.21.39）
  static const Key tabsButtonKey = ValueKey<String>('browser-tabs');

  /// 标签页上限
  ///
  /// ⚠️ 为什么必须有上限：本方案用 `IndexedStack` 把**所有**标签的 WebView
  /// 留在树上保活（切走再切回不丢滚动位置 / 表单），而 Android 上每个后台
  /// WebView 占 **20~50MB**。不设限会 OOM。
  static const int maxTabs = 8;

  /// 这条下载任务还在进行中（按"取消"处理，而不是"移出列表"）
  ///
  /// ⚠️ 判据只有这三态：`enqueued` / `running` / `paused`。
  /// `paused` 也算"进行中"——它只是被系统暂停，取消它才是用户想要的；
  /// 而 `complete` / `failed` / `canceled` 都已经结束，只能"移出列表"。
  @visibleForTesting
  static bool isActiveTask(DownloadTaskStatus? status) =>
      // ⚠️ 判据只有一份：`DownloadListModel.isActive`。
      // 本轮（需求二）起，页面与列表模型共用它，免得两处各写一套 `switch`
      // （这类"两套判据漂移"在这个工程里出过不止一次）。
      DownloadListModel.isActive(status);

  /// 每项右侧的图标：进行中显示叉（取消），已结束显示垃圾桶（移出列表）
  @visibleForTesting
  static IconData trailingIconFor(DownloadTaskStatus? status) =>
      isActiveTask(status) ? Icons.close : Icons.delete_outline;

  /// 插件报「失败 / 取消」时，磁盘上那份文件还算不算数（v1.21.41）
  ///
  /// ## 为什么需要它
  ///
  /// 用户实测：**文件已经完整下好了**，而插件报失败、下载列表进度条只走了一点
  /// → 原来的实现把 `failed` / `canceled` 当终态立即放弃 → 不导入。
  /// 也就是说插件的状态与磁盘事实**可能不一致**，这时该信磁盘。
  ///
  /// 判据用"字节数 > 0"而不是 `exists()`：边下边写时文件会先出现，
  /// 半截 / 空文件照样 `exists()` 为真，导入时会解析失败。
  /// （真正"内容对不对"交给后续的可读性校验与解析。）
  @visibleForTesting
  static bool shouldAcceptFailedDownload(DownloadTaskStatus? status, int? bytesOnDisk) {
    if (status != DownloadTaskStatus.failed &&
        status != DownloadTaskStatus.canceled) {
      return false;
    }
    return bytesOnDisk != null && bytesOnDisk > 0;
  }

  /// 菜单里「回浏览器主页」那一项的名字（单测校验文案与行为一致）
  static const String homeEntryTitle = '回到浏览器主页';

  /// 地址栏那一行（含前后退 / 刷新 / 首页 / 更多）由本页自己渲染：
  /// 主界面在搜索栏上方，浏览网页时就是浏览器地址栏。
  final TextEditingController? addressController;

  /// 返回起始页的请求：每次自增即触发一次
  final int startPageRequest;

  /// 创建后把 submit 能力交给外部（兼容保留；本页内部直接用 [BrowserPageState.submitAddress]）
  final void Function(void Function(String value) submit)? onReady;

  /// 起始页显示状态变化
  final ValueChanged<bool>? onStartPageChanged;

  /// 导航状态变化（地址栏文本、能否前进后退）
  final void Function(String url, bool canGoBack, bool canGoForward)? onNavigated;

  @override
  State<BrowserPage> createState() => BrowserPageState();
}

/// [BrowserPage] 的 State 类型，供 HomePage 用 GlobalKey 转调导航动作
///
/// 地址栏渲染在 HomePage 的 AppBar 上，而「能否前进后退」等状态在浏览器页内部，
/// 所以用 `GlobalKey<BrowserPageState>` 拿到它。
typedef BrowserPageState = _BrowserPageState;

/// 内部别名
const String _kLookupMirrors = BrowserPage.lookupMirrors;

/// 把地址栏 / 搜索框的输入解析成要打开的 URL
///
/// 顶层纯函数（不依赖 State），便于单测。判定顺序：
/// 完整 URL → 像域名的（含点且无空格）→ 其余按搜索词交给当前搜索引擎。
String resolveBrowserInput(String raw, SearchEngine engine) {
  final value = raw.trim();
  if (value.isEmpty) return '';
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return value;
  }
  if (value.startsWith('file://') || value.startsWith('data:')) return value;
  final looksLikeUrl = value.contains('.') && !value.contains(' ');
  if (looksLikeUrl) return 'https://$value';
  return engine.urlFor(value);
}

/// 一个浏览器标签页（v1.21.39）
///
/// ## 为什么每个标签要有**自己的 controller**
///
/// `InAppWebViewController` 是**跟 WebView 实例绑定**的：共用一个 controller
/// 就等于共用一个页面 —— 切标签会变成"换了个名字但内容一起变"。
///
/// ## 为什么所有标签的 WebView 都留在树上（`IndexedStack`）
///
/// 用 `if (i == _activeTabIndex)` 条件渲染的话，切走再切回 WebView 会被
/// **销毁重建**：滚动位置、表单内容、正在播放的媒体全丢，标签页就白做了。
/// `IndexedStack` 只显示当前那个，其余留在树里保活（Chrome 也是这么做的）。
///
/// ⚠️ 代价：每个后台 WebView 在 Android 上占 **20~50MB**，
/// 所以有「最多 [BrowserPage.maxTabs] 个」的上限（见 `_newTab`）。
class _WebTab {
  _WebTab({required this.id, required this.controller, required this.webViewKey});

  /// 稳定自增 id（列表 key 与关闭定位都用它，不用下标 —— 下标会随关闭而错位）
  final int id;

  /// 这个标签的 WebView 控制器（由 `onWebViewCreated` 填进来）
  InAppWebViewController? controller;

  /// **稳定的** GlobalKey：`IndexedStack` 重排时不能让 WebView 重建
  final GlobalKey webViewKey;

  String url = '';
  String title = '';
  bool canGoBack = false;
  bool canGoForward = false;
  double progress = 1;

  /// 最近一次加载错误（设备侧用例读它）
  String lastError = '';

  /// 是否停在起始页（**每标签各一份**：新标签可以是起始页，老标签还在网页上）
  bool isStart = true;

  /// 用户是否**主动**打开过网页（只有主动导航才离开起始页，见原字段注释）
  bool navigate = false;

  /// 显示用标题（没标题时给个占位）
  String get label => title.trim().isNotEmpty
      ? title.trim()
      : (url.isNotEmpty ? url : '新标签页');
}

class _BrowserPageState extends State<BrowserPage> {
  final TextEditingController _address = TextEditingController();

  /// 所有标签（**至少一个**）
  late List<_WebTab> _tabs;

  /// 当前激活的标签下标
  int _activeTabIndex = 0;

  int _nextTabId = 1;

  /// 当前激活标签
  _WebTab get _tab => _tabs[_activeTabIndex];

  /// 当前激活标签的 WebView 控制器
  ///
  /// ⚠️ 这里刻意**保留 `_web` 这个名字**：它是全页十几个方法的读写入口
  /// （`goBack` / `reload` / `_readPage` / `_translatePage` / 系统返回 …），
  /// 改成读 `_tab.controller` 之后那些方法**一行都不用动**，
  /// 但状态自动变成"每标签各一份"。
  InAppWebViewController? get _web => _tab.controller;
  set _web(InAppWebViewController? value) => _tab.controller = value;

  // ---- 每标签状态的**只读**转发（构建处 / 书签 / 翻译 / 朗读都要读它们）----
  //
  // ⚠️ 这些 getter **有用，别删**（`analyze` 有时会报 `unused_element`，
  // 那是同文件内的解析假象：真正读它们的地方在下面几百行）。
  // 写入则不用转发：`_newWebView(tab)` 的回调**直接写自己那个 tab**，
  // 因为回调必须记到"触发它的标签"上，而 `_tab` 永远是当前激活标签。
  double get _progress => _tab.progress;
  bool get _canGoBack => _tab.canGoBack;
  bool get _canGoForward => _tab.canGoForward;
  String get _currentUrl => _tab.url;
  String get _currentTitle => _tab.title;
  bool get _startPage => _tab.isStart;

  /// 加载错误按标签各记一份（设备用例读的仍是"当前标签的"）
  String get debugLastLoadError => _tab.lastError;
  set debugLastLoadError(String value) => _tab.lastError = value;

  bool _busy = false;
  bool _bookmarked = false;

  /// 起始页的搜索框
  final TextEditingController _searchBox = TextEditingController();

  /// 起始页显示的快捷方式与最近访问
  List<WebLink> _shortcuts = const <WebLink>[];

  /// 网页正文抽取脚本（优先正文容器，去掉导航 / 脚本 / 样式）
  static const String _extractScript = WebSpeakScript.extract;

  /// 上次注入主题脚本时的明暗状态（主题变了要重新注入）
  bool? _themedForDark;

  /// HomePage 传进来的地址栏控制器（空则内部自建一个隐藏的，便于单测直接跑本页）
  TextEditingController get _addressField => widget.addressController ?? _address;

  @override
  void initState() {
    super.initState();
    // 第一个标签：起始页
    _tabs = <_WebTab>[_spawnTab()];
    // 地址栏默认**留空**：主界面就是起始页，没必要预填一个网址
    // （用户要求：自定义首页的地址栏默认为空白）
    _address.text = '';
    _searchBox.text = '';
    unawaited(_refreshBookmarkState());
    unawaited(_loadStartPage());
    // 把「提交地址」的能力交给 HomePage（地址栏渲染在那边）
    final ready = widget.onReady;
    if (ready != null) {
      // initState 里不能直接调用外部 setState，放到帧后
      WidgetsBinding.instance.addPostFrameCallback((_) => ready(submitAddress));
    }
    _notifyStartPage();
  }

  /// 造一个新标签（controller 由它自己的 `onWebViewCreated` 填）
  _WebTab _spawnTab() => _WebTab(
        id: _nextTabId++,
        controller: null,
        webViewKey: GlobalKey(debugLabel: 'browser-webview-${_nextTabId - 1}'),
      );

  // ---------------- 标签页管理 ----------------

  /// 新建标签并切过去
  void _newTab() {
    if (_tabs.length >= BrowserPage.maxTabs) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('标签页已到上限（每个标签都占用内存，'
              '关掉几个再开新的）'),
        ),
      );
      return;
    }
    setState(() {
      _tabs.add(_spawnTab());
      _activeTabIndex = _tabs.length - 1;
      // 新标签是起始页 → 地址栏清空
      _addressField.text = '';
    });
    _notifyStartPage();
    _notifyNavigation();
  }

  /// 关闭第 [index] 个标签
  ///
  /// ⚠️ 落点按 Chrome 习惯：**右边一个，没有就左边** ——
  /// 不是"永远回第一个标签"（那样连关几个会一直把人甩到最左边）。
  void _closeTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    // 只剩一个不关：关掉就没有浏览界面了（面板里也不显示 ×）
    if (_tabs.length <= 1) return;
    final tab = _tabs[index];
    // 先断掉引用，避免已销毁的 controller 还被回调用到
    tab.controller = null;
    setState(() {
      _tabs.removeAt(index);
      if (_activeTabIndex > index) {
        _activeTabIndex--;
      } else if (_activeTabIndex == index) {
        _activeTabIndex = index.clamp(0, _tabs.length - 1);
      }
    });
    _addressField.text = _tab.url;
    _syncThemedForActiveTab();
    _notifyStartPage();
    _notifyNavigation();
    unawaited(_refreshBookmarkState());
  }

  /// 切到第 [index] 个标签
  void _selectTab(int index) {
    if (index < 0 || index >= _tabs.length || index == _activeTabIndex) return;
    setState(() => _activeTabIndex = index);
    // ⚠️ 地址栏必须跟着换，否则还显示上一个标签的 URL
    _addressField.text = _tab.url;
    _syncThemedForActiveTab();
    _notifyStartPage();
    _notifyNavigation();
    unawaited(_refreshBookmarkState());
  }

  /// 切标签后把主题注入状态对齐（避免切过去那一下闪白）
  void _syncThemedForActiveTab() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (_themedForDark == dark) return;
    _themedForDark = dark;
    unawaited(_injectTheme(dark));
  }

  /// 标签面板（底部弹层，3 列网格）
  Future<void> _openTabsPanel() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.tab),
              title: Text('标签页（${_tabs.length}/${BrowserPage.maxTabs}）'),
            ),
            const Divider(height: 1),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.all(12),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.85,
                ),
                itemCount: _tabs.length,
                itemBuilder: (context, index) {
                  final tab = _tabs[index];
                  final active = index == _activeTabIndex;
                  return InkWell(
                    key: ValueKey<String>('browser-tab-$index'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _selectTab(index);
                    },
                    child: Card(
                      color: active
                          ? Theme.of(context).colorScheme.primaryContainer
                          : null,
                      child: Stack(
                        children: <Widget>[
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: <Widget>[
                                Icon(
                                  tab.url.isEmpty
                                      ? Icons.home_outlined
                                      : Icons.language,
                                  size: 28,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  tab.label,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                          // 只剩一个标签时不显示 ×（关掉就没有浏览界面了）
                          if (_tabs.length > 1)
                            Positioned(
                              top: 0,
                              right: 0,
                              child: IconButton(
                                key: ValueKey<String>('browser-tab-close-$index'),
                                iconSize: 16,
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.close),
                                tooltip: '关闭标签',
                                onPressed: () {
                                  Navigator.pop(sheetContext);
                                  _closeTab(index);
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            ListTile(
              key: const ValueKey<String>('browser-tab-new'),
              leading: const Icon(Icons.add),
              title: const Text('新建标签页'),
              onTap: () {
                Navigator.pop(sheetContext);
                _newTab();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 某个标签的状态变了：**只在它是当前激活标签时**才重建界面
  ///
  /// 为什么需要它：后台标签的 WebView 还活着，照样会报进度 / 加载完成 / 出错。
  /// 无条件 `setState` 会让"后台标签加载"也去重建整个页面（白花性能，
  /// 而且会把激活标签的地址栏文本改掉）。
  ///
  /// [mutate] 返回 `true` 表示"确实变了" —— 没变就不重建。
  void _updateTab(_WebTab tab, bool Function() mutate) {
    if (!mounted) return;
    if (!identical(tab, _tab)) {
      mutate(); // 后台标签：只记账，不重建
      return;
    }
    setState(() {
      mutate();
    });
  }

  /// 通知 HomePage 当前的导航状态（地址栏文本 + 前进后退可用性）
  ///
  /// ⚠️ v1.21.39：读的是**激活标签**的状态（`_currentUrl` 等 getter 都指向 `_tab`）。
  /// 后台标签也会加载 / 变 URL，但它不该改 AppBar 上的前进后退与地址栏 ——
  /// 那些只在切标签或激活标签自己导航时通知（见 `_updateTab`）。
  void _notifyNavigation() {
    widget.onNavigated?.call(_currentUrl, _canGoBack, _canGoForward);
  }

  @override
  void didUpdateWidget(covariant BrowserPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.startPageRequest != oldWidget.startPageRequest) {
      _goStartPage();
    }
  }

  /// 地址栏输入（HomePage 调用）：完整 URL 直接打开，否则用当前搜索引擎搜
  void submitAddress(String value) {
    final target = resolveInput(value, StorageService.instance.searchEngine);
    if (target.isEmpty) return;
    _addressField.text = target;
    unawaited(_open(target));
  }

  // ---- 供 HomePage 的 AppBar 地址栏按钮转调 ----

  Future<void> goBack() async {
    final web = _web;
    if (web == null) return;
    if (await web.canGoBack()) await web.goBack();
  }

  Future<void> goForward() async {
    final web = _web;
    if (web == null) return;
    if (await web.canGoForward()) await web.goForward();
  }

  Future<void> reload() async {
    final web = _web;
    if (web == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await web.reload();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('刷新失败：$e')));
    }
  }

  /// 当前页面标题（**只给测试看**：设备侧要断言"打开的确实是商店页"）
  @visibleForTesting
  String get currentTitleForTest => _currentTitle;

  /// 当前 WebView 的**实时** URL（**只给测试看**）
  ///
  /// ⚠️ 别用 [_currentTitle] 判断"现在在哪一页"：那个字段只在
  /// `onTitleChanged` 里更新，导航中途 / 失败时还是上一页的标题（会误导断言）。
  /// 这个走控制器的实时查询，拿不到就返回空串。
  @visibleForTesting
  Future<String> currentUrlForTest() async {
    final web = _web;
    if (web == null) return '';
    try {
      final WebUri? uri = await web.getUrl();
      return uri?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 最近一次通过 [_open] 请求加载的地址（**只给测试看**）
  ///
  /// 为什么不看"最终 URL"：商店这类站点会自己重定向（实测被顶到
  /// `edgemobileapp.microsoft.com` 再跳应用商店），**最终 URL 不是我们能控的**。
  /// 我们该守的只有"把正确的地址交给了 WebView"，所以断言这个字段。
  @visibleForTesting
  String debugLastOpenRequest = '';

  // ---------------- 标签页：设备侧测试口子（v1.21.39） ----------------
  //
  // 用例要读「**同一个 controller** 的滚动位置」，否则无法证明 WebView 没被重建
  // —— 这是「多 WebView 保活」方案的全部价值所系。

  /// 当前激活标签的 WebView 控制器
  @visibleForTesting
  InAppWebViewController? get activeControllerForTest => _tab.controller;

  /// 切到某个标签（等价于点标签面板里的那一格）
  @visibleForTesting
  void debugSelectTab(int index) => _selectTab(index);

  /// 新建一个标签（等价于点面板里的「新建标签页」）
  @visibleForTesting
  void debugNewTab() => _newTab();

  /// 关闭某个标签（等价于点面板里的 ×）
  @visibleForTesting
  void debugCloseTab(int index) => _closeTab(index);

  /// 当前标签数量
  @visibleForTesting
  int get debugTabCount => _tabs.length;

  /// 打开「下载文件夹」面板（等价于点下载列表标题行的 📂）
  ///
  /// ⚠️ 本轮（需求二）起**没有 `skipNative` 参数了**：原生跳转那条分支已删，
  /// 这个入口只会弹面板（见 [tryNativeFolderOpen] 的说明）。
  @visibleForTesting
  Future<void> debugShowDownloadFolder() => _showDownloadFolder();

  /// 设备用例专用：**临时**把 📂 面板指向别的目录（v1.21.43 重写版）
  ///
  /// 为什么需要：测试进程**写不了**公共「下载」目录
  /// （`Permission denied, errno = 13`，实测）。而"目录里有文件 / 目录不存在"
  /// 这两条断言必须在**可控目录**上做（Bug 1 的崩溃点正是排序时的空列表）。
  /// `null` = 走产品路径（[StorageService.downloadInboxPath]）。
  @visibleForTesting
  String? debugFolderPathForTest;

  /// 设备用例专用：**在"列完目录"与"渲染弹窗"之间**插一段延迟（v1.21.43）
  ///
  /// 为什么需要：闪退（`lengthSync` 在 build 期抛）要求"列目录"与"渲染"
  /// 之间文件消失。真机上这个窗口是**收纳路径正在移文件**时自然出现的，
  /// 但在用例里跑得太快 —— 弹窗在删除动作之前就建好了，窗口根本不存在。
  ///
  /// 延迟插在**列完之后**（不是之前）：文件必须先进入清单，
  /// 否则删掉它只是"清单里少一个"，根本走不到 `lengthSync`。
  ///
  /// `null` = 不延迟（产品路径）。
  @visibleForTesting
  Duration? debugFolderListDelayForTest;

  /// 📂 导航**整链的探针计时起点 / 编号**（v1.21.43）
  ///
  /// 为什么要编号 + 计时：用户报的是"点 📂 闪退"，而闪退**不会留下 Dart 日志**
  /// （进程直接没了）。所以只能在崩之前尽量多打点，事后看**最后一条**是谁、
  /// 以及从进入到结束花了多久（慢到几秒说明卡在读目录/IMO 上）。
  static int _folderNavSeq = 0;
  static int _folderNavSizeErrors = 0;
  static int _folderNavSizeCalls = 0;

  /// 「更多」菜单的候选项（渲染在 HomePage 的 AppBar 上）
  ///
  /// 工具栏搬到 AppBar 之后，收藏 / 记录 / 书源 / 朗读本页 / 翻译 / 首页 / 下载
  /// 这些入口不能丢，统一收进这个菜单。
  List<PopupMenuEntry<String>> browserMenuEntries() => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'bookmark',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(_bookmarked ? Icons.star : Icons.star_border),
            title: Text(_bookmarked ? '取消收藏本页' : '收藏本页'),
          ),
        ),
        const PopupMenuItem<String>(
          value: 'bookmarks',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.bookmarks_outlined),
            title: Text('我的收藏'),
          ),
        ),
        const PopupMenuItem<String>(
          value: 'history',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.history),
            title: Text('浏览记录'),
          ),
        ),
        const PopupMenuItem<String>(
          value: 'sources',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.auto_stories_outlined),
            title: Text('书源'),
            subtitle: Text('Z-Library 等站点快捷入口，可在设置里换源'),
          ),
        ),
        const PopupMenuItem<String>(
          value: 'read',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.volume_up_outlined),
            title: Text('朗读本页'),
          ),
        ),
        const PopupMenuItem<String>(
          value: 'translate',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.translate),
            // ⚠️ 标签必须跟着**实际引擎**走（v1.21.37 修）：
            // 这里原写作「翻译本页（Edge 翻译）」—— 那是微软 Translator 时代的
            // 说法（当时首选 `translatetheweb.com`，即微软/Edge 同引擎）。
            // v1.21.36 已改成**谷歌优先 + 百度兜底**，标签再写 Edge 就是骗用户。
            title: Text('翻译本页（谷歌／百度）'),
            subtitle: Text('谷歌连不上时自动改用百度'),
          ),
        ),
        const PopupMenuItem<String>(
          value: 'home',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.home_outlined),
            title: Text(BrowserPage.homeEntryTitle),
          ),
        ),
        const PopupMenuItem<String>(
          value: 'setHome',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.home_work_outlined),
            title: Text('设为自定义首页'),
            subtitle: Text('设过之后，主界面上会出现打开它的入口'),
          ),
        ),
        const PopupMenuItem<String>(
          value: 'downloads',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.download_outlined),
            title: Text('下载列表'),
          ),
        ),
      ];

  /// 执行「更多」菜单里的一项
  Future<void> handleMenuAction(String value) async {
    switch (value) {
      case 'bookmark':
        await _toggleBookmark();
      case 'bookmarks':
        await _showBookmarks();
      case 'history':
        await _showHistory();
      case 'sources':
        await _showBookSources();
      case 'read':
        await _readPage();
      case 'translate':
        await _translatePage();
      case 'home':
        _goStartPage();
      case 'setHome':
        await _setAsHome();
      case 'downloads':
        await _showDownloads();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 主题切换（跟随系统 / 手动）时给已加载的页面重新注入样式
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (_themedForDark != null && _themedForDark != dark) {
      _themedForDark = dark;
      unawaited(_injectTheme(dark));
    }
  }

  @override
  void dispose() {
    // ⚠️ v1.21.39：先把每个标签的 controller 引用清掉再销毁。
    // WebView 销毁后 controller 可能还会被延迟回调碰到（进度 / 加载停止），
    // 留着引用会对着已销毁的实例调方法。
    for (final tab in _tabs) {
      tab.controller = null;
    }
    _address.dispose();
    super.dispose();
  }

  /// 把应用主题的底色 / 滚动条样式注入当前页面
  ///
  /// 失败不影响浏览：about:blank、跨域 iframe 等页面本来就不支持注入。
  Future<void> _injectTheme(bool dark) async {
    // ⚠️ v1.21.39：主题要注入到**每个**标签（后台标签切回来时也得是暗色的，
    // 否则会先闪一下白底再被 JS 改回来）。失败的标签单独忽略。
    for (final tab in _tabs) {
      final web = tab.controller;
      if (web == null) continue;
      try {
        await web.evaluateJavascript(
            source: WebThemeScript.inject(dark: dark));
      } catch (_) {
        // 忽略：某些页面（about:blank / 跨域）注入不了
      }
    }
  }

  // ---------------- 导航 ----------------

  /// 把地址栏 / 搜索框的输入解析成要打开的 URL（委托给顶层 [resolveBrowserInput]）
  static String resolveInput(String raw, SearchEngine engine) =>
      resolveBrowserInput(raw, engine);

  /// 主界面搜索框：用当前搜索引擎搜
  Future<void> _search(String query) async {
    final value = query.trim();
    if (value.isEmpty) return;
    await _open(StorageService.instance.searchEngine.urlFor(value));
  }

  // ---------------- 起始页 ----------------

  /// 读起始页要显示的快捷方式
  Future<void> _loadStartPage({bool notify = true}) async {
    final shortcuts = await StorageService.instance.loadShortcuts();
    if (!mounted) return;
    setState(() {
      _shortcuts = shortcuts.take(12).toList(growable: false);
    });
    if (notify) _notifyStartPage();
  }

  /// 回到浏览器主界面（起始页）
  ///
  /// 这就是导航条上「首页」按钮的行为：**没有自定义浏览器首页时就回这里**，
  /// 而不是去加载默认网址 —— 主界面本身已经带了搜索框与快捷方式，
  /// 直接跳到某个搜索站反而多绕一步。
  void _goStartPage() {
    if (!mounted) return;
    setState(() {
      _tab.isStart = true;
      _tab.navigate = false;
      _tab.progress = 1;
      _tab.url = '';
      _tab.title = '';
      _bookmarked = false;
      // 地址栏留空（用户要求：默认空白）
      _addressField.text = '';
      _address.text = '';
    });
    _notifyStartPage();
    unawaited(_loadStartPage(notify: false));
  }

  void _notifyStartPage() => widget.onStartPageChanged?.call(_startPage);

  /// 起始页的搜索框 + 搜索引擎切换
  Widget _startPageSearch(ThemeData theme) {
    final scheme = theme.colorScheme;
    final engine = StorageService.instance.searchEngine;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          key: BrowserPage.searchFieldKey,
          controller: _searchBox,
          textInputAction: TextInputAction.search,
          autocorrect: false,
          onSubmitted: (value) => unawaited(_search(value)),
          decoration: InputDecoration(
            hintText: '搜索或输入网址',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(
              tooltip: '搜索',
              icon: const Icon(Icons.arrow_forward),
              onPressed: () => unawaited(_search(_searchBox.text)),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            filled: true,
            fillColor: scheme.surfaceContainerHighest,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ActionChip(
                  key: BrowserPage.engineButtonKey,
                  avatar: Icon(Icons.travel_explore, size: 18, color: scheme.primary),
                  label: Text('搜索引擎：${engine.name}'),
                  onPressed: _pickSearchEngine,
                ),
              ),
            ),
            // 设过「自定义浏览器首页」才出现：首页键始终回主界面，
            // 想去自定义首页就从这里进
            if (_hasCustomHome)
              ActionChip(
                key: BrowserPage.customHomeKey,
                avatar: Icon(Icons.home_outlined, size: 18, color: scheme.primary),
                label: const Text('自定义首页'),
                onPressed: () => unawaited(_open(StorageService.instance.homeUrl)),
              ),
          ],
        ),
      ],
    );
  }

  /// 切换搜索引擎
  Future<void> _pickSearchEngine() async {
    const engines = StorageService.searchEngines;
    final current = StorageService.instance.searchEngine;
    final picked = await showModalBottomSheet<SearchEngine>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: <Widget>[
                  Text('搜索引擎', style: Theme.of(sheetContext).textTheme.titleMedium),
                  const Spacer(),
                  Text('地址栏里的搜索词也用它',
                      style: Theme.of(sheetContext).textTheme.labelSmall),
                ],
              ),
            ),
            const Divider(height: 1),
            for (final engine in engines)
              ListTile(
                leading: Icon(
                  engine == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: engine == current ? Theme.of(sheetContext).colorScheme.primary : null,
                ),
                title: Text(engine.name),
                subtitle: Text(
                  engine.urlTemplate.replaceFirst('%s', '…'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(sheetContext).textTheme.bodySmall,
                ),
                onTap: () => Navigator.pop(sheetContext, engine),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await StorageService.instance.setSearchEngine(picked);
    if (!mounted) return;
    setState(() {});
  }

  /// 起始页底部：历史 / 收藏夹 / 新增快捷方式
  Widget _startPageActions(ThemeData theme) {
    Widget item({
      required Key key,
      required IconData icon,
      required String label,
      required VoidCallback onTap,
    }) =>
        Expanded(
          child: OutlinedButton(
            key: key,
            onPressed: onTap,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 22),
                const SizedBox(height: 6),
                Text(label, style: theme.textTheme.labelMedium),
              ],
            ),
          ),
        );

    return Row(
      children: <Widget>[
        item(
          key: BrowserPage.historyButtonKey,
          icon: Icons.history,
          label: '历史',
          onTap: () => unawaited(_showHistory()),
        ),
        const SizedBox(width: 8),
        item(
          key: BrowserPage.bookmarksButtonKey,
          icon: Icons.star_border,
          label: '收藏夹',
          onTap: () => unawaited(_showBookmarks()),
        ),
        const SizedBox(width: 8),
        item(
          key: BrowserPage.shortcutButtonKey,
          icon: Icons.add,
          label: '新增快捷方式',
          onTap: () => unawaited(_addShortcut()),
        ),
      ],
    );
  }

  /// 新增快捷方式：把当前地址（或手输的网址）加进快捷方式
  Future<void> _addShortcut() async {
    final controller = TextEditingController(
      text: _currentUrl.isNotEmpty ? _currentUrl : _addressField.text,
    );
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新增快捷方式'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '网址',
            hintText: 'https://example.com',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (url == null || url.trim().isEmpty || !mounted) return;

    var value = url.trim();
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'https://$value';
    }
    final messenger = ScaffoldMessenger.of(context);
    await StorageService.instance.addShortcut(
      WebLink(
        title: '',
        url: value,
        createdAt: DateTime.now(),
        isShortcut: true,
      ),
    );
    await _loadStartPage(notify: false);
    await _refreshBookmarkState();
    messenger.showSnackBar(SnackBar(content: Text('已加入快捷方式：$value')));
  }

  /// 快捷方式管理：逐个删除 / 一键清空
  ///
  /// 起始页的格子空间有限，一次搜索就可能占掉一个位置，所以必须给一个
  /// 「看得见、删得掉」的入口（长按删除太隐蔽，用户找不到）。
  Future<void> _manageShortcuts() async {
    await _loadStartPage(notify: false);
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final theme = Theme.of(sheetContext);
          final scheme = theme.colorScheme;
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.apps, size: 20, color: scheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('快捷方式（${_shortcuts.length}）',
                              style: theme.textTheme.titleMedium),
                        ),
                        if (_shortcuts.isNotEmpty)
                          TextButton.icon(
                            onPressed: () async {
                              final messenger = ScaffoldMessenger.of(sheetContext);
                              await StorageService.instance.clearShortcuts();
                              await _loadStartPage(notify: false);
                              if (sheetContext.mounted) Navigator.pop(sheetContext);
                              messenger.showSnackBar(
                                const SnackBar(content: Text('已清空全部快捷方式')),
                              );
                            },
                            icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                            label: const Text('清空全部'),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  if (_shortcuts.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('还没有快捷方式。浏览到想常去的页面时，点「收藏本页」或'
                          '上面的「新增快捷方式」添加。'),
                    )
                  else
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _shortcuts.length,
                        itemBuilder: (context, index) {
                          final link = _shortcuts[index];
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: scheme.primaryContainer,
                              child: Icon(Icons.public,
                                  size: 18, color: scheme.onPrimaryContainer),
                            ),
                            title: Text(link.displayTitle,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(link.url,
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall),
                            onTap: () {
                              Navigator.pop(sheetContext);
                              unawaited(_open(link.url));
                            },
                            trailing: IconButton(
                              tooltip: '删除',
                              icon: const Icon(Icons.close),
                              onPressed: () async {
                                await StorageService.instance.removeShortcut(link.url);
                                await _loadStartPage(notify: false);
                                if (sheetContext.mounted) {
                                  setSheetState(() {});
                                }
                                await _refreshBookmarkState();
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (!mounted) return;
    await _loadStartPage(notify: false);
  }


  /// 打开一个网址（离开起始页）
  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    debugLastOpenRequest = url; // 只给测试看：证明"我们确实把哪个地址交给了 WebView"
    _addressField.text = url;
    _address.text = url;
    _tab.navigate = true;
    if (_startPage && mounted) {
      setState(() => _tab.isStart = false);
      _notifyStartPage();
    }
    final web = _web;
    if (web == null) return;
    await web.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  /// 书源：镜像状态站 + 用户自建入口（列表可在设置里增删改）
  Future<void> _showBookSources() async {
    final sources = await StorageService.instance.loadBookSources();
    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            // 镜像域名经常换：先给一个「现查现用」的入口，再列用户自己的书源
            ListTile(
              leading: const Icon(Icons.travel_explore),
              title: const Text('检索可用域名'),
              subtitle: const Text('从 open-slum.org 查当前可用的镜像'),
              onTap: () => Navigator.pop(sheetContext, _kLookupMirrors),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('我的书源',
                  style: Theme.of(sheetContext).textTheme.titleSmall),
            ),
            for (final source in sources)
              ListTile(
                leading: const Icon(Icons.auto_stories_outlined),
                title: Text(source.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(source.url,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(sheetContext, source.url),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                '要增删书源，去「设置 → 书源」。',
                style: Theme.of(sheetContext).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (selected == _kLookupMirrors) {
      final mirror = await showMirrorPicker(context);
      if (mirror == null || !mounted) return;
      await _open(mirror.url);
      return;
    }
    await _open(selected);
  }

  Future<void> _refreshBookmarkState() async {
    final bookmarks = await StorageService.instance.loadBookmarks();
    if (!mounted) return;
    setState(() => _bookmarked =
        _currentUrl.isNotEmpty && bookmarks.any((b) => b.url == _currentUrl));
  }

  Future<void> _toggleBookmark() async {
    final url = _currentUrl.isNotEmpty ? _currentUrl : _address.text.trim();
    if (url.isEmpty) return;
    await StorageService.instance.toggleBookmark(
      WebLink(title: _currentTitle, url: url, createdAt: DateTime.now()),
    );
    await _refreshBookmarkState();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_bookmarked ? '已加入收藏' : '已取消收藏')),
    );
  }

  /// 把当前页设为**自定义浏览器首页**（「更多」菜单里的一项）
  ///
  /// 设过之后，主界面顶部会多出一个「打开自定义首页」入口；
  /// 「首页」按钮本身始终回浏览器主界面（用户要求）。
  Future<void> _setAsHome() async {
    final url = _currentUrl.isNotEmpty ? _currentUrl : _address.text.trim();
    if (url.isEmpty) return;
    await StorageService.instance.setHomeUrl(url);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已设为自定义首页：$url（首页键仍回浏览器主页，'
          '主界面上会多一个打开它的入口）')),
    );
  }

  /// 用户是否设过自定义浏览器首页
  bool get _hasCustomHome {
    final home = StorageService.instance.homeUrl.trim();
    return home.isNotEmpty && home != StorageService.defaultHomeUrl;
  }

  // ---------------- 收藏 / 记录 ----------------

  Future<void> _showBookmarks() async {
    final bookmarks = await StorageService.instance.loadBookmarks();
    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _LinkSheet(
        title: '我的收藏',
        emptyText: '还没有收藏，浏览时点「收藏本页」',
        links: bookmarks,
        icon: Icons.star,
        onDelete: (link) async {
          await StorageService.instance.removeBookmark(link.url);
          if (sheetContext.mounted) Navigator.pop(sheetContext);
          await _showBookmarks();
        },
      ),
    );
    if (selected != null) await _open(selected);
  }

  Future<void> _showHistory() async {
    final history = await StorageService.instance.loadHistory();
    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _LinkSheet(
        title: '浏览记录',
        emptyText: '暂无浏览记录',
        links: history,
        icon: Icons.history,
        onClear: () async {
          await StorageService.instance.clearHistory();
          if (sheetContext.mounted) Navigator.pop(sheetContext);
        },
      ),
    );
    if (selected != null) await _open(selected);
  }

  /// 记录一次访问（同网址只保留最新一条）
  Future<void> _recordVisit(String url, String title) async {
    if (url.isEmpty ||
        !(url.startsWith('http://') || url.startsWith('https://'))) return;
    await StorageService.instance.addHistory(
      WebLink(title: title, url: url, createdAt: DateTime.now()),
    );
  }

  // ---------------- 网页朗读 ----------------

  Future<void> _readPage() async {
    final web = _web;
    final messenger = ScaffoldMessenger.of(context);
    if (web == null) return;
    try {
      final raw = await web.evaluateJavascript(source: _extractScript);
      final text = raw is String ? raw.trim() : '';
      if (text.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('没有提取到可朗读的文字')));
        return;
      }
      final chunks = DocumentService.readChunks(text);
      if (chunks.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('没有提取到可朗读的文字')));
        return;
      }
      final title = await web.getTitle() ?? _currentTitle;
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => _WebReadSheet(
          title: title.isEmpty ? '本页朗读' : title,
          chunks: chunks,
          subtitle: '双击正文任意段落，可从该段单独开始朗读',
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('读取网页内容失败：$e')));
    }
  }

  /// 用整页翻译打开当前页（v1.21.36：谷歌优先，不可达自动退百度）
  ///
  /// 失败分支保持不变：非 http(s) 只给提示、**不跳转**。
  Future<void> _translatePage() async {
    // 先取 messenger：下面要 `await` 探测，之后不能再用 context（跨异步间隙）
    final messenger = ScaffoldMessenger.of(context);
    final target = await WebTranslate.resolveUrl(_currentUrl);
    if (target == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('当前页面不是网页（http/https），无法翻译')),
      );
      return;
    }
    if (!mounted) return;
    // 落到百度兜底时提示一句 —— 否则用户会以为"谷歌翻译怎么长这样"
    if (target.startsWith(WebTranslate.fallbackEndpoint)) {
      messenger.showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 3),
          content: Text('谷歌翻译不可达，已切换到百度翻译'),
        ),
      );
    }
    await _open(target);
  }

  /// 双击正文某一段：只读这一段（T2S 的「双击朗读」）
  Future<void> _speakNode(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    AutoSleepController.instance.notifyUserActivity();
    final chunks = DocumentService.readChunks(trimmed);
    if (chunks.isEmpty || !mounted) return;
    final title = _currentTitle.isEmpty ? '本页朗读' : _currentTitle;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _WebReadSheet(
        title: title,
        chunks: chunks,
        subtitle: '双击的段落（${trimmed.length} 字）',
        autoStart: true,
      ),
    );
  }

  // ---------------- 下载 ----------------

  /// 解析下载文件名：**服务端原名优先**（v1.21.39）
  ///
  /// ## 为什么不能只用 [DownloadStartRequest.suggestedFilename]
  ///
  /// 它来自 WebView `DownloadListener.onDownloadStart` 的 `contentDisposition`，
  /// 而 WebView **在重定向之后往往拿不到原始响应头** —— Z-Library 这类站是
  /// `/dl/xxx → 302 → CDN`，最终那次响应在 WebView 里只剩 URL，
  /// 名字就退化成末段（用户实测：下下来叫 `redirection.pdf`）。
  ///
  /// ## 做法
  ///
  /// ① WebView 给了就直接用（**零成本**，绝大多数站走这条）；
  /// ② 给了但明显是 URL 末段 / 没给 → **自己再发一次 GET** 问服务端要
  ///    `Content-Disposition`：
  ///    - 用 **GET 不用 HEAD**：很多 CDN 对 HEAD 的处理不一致，
  ///      可能干脆不给 Content-Disposition；
  ///    - `followRedirects: true`，否则重定向那一跳的响应头就白问了；
  ///    - **只读响应头就立刻放弃 body**（`response.stream.listen(null).cancel()`）
  ///      —— 不下载正文，几 KB 都不到；
  ///    - 10 秒超时；任何失败返回 null，调用方退回 URL 末段。
  Future<String?> _resolveDownloadName(DownloadStartRequest request) async {
    final suggested = request.suggestedFilename?.trim() ?? '';
    // ① WebView 给的名字可用（不是 URL 末段那种退化名）就直接用
    if (suggested.isNotEmpty &&
        FileNaming.sanitize(suggested).isNotEmpty &&
        !_looksLikeRedirectName(suggested, request.url)) {
      return suggested;
    }
    // ② 自己问一次服务端
    final probed = await _probeContentDisposition(request.url);
    if (probed != null) return probed;
    // ③ 实在问不到：把 WebView 给的（哪怕是退化名）交回去，让调用方兜底
    return suggested.isEmpty ? null : suggested;
  }

  /// 这个建议名是不是"重定向退化名"（末段是 redirection / download 之类）
  ///
  /// 判据刻意保守：只有**明显**是重定向占位名才去重新探测 ——
  /// 探测要多发一次网络请求，不能因为名字短就乱探。
  static bool _looksLikeRedirectName(String name, Uri url) {
    final lower = name.toLowerCase();
    const placeholder = <String>[
      'redirection',
      'redirect',
      'download',
      'index',
      'file',
      'dl',
      'get',
    ];
    final dot = lower.lastIndexOf('.');
    final base = dot > 0 ? lower.substring(0, dot) : lower;
    return placeholder.contains(base);
  }

  /// 探测响应头时用的 UA
  ///
  /// 与下载请求本身保持一致（浏览器页整体走桌面型 UA，见 `_open` 的
  /// `setSettings`）：有些站按 UA 决定给不给 `Content-Disposition`、
  /// 甚至给哪个文件，UA 不一致会探到和真实下载不同的名字。
  static const String _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  /// 发一次 GET 只取 `Content-Disposition`（读完头就放弃 body）
  Future<String?> _probeContentDisposition(Uri url) async {
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        // 有些站按 UA 决定给不给 disposition / 给哪个文件
        ..userAgent = _desktopUserAgent;
      final request = await client
          .getUrl(url)
          .timeout(const Duration(seconds: 10));
      final response = await request.close().timeout(const Duration(seconds: 10));
      final disposition = response.headers.value('content-disposition');
      // ⚠️ 只读头，**立刻放弃 body**：不 cancel 的话连接会一直挂着，
      // 而且大文件会把内存吃掉。（`HttpClientResponse` 本身就是 Stream）
      unawaited(response.listen(null).cancel());
      client.close(force: true);
      final name = FileNaming.parseContentDisposition(disposition);
      CrashLog.mark('下载命名探测：status=${response.statusCode} '
          'disposition="${disposition ?? ''}" → ${name ?? '(没解析出名字)'}');
      return name;
    } catch (e) {
      CrashLog.mark('下载命名探测失败：$e');
      return null;
    }
  }

  Future<void> _handleDownload(DownloadStartRequest request) async {
    if (_busy) return;
    final scheme = request.url.scheme.toLowerCase();
    final messenger = ScaffoldMessenger.of(context);
    if (scheme != 'http' && scheme != 'https') {
      messenger
          .showSnackBar(const SnackBar(content: Text('该链接不是直接的下载地址，暂不支持')));
      return;
    }
    setState(() => _busy = true);
    try {
      final storage = StorageService.instance;
      // ⚠️ 有自定义路径时**必须走私有目录那条路**（`saveInPublicStorage: false`）：
      // 公共目录分支走 MediaStore，`savedDir` 会被忽略，自定义路径根本不生效。
      // ★v1.21.44：判据从"必须在应用私有目录内"放开成"是文件系统路径" ——
      // 能不能写由 [_prepareSavedDir] 当场实测（写不进就降级并提示）。
      final useCustom = StorageService.isFilesystemPath(storage.customDownloadPath);
      final toPublic = !useCustom &&
          storage.downloadTarget == DownloadTarget.publicDownloads;
      // Android 13+ 通知权限用于显示下载进度；写公共目录时还需要存储权限
      if (Platform.isAndroid) {
        await Permission.notification.request();
        if (toPublic) await Permission.storage.request();
      }

      final savedDir = await _prepareSavedDir(storage);
      // 文件名尽量用服务端给的原名（只清洗非法字符，空格 / 中文 / 括号都保留）；
      // 重定向站点 WebView 拿不到原始响应头 → [_resolveDownloadName] 会自己再探一次；
      // 同名文件按 Android 下载器的习惯加 (1)(2)，不覆盖也不改名
      final serverName = await _resolveDownloadName(request);
      final fileName = FileNaming.uniqueName(
        FileNaming.downloadName(
          suggested: serverName ?? request.suggestedFilename,
          urlPath: request.url.path,
          mimeType: request.mimeType,
        ),
        (candidate) =>
            File('$savedDir${Platform.pathSeparator}$candidate').existsSync(),
      );
      final taskId = await FlutterDownloader.enqueue(
        url: request.url.toString(),
        savedDir: savedDir,
        fileName: fileName,
        headers: <String, String>{
          'User-Agent': request.userAgent ?? 'Mozilla/5.0'
        },
        showNotification: true,
        openFileFromNotification: false,
        // ⚠️ v1.21.43：**必须显式给 timeout**，否则吃插件默认的 **15 秒**。
        //
        // 插件源码（`downloader.dart:104` → `DownloadWorker.kt:310-311`）：
        // ```kotlin
        // httpConn.connectTimeout = timeout
        // httpConn.readTimeout    = timeout    // 相邻数据包的最大间隔
        // ```
        // 那个 `timeout` 默认 `15000`（毫秒），而我们原来**没传** ——
        // 于是"两次收到数据之间超过 15 秒就断"。
        //
        // 真机症状（用户报「**下载还是无法下全**」，日志为证）：
        // ```
        // 19:41:57  progress=0%   19:42:04  progress=3%
        // 19:42:12  progress=6%   19:42:13  status=failed progress=6%
        // ```
        // 从入队到失败 **16 秒**，恰好卡在 15 秒超时上 —— 而这本书几十 MB、
        // 源站是慢速 CDN（`dln1.ncdn.ec`），15 秒的包间隔对它是常态。
        //
        // 2 分钟是折中：给慢速 CDN 足够余量，又不至于真断线时让用户干等太久。
        timeout: BrowserPage.downloadTimeoutMs,
        saveInPublicStorage: toPublic,
        // 不要求「存储空间不紧张」：这个条件不满足时任务会一直排队且不给任何提示
        // （用户看到的就是「点了下载没反应」）。真写不下时让它失败并报错更清楚。
        requiresStorageNotLow: false,
      );
      if (taskId == null) {
        // 插件把失败原因吞进自己的日志里了，这里留一条自己的记录便于排查
        CrashLog.mark('下载任务创建失败：${request.url}（savedDir=$savedDir）');
        messenger.showSnackBar(
          const SnackBar(content: Text('下载任务创建失败，请稍后再试或换个链接')),
        );
        return;
      }
      // 探针（v1.21.41）：记下"我们要求的落点"与插件返回的 taskId。
      // 之后 `_waitForDownload` 会记状态/进度/磁盘三者的变化 ——
      // 用户报的"进度条只走一点、显示失败但文件已下好"就是靠这两条对出来的。
      CrashLog.mark('下载探针：入队 url=${request.url} '
          'name="$fileName" savedDir="$savedDir" toPublic=$toPublic '
          'taskId=$taskId');
      messenger.showSnackBar(SnackBar(content: Text('开始下载：$fileName')));

      final path = await _waitForDownload(taskId, savedDir, fileName);
      if (!mounted) return;
      if (path == null) {
        messenger
            .showSnackBar(const SnackBar(content: Text('下载未完成，可在「下载列表」里查看进度')));
        return;
      }
      await _onDownloaded(path, fileName);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('下载失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 准备保存目录
  ///
  /// 优先级（v1.21.44 起）：
  /// 1. **用户自定义文件夹** —— 只要它是**文件系统路径**（以 `/` 开头）就先用，
  ///    并**当场实测能不能写**（[StorageService.isWritableDir]）：
  ///    * 能写 → 就用它（这是"自选文件夹"真正生效的那条路）；
  ///    * 写不进（Android 10+ 对应用私有目录之外的写入有系统限制 / SD 卡拔出 /
  ///      权限被撤 / 目录被删）→ **降级到应用私有目录**并弹提示，
  ///      绝不能把文件丢进一个写不进去的目录（插件会直接失败，用户只看到"下载失败"）。
  ///
  ///    ⚠️ v1.21.44 之前这里只接受"应用私有目录之内"的路径，而系统文件选择器
  ///    进不去应用私有目录 —— 等于"自定义文件夹"永远选不成（设置页那段
  ///    "只有部分机型可用"的弹窗就是当时留下的结论）。
  ///
  /// 2. 否则用 `<应用目录>/downloads/<文件夹名>`（应用私有，永远可写）；
  /// 3. 系统下载目录由插件的 MediaStore 流程决定（`savedDir` 会被忽略），
  ///    这里仍返回一个可写目录，避免插件在参数校验阶段就失败。
  Future<String> _prepareSavedDir(StorageService storage) async {
    final custom = storage.customDownloadPath;
    if (StorageService.isFilesystemPath(custom)) {
      final bool usable = await StorageService.isUsableCustomDir(custom);
      if (usable) {
        final dir = Directory(custom);
        if (!await dir.exists()) await dir.create(recursive: true);
        return dir.path;
      }
      _notifyCustomDirFallback(custom);
    }
    final dir = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/downloads/${storage.downloadFolder}',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// 自定义文件夹用不了时的提示（降级一定伴随这句，不能让用户以为存到了自选目录）
  void _notifyCustomDirFallback(String badPath) {
    CrashLog.mark('下载[自定义降级] 自定义文件夹不可用 → 回退应用私有目录：$badPath');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text('自定义文件夹不可用：$badPath\n已回退到应用私有目录，可在设置里重新选择'),
      ),
    );
  }

  /// 轮询任务状态直到完成 / 失败，返回落盘路径
  ///
  /// ## ⚠️ 为什么"插件报 failed"不能直接认输（v1.21.41）
  ///
  /// 用户实测：**文件已经完整下好了**，而浏览器下载列表进度条只走了一点、
  /// 状态显示"下载失败"，于是自动导入没生效。
  ///
  /// 也就是说 `flutter_downloader` 报的状态与磁盘事实**可能不一致**
  /// （WorkManager 侧进度/结果同步缺失、或它按自己的口径判失败）。
  /// 原来的实现把 `failed` / `canceled` 当**终态立即 return null** ——
  /// 明明文件就在那儿，我们却放弃了。
  ///
  /// 现在改成：报失败/取消时**先看磁盘上文件到底有没有、像不像下完了**；
  /// 像是下完了就照常返回路径（后续导入流程会再校验一次可读性）。
  /// 同时记 `下载探针` 日志，便于下次直接定位。
  Future<String?> _waitForDownload(
      String taskId, String savedDir, String fileName) async {
    final separator = Platform.pathSeparator;
    String? lastStatus;
    int? lastProgress;
    var polls = 0;
    for (var i = 0; i < 240; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      polls++;
      final tasks =
          await FlutterDownloader.loadTasks() ?? const <DownloadTask>[];
      for (final task in tasks) {
        if (task.taskId != taskId) continue;

        final name = task.filename ?? fileName;
        final dir = task.savedDir.isEmpty ? savedDir : task.savedDir;
        final candidate =
            dir.endsWith(separator) ? '$dir$name' : '$dir$separator$name';

        // 探针（v1.21.41）：状态 / 进度 / 磁盘事实 三者一起记 ——
        // 用户报的"三者不一致"就是靠这条定位的
        final onDisk = await _probeFileOnDisk(candidate);
        if (task.status.name != lastStatus ||
            task.progress != lastProgress) {
          lastStatus = task.status.name;
          lastProgress = task.progress;
          CrashLog.mark('下载探针：poll=$polls status=${task.status.name} '
              'progress=${task.progress}% savedDir="$dir" name="$name" '
              '磁盘=$onDisk');
        }

        if (task.status == DownloadTaskStatus.complete) {
          CrashLog.mark('下载探针：判定完成（插件状态）→ $candidate');
          return candidate;
        }
        if (task.status == DownloadTaskStatus.failed ||
            task.status == DownloadTaskStatus.canceled) {
          // ⚠️ 关键改动：**先看磁盘**。文件在且非空 → 当作下好了，别认输。
          if (BrowserPage.shouldAcceptFailedDownload(task.status, onDisk)) {
            CrashLog.mark('下载探针：插件报 ${task.status.name} 但磁盘已有 '
                '${onDisk}B → 按"已下好"处理（状态与事实不一致）');
            return candidate;
          }
          CrashLog.mark('下载探针：判定失败（插件报 ${task.status.name}，'
              '且磁盘上没有可用文件，磁盘=$onDisk）');
          return null;
        }
        break;
      }
    }
    CrashLog.mark('下载探针：轮询超时（polls=$polls 最后一次 status=$lastStatus '
        'progress=$lastProgress%）');
    return null;
  }

  /// ⚠️ 本轮（需求二）**删掉了**原来的 `_tryOpenFolderNatively` 与
  /// `_folderChannel`（`tts_reader/folder` 通道）：
  ///
  /// 真机点 📂 闪退，崩的就是这条原生 `ACTION_VIEW` Intent 路
  /// （原生侧 `FolderChannel.kt` 仍在，但**产品路径不再调用它**）。
  /// 删掉之后 📂 一律走下面的面板路径 —— 见 [tryNativeFolderOpen] 的留档。
  ///
  /// 探针用：文件在磁盘上的字节数（不存在 / 读不到返回 null）
  /// 顺便当"下完了没"的判据：`exists()` 不够 —— 边下边写时文件会先出现，
  /// 半截文件照样 `exists()` 为真，导入时会解析失败。
  static Future<int?> _probeFileOnDisk(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.length();
    } catch (_) {
      return null;
    }
  }

  /// 下载完成：可朗读的格式直接进文档库，其它格式只提示保存位置
  /// 下载完成后的收尾
  ///
  /// ⚠️ v1.21.40：入库逻辑**不再写在这里**，改调公共的
  /// [importDownloadedFile]（后台扫描 `DownloadWatcher` 用的是同一份）——
  /// 这类"两套实现漂移"前几轮已经出过 bug。
  ///
  /// 这里只保留**界面那部分**：用户就在浏览器页等下载时，要立刻看到结果、
  /// 还能一键「立即朗读」（后台扫描没有界面，给不了这个）。
  Future<void> _onDownloaded(String path, String fileName) async {
    final messenger = ScaffoldMessenger.of(context);
    // 先按文件头纠正扩展名：有些地址不给文件名（`/slow_download/<hash>/`），
    // 下载器只能兜底存成 `.bin`，内容是好的 PDF 却按扩展名判成"不支持"。
    final String named = await normalizeDownloadedName(path);
    if (!DocumentType.isReadable(named)) {
      messenger.showSnackBar(
        SnackBar(
            content: Text('已下载：$fileName（该格式暂不支持朗读，仅支持 PDF / EPUB / TXT）')),
      );
      return;
    }
    // 公共下载目录在部分系统上应用读不到（MediaStore 归属问题），先确认文件真的能读
    final located =
        await locateDownloadedFile(named, fileName: FileNaming.baseName(named));
    // 改名成功说明我们**能读写这个文件**（改名前刚做过 rename），
    // 那种情况就算 MediaStore 查不到也照样能导入，不该卡在这里。
    final found = located ?? (named != path ? named : null);
    if (found == null) {
      messenger
          .showSnackBar(SnackBar(content: Text('已下载到：$path（应用读不到该位置，未导入文档库）')));
      return;
    }
    // 收进「下载」目录下的应用专属子文件夹（同卷改名，瞬间完成、不是两份）
    final real = await inboxDownloadedFile(found);
    final document = await importDownloadedFile(real);
    if (document == null) {
      messenger
          .showSnackBar(SnackBar(content: Text('已下载到：$real（导入文档库失败）')));
      return;
    }
    if (!mounted) return;
    // 方案 4：悬浮卡（倒计时圆环 3 秒自动收起 + 立即朗读 / 关闭）
    unawaited(
      showDownloadDoneCard(
        context,
        bookName: document.title,
        onRead: () {
          if (!mounted) return;
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              // ⚠️ 必须走分派，不能直接开 ReaderPage：
              // 这里下载的文档**任意类型都可能是**（`DocumentType.isReadable` 过就造），
              // 下载一本 PDF 点「立即朗读」会掉进 ReaderPage 的旧路径 ——
              // 而那条路径正在被删除（PDF 已改为独立的 PdfReadingPage）。
              builder: (_) => openReadingScreen(document),
            ),
          );
        },
      ),
    );
  }

  /// 网页 `<select>`：弹出 Flutter 选择面板，选完回写页面
  ///
  /// 参数结构（JS 侧 `WebSelectBridge.source` 产生）：
  /// `{id, label, multiple, options: [{index, text, selected, disabled}]}`
  Future<void> _showWebSelect(Map<String, dynamic> data) async {
    final String id = (data['id'] as String?) ?? '';
    if (id.isEmpty) return;
    final String label = (data['label'] as String?) ?? '';
    final bool multiple = data['multiple'] == true;
    final List<dynamic> rawOptions =
        (data['options'] as List<dynamic>?) ?? const <dynamic>[];

    final List<String> texts = <String>[];
    int? selectedIndex;
    final List<int> selectedIndexes = <int>[];
    for (final dynamic item in rawOptions) {
      if (item is! Map) continue;
      final Map<String, dynamic> option = Map<String, dynamic>.from(item);
      final int index = (option['index'] as num?)?.toInt() ?? texts.length;
      final String text = (option['text'] as String?) ?? '';
      texts.add(text.isEmpty ? '（空）' : text);
      if (option['selected'] == true) {
        selectedIndex ??= index;
        selectedIndexes.add(index);
      }
    }
    if (texts.isEmpty) return;
    if (!mounted) return;

    final List<int>? picked = await showModalBottomSheet<List<int>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => WebSelectSheet(
        label: label,
        options: texts,
        multiple: multiple,
        currentIndex: selectedIndex,
        currentIndexes: selectedIndexes,
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;

    final InAppWebViewController? web = _web;
    if (web == null) return;
    try {
      await web.evaluateJavascript(
        source: WebSelectBridge.applyScript(
          id: id,
          index: multiple ? null : picked.first,
          multiIndexes: multiple ? picked : null,
        ),
      );
    } catch (_) {
      // 页面可能已经跳走了，忽略
    }
  }

  /// 下载列表（**Chrome 式**：进度条 + 分组 + 按状态给动作）
  ///
  /// 列表本体在 [DownloadsSheet]（StatefulWidget）：它要自己轮询刷新进度、
  /// 要在关面板时停掉定时器，这两件事 `StatefulBuilder` 给不了（没有 `dispose`）。
  Future<void> _showDownloads() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => DownloadsSheet(
        onOpenFolder: _showDownloadFolder,
        onOpenTask: _openDownloadedTask,
      ),
    );
  }

  /// 点下载列表里某一项的「打开」：把这本书打开（**不是**用系统程序打开文件）
  ///
  /// ## 为什么是"打开这本书"而不是"用别的应用打开这个文件"
  ///
  /// 这是**读书应用**：下完的书已经在文档库里了，用户点「打开」想要的是接着读，
  /// 而不是把这个 PDF 甩给系统 PDF 阅读器。所以这里找的是**文档库里那一本**。
  ///
  /// ## 顺序（三步，逐级兜底）
  ///
  /// 1. 先按**文件名**在文档库里找（下载完成时 / 后台扫描已经导入过）；
  /// 2. 找不到就**现场导一次** —— 走的是与自动导入**同一条**路
  ///    （[importDownloadedFile]，含完整性校验），不另写一套；
  /// 3. 还是没有 → 如实说"还没进文档库"（半截文件 / 格式不支持都落到这里）。
  Future<void> _openDownloadedTask(DownloadTask task) async {
    final messenger = ScaffoldMessenger.of(context);
    final String name = task.filename ?? '';
    if (name.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('这条任务是旧记录，没有文件名，打不开')),
      );
      return;
    }

    Document? found;
    final List<Document> docs = await StorageService.instance.loadDocuments();
    for (final Document d in docs) {
      if (FileNaming.baseName(d.path).toLowerCase() == name.toLowerCase()) {
        found = d;
        break;
      }
    }
    if (found == null) {
      final String candidate = task.savedDir.isEmpty
          ? name
          : '${task.savedDir}${Platform.pathSeparator}$name';
      final String? real = await locateDownloadedFile(candidate, fileName: name);
      if (real != null) {
        found = await importDownloadedFile(await inboxDownloadedFile(real));
      }
    }

    if (!mounted) return;
    // `found` 在闭包里用不了类型提升，所以取一个 final 局部量再判一次 null
    final Document? target = found;
    if (target == null) {
      messenger.showSnackBar(
        SnackBar(content: Text('「$name」还没进文档库（可能没下完，或格式不支持朗读）')),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => openReadingScreen(target)),
    );
  }

  /// 「下载文件夹」：**直接弹面板**（绝对路径 + 文件清单 + 「复制路径」）
  ///
  /// ## 为什么不再"先请系统文件管理器打开"（本轮 · 需求二 改动）
  ///
  /// 原来这里是"先试原生跳转、失败才弹面板"。真机（TB335FC）点 📂 **闪退**，
  /// 崩的就是原生那条 `ACTION_VIEW` Intent 路（`FolderChannel.kt`）。
  /// 根因没有 logcat 佐证，而"点一下可能闪退"不能带进正式版 ——
  /// **用户拍板：删掉原生分支，按钮保留**，📂 一律弹面板。
  ///
  /// 面板里给的是**绝对路径**（可复制）：粘进文件管理器一样能进去，
  /// 所以能力没有减少。留档见 [tryNativeFolderOpen]。
  ///
  /// ## 为什么 Android 侧本来就得这么绕
  ///
  /// Android **没有**「打开某个目录」的标准 Intent：
  /// - `ACTION_VIEW` + `resource/folder` 只有**部分**第三方文件管理器认
  ///   （MIUI / ColorOS 的文件管理、Solid Explorer 认；Google 的 Files 不认）；
  /// - `file://` URI 在 Android 7+ 会抛 `FileUriExposedException`；
  /// - SAF 的 `ACTION_OPEN_DOCUMENT_TREE` 是用来**选**目录的，**不是用来看**目录。
  Future<void> _showDownloadFolder() async {
    // ── 探针（v1.21.43）────────────────────────────────────────────────
    // 用户报「点 📂 导航至软件下载文件夹会闪退」，而**闪退不留 Dart 日志**
    // （进程直接没了）。所以全链打点：崩了就看最后一条是谁。
    final int navSeq = ++_folderNavSeq;
    final sw = Stopwatch()..start();
    // ⚠️ 所有探针里的 I/O（`exists()` / `lengthSync()`）都必须包在
    // `runZonedGuarded` 之外、且各自 try 住 —— 探针自己绝不能成为崩溃源
    // （那就变成"诊断工具把病人治死了"）。
    String dirState = '?';
    try {
      dirState = await Directory(
        debugFolderPathForTest ?? StorageService.instance.downloadInboxPath,
      ).exists()
          ? '有'
          : '无';
    } catch (e) {
      dirState = '读不到($e)';
    }
    CrashLog.mark('探针[📂进入] seq=$navSeq path=${debugFolderPathForTest ?? StorageService.instance.downloadInboxPath} '
        '目录=$dirState 原生跳转=已删');
    // ──────────────────────────────────────────────────────────────────

    // v1.21.43（块3）：📂 导航到**软件专属子文件夹**（书最终待的地方），
    // 而不是「下载」根目录 —— 根目录里还混着用户其它下载。
    //
    // `debugFolderPathForTest` 只给设备用例用（测试进程写不了公共目录，
    // 需要一个"可读目录"来验面板与排序）；产品路径永远是 [downloadInboxPath]。
    final String path =
        debugFolderPathForTest ?? StorageService.instance.downloadInboxPath;
    // 子文件夹可能还没建（还没下载过任何书）：先建出来，别让 📂 落空
    if (debugFolderPathForTest == null) {
      try {
        final dir = Directory(path);
        if (!await dir.exists()) await dir.create(recursive: true);
      } catch (_) {
        // 建不出来也让后面的面板如实显示路径
      }
    }

    // ① **本轮（需求二）已删掉"先请原生侧打开文件夹"那一步** —— 见方法注释。
    //    原来这里写的是 `if (!skipNative && tryNativeFolderOpen) { ... }`：
    //    真机点 📂 闪退，崩的就是那条 Intent 路。

    // ② **直接给面板**（绝对路径 + 文件清单 + 「复制路径」）
    final Directory dir = Directory(path);

    // ⚠️ v1.21.40 修崩溃：**排序前必须复制成可修改列表**。
    // `toList()` 在部分实现里返回**不可修改列表**，直接 `sort()` 会抛
    // `Unsupported operation: Cannot modify an unmodifiable list`
    // （真机连崩 8 次，异常被 `unawaited` 吞掉 → 用户看到的是"点 📂 没反应"）。
    // 另外初始值是 `const <File>[]`（目录不存在时走这条）—— 它**更**不可修改。
    final List<File> entries = <File>[];
    try {
      if (await dir.exists()) {
        entries.addAll(
          await dir.list().where((e) => e is File).cast<File>().toList(),
        );
        // 设备用例的竞态窗口：**列完之后**再等一会儿才渲染
        // （产品路径为 null，无延迟）。见 debugFolderListDelayForTest 说明。
        final delay = debugFolderListDelayForTest;
        if (delay != null) await Future<void>.delayed(delay);
      }
    } catch (_) {
      // 目录不可读（权限 / 已被清理）：下面按"空目录"展示，路径仍然给出来
    }
    final List<File> sorted = List<File>.of(entries)
      ..sort((a, b) => a.path.compareTo(b.path));

    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final String summary = sorted.isEmpty
        ? '目录是空的（还没下载过，或文件已被移走）'
        : '共 ${sorted.length} 个文件';
    // 探针（v1.21.43）：清单**内容概要** —— 这是"崩在渲染前还是渲染中"的分界点。
    // 打了这条说明清单已拿到；若之后崩，问题在渲染（`lengthSync`）；
    // 若连这条都没打，问题在读目录/原生那一步。
    final int sizeBefore = _folderNavSizeCalls;
    CrashLog.mark('探针[📂 size] seq=$navSeq 文件数=${sorted.length} '
        '前几项=${sorted.take(3).map((f) => FileNaming.baseName(f.path)).join(",")}'
        '${sorted.isEmpty ? "(空)" : ""} 已累计取值=$sizeBefore');
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('下载文件夹'),
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
                Text(summary, style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 12),
                for (final file in sorted)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${FileNaming.baseName(file.path)} · '
                      '${_sizeTextSafe(file)}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                const SizedBox(height: 12),
                // ⚠️ 这里的文案必须与事实一致。
                // v1.21.41 修过一次事实错误（原来写死"自定义文件夹在应用私有目录里，
                // 文件管理器看不到"—— 但**应用的外部私有目录**
                // `/storage/emulated/0/Android/data/<包名>/files/` 在多数机型上
                // 是能在系统文件管理器里进去的）。
                //
                // 本轮（需求二）再修一次：**"尝试原生跳转"这条分支已经删了**，
                // 所以不能再写"没能打开"（听起来像"试过了、失败了"），
                // 得如实说"这里不直接跳转，用路径自己进"。
                const Text(
                  '本应用不直接跳转到文件夹（那是点 📂 闪退的来源）。\n'
                  '取文件：①点「复制路径」，在文件管理器里粘贴进入；'
                  '②或用数据线从电脑上取。\n'
                  '注：系统「下载」目录任何人都能看到；'
                  '如果保存位置在应用目录里，多数机型要开"显示隐藏/系统文件"才看得到'
                  '（卸载应用会一起删掉）。',
                  style: TextStyle(fontSize: 12),
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
              messenger.showSnackBar(
                const SnackBar(content: Text('下载文件夹路径已复制')),
              );
            },
            child: const Text('复制路径'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    // 探针（v1.21.43）：**导航完成** —— 弹窗被关掉后才算走完整链。
    // 有了它就能区分"崩在弹窗里"和"弹窗都正常、是别处崩的"。
    sw.stop();
    CrashLog.mark('探针[📂 导航完成] seq=$navSeq 耗时=${sw.elapsedMilliseconds}ms '
        '结果=success 文件数=${sorted.length} '
        '取值次数=$_folderNavSizeCalls 取值异常=$_folderNavSizeErrors');
  }

  /// 人类可读体积（下载文件夹清单用）
  static String _sizeText(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// **安全取体积**：文件在"列目录"和"渲染清单"之间没了也不能崩（v1.21.43 修闪退）
  ///
  /// ## 崩溃原因（用户报「点 📂 导航至软件下载文件夹会闪退」）
  ///
  /// 清单用的 `file.lengthSync()` 是**同步**调用，而且它写在弹窗的
  /// `builder` 里 —— 也就是**每帧 build 都会执行**。而
  /// 「列目录」与「渲染」之间文件完全可能已经不在：
  /// · 下载收纳路径正在把文件从「下载」根目录**移进**专属子文件夹；
  /// · 用户/系统清理、同名重下产生的 ` (1)` 副本被覆盖。
  ///
  /// 一旦文件没了，`lengthSync()` 抛 `FileSystemException`
  /// （*Cannot retrieve length of file*）。**在 build 里抛异常 = 闪退**，
  /// 而且 `onPressed` 上那层 `.catchError` **接不到** ——
  /// 同步 build 异常不会变成 Future 的错误，所以日志里连一条都不留。
  ///
  /// 所以这里返回人类可读的占位（"已移走"），而不是抛。
  static String _sizeTextSafe(File file) {
    _folderNavSizeCalls++;
    try {
      return _sizeText(file.lengthSync());
    } catch (e) {
      // 探针（v1.21.43）：把**异常类型 + 文件名**记下来。
      //
      // 为什么必须带文件名：`FileSystemException` 的 msg 是
      // 「Cannot retrieve length of file, path = <路径>」，光看 msg 分不清是哪个
      // —— 而"哪个文件被移走了"正是判断竞态（收纳路径正在搬文件）的关键。
      // 这也是用户要的「崩之前最后一个打点」：真崩了就看最后一条是谁。
      _folderNavSizeErrors++;
      CrashLog.mark('探针[📂 lengthSync异常] n=$_folderNavSizeErrors '
          'name=${FileNaming.baseName(file.path)} type=${e.runtimeType} '
          'msg=$e');
      return '已移走';
    }
  }

  // ---------------- 界面 ----------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: <Widget>[
        // 加载进度条恒占 2px：出现 / 消失时下面的内容不跳
        SizedBox(
          height: BrowserPage.progressBarHeight,
          child: _progress < 1
              ? LinearProgressIndicator(
                  value: _progress <= 0 ? null : _progress,
                  minHeight: BrowserPage.progressBarHeight,
                )
              : null,
        ),
        // 地址栏那一行固定在顶部：主界面时在搜索栏上方，浏览网页时就是浏览器地址栏
        _addressRow(Theme.of(context)),
        Expanded(
          child: PopScope<Object?>(
            // 系统返回键先退网页历史，再退到起始页：直接退出应用最反直觉
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              unawaited(_handleSystemBack());
            },
            child: Stack(
              children: <Widget>[
                // 垫在 WebView 下面的主题底色（见 initialSettings 里的注释）
                ColoredBox(
                  color: dark ? const Color(0xFF121212) : scheme.surface,
                  child: _webViews(),
                ),
                // 起始页盖在 WebView 上面（WebView 留在树里，回来时状态还在）
                if (_startPage) _startPageView(),
                if (_busy)
                  ColoredBox(
                    color: scheme.surface.withAlpha(180),
                    child: const Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 全部标签的 WebView：**每标签一个实例**，只显示当前那个
  ///
  /// ⚠️ 为什么用 [IndexedStack] 而不是 `if (i == _activeTabIndex)` 条件渲染：
  /// 条件渲染会在切走时**销毁** WebView，切回来是重建 —— 滚动位置、表单内容、
  /// 正在播放的媒体全丢，标签页就白做了。`IndexedStack` 让它们都留在树上保活。
  ///
  /// ⚠️ 每个标签必须有**自己的 [GlobalKey]**（`tab.webViewKey`）：用下标或临时 key
  /// 会让 `IndexedStack` 在增删标签时把 WebView 当成"另一个 widget"而重建。
  Widget _webViews() => IndexedStack(
        index: _activeTabIndex,
        children: <Widget>[
          for (final tab in _tabs)
            _newWebView(tab),
        ],
      );

  /// 某个标签的 WebView 参数
  ///
  /// 回调**一律通过 [tab] 记账**，不读 `_tab`（后者永远指向"当前激活标签"）：
  /// 后台标签也会继续加载 / 报进度 / 报错误，写成 `_tab` 就会把**别的标签**的
  /// URL、标题、进度写到当前标签上（多标签最容易踩的就是这个）。
  Widget _newWebView(_WebTab tab) {
    // 明暗从**当前**主题取（不能引用 build 里的局部量）
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return InAppWebView(
      key: tab.webViewKey,
initialUrlRequest: URLRequest(url: WebUri('about:blank')),
  initialSettings: InAppWebViewSettings(
    javaScriptEnabled: true,
    useOnDownloadStart: true,
    useShouldOverrideUrlLoading: true,
    mediaPlaybackRequiresUserGesture: false,
    supportZoom: true,
    // 透明背景 + 下面垫一层主题底色：页面自己没写底色时不会
    // 在暗色主题下先闪一下白屏（WebView 原生背景默认是白的）
    transparentBackground: true,
  ),
  onWebViewCreated: (controller) {
    _web = controller;
    // 双击正文段落即读：JS 侧把节点文字回传，这里直接开读
    controller.addJavaScriptHandler(
      handlerName: WebSpeakScript.handlerName,
      callback: (args) {
        final text = args.isNotEmpty && args.first is String
            ? args.first as String
            : '';
        unawaited(_speakNode(text));
        return null;
      },
    );
    // yuedu:// / legado:// 链接的 DOM 层拦截（有些站点按钮点了不走导航回调，
    // 只靠 shouldOverrideUrlLoading 会「点了没反应」）
    controller.addJavaScriptHandler(
      handlerName: YueduLinkScript.handlerName,
      callback: (args) {
        final String link = args.isNotEmpty && args.first is String
            ? args.first as String
            : '';
        if (link.isEmpty) return null;
        CrashLog.mark('浏览器[深链点击] $link');
        if (SourceLinkParser.isRssSourceLink(link)) {
          unawaited(_offerRssSourceImport(link));
        } else if (SourceLinkParser.isBookSourceLink(link)) {
          unawaited(_offerBookSourceImport(link));
        }
        return null;
      },
    );
    // 网页 <select>：插件没把原生选择器接出来（真机上「点语言下拉没反应」），
    // 这里接管 —— 由 Flutter 弹面板，选完回写页面。
    controller.addJavaScriptHandler(
      handlerName: WebSelectBridge.handlerName,
      callback: (args) {
        final dynamic raw = args.isEmpty ? null : args.first;
        if (raw is Map) {
          unawaited(_showWebSelect(Map<String, dynamic>.from(raw)));
        }
        return null;
      },
    );
  },
  onLoadStart: (controller, url) {
    _updateTab(tab, () {
      tab.progress = 0;
      return true;
    });
  },
  // 加载失败要留痕：排查"点了没反应/白屏"时这是唯一线索
  // （设备侧用例也读它，见 debugLastLoadError）
  onReceivedError: (controller, request, error) {
    tab.lastError = '${error.type}: ${error.description} @ ${request.url}';
    // ⚠️ v1.21.40：改走 CrashLog 而不是 print ——
    // release 包里 `print` 根本看不到，而白屏 / "点了没反应"的唯一线索就是它。
    CrashLog.mark('浏览器加载错误[tab=${tab.id}] ${tab.lastError}');
  },
  onReceivedHttpError: (controller, request, response) {
    tab.lastError = 'HTTP ${response.statusCode} @ ${request.url}';
    CrashLog.mark('浏览器 HTTP 错误[tab=${tab.id}] ${tab.lastError}');
  },
  onLoadStop: (controller, url) async {
    final canGoBack = await controller.canGoBack();
    final canGoForward = await controller.canGoForward();
    final title = await controller.getTitle() ?? '';
    final href = url?.toString() ?? '';
    if (!mounted) return;
    // 只有**用户主动打开的**网页才离开起始页；
    // WebView 自己初始化那次加载不算（见 tab.navigate 注释）
    final bool leftStartPage = tab.navigate &&
        href.isNotEmpty &&
        href != 'about:blank' &&
        tab.isStart;
    _updateTab(tab, () {
      tab.progress = 1;
      tab.canGoBack = canGoBack;
      tab.canGoForward = canGoForward;
      tab.url = href;
      tab.title = title;
      if (tab.navigate && href.isNotEmpty && href != 'about:blank') {
        tab.isStart = false;
      }
      return true;
    });
    // ⚠️ 地址栏 / AppBar 的"离开起始页"只在**激活标签**上生效：
    // 后台标签加载完也去改地址栏，就会把当前标签的 URL 顶掉
    if (identical(tab, _tab)) {
      if (leftStartPage || (tab.navigate && href.isNotEmpty)) {
        if (href.isNotEmpty && href != 'about:blank') _addressField.text = href;
      }
      if (leftStartPage) _notifyStartPage();
      _notifyNavigation();
    }
    await _refreshBookmarkState();
    await _recordVisit(href, title);
    // 打标必须在页面加载完成后做一次；失败不影响浏览
    try {
      await controller.evaluateJavascript(
          source: WebSpeakScript.doubleTap);
    } catch (_) {
      // 某些页面（about:blank、跨域 iframe 等）不支持注入，忽略
    }
    // yuedu:// / legado:// 链接拦截：站点那种「一键导入」按钮点了常常
    // 不走导航回调（真机实测 dy.mgz6.com），所以每页注入一次点击拦截。
    try {
      await controller.evaluateJavascript(source: YueduLinkScript.source);
    } catch (_) {
      // 注入失败就退回 shouldOverrideUrlLoading 那条路
    }
    // 网页 <select> 接管（原生选择器在插件这层没接出来）
    try {
      await controller.evaluateJavascript(source: WebSelectBridge.source);
    } catch (_) {
      // 注入失败：select 就还是点不动，但不影响其它功能
    }
    // 主题：只给**这个**标签注入（`_injectTheme` 会遍历全部，这里按 tab 精准做，
    // 免得每加载完一个标签就重复注入所有标签）
    try {
      await controller.evaluateJavascript(
          source: WebThemeScript.inject(dark: dark));
    } catch (_) {
      // 忽略
    }
  },
  onProgressChanged: (controller, progress) {
    _updateTab(tab, () {
      tab.progress = progress / 100;
      return true;
    });
  },
  onDownloadStartRequest: (controller, request) {
    // 下载时把"这次是谁点的"记在激活标签上：后台标签弹下载会让人莫名其妙
    unawaited(_handleDownload(request));
  },
  shouldOverrideUrlLoading: (controller, action) async {
    // ⚠️ `intent://` / `market://` 这类"唤起别的 App"的链接
    // WebView 处理不了，放行就会停在
    // `ERR_UNKNOWN_URL_SCHEME / Webpage not available` 错误页上
    // （v1.21.36 实测：Edge 扩展商店最后就是跳到
    //  `intent://play.google.com/…com.microsoft.emmx`）。
    // 这里拦下来、明确告诉用户发生了什么，而不是丢一个错误页。
    final String target =
        action.request.url?.toString() ?? '';
    final String scheme =
        action.request.url?.scheme.toLowerCase() ?? '';

    // 书源导入链接（yuedu:// / legado://）：拦下来问一句再导，**不静默改用户的书源库**
    if (SourceLinkParser.isBookSourceLink(target)) {
      unawaited(_offerBookSourceImport(target));
      return NavigationActionPolicy.CANCEL;
    }
    // 订阅源（RSS）导入链接：同一条路，只是落到订阅源库
    // （真机日志 02:10 出现过 `legado://import/rssSource?src=…` 落到
    //  `ERR_UNKNOWN_URL_SCHEME` 错误页 —— 那是没拦它导致的）
    if (SourceLinkParser.isRssSourceLink(target)) {
      unawaited(_offerRssSourceImport(target));
      return NavigationActionPolicy.CANCEL;
    }

    if (scheme == 'intent' ||
        scheme == 'market' ||
        scheme == 'tg' ||
        scheme == 'weixin' ||
        scheme == 'alipays') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 4),
            content: Text(
              scheme == 'intent' || scheme == 'market'
                  ? '这个链接要打开应用商店里的另一个 App'
                  : '这个链接要打开外部 App（本站内打不开）',
            ),
          ),
        );
      }
      return NavigationActionPolicy.CANCEL;
    }
    if (target.isNotEmpty) {
      // v1.21.40：降级成 debugPrint（release 包不输出）。
      // 这条只是导航轨迹、不是错误，不该进 CrashLog 把真问题淹掉。
      debugPrint('BROWSER_NAV[tab=${tab.id}] $target');
    }
    return NavigationActionPolicy.ALLOW;
  },
    );
  }


  /// 浏览器里点到 `yuedu://` 书源导入链接：确认后再导
  ///
  /// ⚠️ **不静默导入**：点一个链接就改用户的书源库，属于越权操作。
  /// 用户明确点「导入」才走 `SourceImporter`。
  /// 浏览器里点到 `yuedu://rsssource` / `legado://import/rssSource`：确认后导入订阅源
  ///
  /// 与书源那条同构，只是写到 `RssStore`（两套库分开存）。
  Future<void> _offerRssSourceImport(String link) async {
    final String? src = SourceLinkParser.extractRssSourceUrl(link);
    if (!mounted) return;
    if (src == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这个订阅源链接里没有可用的地址')),
      );
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('发现订阅源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('这个链接包含订阅源（RSS），要导入吗？'),
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
    if (ok != true || !mounted) return;

    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
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
      // 先给用户勾选（与阅读 App 同款弹窗），确认后才写库
      final List<RssSource> existingAll = await RssStore.instance.load();
      if (!mounted) return;
      final List<RssSource>? picked = await showRssImportConfirm(
        context,
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

  Future<void> _offerBookSourceImport(String link) async {
    final String? src = SourceLinkParser.extractBookSourceUrl(link);
    if (!mounted) return;
    if (src == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这个书源链接里没有可用的地址')),
      );
      return;
    }

    final bool? ok = await showDialog<bool>(
      context: context,
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
    if (ok != true || !mounted) return;

    final ParseOutcome outcome;
    try {
      outcome = await SourceImporter.parse(src);
    } catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('导入失败'),
          content: Text('$e'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;

    if (outcome.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('导入失败'),
          content: Text(
            outcome.errors.isEmpty ? '没解析出任何书源' : outcome.errors.join('\n'),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }

    // 与订阅页那条路径一致：先让用户勾选要哪些，再写库
    final List<SourceRule> existing = await LegadoSourceStore.instance.load();
    if (!mounted) return;
    final NavigatorState navigator = Navigator.of(context);
    final List<SourceRule>? picked = await navigator.push<List<SourceRule>>(
      MaterialPageRoute<List<SourceRule>>(
        builder: (_) => SourceImportConfirmPage(
          sources: outcome.rules,
          localUrls: <String>{for (final SourceRule r in existing) r.url},
        ),
      ),
    );
    if (!mounted || picked == null || picked.isEmpty) return;

    final ({int added, int updated}) result = await applySelectedSources(picked);
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入完成'),
        content: Text('新增 ${result.added} 个书源，更新 ${result.updated} 个'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Widget _startPageView() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Positioned.fill(
      key: BrowserPage.startPageKey,
      child: ColoredBox(
        color: scheme.surface,
        // 地址栏那一行由外层 Column 固定在顶部（在**搜索栏上方**），
        // 这里只排搜索框 / 快捷入口这些主界面内容
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: <Widget>[
            _startPageSearch(theme),
            const SizedBox(height: 20),
            _startPageActions(theme),
            const SizedBox(height: 24),
            Row(
              children: <Widget>[
                Text('快捷方式', style: theme.textTheme.titleSmall),
                const Spacer(),
                if (_shortcuts.isNotEmpty)
                  TextButton.icon(
                    key: BrowserPage.manageShortcutsKey,
                    onPressed: () => unawaited(_manageShortcuts()),
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('管理'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (_shortcuts.isNotEmpty)
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: <Widget>[
                  for (final link in _shortcuts) _shortcutChip(theme, link),
                ],
              )
            else
              Text(
                '还没有快捷方式。浏览到想常去的页面时点「收藏本页」，'
                '或点上面的「新增快捷方式」添加（搜索结果页不会被收录）。',
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }

  /// 顶部地址栏一行：左边后退 / 前进，中间地址栏，右边刷新 / 首页 / 更多
  ///
  /// 主界面（未打开网页）时它在**搜索栏上方**；打开网页后它就是浏览器地址栏。
  /// 两种状态共用同一个控件，所以主界面 ↔ 网页之间切换不会有「工具栏跳位」的观感。
  Widget _addressRow(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Material(
      key: BrowserPage.addressRowKey,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 4, 2, 6),
        child: Row(
          children: <Widget>[
            IconButton(
              tooltip: '后退',
              visualDensity: VisualDensity.compact,
              onPressed: _canGoBack ? () => unawaited(goBack()) : null,
              icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            ),
            IconButton(
              tooltip: '前进',
              visualDensity: VisualDensity.compact,
              onPressed: _canGoForward ? () => unawaited(goForward()) : null,
              icon: const Icon(Icons.arrow_forward_ios, size: 18),
            ),
            Expanded(
              child: TextField(
                key: BrowserPage.addressFieldKey,
                controller: _addressField,
                textInputAction: TextInputAction.go,
                keyboardType: TextInputType.url,
                autocorrect: false,
                style: theme.textTheme.bodyMedium,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  hintText:
                      '输入网址，或用「${StorageService.instance.searchEngine.name}」搜索',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  prefixIconConstraints: const BoxConstraints(minWidth: 34),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (value) => submitAddress(value),
              ),
            ),
            IconButton(
              tooltip: '刷新',
              visualDensity: VisualDensity.compact,
              onPressed: _startPage ? null : () => unawaited(reload()),
              icon: const Icon(Icons.refresh, size: 20),
            ),
            IconButton(
              // 首页键：没有自定义浏览器首页时回**应用内的浏览器主界面**
              // （主界面自带搜索与快捷方式，比跳去某个搜索站更直接）
              tooltip: '回到浏览器主页',
              visualDensity: VisualDensity.compact,
              onPressed: _startPage ? null : _goStartPage,
              icon: const Icon(Icons.home_outlined, size: 20),
            ),
            // 标签页（v1.21.39）：数字角标显示当前开了几个
            IconButton(
              key: BrowserPage.tabsButtonKey,
              tooltip: '标签页',
              visualDensity: VisualDensity.compact,
              onPressed: () => unawaited(_openTabsPanel()),
              icon: Badge(
                label: Text('${_tabs.length}'),
                isLabelVisible: _tabs.length > 1,
                child: const Icon(Icons.tab, size: 20),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '更多',
              icon: const Icon(Icons.more_vert, size: 20),
              padding: EdgeInsets.zero,
              onSelected: (value) => unawaited(handleMenuAction(value)),
              itemBuilder: (_) => browserMenuEntries(),
            ),
          ],
        ),
      ),
    );
  }

  /// 起始页上的一个快捷方式：点开、右上角小叉删除
  Widget _shortcutChip(ThemeData theme, WebLink link) {
    final scheme = theme.colorScheme;
    final label = link.displayTitle;
    return SizedBox(
      width: 104,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          InkWell(
            onTap: () => unawaited(_open(link.url)),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: 104,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.public, size: 22, color: scheme.primary),
                  const SizedBox(height: 8),
                  Text(
                    label,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
          // 直接给一个看得见的删除入口（长按太隐蔽，用户会找不到）
          Positioned(
            right: -6,
            top: -6,
            child: Material(
              color: scheme.surfaceContainerHigh,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => unawaited(_removeShortcut(link, ask: false)),
                child: Tooltip(
                  message: '删除快捷方式',
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(Icons.close, size: 14, color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 删除一个快捷方式（长按 / 小叉都走这里）
  Future<void> _removeShortcut(WebLink link, {bool ask = true}) async {
    final messenger = ScaffoldMessenger.of(context);
    if (ask) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('删除快捷方式'),
          content: Text('确定删除「${link.displayTitle}」吗？'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await StorageService.instance.removeShortcut(link.url);
    await _refreshBookmarkState();
    await _loadStartPage(notify: false);
    if (!mounted) return;
    messenger.showSnackBar(const SnackBar(content: Text('已删除快捷方式')));
  }

  /// 系统返回键：先退网页历史，再回起始页，最后才让应用退出
  Future<void> _handleSystemBack() async {
    final web = _web;
    if (web != null && await web.canGoBack()) {
      await web.goBack();
      return;
    }
    // 退无可退但还在网页上：回到浏览器主界面
    if (!_startPage) {
      _goStartPage();
      return;
    }
    // 已经在起始页：走系统默认行为（退出应用 / 回到桌面）
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      await SystemNavigator.pop();
    }
  }

}

/// 下载任务的状态图标（**顶层函数**：`_BrowserPageState` 与 [_DownloadsSheet]
/// 都要用，所以不能挂在某一个类里）
IconData _downloadStatusIcon(DownloadTaskStatus? status) => switch (status) {
      DownloadTaskStatus.complete => Icons.check_circle_outline,
      DownloadTaskStatus.running => Icons.downloading,
      DownloadTaskStatus.enqueued => Icons.schedule,
      DownloadTaskStatus.paused => Icons.pause_circle_outline,
      DownloadTaskStatus.failed => Icons.error_outline,
      DownloadTaskStatus.canceled => Icons.cancel_outlined,
      _ => Icons.help_outline,
    };

/// **下载列表弹层（Chrome 式）**：进度条 + 分组 + 按状态给动作
///
/// ## 为什么是独立的 StatefulWidget（原来是 `StatefulBuilder`）
///
/// 1. **进度要自己刷新**：`flutter_downloader` **没有变更推送**，只能
///    `loadTasks()` 轮询。轮询要定时器，定时器要 `dispose` ——
///    `StatefulBuilder` 给不了 `dispose`，漏掉就是"面板关了还在后台轮询"（白耗电）。
/// 2. 列表现在有**分组 + 每项多个动作按钮**，继续塞在 builder 闭包里没法读。
///
/// ## 为什么这个类是**公开**的（而不是 `_DownloadsSheet`）
///
/// `BrowserPage` 本体在组件测试里起不来（它一 build 就要 `InAppWebViewPlatform`，
/// 那是平台通道、单元测试里没有）。把面板单独公开，用例就能**只 pump 面板**
/// 去验"分组 / 进度条 / 按钮 / 关掉后不留定时器"这几件事 —— 不必上真机。
///
/// ## 与插件状态的关系（真机踩过的坑）
///
/// 插件报的状态**与磁盘事实可能不一致**（用户实测：文件已经完整下好，插件却报
/// `failed`、进度只走了一点）。所以这里：
/// · 状态只当**显示**依据，不当"文件在不在"的判据；
/// · 每一项的「打开」走调用方给的 `onOpenTask`（先查文档库、必要时现场导入），
///   **不依赖插件状态说什么**。
class DownloadsSheet extends StatefulWidget {
  const DownloadsSheet({
    super.key,
    required this.onOpenFolder,
    required this.onOpenTask,
    this.debugTasks,
  });

  /// 标题行 📂：打开「下载文件夹」面板（产品决策在调用方）
  final Future<void> Function() onOpenFolder;

  /// 某一项的「打开」：把这本书打开
  final Future<void> Function(DownloadTask task) onOpenTask;

  /// 组件用例专用：**临时**用这份任务表渲染（不去读插件任务表，组件测试没有
  /// 平台通道）。`null` = 走产品路径。
  @visibleForTesting
  final List<DownloadTask>? debugTasks;

  @override
  State<DownloadsSheet> createState() => _DownloadsSheetState();
}

class _DownloadsSheetState extends State<DownloadsSheet> {
  List<DownloadTask> _tasks = const <DownloadTask>[];
  Timer? _poll;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    // ⚠️ 只在面板开着时轮询，且 `dispose` 一定取消 —— **不许留悬挂定时器**
    // （用例与真机都受不了"面板关了还在每秒读一次数据库"）。
    _poll = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_refresh()),
    );
  }

  @override
  void dispose() {
    // ⚠️ 这一句不许删：漏了就是"面板关了还在每秒读一次任务表"。
    // 用例守着它（`test/download_sheet_ui_test.dart`）：
    // 注释掉这行 → 立刻报 "A Timer is still pending after the widget tree was disposed"。
    _poll?.cancel();
    _poll = null;
    super.dispose();
  }

  /// 重新读一遍任务表（防重入：1 秒一次 × 用户还在点按钮，很容易叠上两次）
  Future<void> _refresh() async {
    if (_loading) return;
    _loading = true;
    try {
      final List<DownloadTask> next = widget.debugTasks ??
          await FlutterDownloader.loadTasks() ??
          const <DownloadTask>[];
      if (!mounted) return;
      setState(() => _tasks = next);
    } catch (e) {
      // 插件在个别 ROM 上会抛：面板不该因此白屏，记一条日志就够
      CrashLog.mark('下载列表刷新失败：$e');
    } finally {
      _loading = false;
    }
  }

  /// 跑一个插件动作，然后刷新
  ///
  /// ⚠️ 失败**必须让用户看见**：这类动作失败时插件只写自己的原生日志，
  /// 界面一动不动，用户会以为"按钮坏了"（v1.21.40 的教训）。
  Future<void> _run(String what, Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      CrashLog.mark('下载列表「$what」失败：$e');
      _toast('$what失败：$e');
    }
    await _refresh();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// 「打开」这一项：**先关面板，再开阅读页**
  ///
  /// 不先关的话阅读页会压在面板下面，用户点完像"没反应"。
  Future<void> _open(DownloadTask task) async {
    Navigator.of(context).pop();
    await widget.onOpenTask(task);
  }

  @override
  Widget build(BuildContext context) {
    final List<DownloadGroup> groups = DownloadListModel.groupsOf(_tasks);
    return SafeArea(
      child: ConstrainedBox(
        // 长列表不要顶到屏幕上边：给个上限，内部滚动
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('下载列表'),
              trailing: IconButton(
                key: BrowserPage.downloadFolderKey,
                icon: const Icon(Icons.folder_open),
                tooltip: '下载文件夹',
                onPressed: () => unawaited(
                  // ⚠️ 不要让异常静默消失（v1.21.40）：这里曾崩过 8 次，
                  // 异常被 `unawaited` 吞掉，用户看到的只是"点 📂 没反应"。
                  widget.onOpenFolder().catchError((Object e) {
                    CrashLog.mark('下载文件夹面板打开失败：$e');
                    _toast('打开下载文件夹失败：$e');
                  }),
                ),
              ),
            ),
            const Divider(height: 1),
            if (groups.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Text('暂无下载任务'),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: <Widget>[
                    for (final DownloadGroup group in groups) ...<Widget>[
                      _groupHeader(group),
                      for (final DownloadTask task in group.tasks) _item(task),
                    ],
                    const SizedBox(height: 8),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 分组小标题（「正在下载（2）」这种）
  Widget _groupHeader(DownloadGroup group) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Text(
          '${DownloadListModel.sectionTitle(group.section)}（${group.length}）',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      );

  Widget _item(DownloadTask task) {
    final DownloadSection section = DownloadListModel.sectionOf(task.status);
    return ListTile(
      // 这个 key 不能改：设备用例按它定位某一项
      key: ValueKey<String>('download-item-${task.taskId}'),
      isThreeLine: true,
      leading: Icon(_downloadStatusIcon(task.status)),
      title: Text(
        task.filename ?? '未命名文件',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SizedBox(height: 2),
          Text(
            // 来源（从哪个站点下的）+ 状态 + 百分比：Chrome 那一行也是这个信息
            '${DownloadListModel.sourceLabel(task.url)} · '
            '${DownloadListModel.statusLabel(task.status)} · ${task.progress}%',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: DownloadListModel.progressFraction(task.progress),
              minHeight: 4,
              // 失败那条用错误色：一眼能看出"这条不用等了"
              color: section == DownloadSection.failed
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
          ),
        ],
      ),
      trailing: _actions(task),
    );
  }

  /// 每项右侧的动作按钮 —— **由状态决定**（判据全在 [DownloadListModel]）
  ///
  /// | 状态 | 按钮 |
  /// | --- | --- |
  /// | 排队中 / 下载中 | 暂停、取消 |
  /// | 已暂停 | 继续、取消 |
  /// | 已完成 | 打开、移除 |
  /// | 失败 / 已取消 | 重试、移除 |
  Widget _actions(DownloadTask task) {
    // ⚠️ `task.status` 在插件里是**非空**枚举，但列表的判据全部按可空写：
    // 插件将来新增状态值时，`null` 会走"未知"那条最保守的路（不崩、不误判）。
    final DownloadTaskStatus status = task.status;
    final bool active = DownloadListModel.isActive(status);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (DownloadListModel.canPause(status))
          _action(
            Icons.pause,
            '暂停',
            () => _run('暂停',
                () => FlutterDownloader.pause(taskId: task.taskId)),
          ),
        if (DownloadListModel.canResume(status))
          _action(Icons.play_arrow, '继续', () => _run('继续', () async {
                final String? newId = await FlutterDownloader.resume(
                  taskId: task.taskId,
                  requiresStorageNotLow: false,
                  // 与首次下载同一个超时：不能吃插件默认的 15 秒
                  // （慢速 CDN 上"相邻数据包间隔"超 15 秒就会被判失败）
                  timeout: BrowserPage.downloadTimeoutMs,
                );
                // ⚠️ 插件返回 null = **它没接受这次继续**（暂停分片已经不在了）。
                // 不提示的话，用户看到的是"点了继续、什么都没发生"。
                if (newId == null) {
                  _toast('继续失败：暂停的分片可能已经不在了，可以试「重试」');
                }
              })),
        if (DownloadListModel.canRetry(status))
          _action(Icons.refresh, '重试', () => _run('重试', () async {
                final String? newId = await FlutterDownloader.retry(
                  taskId: task.taskId,
                  requiresStorageNotLow: false,
                  timeout: BrowserPage.downloadTimeoutMs,
                );
                if (newId == null) {
                  _toast('重试失败：这条任务插件已经接不回去了，可以重新下载');
                }
              })),
        if (DownloadListModel.canOpen(status))
          _action(
            Icons.menu_book_outlined,
            '打开',
            () => unawaited(_open(task)),
          ),
        // ⚠️ 叉 / 垃圾桶的语义**不能互换**（`BrowserPage.trailingIconFor`
        // 是那条回归用例的判据来源，这里用它取图标 = 界面与用例同一份判据）：
        // · 进行中 → 叉 = `cancel`（真的停止下载）
        // · 已结束 → 垃圾桶 = `remove`（**只移记录，不删文件**）
        if (active || DownloadListModel.canRemove(status))
          _action(
            BrowserPage.trailingIconFor(status),
            active ? '取消下载' : '从列表移除',
            () => _run(
              active ? '取消' : '移除',
              () => active
                  ? FlutterDownloader.cancel(taskId: task.taskId)
                  // `shouldDeleteContent` 必须是 false：文件可能已经被自动
                  // 导入文档库，删了书就打不开 —— 比"列表多一条记录"严重得多。
                  : FlutterDownloader.remove(
                      taskId: task.taskId,
                      shouldDeleteContent: false,
                    ),
            ),
          ),
      ],
    );
  }

  Widget _action(IconData icon, String tooltip, VoidCallback onPressed) =>
      IconButton(
        icon: Icon(icon),
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
      );
}

/// 收藏 / 浏览记录列表
class _LinkSheet extends StatelessWidget {
  const _LinkSheet({
    required this.title,
    required this.emptyText,
    required this.links,
    required this.icon,
    this.onDelete,
    this.onClear,
  });

  final String title;
  final String emptyText;
  final List<WebLink> links;
  final IconData icon;
  final Future<void> Function(WebLink link)? onDelete;
  final Future<void> Function()? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: Row(
                children: <Widget>[
                  Text(title, style: theme.textTheme.titleLarge),
                  const Spacer(),
                  Text('${links.length} 条', style: theme.textTheme.labelMedium),
                  if (onClear != null)
                    IconButton(
                      tooltip: '清空记录',
                      onPressed: () => unawaited(onClear!()),
                      icon: const Icon(Icons.delete_sweep_outlined),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: links.isEmpty
                  ? Center(
                      child: Text(emptyText, style: theme.textTheme.bodyMedium))
                  : ListView.builder(
                      itemCount: links.length,
                      itemBuilder: (context, index) {
                        final link = links[index];
                        return ListTile(
                          leading: Icon(icon, size: 20),
                          title: Text(link.displayTitle,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${link.url}\n${_formatTime(link.createdAt)}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                          isThreeLine: true,
                          onTap: () => Navigator.pop(context, link.url),
                          trailing: onDelete == null
                              ? null
                              : IconButton(
                                  tooltip: '删除',
                                  onPressed: () => unawaited(onDelete!(link)),
                                  icon: const Icon(Icons.close, size: 18),
                                ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatTime(DateTime time) {
    String two(int value) => value < 10 ? '0$value' : '$value';
    return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }
}

/// 网页朗读面板：正文分片 + 队列朗读
class _WebReadSheet extends StatefulWidget {
  const _WebReadSheet({
    required this.title,
    required this.chunks,
    this.subtitle,
    this.autoStart = true,
  });

  final String title;
  final List<String> chunks;

  /// 标题下的一行补充说明
  final String? subtitle;

  /// 打开面板是否立刻开始朗读
  final bool autoStart;

  @override
  State<_WebReadSheet> createState() => _WebReadSheetState();
}

class _WebReadSheetState extends State<_WebReadSheet> {
  final TtsManager _tts = TtsManager.instance;
  final GlobalKey _activeKey = GlobalKey();
  int? _followedIndex;

  @override
  void initState() {
    super.initState();
    // 打开面板即从第一段开始朗读（双击段落进来的也是同一条链路）
    if (widget.autoStart) _tts.speakLines(widget.chunks);
  }

  void _follow(int? index) {
    if (index == null || index == _followedIndex) return;
    _followedIndex = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _activeKey.currentContext;
      if (context == null || !mounted) return;
      Scrollable.ensureVisible(context,
          duration: const Duration(milliseconds: 200), alignment: 0.4);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: _tts,
      builder: (context, _) {
        final active = _tts.plainIndex;
        final playing = _tts.playing;
        final reading = _tts.readingPlain || _tts.speaking;
        if (reading) _follow(active);
        return SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.8,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.volume_up_outlined, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium,
                          ),
                          if (widget.subtitle != null)
                            Text(
                              widget.subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall,
                            ),
                        ],
                      ),
                    ),
                    Text('${widget.chunks.length} 段',
                        style: theme.textTheme.labelMedium),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: widget.chunks.length,
                  itemBuilder: (context, index) {
                    final isActive = reading && index == active;
                    return Padding(
                      key: isActive ? _activeKey : null,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 3),
                      child: InkWell(
                        onTap: () =>
                            _tts.speakLines(widget.chunks, start: index),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: isActive
                                ? scheme.primaryContainer
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            child: Text(
                              widget.chunks[index],
                              style: theme.textTheme.bodyLarge?.copyWith(
                                height: 1.6,
                                color:
                                    isActive ? scheme.onPrimaryContainer : null,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Material(
                color: scheme.surfaceContainerHigh,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: <Widget>[
                        IconButton.filledTonal(
                          tooltip: '重新朗读本页',
                          onPressed: () => _tts.speakLines(widget.chunks),
                          icon: const Icon(Icons.replay),
                        ),
                        IconButton.filled(
                          tooltip: playing ? '暂停' : '播放',
                          iconSize: 30,
                          onPressed: () {
                            if (playing) {
                              _tts.pause();
                            } else if (_tts.speaking && _tts.paused) {
                              _tts.resume();
                            } else {
                              _tts.speakLines(widget.chunks, start: active);
                            }
                          },
                          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                        ),
                        IconButton.filledTonal(
                          tooltip: '停止',
                          onPressed: _tts.stop,
                          icon: const Icon(Icons.stop),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

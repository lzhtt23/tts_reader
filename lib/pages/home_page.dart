import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../features/pdf_reading/open_reading_screen.dart';
import '../features/pdf_reading/pdf_read_session.dart';
import '../models/document.dart';
import '../models/source_rule.dart';
import '../services/crash_log.dart';
import '../services/document_service.dart';
import '../services/file_naming.dart';
import '../services/library_storage.dart';
import '../services/legado_source_store.dart';
import '../services/online_book_downloader.dart';
import '../services/source_client.dart';
import '../services/speak_intake.dart';
import '../services/storage_service.dart';
import 'lan_upload_page.dart';
import '../tts/tts_manager.dart';
import '../widgets/adaptive.dart';
import '../widgets/tutorial_dialog.dart';
import '../widgets/reading_control_bar.dart';
import 'browser_page.dart';
import 'discover_page.dart';
import 'legado_read_page.dart';
import 'settings_page.dart';
import 'speak_now_page.dart';

/// 文档库排序方式（T2S 的「最近」列表）
enum DocumentSort {
  recent('最近阅读', Icons.history),
  imported('导入时间', Icons.schedule),
  title('标题', Icons.sort_by_alpha);

  const DocumentSort(this.label, this.icon);

  final String label;
  final IconData icon;

  /// 下一个排序方式（点一次换一个）
  DocumentSort get next => DocumentSort.values[(index + 1) % DocumentSort.values.length];
}

/// 首页：文档库 / 浏览器 / 设置 三个 Tab
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  /// 文档库搜索行右侧的「导入文件」方形按钮
  ///
  /// 2026-10-18 起导入从右下角悬浮按钮挪到搜索行旁边：控制栏展开时会向
  /// 左铺开，原来的悬浮按钮会被挤走；放这里位置固定，也不挡列表最后几本。
  /// 用例统一用这个 key 找它（别再按 `FloatingActionButton` + 文字找）。
  /// 「更多」菜单（v1.22.76）
  static const Key moreMenuKey = ValueKey<String>('home-more-menu');

  /// 文档库「显示」选择器（列表 / 2 列 / 3 列）
  static const Key layoutSelectorKey = ValueKey<String>('home-layout-selector');

  /// 「继续朗读」卡
  static const Key resumeCardKey = ValueKey<String>('home-resume-card');

  static const Key importButtonKey = ValueKey<String>('library-import');

  /// 书架分类栏（本地 / 在线）
  static const Key shelfTabKey = ValueKey<String>('library-shelf-tab');

  /// 在线书架每行的「下载」键
  static const Key onlineDownloadKey = ValueKey<String>('online-shelf-download');

  /// 「返回朗读页」该跳去哪本书（**纯函数，便于单测钉住**）
  ///
  /// ## ⚠️ 判据必须与控制栏一致：`isPlaybackActive`，不是 `isActive`
  ///
  /// 用户报的现象：**EPUB 正在朗读时，文档库控制栏显示的书名是对的，点进去却跳到 PDF**；
  /// 暂停再进才正常。
  ///
  /// 根因就是这里原来用的是 `pdf.isActive`：
  /// - 控制栏显示走的是 `pdf.isPlaybackActive`（§4.103 的口径：**存在 且 在播/暂停**）→ 显示 EPUB ✅
  /// - 而这里用的是 `pdf.isActive`（只要会话还在就算）→ PDF 被 EPUB 顶停之后它**仍为 true**，
  ///   于是跳转去问它、拿到的是那本**已经停掉的 PDF** ❌
  ///
  /// 两处判据不一致 → 标题与跳转指向两本书。暂停（或停止）之后 PDF 会话真的结束了，
  /// `isActive` 才变 false，所以"暂停再进就正常"。
  ///
  /// `reading_control_bar.dart` 的 `_pickSource` 里有一整段注释专门讲过这个坑，
  /// 但本方法当时漏改了 —— 两处**必须用同一个判据**，改动时请一起看。
  ///
  /// 顺序：PDF 优先（两个来源都可能正在读时，PDF 的位置更"重"，用户刚看过那一页）。
  @visibleForTesting
  static String? readingTargetDocumentId({
    required PdfReadSession pdf,
    required TtsManager tts,
  }) {
    if (pdf.isPlaybackActive) return pdf.documentId;
    return tts.activeDocumentId;
  }

  /// **当前是否有一场朗读正在进行**（导入后要不要自动打开，看它）
  ///
  /// 「进行中」把**暂停**也算进来：暂停时 `TtsManager._speaking` 仍为 true、
  /// `PdfReadSession.isPlaybackActive` 也仍为 true —— 这正是有意的。
  /// 暂停中的会话一样会被"打开另一本书"终止（`terminateForDocumentSwitch`），
  /// 用户回来就续不上了，所以暂停也算忙。
  @visibleForTesting
  static bool readingInProgress({
    required PdfReadSession pdf,
    required TtsManager tts,
  }) {
    return shouldTreatAsReading(
      ttsSpeaking: tts.speaking,
      pdfPlaybackActive: pdf.isPlaybackActive,
    );
  }

  /// 纯判据（便于单测）：任何一个来源在朗读/暂停中 → 算"忙"
  @visibleForTesting
  static bool shouldTreatAsReading({
    required bool ttsSpeaking,
    required bool pdfPlaybackActive,
  }) {
    return ttsSpeaking || pdfPlaybackActive;
  }

  /// **导入完成后是否该自动跳进阅读页**（v1.22.61，用户 2026-10-25 拍板方案①）
  ///
  /// ## 为什么要有这条
  ///
  /// 原来 `_import()` 末尾**无条件** `await _open(stored)` —— 直接跳进新书。
  /// 而进阅读页会走 `TtsManager.loadDocument()` / `PdfReadSession.open()`，
  /// 两者的第一步都是 `terminateForDocumentSwitch(新书 id)`，按"换歌"语义
  /// **终止正在进行的朗读**。于是「朗读中导入一本书」= 朗读被打断，不是偶发。
  ///
  /// 用户要求：朗读时导入只**加入文档库**，不要立即打开。
  ///
  /// 判据：有朗读在进行 → 不自动打开（只入库 + 提示条给「打开」按钮）；
  /// 没有朗读 → 保持原来的"导入即打开"，不改既有手感。
  @visibleForTesting
  static bool shouldAutoOpenAfterImport({
    required bool ttsSpeaking,
    required bool pdfPlaybackActive,
  }) {
    return !shouldTreatAsReading(
      ttsSpeaking: ttsSpeaking,
      pdfPlaybackActive: pdfPlaybackActive,
    );
  }

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // ---------------- Tab 索引（具名常量） ----------------
  //
  // ⚠️ 2026-10-18 从硬编码 0/1/2 改成常量：加「发现」页时 `_index` 的用法
  // 散在 6 处（IndexedStack、_visited、浏览器进度条、AppBar、FAB、宽窄两套
  // destinations），直接平移数字很容易漏一处。以后再加 Tab 只改这里。

  /// 上次构建时用的 index（导航探针用，避免每帧打日志）
  int _lastBuiltIndex = -1;

  /// 文档库（本地书架 + 文档列表）
  static const int _kLibrary = 0;

  /// 发现（搜书源）
  static const int _kDiscover = 1;

  /// 浏览器（内置网页朗读）
  static const int _kBrowser = 2;

  /// 设置
  static const int _kSettings = 3;

  int _index = _kLibrary;

  /// 已访问过的 Tab：未访问的页面不构建，避免启动就初始化 WebView
  final Set<int> _visited = <int>{_kLibrary};
  List<Document> _documents = const <Document>[];
  bool _loading = true;

  /// 在线书架（`OnlineBookRecord`）：只存元数据，正文按需抓
  List<OnlineBookRecord> _onlineBooks = const <OnlineBookRecord>[];

  /// 书架分类：0 = 本地书架，1 = 在线书架
  ///
  /// 用户要求：搜索栏下面加一个分类栏，第一类本地、第二类在线。
  int _shelfTab = 0;

  /// 文档库排序方式（默认最近阅读优先）
  DocumentSort _sort = DocumentSort.recent;

  /// 文档库搜索框（按书名 / 文件名过滤）
  final TextEditingController _search = TextEditingController();

  /// 当前排序结果
  List<Document> get _sorted {
    final documents = List<Document>.of(_documents);
    switch (_sort) {
      case DocumentSort.recent:
        documents.sort((a, b) => b.activityAt.compareTo(a.activityAt));
      case DocumentSort.imported:
        documents.sort((a, b) => b.importedAt.compareTo(a.importedAt));
      case DocumentSort.title:
        documents.sort((a, b) => a.title.compareTo(b.title));
    }
    return documents;
  }

  /// 搜索关键字（已去空白、转小写）
  String get _keyword => _search.text.trim().toLowerCase();

  /// 搜索命中的文档：书名优先，另外也匹配文件名
  ///
  /// 有些文档的书名与文件名不一致（比如导入时用的是选择器报的名字），
  /// 两个都匹配才不会出现「明明有这本书却搜不到」。
  bool _matches(Document document, String keyword) {
    if (keyword.isEmpty) return true;
    if (document.title.toLowerCase().contains(keyword)) return true;
    final fileName = FileNaming.baseName(document.path).toLowerCase();
    return fileName.contains(keyword);
  }

  /// 排序 + 搜索过滤后的列表（界面用它渲染）
  List<Document> get _visible {
    final keyword = _keyword;
    final documents = _sorted;
    if (keyword.isEmpty) return documents;
    return documents.where((document) => _matches(document, keyword)).toList();
  }

  /// 超过该体积的文件导入时给出提示（解析很慢，且占用内存高）
  static const int _largeFileBytes = 80 * 1024 * 1024;

  /// 解析缓存目录（首次求值后记住）
  String? _cacheDirValue;

  /// 浏览器页的 Key（用它转调「回到主界面」）
  ///
  /// 地址栏现在渲染在浏览器页内部（主界面搜索栏上方那一行），
  /// HomePage 只需要在从浏览器 Tab 切走时把它叫回主界面。
  final GlobalKey<BrowserPageState> _browserKey = GlobalKey<BrowserPageState>();

  @override
  void initState() {
    super.initState();
    _load();
    // 首次使用弹教程：必须等首帧之后才弹（initState 里拿不到 Navigator）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(TutorialDialog.maybeShow(context));
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // ---------------- 底部朗读控制栏 ----------------

  /// 「返回朗读页」该跳去哪本书 —— 判据见 [HomePage.readingTargetDocumentId]
  Future<void> _openReadingPage() async {
    final messenger = ScaffoldMessenger.of(context);
    final id = HomePage.readingTargetDocumentId(
      pdf: PdfReadSession.instance,
      tts: TtsManager.instance,
    );
    if (id == null) {
      messenger.showSnackBar(const SnackBar(content: Text('当前朗读的是文本片段，没有对应的阅读页')));
      return;
    }
    final matches = _documents.where((document) => document.id == id).toList();
    if (matches.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('这本书已从文档库移除')));
      return;
    }
    await _open(matches.first);
  }

  Future<void> _load() async {
    final documents = await StorageService.instance.loadDocuments();
    final online = await LegadoSourceStore.instance.loadBooks();
    if (!mounted) return;
    setState(() {
      _documents = documents;
      _onlineBooks = online;
      _loading = false;
    });
    // 保险：老文档（在「下载入库补封面」之前进来的）可能还没有封面，
    // 这里顺手补一轮。每本只试一次（`_coverTried`），失败不会反复重试。
    unawaited(_backfillMissingCovers(documents));
  }

  /// 本次会话里已经试过补封面的文档（避免每次刷新都重试失败项）
  final Set<String> _coverTried = <String>{};

  /// 给「没有封面」的文档补封面（串行，最多 [maxPerRound] 本）
  ///
  /// 为什么要限量：文档库可能有一堆旧书，一次全解析会卡住界面
  /// （PDF 抽封面要真渲染一页）。
  Future<void> _backfillMissingCovers(
    List<Document> documents, {
    int maxPerRound = 3,
  }) async {
    var done = 0;
    for (final Document d in documents) {
      if (done >= maxPerRound) break;
      if ((d.coverPath ?? '').isNotEmpty) continue;
      if (!_coverTried.add(d.id)) continue;
      done++;
      await _backfillCover(d);
    }
  }

  /// 解析缓存目录（删除文档时用来清缓存；拿不到就返回空串）
  Future<String> _cacheDir() async {
    final cached = _cacheDirValue;
    if (cached != null) return cached;
    String dir;
    try {
      dir = await DocumentService.cacheDirectory();
    } catch (_) {
      dir = '';
    }
    _cacheDirValue = dir;
    return dir;
  }

  /// 导入本地 PDF / EPUB / TXT：只登记元数据，正文在打开时后台解析
  /// 局域网传书：手机起 HTTP 服务，电脑浏览器拖文件进来（v1.22.70）
  Future<void> _openLanUpload() async {
    final int? imported = await Navigator.of(context).push<int>(
      MaterialPageRoute<int>(builder: (_) => const LanUploadPage()),
    );
    if (!mounted || imported == null || imported <= 0) return;
    // 传进来的书直接进库：清掉搜索过滤并重新读一遍，避免用户以为没收到
    if (_search.text.isNotEmpty) _search.clear();
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已从电脑接收 $imported 本书')),
    );
  }

  Future<void> _import() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['pdf', 'epub', 'txt'],
      allowMultiple: false,
    );
    final files = result?.files ?? const <PlatformFile>[];
    if (files.isEmpty) return;
    final picked = files.first;
    final path = picked.path;
    if (path == null || path.isEmpty) return;

    final file = File(path);
    final size = await file.exists() ? await file.length() : 0;
    if (size > _largeFileBytes && mounted) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('文件较大'),
          content: Text(
            '该文件约 ${(size / (1024 * 1024)).toStringAsFixed(1)} MB，解析时间较长且占用内存较高。\n'
            '解析在后台线程进行，界面不会卡住，也可以随时返回取消。',
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('继续导入')),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    final document = Document(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      // 书名用选择器报的**原始文件名**：Android 上 picker 会把文件复制到缓存目录，
      // 万一缓存副本的名字被改过（或退回 "unamed"），至少书名还是用户看到的那样
      title: picked.name.trim().isEmpty
          ? DocumentService.titleFromPath(path)
          : FileNaming.titleOf(picked.name),
      path: path,
      type: DocumentType.fromExtension(path),
      importedAt: DateTime.now(),
    );
    // 收进应用私有目录：picker 给的是缓存副本，系统清缓存后书就打不开了。
    // 复制保持原名，失败也照常导入（只是引用外部路径）。
    final adopted = await LibraryStorage.adopt(path, name: picked.name);
    final stored = adopted.path.isEmpty || adopted.path == path
        ? document
        : document.copyWith(path: adopted.path, type: DocumentType.fromExtension(adopted.path));
    if (!adopted.ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('复制到应用目录失败（${adopted.error}），将直接引用原文件')),
      );
    }
    await StorageService.instance.upsertDocument(stored);
    // 清掉搜索过滤：刚导入的书不一定匹配当前关键字，别让用户以为没导进来
    if (_search.text.isNotEmpty) _search.clear();
    await _load();
    if (!mounted) return;
    // 注意：后面一律用 stored —— 阅读页解析完会把「进度 / 封面」回写文档库，
    // 用旧对象（缓存路径）打开会把刚存好的书库路径覆盖掉
    unawaited(_backfillCover(stored));
    // ★v1.22.61（用户 2026-10-25 拍板方案①）：**朗读进行中就不要自动打开新书**。
    //
    // 进阅读页会 `terminateForDocumentSwitch(新书id)` —— 按"换歌"语义
    // **终止正在进行的朗读**。所以朗读中导入 = 朗读被打断（确定行为，不是偶发）。
    //
    // 用户要求：朗读时导入只加入文档库、不立即打开，避免打断朗读。
    // 没在朗读时保持原来的"导入即打开"，不动既有手感。
    if (!HomePage.shouldAutoOpenAfterImport(
      ttsSpeaking: TtsManager.instance.speaking,
      pdfPlaybackActive: PdfReadSession.instance.isPlaybackActive,
    )) {
      CrashLog.mark('文档库[导入完成] 正在朗读 → 不自动打开 '
          'ttsSpeaking=${TtsManager.instance.speaking} '
          'pdfPlayback=${PdfReadSession.instance.isPlaybackActive} '
          '新书=${stored.id}/${stored.title}');
      // ★v1.22.61：提示条**必须自己消失**（用户 2026-10-25 明确要求"不要一直显示"）。
      //
      // ## ⚠️ 光设 `duration` 不够 —— 真机实证
      //
      // 平板实测（联想 TB335FC）：
      // ```
      // accessibility_enabled=1
      // enabled_services=li.songe.gkd/...SelectToSpeakService
      // ```
      // 开启无障碍服务后 Flutter 的 `MediaQuery.accessibleNavigation` 为真，
      // 而 `ScaffoldMessenger` 在那种模式下**直接忽略 `SnackBar.duration`**
      // （把它当成"需要用户读完/手动关闭"的语义）→ 提示条**永远不消失**。
      // 这就是用户报的"一直显示"，与时长设 4s 还是 8s 无关。
      //
      // 修法：**不依赖 duration**，自己起一个定时器调 `controller.close()`。
      // 用 controller 而不是 `hideCurrentSnackBar()`，是为了只关掉**这一条** ——
      // 否则会误关掉 4 秒内新弹出来的其它提示。
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      final controller = messenger.showSnackBar(
        SnackBar(
          content: const Text('已加入文档库（正在朗读，未打开）'),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: '打开',
            // 用户明确要打开时才跳 —— 此时打断朗读是用户自己的选择
            onPressed: () => unawaited(_open(stored)),
          ),
        ),
      );
      // 无障碍模式下 duration 失效 → 用定时器兜底强制收起
      unawaited(
        Future<void>.delayed(const Duration(seconds: 4), () {
          try {
            controller.close();
          } catch (_) {
            // 已经被用户点掉 / 页面已销毁：忽略
          }
        }),
      );
      return;
    }
    await _open(stored);
  }

  /// 后台抽取 / 生成封面并回写文档库
  ///
  /// 需求「自动解析文件（PDF，TXT，EPUB）封面，没有就使用默认样式」：
  /// - EPUB 抽自带封面；PDF / TXT 拿不到图源时由 [DocumentService.extractCover]
  ///   生成默认样式封面（所以这里不再限定 EPUB）；
  /// - 已有封面就跳过，不重复生成。
  Future<void> _backfillCover(Document document) async {
    if ((document.coverPath ?? '').isNotEmpty) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cover = await DocumentService.extractCover(
        document,
        '${dir.path}/covers/${document.id}.jpg',
      );
      if (cover == null) return;
      await StorageService.instance.upsertDocument(document.copyWith(coverPath: cover));
      if (mounted) await _load();
    } catch (_) {
      // 忽略：封面失败不影响使用
    }
  }

  /// 打开并**直接开读**（文档库「继续朗读」卡的播放键，v1.22.76）
  Future<void> _openAndSpeak(Document document) async {
    final NavigatorState navigator = Navigator.of(context);
    await navigator.push(MaterialPageRoute<void>(
      builder: (_) => openReadingScreen(document, autoSpeak: true),
    ));
    await _load();
  }

  Future<void> _open(Document document) async {
    final navigator = Navigator.of(context);
    await navigator.push(MaterialPageRoute<void>(
      builder: (_) => openReadingScreen(document),
    ));
    await _load(); // 返回后刷新阅读进度 / 封面
  }

  /// 打字朗读：进入即读页，输入或粘贴文本后朗读
  void _openTypeSpeak() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SpeakNowPage(source: SpeakSource.type)),
    );
  }

  /// 剪贴板朗读：读系统剪贴板里的文本并立刻开始朗读
  Future<void> _speakClipboard() async {
    String text = '';
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text?.trim() ?? '';
    } catch (_) {
      text = '';
    }
    if (!mounted) return;
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('剪贴板里没有文本')));
      return;
    }
    // 走统一入口：与分享 / 划词同一条链路，界面由 app 级监听打开即读页
    SpeakIntake.instance.submit(text, SpeakSource.clipboard);
  }

  Future<void> _delete(Document document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除文档'),
        content: Text(
          '确定从文档库移除「${document.title}」吗？\n'
          '导入时复制进来的副本会一起删除，外部原文件不受影响。',
        ),
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
    final remaining = await StorageService.instance.removeDocument(document.id);
    // 书库副本跟着删掉（下载目录 / 外部原文件不动）；同一份副本被别的文档共用时保留
    if (!remaining.any((item) => item.path == document.path)) {
      await LibraryStorage.release(document.path);
    }
    // 解析缓存也一起清掉，否则缓存目录只增不减
    DocumentService.dropCache(await _cacheDir(), document.id);
    // 书签跟着文档一起清理，否则书签面板里会留一堆点不开的条目
    await StorageService.instance.removeDocBookmarksOf(document.id);
    // 删的是本地那份：把在线书架里指向它的「已下载」标记清掉。
    // ⚠️ **只清标记，不移出书架**（用户明确要求）——之后点开回到在线阅读。
    final int cleared =
        await LegadoSourceStore.instance.detachLocalDocumentByDocumentId(
      document.id,
    );
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          cleared > 0
              ? '已移除「${document.title}」（在线书架里那本还在，点开会在线阅读）'
              : '已移除「${document.title}」',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWideLayout(context);
    // 导航探针：只在**真正换页**时记一行，避免每帧刷屏。
    // 重点看「构建时 index 是多少」——如果点击后出现 index 与目标不符的构建，
    // 就说明有别的路径改动了 _index（例如某处写死了数字）。
    if (_lastBuiltIndex != _index) {
      CrashLog.mark(
        '导航[构建] index=$_index(${_tabName(_index)}) 上次=$_lastBuiltIndex '
        '已建=${_visited.map(_tabName).join(",")}',
      );
      _lastBuiltIndex = _index;
    }
    final body = IndexedStack(
      index: _index,
      children: <Widget>[
        _libraryView(),
        if (_visited.contains(_kDiscover))
          const DiscoverPage()
        else
          const SizedBox.shrink(),
        if (_visited.contains(_kBrowser))
          BrowserPage(key: _browserKey)
        else
          const SizedBox.shrink(),
        if (_visited.contains(_kSettings))
          SettingsPage(onOpenUrl: _openInBrowser)
        else
          const SizedBox.shrink(),
      ],
    );
    // 浏览器的地址栏与前进/后退已经**渲染在 AppBar 里**（与标题同层），
    // 所以页面内容不再需要为它让高度 —— 只需要给加载进度条留 2px。
    final below = _index == _kBrowser ? BrowserPage.progressBarHeight : 0.0;
    //
    // ★v1.21.99：**必须始终用同一个 Padding 包裹**，不能 `below == 0 ? body : Padding(...)`。
    //
    // 真机探针日志（2026-10-19 02:09）暴露了后者的问题：
    // ```
    // 导航[构建] index=2(浏览器) 上次=0
    // 页面[发现] initState（首次构建）      ← 切到浏览器时发现页被重建了
    // 导航[构建] index=3(设置) 上次=2
    // 页面[发现] initState（首次构建）      ← 切到设置时又重建一次
    // ```
    // 原因：切到/离开浏览器时 `below` 在 0 与 2.0 之间变，外层 widget 的**类型**
    // 跟着在 `IndexedStack` 与 `Padding(IndexedStack)` 之间切换 —— 类型变了，
    // 整棵子树被卸载重建，四个页面全部重来一遍（既闪、又重复 initState）。
    // 现在结构恒定，只改 padding 数值。
    final paddedBody = Padding(
      padding: EdgeInsets.only(top: below),
      child: body,
    );
    final rail = NavigationRail(
      selectedIndex: _index,
      onDestinationSelected: _selectTab,
      labelType: NavigationRailLabelType.all,
      destinations: const <NavigationRailDestination>[
        NavigationRailDestination(
          icon: Icon(Icons.library_books_outlined),
          selectedIcon: Icon(Icons.library_books),
          label: Text('文档库'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.explore_outlined),
          selectedIcon: Icon(Icons.explore),
          label: Text('发现'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.public_outlined),
          selectedIcon: Icon(Icons.public),
          label: Text('浏览器'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: Text('设置'),
        ),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        // 标题永远是应用自己的标题：浏览器的地址栏已经移到页面里
        // （主界面在搜索栏上方那一行，见 BrowserPage._addressRow），
        // AppBar 只负责标题，不再塞工具栏。
        title: Text(switch (_index) {
          _kLibrary => '文档库',
          _kDiscover => '发现',
          _kBrowser => '浏览器',
          _ => '设置',
        }),
        actions: <Widget>[
          if (_index == _kLibrary) ...<Widget>[
            // ★v1.22.76：顶栏从 5 个图标收敛到 2 个（用户 2026-11-22 确认）
            //
            // 原来打字朗读 / 剪贴板 / 排序 / 局域网 / 刷新 五个并列摆在标题右边，
            // 一级界面上一排图标，主次不分。现在只留「导入」和「更多」，
            // 其余进菜单 —— 功能一个不少，只是收起来。
            // 空库时中央已有「导入文件」引导按钮，顶栏不必再来一个
            if (_documents.isNotEmpty)
              IconButton(
                key: HomePage.importButtonKey,
                tooltip: '导入文件',
                onPressed: _import,
                icon: const Icon(Icons.add),
              ),
            PopupMenuButton<String>(
              key: HomePage.moreMenuKey,
              tooltip: '更多',
              icon: const Icon(Icons.more_vert),
              onSelected: (String value) {
                switch (value) {
                  case 'type':
                    _openTypeSpeak();
                  case 'clipboard':
                    _speakClipboard();
                  case 'lan':
                    _openLanUpload();
                  case 'sort':
                    setState(() => _sort = _sort.next);
                  case 'refresh':
                    _load();
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(
                  value: 'type',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.record_voice_over_outlined),
                    title: Text('打字朗读'),
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'clipboard',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.content_paste_go),
                    title: Text('朗读剪贴板'),
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'lan',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.wifi_tethering),
                    title: Text('局域网传书'),
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem<String>(
                  value: 'sort',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_sort.icon),
                    title: Text('排序：${_sort.label}'),
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'refresh',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.refresh),
                    title: Text('刷新'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      // 宽屏（平板横屏 / 桌面）改成左侧导航栏：底部导航在横屏下离拇指太远
      body: wide
          ? Row(children: <Widget>[rail, const VerticalDivider(width: 1), Expanded(child: paddedBody)])
          : paddedBody,
      // 胶片（朗读控制栏）从右下角发起：展开时向左延伸成一条（见 ReadingControlBar）
      floatingActionButton: _index == _kLibrary
          ? ReadingControlBar(
              onReturnToReading: _openReadingPage,
              onOpenSettings: () => _selectTab(_kSettings),
              // 迷你条的封面：按文档 id 查库里的封面路径（查不到就用占位图）
              coverPathOf: (documentId) {
                if (documentId == null || documentId.isEmpty) return null;
                for (final doc in _documents) {
                  if (doc.id == documentId) return doc.coverPath;
                }
                return null;
              },
            )
          : null,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _selectTab,
              destinations: const <NavigationDestination>[
                NavigationDestination(
                  icon: Icon(Icons.library_books_outlined),
                  selectedIcon: Icon(Icons.library_books),
                  label: '文档库',
                ),
                NavigationDestination(
                  icon: Icon(Icons.explore_outlined),
                  selectedIcon: Icon(Icons.explore),
                  label: '发现',
                ),
                NavigationDestination(
                  icon: Icon(Icons.public_outlined),
                  selectedIcon: Icon(Icons.public),
                  label: '浏览器',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: '设置',
                ),
              ],
            ),
    );
  }

  /// 切换 Tab（底部导航与侧边导航共用）
  void _selectTab(int index) {
    // 导航探针（用户报「点别的 Tab 会先抽出发现页」）：
    // 记录「谁请求切到哪、当时在哪、已经建过哪些页」。
    // 只有真机日志能说清那次闪，所以先把证据留足。
    CrashLog.mark(
      '导航[点击] 目标=${_tabName(index)}($index) 当前=${_tabName(_index)}($_index) '
      '已建=${_visited.map(_tabName).join(",")}',
    );
    setState(() {
      _index = index;
      _visited.add(index);
    });
    CrashLog.mark('导航[切换完成] index=$_index(${_tabName(_index)})');
    if (index == _kLibrary) _load(); // 浏览器里导入的文档回到文档库时可见
  }

  /// Tab 名字（日志与探针用）
  String _tabName(int index) => switch (index) {
    _kLibrary => '文档库',
    _kDiscover => '发现',
    _kBrowser => '浏览器',
    _kSettings => '设置',
    _ => '未知$index',
  };

  /// 在**应用内浏览器**里打开一个网址（设置页「项目主页」等入口用）
  ///
  /// ⚠️ 顺序有讲究：IndexedStack 里的 BrowserPage 是**懒建**的
  /// （`_visited` 控制），所以必须先切到浏览器 Tab 把它建出来，
  /// 否则 `_browserKey.currentState` 还是 null，`submitAddress` 会落空。
  /// 又因为建出来要等这一帧结束，所以真正打开放在下一帧的回调里。
  ///
  /// ⚠️ 这里**必须用 `_kBrowser`，不能写死 1**：加「发现」页之后 1 已经
  /// 变成发现页了。写死 1 的后果是「从设置里打开网址 → 先闪一下发现页 →
  /// 浏览器页根本没建出来 → 网址打不开」。
  void _openInBrowser(String url) {
    _selectTab(_kBrowser);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _browserKey.currentState?.submitAddress(url);
    });
  }

  // ---------------- 文档库 ----------------

  Widget _libraryView() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_documents.isEmpty) {
      final scheme = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.menu_book_outlined, size: 72, color: scheme.outline),
            const SizedBox(height: 16),
            Text('文档库还是空的', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '支持 PDF / EPUB / TXT，导入后即可朗读',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              // 空库时这里是唯一入口；非空库时同一个 key 落在搜索行右侧的方形按钮上
              //（两者互斥，不会同时出现，所以 key 不冲突）
              key: HomePage.importButtonKey,
              onPressed: _import,
              icon: const Icon(Icons.add),
              label: const Text('导入文件'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _openTypeSpeak,
              icon: const Icon(Icons.record_voice_over_outlined),
              label: const Text('打字朗读一段文本'),
            ),
          ],
        ),
      );
    }
    final documents = _visible;
    // 搜索栏固定在列表上方（滚动时不跟着走），空库时不显示
    return Column(
      children: <Widget>[
        _librarySearchBar(),
        _shelfTabBar(),
        Expanded(
          child: _shelfTab == 0
              ? (documents.isEmpty ? _noMatchView() : _libraryList(documents))
              : _onlineShelfView(),
        ),
      ],
    );
  }

  /// 书架分类栏：本地书架 / 在线书架
  ///
  /// 用 `SegmentedButton` 而不是 TabBar：两个分类是**同一页的两种视图**，
  /// 不是两套独立页面；Segmented 也更符合「筛选」的语义，且窄屏不挤。
  Widget _shelfTabBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SegmentedButton<int>(
              key: HomePage.shelfTabKey,
              showSelectedIcon: false,
              segments: <ButtonSegment<int>>[
                ButtonSegment<int>(
                  value: 0,
                  icon: const Icon(Icons.folder_outlined, size: 18),
                  label: Text('本地书架（${_documents.length}）'),
                ),
                ButtonSegment<int>(
                  value: 1,
                  icon: const Icon(Icons.cloud_outlined, size: 18),
                  label: Text('在线书架（${_onlineBooks.length}）'),
                ),
              ],
              selected: <int>{_shelfTab},
              onSelectionChanged: (Set<int> v) => setState(() => _shelfTab = v.first),
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 在线书架列表
  Widget _onlineShelfView() {
    final ThemeData theme = Theme.of(context);
    if (_onlineBooks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.cloud_outlined, size: 64, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text('在线书架是空的', style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                '去「发现」搜一本书，在详情页点「放入书架」',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: () => _selectTab(_kDiscover),
                icon: const Icon(Icons.explore_outlined, size: 18),
                label: const Text('去发现'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
      itemCount: _onlineBooks.length,
      itemBuilder: (context, index) {
        final OnlineBookRecord book = _onlineBooks[index];
        return Card.filled(
          margin: const EdgeInsets.only(bottom: 12),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: Icon(Icons.cloud_outlined, color: theme.colorScheme.primary),
            title: Text(book.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Row(
              children: <Widget>[
                if (book.isDownloaded) ...<Widget>[
                  // 已经整本下好了：点开读本地那份，不再联网
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '已下载',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    <String>[
                      if (book.author.trim().isNotEmpty) book.author.trim(),
                      if (book.chapterName.trim().isNotEmpty)
                        '读到：${book.chapterName.trim()}',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // 下载键（用户要求：在线书架每行要有下载）
                // 已整本下好的**置灰**：不能再下一次（用户要求不可重复下载）
                IconButton(
                  key: HomePage.onlineDownloadKey,
                  tooltip: book.isDownloaded ? '已下载' : '下载整本',
                  icon: Icon(
                    book.isDownloaded
                        ? Icons.download_done
                        : Icons.download_outlined,
                  ),
                  onPressed: book.isDownloaded
                      ? null
                      : () => _downloadOnlineBook(book),
                ),
                IconButton(
                  tooltip: '从书架移除',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => _removeOnlineBook(book),
                ),
              ],
            ),
            onTap: () => _openOnlineBook(book),
          ),
        );
      },
    );
  }

  /// 从在线书架移除（只删记录，不动本地文件）
  Future<void> _removeOnlineBook(OnlineBookRecord book) async {
    await LegadoSourceStore.instance.removeBook(book.url);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已从在线书架移除「${book.name}」')),
    );
  }

  /// 打开在线书架里的一本
  ///
  /// **优先本地**（用户要求）：如果这本已经整本下载过，就直接打开本地那份，
  /// 不再联网解析 —— 已经下好的书再去在线抓一遍既慢又可能失败。
  /// 本地那份若已被用户删掉，就退回在线阅读。
  Future<void> _openOnlineBook(OnlineBookRecord book) async {
    if (book.isDownloaded) {
      final List<Document> docs = await StorageService.instance.loadDocuments();
      Document? local;
      for (final Document d in docs) {
        if (d.id == book.localDocumentId) {
          local = d;
          break;
        }
      }
      if (!mounted) return;
      if (local != null) {
        await _open(local);
        return;
      }
      // 本地文件被删了：退回在线读，并顺手清掉那条失效标记
      await LegadoSourceStore.instance.attachLocalDocument(
        bookUrl: book.url,
        documentId: '',
      );
      if (!mounted) return;
    }

    final SourceRule? rule =
        await OnlineBookDownloader.sourceOf(book.sourceUrl);
    if (!mounted) return;
    if (rule == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这个书源已经被删了，读不了这本')),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LegadoReadPage(
          source: rule,
          book: OnlineBook(
            name: book.name,
            url: book.url,
            author: book.author,
            coverUrl: book.coverUrl,
            lastChapter: book.chapterName,
          ),
          initialChapter: book.chapterIndex,
        ),
      ),
    );
    if (mounted) await _load();
  }

  /// 在线书架里的「下载」键：整本拉下来进文档库
  ///
  /// 与详情页那个下载共用 [OnlineBookDownloader]，进度会出现在
  /// 发现页的「下载列表」里。
  Future<void> _downloadOnlineBook(OnlineBookRecord book) async {
    // 已下载过就别再抓一遍（用户要求「已下载的书不可重复下载」）
    final String? existing =
        await OnlineBookDownloader.downloadedDocId(book.url);
    if (!mounted) return;
    if (existing != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('「${book.name}」已经下载过了，去文档库里读')),
      );
      await _load();
      return;
    }
    final SourceRule? rule =
        await OnlineBookDownloader.sourceOf(book.sourceUrl);
    if (!mounted) return;
    if (rule == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这个书源已经被删了，下不了这本')),
      );
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text('开始下载「${book.name}」，进度见发现页的下载列表')),
    );
    try {
      await OnlineBookDownloader.download(
        source: rule,
        book: OnlineBook(
          name: book.name,
          url: book.url,
          author: book.author,
          coverUrl: book.coverUrl,
          lastChapter: book.chapterName,
        ),
      );
      messenger.showSnackBar(
        SnackBar(content: Text('「${book.name}」已下载，加入文档库')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('下载失败：$e')),
      );
    }
    if (mounted) await _load();
  }

  /// 文档库搜索栏
  ///
  /// 版式（2026-10-18 改）：**圆角矩形搜索框 + 右侧方形「＋」导入键**。
  /// 导入原来是个右下角的悬浮按钮，展开的控制栏一拉宽就把它挤走了；
  /// 现在挪到搜索行右边，位置固定、也不会挡住列表最后几本。
  Widget _librarySearchBar() {
    final theme = Theme.of(context);
    final searching = _keyword.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索书名或文件名',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: searching
                    ? IconButton(
                        tooltip: '清空',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _search.clear();
                          setState(() {});
                        },
                      )
                    : null,
                helperText: searching
                    ? (() {
                        final count = _visible.length;
                        return count == 0 ? '没有匹配的文档' : '找到 $count 本';
                      })()
                    : null,
                // 圆角矩形（原来是没有圆角的 OutlineInputBorder）
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              style: theme.textTheme.bodyMedium,
            ),
          ),
          // v1.22.76：这里原来有个大「+」导入按钮，顶栏现在也有了 ——
          // 两个并排重复。导入入口统一收到顶栏（见 AppBar 的 actions）。
        ],
      ),
    );
  }

  /// 搜索无结果
  Widget _noMatchView() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.search_off, size: 56, color: scheme.outline),
          const SizedBox(height: 12),
          Text('没有匹配的文档', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('试试书名里的其它字，或者清空搜索', style: theme.textTheme.bodySmall),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: () {
              _search.clear();
              setState(() {});
            },
            icon: const Icon(Icons.close, size: 18),
            label: const Text('清空搜索'),
          ),
        ],
      ),
    );
  }

  /// 当前该用几列（v1.22.76）
  ///
  /// 顺序：用户手选 > 按宽度自动。
  /// 自动档的断点是按「一列至少 150dp 才看得清封面」定的：
  /// 600 以下单列、600~840 三列、840~1100 四列、再宽五列。
  int _resolveColumns(BuildContext context) {
    final String pref = StorageService.instance.libraryLayout.value;
    if (pref == 'list') return 1;
    if (pref == 'c2') return 2;
    if (pref == 'c3') return 3;
    final double w = MediaQuery.sizeOf(context).width;
    if (w >= 1100) return 5;
    if (w >= 840) return 4;
    if (w >= 600) return 3;
    return 1;
  }

  /// 文档库列表：继续朗读卡 + 显示选择器 + 书列表/网格（v1.22.76）
  ///
  /// 用一个 `CustomScrollView` 把三块串起来：顶部两块是"头"，后面才是书。
  /// 这样滚动时头会跟着走，书多了不会把它们钉死在上面。
  Widget _libraryList(List<Document> documents) {
    // 监听显示方式：用户点「2 列 / 3 列」时 `setLibraryLayout` 只改 notifier，
    // 不监听的话值变了界面不重建（点了没反应）；auto 跟随宽度变化也靠这里。
    return ValueListenableBuilder<String>(
      valueListenable: StorageService.instance.libraryLayout,
      builder: (BuildContext context, String _, Widget? __) {
        return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = _resolveColumns(context);
        // 网格单元尺寸：宽度均分，高度 = 封面(3:4) + 书名两行 + 进度条
        const double hPad = 12;
        const double gap = 12;
        final double cellW =
            (constraints.maxWidth - hPad * 2 - gap * (columns - 1)) / columns;
        final double cellH = cellW * 4 / 3 + 58;

        return CustomScrollView(
          slivers: <Widget>[
            // 搜索中不显示「继续朗读」：它会显示一本**不匹配关键字**的书，
            // 与"过滤后只看到相关书"的预期冲突（用例也据此判定过滤生效）。
            if (_search.text.trim().isEmpty)
              SliverToBoxAdapter(child: _resumeCard()),
            SliverToBoxAdapter(child: _layoutSelector(columns, documents.length)),
            if (columns == 1)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(hPad, 0, hPad, 96),
                sliver: SliverList.builder(
                  itemCount: documents.length,
                  itemBuilder: (BuildContext context, int index) =>
                      _listRow(documents[index]),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(hPad, 0, hPad, 96),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: gap,
                    mainAxisSpacing: 14,
                    mainAxisExtent: cellH,
                  ),
                  itemCount: documents.length,
                  itemBuilder: (BuildContext context, int index) =>
                      _gridCard(documents[index]),
                ),
              ),
          ],
        );
      },
    );
      },
    );
  }

  /// 这本书「读到哪里」的统一口径（v1.22.78）
  ///
  /// PDF 的进度存在 `pdfReadingSpots`（按 documentId 的页/句），
  /// 而 `Document.progress` 那条字段 PDF 从来不用 —— 直接用 progress 显示
  /// 就会出现「明明读到第 12 页，列表写 0%」。这里折算一次，全页共用。
  ({String text, double value}) _readingProgress(Document document) {
    if (document.type == DocumentType.pdf) {
      final spot = StorageService.instance.pdfReadingSpot(document.id);
      if (spot != null) {
        final int page = spot.pageIndex + 1; // 内部 0 起，显示 1 起
        final int? total = spot.pageCount;
        if (total != null && total > 0) {
          final double v = (page / total).clamp(0.0, 1.0);
          // 不带动词：调用处自己拼（续读卡是"上次读到 · 14 / 319 页"，
          // 列表行是"PDF · 14 / 319 页"），否则会出现"读到 · 读到"重复。
          return (text: '$page / $total 页', value: v);
        }
        return (text: '第 $page 页', value: 0);
      }
    }
    return (
      text: '进度 ${(document.progress * 100).round()}%',
      value: document.progress,
    );
  }

  /// 「继续朗读」卡：最近读过、且没读完的那本（v1.22.76）
  ///
  /// 为什么值得占首屏一块：文档库最高频的动作就是「接着上次读」，
  /// 而书一多就得靠找。没有符合条件的书时整块不渲染（不占位）。
  Widget _resumeCard() {
    Document? target;
    for (final Document d in _documents) {
      if (d.lastReadAt == null) continue;
      if ((target == null) || d.lastReadAt!.isAfter(target.lastReadAt!)) {
        target = d;
      }
    }
    if (target == null) return const SizedBox.shrink();
    final Document doc = target;
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final ({String text, double value}) read = _readingProgress(doc);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Material(
        key: HomePage.resumeCardKey,
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _open(doc),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: <Widget>[
                _cover(doc, width: 44, height: 58),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        doc.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        // 进度为 0 的书说"上次读到"别扭（其实还没读）——按实际状态换措辞
                        '${read.value > 0 ? '上次读到 · ${read.text}' : '上次打开'}'
                        ' · ${_relativeTime(doc.lastReadAt!)}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // 直接开读：相当于"点开这本书并开始朗读"
                IconButton.filled(
                  tooltip: '继续朗读',
                  onPressed: () => _openAndSpeak(doc),
                  icon: const Icon(Icons.play_arrow),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 显示方式选择器：列表 / 2 列 / 3 列（v1.22.76）
  ///
  /// ⚠️ 用 `Wrap` 不用 `Row`：320dp 窄屏上「显示」+ 三个胶囊 + 本数放不下，
  /// `Row` 直接溢出（窄屏巡检用例会红）。Wrap 放不下就折行，不挤。
  Widget _layoutSelector(int current, int count) {
    final ThemeData theme = Theme.of(context);
    Widget chip(String label, String value, IconData icon, bool selected) {
      return Padding(
        padding: const EdgeInsets.only(right: 6, bottom: 4),
        child: ChoiceChip(
          label: Text(label),
          avatar: Icon(icon, size: 15),
          selected: selected,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          onSelected: (_) =>
              StorageService.instance.setLibraryLayout(value),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Wrap(
        key: HomePage.layoutSelectorKey,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 10, bottom: 4),
            child: Text('显示', style: theme.textTheme.labelMedium),
          ),
          // 高亮看**实际生效**的列数，不看存的值：auto 时存的是 'auto'，
          // 但用户看到的是某一列，那个就得亮起来（否则三个都不亮，像没选中）。
          chip('列表', 'list', Icons.view_list_outlined, current == 1),
          chip('2 列', 'c2', Icons.view_column_outlined, current == 2),
          chip('3 列', 'c3', Icons.grid_view_outlined, current == 3),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '$count 本',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
        ],
      ),
    );
  }

  /// 单列行（默认形态）
  Widget _listRow(Document document) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final ({String text, double value}) read = _readingProgress(document);
    final String pctLabel = read.value <= 0
        ? ''
        : '${(read.value * 100).round()}%';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _open(document),
          // 删除原来是一个常驻按钮（占地方、又容易误点），改成**长按**：
          // 想删的人会去长按，只想读的人不会被一个垃圾桶一直杵在右边打扰。
          onLongPress: () => _delete(document),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(11, 9, 8, 9),
            child: Row(
              children: <Widget>[
                _cover(document, width: 50, height: 66),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      SizedBox(
                        height: 34,
                        child: Text(
                          document.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            height: 1.26,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${document.type.label} · ${read.text}'
                        '${document.lastReadAt == null ? '' : ' · ${_relativeTime(document.lastReadAt!)}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: read.value,
                                minHeight: 3,
                                backgroundColor: scheme.outlineVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 7),
                          Text(
                            pctLabel,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: scheme.outline),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 网格单元（2 列 / 3 列 / 平板多列）
  Widget _gridCard(Document document) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final ({String text, double value}) read = _readingProgress(document);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double w = constraints.maxWidth;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 封面占满宽度，按 3:4 撑高（与预览一致）
            Expanded(
              child: GestureDetector(
                onTap: () => _open(document),
                onLongPress: () => _delete(document),
                child: _cover(document, width: w, height: w * 4 / 3, radius: 9),
              ),
            ),
            const SizedBox(height: 7),
            GestureDetector(
              onTap: () => _open(document),
              onLongPress: () => _delete(document),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    height: 30,
                    child: Text(
                      document.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.26,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: read.value,
                            minHeight: 3,
                            backgroundColor: scheme.outlineVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        read.value <= 0 ? '' : '${(read.value * 100).round()}%',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 9,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// 「上次阅读」的相对时间
  static String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')}';
  }

  /// 封面（v1.22.76 重写）
  ///
  /// 有抽出来的封面图就用图；没有就**画一本书**：渐变底 + 竖排书名 + 书脊阴影。
  /// 原来无图时是"类型色块 + 图标"，在书架里看着像占位符；而 PDF/TXT 大多没有
  /// 封面图，等于整个书架的观感都由占位符决定。
  ///
  /// 底色按 [Document.id] 哈希取，保证**同一本书每次都是同一个颜色**。
  Widget _cover(
    Document document, {
    required double width,
    required double height,
    double radius = 6,
  }) {
    final (Color, Color, Color) palette = _coverPalette(document.id);
    final String title = document.title.trim();
    // 竖排：Flutter 不支持 writing-mode，逐字换行最稳（中文封面本来就是竖排）
    final String vertical = title.isEmpty
        ? document.type.label
        : title.replaceAll(RegExp(r'\s+'), '').characters.take(6).join('\n');

    final Widget placeholder = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[palette.$1, palette.$2, palette.$3],
        ),
      ),
      child: Stack(
        children: <Widget>[
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: width * 0.12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: <Color>[
                    Colors.black.withAlpha(90),
                    Colors.black.withAlpha(0),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                width * 0.16, height * 0.09, width * 0.1, height * 0.11),
            child: Center(
              child: Text(
                vertical,
                textAlign: TextAlign.center,
                maxLines: 6,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  // 字号跟着封面宽度走：小封面（50dp）也读得出，大封面不显空
                  fontSize: (width * 0.17).clamp(7.0, 20.0),
                  height: 1.15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: Colors.white.withAlpha(235),
                  shadows: const <Shadow>[
                    Shadow(blurRadius: 2, color: Color(0x66000000)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );

    final String path = document.coverPath ?? '';
    if (path.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.file(
        File(path),
        width: width,
        height: height,
        fit: BoxFit.cover,
        // 列表里只解码缩略图大小，避免大图解码造成掉帧
        cacheWidth: (width * 2).round().clamp(120, 640),
        errorBuilder:
            (BuildContext context, Object error, StackTrace? stack) =>
                placeholder,
      ),
    );
  }

  /// 封面色：按 id 稳定取一组渐变（同一本书永远同一个色）
  static (Color, Color, Color) _coverPalette(String id) {
    const List<(Color, Color, Color)> palettes = <(Color, Color, Color)>[
      (Color(0xFF4A3B6B), Color(0xFF8B6FB8), Color(0xFFC3A4D9)),
      (Color(0xFF6B2E2E), Color(0xFFA34A3C), Color(0xFFD08A6E)),
      (Color(0xFF24405C), Color(0xFF3C6E8F), Color(0xFF7FB0C9)),
      (Color(0xFF3A4A2E), Color(0xFF6B7F45), Color(0xFFA8B87A)),
      (Color(0xFF4A3A2A), Color(0xFF8A6A45), Color(0xFFC6A47C)),
      (Color(0xFF2E3A4A), Color(0xFF4A5E75), Color(0xFF8FA6BE)),
    ];
    final int index = id.isEmpty
        ? 0
        : id.codeUnits.fold<int>(0, (int a, int b) => a + b) % palettes.length;
    return palettes[index];
  }
}

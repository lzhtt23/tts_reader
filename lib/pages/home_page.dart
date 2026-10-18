import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../features/pdf_reading/open_reading_screen.dart';
import '../features/pdf_reading/pdf_read_session.dart';
import '../models/document.dart';
import '../services/document_service.dart';
import '../services/file_naming.dart';
import '../services/library_storage.dart';
import '../services/speak_intake.dart';
import '../services/storage_service.dart';
import '../tts/tts_manager.dart';
import '../widgets/adaptive.dart';
import '../widgets/tutorial_dialog.dart';
import '../widgets/reading_control_bar.dart';
import 'browser_page.dart';
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
  static const Key importButtonKey = ValueKey<String>('library-import');

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

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  /// 已访问过的 Tab：未访问的页面不构建，避免启动就初始化 WebView
  final Set<int> _visited = <int>{0};
  List<Document> _documents = const <Document>[];
  bool _loading = true;

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
    if (!mounted) return;
    setState(() {
      _documents = documents;
      _loading = false;
    });
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
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已移除「${document.title}」')));
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWideLayout(context);
    final body = IndexedStack(
      index: _index,
      children: <Widget>[
        _libraryView(),
        if (_visited.contains(1))
          BrowserPage(key: _browserKey)
        else
          const SizedBox.shrink(),
        if (_visited.contains(2)) SettingsPage(onOpenUrl: _openInBrowser) else const SizedBox.shrink(),
      ],
    );
    // 浏览器的地址栏与前进/后退已经**渲染在 AppBar 里**（与标题同层），
    // 所以页面内容不再需要为它让高度 —— 只需要给加载进度条留 2px
    final below = _index == 1 ? BrowserPage.progressBarHeight : 0.0;
    final paddedBody = below == 0 ? body : Padding(padding: EdgeInsets.only(top: below), child: body);
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
        title: Text(switch (_index) { 0 => '文档库', 1 => '浏览器', _ => '设置' }),
        actions: <Widget>[
          if (_index == 0) ...<Widget>[
            // 打字朗读入口
            IconButton(
              tooltip: '打字朗读',
              onPressed: _openTypeSpeak,
              icon: const Icon(Icons.record_voice_over_outlined),
            ),
            // 剪贴板朗读入口
            IconButton(
              tooltip: '朗读剪贴板',
              onPressed: _speakClipboard,
              icon: const Icon(Icons.content_paste_go),
            ),
            IconButton(
              tooltip: '排序：${_sort.label}',
              onPressed: () => setState(() => _sort = _sort.next),
              icon: Icon(_sort.icon),
            ),
            IconButton(
              tooltip: '刷新',
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ],
      ),
      // 宽屏（平板横屏 / 桌面）改成左侧导航栏：底部导航在横屏下离拇指太远
      body: wide
          ? Row(children: <Widget>[rail, const VerticalDivider(width: 1), Expanded(child: paddedBody)])
          : paddedBody,
      // 胶片（朗读控制栏）从右下角发起：展开时向左延伸成一条（见 ReadingControlBar）
      floatingActionButton: _index == 0
          ? ReadingControlBar(
              onReturnToReading: _openReadingPage,
              onOpenSettings: () => _selectTab(2),
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
    setState(() {
      _index = index;
      _visited.add(index);
    });
    if (index == 0) _load(); // 浏览器里导入的文档回到文档库时可见
  }

  /// 在**应用内浏览器**里打开一个网址（设置页「项目主页」等入口用）
  ///
  /// ⚠️ 顺序有讲究：IndexedStack 里的 BrowserPage 是**懒建**的
  /// （`_visited` 控制），所以必须先 `_selectTab(1)` 把它建出来，
  /// 否则 `_browserKey.currentState` 还是 null，`submitAddress` 会落空。
  /// 又因为建出来要等这一帧结束，所以真正打开放在下一帧的回调里。
  void _openInBrowser(String url) {
    _selectTab(1);
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
    final columns = libraryColumns(context);
    // 搜索栏固定在列表上方（滚动时不跟着走），空库时不显示
    return Column(
      children: <Widget>[
        _librarySearchBar(),
        Expanded(
          child: documents.isEmpty
              ? _noMatchView()
              : columns > 1
              // 平板 / 横屏：文档库改成多列网格，一屏能看更多书
              ? GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    mainAxisExtent: 112,
                  ),
                  itemCount: documents.length,
                  itemBuilder: (context, index) => _documentCard(documents[index]),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                  itemCount: documents.length,
                  itemBuilder: (context, index) => _documentCard(documents[index]),
                ),
        ),
      ],
    );
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
          const SizedBox(width: 10),
          SizedBox(
            width: 56,
            height: 56,
            child: IconButton.filledTonal(
              key: HomePage.importButtonKey,
              tooltip: '导入文件',
              onPressed: _import,
              iconSize: 26,
              icon: const Icon(Icons.add),
              style: IconButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
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

  Widget _documentCard(Document document) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (IconData icon, Color color) = switch (document.type) {
      DocumentType.pdf => (Icons.picture_as_pdf, scheme.error),
      DocumentType.epub => (Icons.menu_book, scheme.primary),
      DocumentType.txt => (Icons.description, scheme.tertiary),
    };
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(document),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // 封面：EPUB 用抽取出的图片，其它类型用类型色占位封面
              _cover(document, icon, color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      document.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            '${document.type.label} · 进度 ${(document.progress * 100).round()}%',
                            style: theme.textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (document.lastReadAt != null) ...<Widget>[
                          const SizedBox(width: 8),
                          Text(
                            '上次 ${_relativeTime(document.lastReadAt!)}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (document.hasTextLayer == false) ...<Widget>[
                          const SizedBox(width: 8),
                          // 扫描件：没有文本层，朗读不出内容
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: scheme.errorContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '无文本层',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(value: document.progress, minHeight: 4),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '删除',
                onPressed: () => _delete(document),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
      ),
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

  Widget _cover(Document document, IconData icon, Color color) {
    const width = 52.0;
    const height = 72.0;
    final path = document.coverPath;
    final placeholder = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[color.withAlpha(70), color.withAlpha(24)],
        ),
      ),
      child: Icon(icon, color: color, size: 26),
    );
    if (path == null || path.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.file(
        File(path),
        width: width,
        height: height,
        fit: BoxFit.cover,
        // 列表里只解码缩略图大小，避免大图解码造成掉帧
        cacheWidth: 160,
        errorBuilder: (context, error, stackTrace) => placeholder,
      ),
    );
  }
}

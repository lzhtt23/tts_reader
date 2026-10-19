import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/document.dart';
import 'crash_log.dart';
import 'document_service.dart';
import 'file_naming.dart';
import 'library_storage.dart';
import 'storage_service.dart';

/// 把「下载好的文件」收进文档库 —— **浏览器页与后台 watcher 共用这一份**（v1.21.40）
///
/// ## 为什么必须抽成公共函数
///
/// 前几轮已经出过"两套实现漂移"的 bug（同一件事在浏览器页与别处各写一份，
/// 改了一处忘另一处）。所以「拼路径 → 判可朗读格式 → 收进私有目录 → 入库」
/// 只留这一份实现。
///
/// 返回导入的文档；不满足条件（格式不支持 / 文件读不到）返回 null，
/// **不抛异常**（调用方可能是后台扫描，没有界面可以报错）。
Future<Document?> importDownloadedFile(String path) async {
  try {
    // ★v1.22.12：**先按文件头把名字纠正过来**
    //
    // `annas-archive.gl` 那种 `/slow_download/<hash>/` 地址没有文件名，
    // 服务器不给 `Content-Disposition`，下载器只能兜底存成 `.bin` ——
    // 于是"下载完成"但格式判不出来，用户拿到的是一坨打不开的东西。
    final String normalized = await normalizeDownloadedName(path);
    if (!DocumentType.isReadable(normalized)) return null;
    final String? real = await locateDownloadedFile(normalized);
    if (real == null) {
      CrashLog.mark('下载导入：找不到文件，跳过（$path）');
      return null;
    }

    // ⚠️ v1.21.43（块2）：**两道完整性判据**，治真机事故「半截文件被当成品导入」。
    //
    // 真机日志（用户 19:42）：下载只到 6% 就 failed，浏览器页正确放弃了；
    // 但后台扫描把那份半截文件"找到"、收纳、还写进了文档库 ——
    // 用户得到的是一本打不开的书（点开即 FPDF_GetLastError=3）。
    // **半截文件比"没导入"糟糕得多。**
    final head = await describeFileHead(real);
    final size = await File(real).length();
    CrashLog.mark('下载导入[进入] name=${FileNaming.baseName(real)} '
        '路径=$real 大小=${size}B 文件头=$head');
    if (size == 0) {
      CrashLog.mark('下载导入：文件为空，不当成品（$real）');
      return null;
    }

    // ① 文件头魔数
    final lower = real.toLowerCase();
    if (lower.endsWith('.pdf') && !head.startsWith('PDF')) {
      CrashLog.mark('下载导入：⚠️ 扩展名是 pdf 但文件头不是 %PDF（$head）'
          '—— 文件很可能没下完，本轮不导入');
      return null;
    }
    if (lower.endsWith('.epub') && !head.startsWith('ZIP')) {
      CrashLog.mark('下载导入：⚠️ 扩展名是 epub 但文件头不是 PK（$head）'
          '—— 文件很可能没下完，本轮不导入');
      return null;
    }

    // ② **真解析一次** —— 魔数拦不住截断：被截断的 PDF 开头仍是 %PDF
    //    （用例「★真机事故复现：半截 PDF」证明了这一点）。
    //    产物不进缓存（只当校验），用户真打开时照常解析。
    try {
      final probe = Document(
        id: 'download-probe',
        title: FileNaming.titleOf(real),
        path: real,
        type: DocumentType.fromExtension(real),
        importedAt: DateTime.now(),
      );
      final parsed = await DocumentService.parse(probe);
      CrashLog.mark('下载导入[校验] 可解析 ✓ 页数=${parsed.pageCount} '
          '字数=${parsed.textCharCount}');
    } catch (e) {
      CrashLog.mark('下载导入：⚠️ 解析失败，判为"没下完"，不导入（$real）：$e');
      return null;
    }

    // 收进应用私有目录：下载到应用目录里的不再复制，
    // 下载到系统「下载」目录的会复制一份进来（保持原名），
    // 免得日后被移走 / 删掉。
    final adopted = await LibraryStorage.adopt(real);
    final String stored =
        adopted.path.isEmpty || adopted.path == real ? real : adopted.path;

    final document = Document(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: DocumentService.titleFromPath(stored),
      path: stored,
      type: DocumentType.fromExtension(stored),
      importedAt: DateTime.now(),
    );
    await StorageService.instance.upsertDocument(document);
    // ★v1.22.8：**入库时就把封面做出来**
    //
    // 原来只有「文件选择器导入」那条路会补封面，
    // 浏览器下载 / 后台扫描进来的书没有封面，文档库里是一块空白占位。
    // 这里补上（失败不影响入库：封面只是装饰）。
    await attachCoverFor(document);
    CrashLog.mark('下载完成并已导入文档库：${document.title}（来源=$real）');
    return document;
  } catch (e) {
    // 后台扫描不能因为一个文件失败就整体中断
    CrashLog.mark('下载文件导入失败（$path）：$e');
    return null;
  }
}

/// 按**文件头**纠正下载文件的扩展名（`.bin` → `.pdf` / `.epub` / `.txt`）
///
/// ## 为什么需要
///
/// 有些下载地址根本没有文件名，例如 `annas-archive.gl/slow_download/<hash>/`。
/// 如果服务器也不再给 `Content-Disposition`，下载器只能兜底叫 `xxx.bin` ——
/// 内容是好的 PDF，但按扩展名判"不可朗读"，用户看到的就是「下载完成但打不开」。
///
/// ## 判据
///
/// 只看前 8 字节（够认魔数，也不会为校验去读整本大文件）：
/// * `%PDF` → pdf
/// * `PK\x03\x04` → epub（zip 容器；进一步看有没有 `mimetype` 才算 epub，
///   这里先按 epub 认，真解析时还会再校验一次）
/// * 能按 UTF-8 解出来且没有 NUL 字节 → txt
///
/// 名字**已经是对的就原样返回**，不改名；改名失败也原样返回（不影响后续）。
Future<String> normalizeDownloadedName(String path) async {
  try {
    final File file = File(path);
    if (!await file.exists()) return path;
    final String lower = path.toLowerCase();
    // 已经是能识别的扩展名：不动
    for (final String ext in <String>['.pdf', '.epub', '.txt']) {
      if (lower.endsWith(ext)) return path;
    }

    final RandomAccessFile raf = await file.open();
    late final List<int> head;
    try {
      head = await raf.read(8);
    } finally {
      await raf.close();
    }
    if (head.isEmpty) return path;
    final String magic = _magicOf(head);

    String? ext;
    // ⚠️ `_magicOf` 返回的是**给人看**的字符串（'PDF(%PDF)' / 'ZIP/PK(epub 等)'），
    // 所以这里用前缀判断，不能拿 'PDF' 去全等比较。
    if (magic.startsWith('PDF')) {
      ext = 'pdf';
    } else if (magic.startsWith('ZIP')) {
      ext = 'epub';
    } else if (_looksLikeText(head)) {
      ext = 'txt';
    }
    if (ext == null) {
      CrashLog.mark('下载改名：认不出格式（头=$magic），保持原名（$path）');
      return path;
    }

    // 去掉原扩展名后接上正确的（`book.bin` → `book.pdf`）
    final String base = path.contains('.')
        ? path.substring(0, path.lastIndexOf('.'))
        : path;
    final String target = '$base.$ext';
    if (target == path) return path;
    if (await File(target).exists()) {
      // 目标已存在就不覆盖，换个带序号的
      final String stamped = '$base-${DateTime.now().millisecondsSinceEpoch}.$ext';
      await file.rename(stamped);
      CrashLog.mark('下载改名：$path → $stamped（头=$magic）');
      return stamped;
    }
    await file.rename(target);
    CrashLog.mark('下载改名：$path → $target（头=$magic）');
    return target;
  } catch (e) {
    CrashLog.mark('下载改名失败（$path）：$e');
    return path;
  }
}

/// 前几个字节看起来像文本吗（没有 NUL、不是控制字符为主）
bool _looksLikeText(List<int> head) {
  if (head.isEmpty) return false;
  var bad = 0;
  for (final int b in head) {
    if (b == 0) return false; // 有 NUL：二进制
    // 允许 \t \n \r 和可打印 ASCII
    if (b == 0x09 || b == 0x0A || b == 0x0D) continue;
    if (b < 0x20) bad++;
  }
  return bad <= 1;
}

/// 给刚入库的文档补一张封面（解析不出来就当失败，不影响入库）
///
/// 下载进来的书可能是 PDF / EPUB / TXT 任何一种：
/// * EPUB 抽自带封面
/// * PDF 抽第一页
/// * TXT 没有图源 → 由 `DocumentService` 排版生成（支持中文书名）
Future<void> attachCoverFor(Document document) async {
  if ((document.coverPath ?? '').isNotEmpty) return;
  try {
    final Directory dir = await getApplicationDocumentsDirectory();
    final String outPath = '${dir.path}/covers/${document.id}.jpg';
    final String? cover = await DocumentService.extractCover(document, outPath);
    if (cover == null) return;
    await StorageService.instance.upsertDocument(
      document.copyWith(coverPath: cover),
    );
    CrashLog.mark('封面生成：${document.title}');
  } catch (e) {
    CrashLog.mark('封面生成失败（${document.title}）：$e');
  }
}

/// 文件头魔数（判定"这文件是不是对应格式"）
///
/// 只读前 8 字节：够认 `%PDF` 与 `PK`，也不至于为了校验去读整个大文件。
///
/// ⚠️ **它拦不住截断文件** —— 被截断的 PDF 开头仍是 `%PDF`。截断必须靠
/// 「真解析一次」来挡（见 [importDownloadedFile]）。
Future<String> describeFileHead(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return '文件不存在';
    final raf = await file.open();
    try {
      final head = await raf.read(8);
      return _magicOf(head);
    } finally {
      await raf.close();
    }
  } catch (e) {
    return '读不到($e)';
  }
}

String _magicOf(List<int> head) {
  if (head.length >= 4 &&
      head[0] == 0x25 &&
      head[1] == 0x50 &&
      head[2] == 0x44 &&
      head[3] == 0x46) {
    return 'PDF(%PDF)';
  }
  if (head.length >= 2 && head[0] == 0x50 && head[1] == 0x4B) {
    return 'ZIP/PK(epub 等)';
  }
  return '未知或为空(head=${head.take(4).toList()})';
}

/// 找到下载好的文件
///
/// 插件任务表里只存着 enqueue 时传的 `savedDir`；选了「系统下载目录」时，
/// 文件其实由 MediaStore 放到公共「下载」根目录（`savedDir` 被忽略），
/// 所以这里按系统约定补候选路径。
Future<String?> locateDownloadedFile(String path, {String? fileName}) async {
  if (await File(path).exists()) return path;
  final String name = fileName ?? path.split(RegExp(r'[\\/]')).last;
  if (name.isEmpty) return null;
  if (!Platform.isAndroid) return null;
  // Environment.DIRECTORY_DOWNLOADS 的固定位置
  final String publicPath = '${StorageService.publicDownloadPath}/$name';
  if (await File(publicPath).exists()) return publicPath;
  // 已经收进「应用专属子文件夹」的也要找得到（见 [inboxDownloadedFile]）
  final String inboxPath =
      '${StorageService.publicDownloadPath}/${StorageService.downloadInboxFolder}/$name';
  if (await File(inboxPath).exists()) return inboxPath;
  return null;
}

/// 把刚下好的文件收进**系统「下载」目录下的应用专属子文件夹**（v1.21.41）
///
/// ## 为什么是"下完再挪"而不是"直接下进去"
///
/// `flutter_downloader` 写公共目录时 `RELATIVE_PATH` 是**写死的**：
/// ```kotlin
/// // flutter_downloader-1.11.8/android/.../DownloadWorker.kt:527
/// values.put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
/// ```
/// 我们传的 `savedDir` 会被彻底忽略 —— 它只能落「下载」**根目录**。
///
/// **但同一存储卷内的移动就是改名**：瞬间完成、**不占额外空间**、不是两份。
/// 所以流程是"先让它下到根目录，下载完立刻挪进子文件夹"，
/// 效果与"直接下进子文件夹"一样，而且**不用改插件源码、不用引新依赖**。
///
/// ## 为什么必须挪
///
/// 1. 用户要的就是"下载目录里有个软件专属文件夹，文件都放那儿"（分类清楚）；
/// 2. 留在根目录会跟用户其它下载混在一起。
///
/// ⚠️ 公共「下载」下的子文件夹**卸载不删**（它属于公共目录，不属于本应用）——
/// 这正是用户要的，与应用私有目录（卸载必删，已实测）有本质区别。
///
/// 失败时**保留原位**并返回原路径（宁可不挪，也不能把文件弄丢）。
Future<String> inboxDownloadedFile(String path) async {
  if (!Platform.isAndroid) return path;
  try {
    final file = File(path);
    if (!await file.exists()) return path;
    const root = StorageService.publicDownloadPath;
    // 只处理"落在公共下载根目录"的文件：其它位置（私有目录 / 自定义路径）不搬
    final parent = file.parent.path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    if (parent != root) return path;

    final inbox = Directory('$root/${StorageService.downloadInboxFolder}');
    if (!await inbox.exists()) await inbox.create(recursive: true);
    final name = FileNaming.baseName(path);
    // 重名就让开，别覆盖用户已有的文件
    final targetName = FileNaming.uniqueName(
      name,
      (candidate) => File('${inbox.path}/$candidate').existsSync(),
    );
    final target = '${inbox.path}/$targetName';
    try {
      // 同卷 rename：瞬间完成，不产生第二份数据
      await file.rename(target);
      CrashLog.mark('下载收纳：$path → $target');
      return target;
    } on FileSystemException catch (e) {
      // 跨卷 / 被占用：退回"复制 + 删原件"，仍是净一份
      CrashLog.mark('下载收纳 rename 失败（改走复制）：$e');
      final copied = await file.copy(target);
      try {
        await file.delete();
      } catch (_) {
        // 删不掉原件也不算失败：两份总比丢文件好
      }
      return copied.path;
    }
  } catch (e) {
    CrashLog.mark('下载收纳失败（保留原位）：$e');
    return path;
  }
}

/// **后台下载的收尾扫描**（v1.21.40，方案 A）
///
/// ## 解决什么问题
///
/// `flutter_downloader` 走 WorkManager，**下载本身在后台是支持的**；
/// 缺的是「下载完成 → 自动导入文档库」这一步只写在浏览器页里，靠**页面前台轮询**
/// —— 用户离开浏览器 Tab（或退到桌面 / 杀掉应用），轮询就停了，
/// 下载跑完了也不会入库，用户回来发现"下了但书不在"。
///
/// ## 方案 A：应用启动 + 每次回前台扫一遍
///
/// 「用户总要看书的」，所以这两个时机足够。比 `FlutterDownloader.registerCallback`
/// 简单得多 —— 那个回调跑在独立 isolate，碰不了 SharedPreferences / path_provider，
/// 调试也难。
class DownloadWatcher {
  DownloadWatcher._();

  static final DownloadWatcher instance = DownloadWatcher._();

  /// 已处理过的任务 id（落盘，避免每次启动重复导入）
  static const String _kHandled = 'download_handled_task_ids';

  /// **退避表**：任务 id → 下次允许再扫的时间（毫秒时间戳），落盘（v1.21.43）
  ///
  /// ## 治什么（真机日志实证）
  ///
  /// 用户 2026-10-11 那次失败的下载 `7b881749:failed(6%)`，
  /// 后台扫描从 **19:41 一直重复到 01:26**（每 6~13 秒一条日志）：
  /// ```
  /// 19:42:14 / 19:45:45 / 19:45:48 / 19:46:11 / … / 01:20:19 / 01:26
  /// ```
  /// 它已经**永远不会再产出文件**了，反复扫只是刷日志、耗电、淹没有效信息。
  ///
  /// ## 规则
  ///
  /// 失败/取消的任务按**指数退避**延后重扫：第 n 次失败后等 `30min × 2^(n-1)`，
  /// 上限 24 小时。这样"偶发失败、稍后其实能补上"仍有补救机会
  /// （用户可能重新下载成功），而"永远失败的尸体"会迅速安静下来。
  static const String _kBackoff = 'download_failed_backoff';

  /// 退避基数：第一次失败后等 30 分钟再试
  static const Duration _backoffBase = Duration(minutes: 30);

  /// 退避上限：最多等到 24 小时
  static const Duration _backoffMax = Duration(hours: 24);

  /// 退避表最多留多少条（避免偏好无限长）
  static const int _keepBackoff = 30;

  /// 保留多少个已处理 id（够覆盖"最近下的几本"，又不让偏好无限长）
  static const int _keepHandled = 50;

  /// 记一个已处理 id 用多久才算"不该再扫"（防止历史任务被反复扫描）
  bool _sweeping = false;

  /// 测试用：强制放开防重入（用例里连续调）
  @visibleForTesting
  bool debugForceUnlocked = false;

  /// 扫一遍：把**已完成但还没导入**的下载任务收进文档库
  ///
  /// 防重入（同时只能有一次扫描）；任何失败只记 [CrashLog]，**不抛异常**
  /// —— 它挂在应用启动与回前台上，抛了会影响主流程。
  ///
  /// 返回本次导入的文档数（测试用）。
  Future<int> sweep() async {
    if (_sweeping && !debugForceUnlocked) return 0;
    _sweeping = true;
    try {
      final List<DownloadTask> tasks = await _loadTasks();
      if (tasks.isEmpty) return 0;

      final SharedPreferences sp = await SharedPreferences.getInstance();
      final List<String> handled = sp.getStringList(_kHandled) ?? <String>[];
      final Set<String> handledSet = handled.toSet();
      final Map<String, int> backoff = _loadBackoff(sp);
      final int nowMs = DateTime.now().millisecondsSinceEpoch;

      int imported = 0;
      final List<String> newlyHandled = <String>[];
      final Map<String, int> backoffUpdates = <String, int>{};
      for (final task in tasks) {
        final String id = task.taskId;
        if (handledSet.contains(id)) continue;

        // ⚠️ v1.21.43（退避）：**失败/取消的任务只记退避，不进导入流程**。
        //
        // 真机日志实证：`7b881749:failed(6%)` 从 19:41 一直重扫到 01:26
        // （每 6~13 秒一条），它**永远不会再产出文件**了。
        // 而且把半截文件送进导入流程，正是当初"残片被收纳进子文件夹"的入口
        // —— 现在虽然有完整性校验兜底，但不该让它走到那一步。
        if (task.status == DownloadTaskStatus.failed ||
            task.status == DownloadTaskStatus.canceled) {
          final int? dueAt = backoff[id];
          if (shouldSkipByBackoff(dueAt, nowMs)) {
            continue; // 还在退避窗口内：这次**不扫、也不打日志**
          }
          final int fails = _backoffCount(sp, id) + 1;
          final Duration wait = _backoffFor(fails);
          backoffUpdates[id] = nowMs + wait.inMilliseconds;
          _saveBackoffCount(sp, id, fails);
          newlyHandled.add(id);
          CrashLog.mark('下载探针[后台扫描] task=${id.substring(0, 8)} '
              'status=${task.status.name} progress=${task.progress}% '
              '→ 未完成，不进导入（第 $fails 次失败，'
              '${wait.inMinutes} 分钟后再看）');
          continue;
        }

        // 只处理 `complete`：文件确实下完了才谈导入
        if (task.status != DownloadTaskStatus.complete) continue;

        final String? path = await _resolvePath(task);
        CrashLog.mark('下载探针[后台扫描] task=${id.substring(0, 8)} '
            'status=${task.status.name} progress=${task.progress}% '
            'savedDir="${task.savedDir}" → 落盘=${path ?? '(找不到文件)'}');
        if (path == null) {
          // 已完成却找不到文件：记成已处理，不再反复扫
          CrashLog.mark('下载探针[后台扫描] task=${id.substring(0, 8)} '
              '已完成但找不到文件 → 记成已处理');
          newlyHandled.add(id);
          continue;
        }
        // 与浏览器页同一条路：先收进「下载」下的应用专属子文件夹，再入库
        final doc = await importDownloadedFile(await inboxDownloadedFile(path));
        // 不管导入成功还是"格式不支持 / 文件不完整"，这个任务都算处理过了 ——
        // 否则每次回前台都要重新扫一遍同一个文件
        newlyHandled.add(id);
        if (doc != null) imported++;
      }

      if (newlyHandled.isNotEmpty) {
        final List<String> keep = <String>[
          ...newlyHandled,
          ...handled.where((e) => !newlyHandled.contains(e)),
        ];
        await sp.setStringList(
          _kHandled,
          keep.length > _keepHandled ? keep.sublist(0, _keepHandled) : keep,
        );
      }
      if (backoffUpdates.isNotEmpty) {
        await _saveBackoff(sp, backoff, backoffUpdates);
      }
      if (imported > 0) {
        CrashLog.mark('后台下载扫描：本次导入 $imported 本书');
      }
      return imported;
    } catch (e) {
      CrashLog.mark('后台下载扫描失败：$e');
      return 0;
    } finally {
      _sweeping = false;
    }
  }

  /// 测试用：清掉"已处理"记录
  Future<void> resetForTest() async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.remove(_kHandled);
    _sweeping = false;
  }

  Future<List<DownloadTask>> _loadTasks() async {
    try {
      final tasks = await FlutterDownloader.loadTasks() ?? const <DownloadTask>[];
      // 探针（v1.21.41）：把插件任务表**原样**记一遍。
      // 用户报的"进度条只走一点 / 显示失败但文件已下好"就是状态与事实不一致，
      // 这条能看到插件到底报了什么。
      if (tasks.isNotEmpty) {
        final summary = tasks
            .map((t) => '${t.taskId.substring(0, 8)}:${t.status.name}'
                '(${t.progress}%,${t.filename ?? '-'})')
            .join(' | ');
        CrashLog.mark('下载探针[后台扫描] 任务表(${tasks.length})：$summary');
      }
      return tasks;
    } catch (e) {
      CrashLog.mark('后台下载扫描：取任务表失败 $e');
      return const <DownloadTask>[];
    }
  }

  /// 评一个任务的退避时长：`30min × 2^(fails-1)`，上限 24 小时
  ///
  /// 第 1 次失败等 30 分钟，第 2 次 1 小时，第 3 次 2 小时 …… 第 7 次起封顶 24 小时。
  /// 这样"偶发失败、稍后其实能补上"仍有补救机会，"永远失败的尸体"会迅速安静。
  ///
  /// （纯函数、公开给测试：退避规则必须能被单测钉住，不能只靠真机观察。）
  @visibleForTesting
  static Duration backoffFor(int fails) {
    if (fails <= 1) return _backoffBase;
    final int shift = (fails - 1).clamp(0, 10);
    final Duration d = _backoffBase * (1 << shift);
    return d > _backoffMax ? _backoffMax : d;
  }

  /// **该不该跳过这个失败任务**（纯函数、可单测）
  ///
  /// [dueAtMs] 是上次记下的"下次允许再扫的时间"；`null` 表示还没记过（要扫一次）。
  /// 正在进行的任务不该调用它 —— 只有 failed/canceled 才走退避。
  @visibleForTesting
  static bool shouldSkipByBackoff(int? dueAtMs, int nowMs) =>
      dueAtMs != null && nowMs < dueAtMs;

  static Duration _backoffFor(int fails) => backoffFor(fails);

  /// 读出退避表（任务 id → 下次允许再扫的毫秒时间戳）
  static Map<String, int> _loadBackoff(SharedPreferences sp) {
    final raw = sp.getStringList(_kBackoff) ?? <String>[];
    final Map<String, int> map = <String, int>{};
    for (final entry in raw) {
      final i = entry.indexOf('|');
      if (i <= 0) continue;
      final id = entry.substring(0, i);
      final at = int.tryParse(entry.substring(i + 1));
      if (at != null) map[id] = at;
    }
    return map;
  }

  /// 写回退避表（合并更新，只留最近 [_keepBackoff] 条）
  static Future<void> _saveBackoff(
    SharedPreferences sp,
    Map<String, int> current,
    Map<String, int> updates,
  ) async {
    final merged = <String, int>{...current, ...updates};
    // 按到期时间倒序留最近的那些（最老的尸体先淘汰）
    final entries = merged.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final keep = entries.take(_keepBackoff).map((e) => '${e.key}|${e.value}');
    await sp.setStringList(_kBackoff, keep.toList());
  }

  /// 这个任务累计失败了几次（键名带前缀，避免和别的设置串）
  static int _backoffCount(SharedPreferences sp, String taskId) =>
      sp.getInt('dl_fail_count_$taskId') ?? 0;

  static Future<void> _saveBackoffCount(
    SharedPreferences sp,
    String taskId,
    int count,
  ) =>
      sp.setInt('dl_fail_count_$taskId', count);

  /// 仅供测试：清掉失败计数与退避表
  @visibleForTesting
  Future<void> resetBackoffForTest() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kBackoff);
    for (final k in sp.getKeys().where((k) => k.startsWith('dl_fail_count_')).toList()) {
      await sp.remove(k);
    }
  }

  /// 拼出任务落盘的真实路径（三个候选依次试）
  ///
  /// ① `task.savedDir + filename`（私有目录那条路，`savedDir` 有效）
  /// ② `/storage/emulated/0/Download/<name>`（公共目录那条路，MediaStore 忽略 savedDir）
  /// ③ 应用私有 `downloads/<name>`（`savedDir` 为空时的兜底）
  Future<String?> _resolvePath(DownloadTask task) async {
    final String name = task.filename ?? '';
    if (name.isEmpty) return null;

    if (task.savedDir.isNotEmpty) {
      final String candidate = '${task.savedDir}${Platform.pathSeparator}$name';
      if (await File(candidate).exists()) return candidate;
    }
    if (Platform.isAndroid) {
      final String publicCandidate =
          '${StorageService.publicDownloadPath}/$name';
      if (await File(publicCandidate).exists()) return publicCandidate;
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final String privateCandidate =
          '${dir.path}/downloads/${StorageService.instance.downloadFolder}/$name';
      if (await File(privateCandidate).exists()) return privateCandidate;
    } catch (_) {
      // 拿不到私有目录：这条候选跳过
    }
    return null;
  }}

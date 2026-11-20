import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';

import '../models/document.dart';
import '../models/reader_style.dart';
import 'library_storage.dart';
import 'storage_service.dart';

/// 备份包导入/导出过程中的可预期错误（配置不对、包损坏、版本不符）
class LibraryBackupException implements Exception {
  LibraryBackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一次导出的结果
class LibraryBackupResult {
  const LibraryBackupResult({
    required this.path,
    required this.documentCount,
    required this.fileCount,
    required this.bytes,
    required this.missingFiles,
  });

  /// 生成的 zip 绝对路径
  final String path;
  final int documentCount;

  /// 真正打进包的书籍文件数
  final int fileCount;
  final int bytes;

  /// 记录里有、但磁盘上找不到的文件（书名列表，用于如实告知用户）
  final List<String> missingFiles;
}

/// 一次导入的结果
class LibraryRestoreResult {
  const LibraryRestoreResult({
    required this.addedDocuments,
    required this.updatedDocuments,
    required this.skippedDocuments,
    required this.filesWritten,
    required this.filesReused,
    required this.missingFiles,
    required this.styleApplied,
  });

  final int addedDocuments;
  final int updatedDocuments;

  /// 备份里有、但本机已有且进度更新（或完全一致）而没有改动的
  final int skippedDocuments;
  final int filesWritten;

  /// 同名同大小、直接复用现有文件的数量
  final int filesReused;

  /// 备份里缺文件的记录数（这些记录仍会导入，只是打开时会提示文件不存在）
  final int missingFiles;

  /// 是否把备份里的阅读样式应用到了本机（只在书库为空时才应用）
  final bool styleApplied;
}

/// 书库备份与恢复
///
/// ## 为什么需要
///
/// 书存在应用私有目录（`app_flutter/books/`），文档库记录与朗读进度存在
/// SharedPreferences。**卸载应用或清除数据 = 书和进度一起没了**，
/// 而此前只有「书源」「替换规则」能导入导出，书库本身没有任何出口。
///
/// Android 的 `allowBackup` 虽然是默认开，但系统备份对单个应用有 25MB 上限，
/// 一个正常规模的 PDF 书库早就超了 —— 指望系统备份等于没备。
///
/// ## 包格式
///
/// ```text
/// taohuayuan-library-YYYYMMDD-HHMMSS.zip
/// ├── meta.json          schemaVersion / exportedAt / documents / spots / style
/// └── books/             书库文件，保持原文件名
/// ```
///
/// `documents[].path` **不存绝对路径**，只存 `books/` 内的文件名：
/// 应用私有目录的绝对路径会随安装变化（多用户/工作资料/重装后 user id 也可能变），
/// 存绝对路径的话恢复出来就是一串打不开的死链接。
///
/// ## 导入的合并规则（都写在这，避免以后各改一套）
///
/// | 情况 | 处理 |
/// | --- | --- |
/// | 本机没有这个 id | 新增记录 |
/// | 本机有、备份 progress 更大 | 用备份的记录与进度 |
/// | 本机有、进度相同或更大 | 保留本机，计入 skipped |
/// | 书库文件同名同大小 | 复用现有文件，不重复占空间 |
/// | 书库文件同名不同大小 | 另存为 `名字 (1).pdf`，原文件不动 |
/// | 备份里缺书籍文件 | 记录照常导入（打开时提示文件不存在），计入 missingFiles |
/// | 阅读样式 | **只在导入前书库为空时**应用，避免覆盖用户当前排版习惯 |
class LibraryBackup {
  LibraryBackup._();

  /// 包格式版本。以后改结构就 +1，并在 [importFromZip] 里给出兼容分支。
  static const int schemaVersion = 1;

  static const String metaEntry = 'meta.json';
  static const String booksPrefix = 'books/';

  static const String _namePrefix = 'taohuayuan-library-';

  /// 导出到 [targetDirPath] 指定的目录（通常是用户选的文件夹）
  static Future<LibraryBackupResult> exportToDirectory(
    String targetDirPath,
  ) async {
    final Directory target = Directory(targetDirPath);
    if (!target.existsSync()) {
      throw LibraryBackupException('目标文件夹不存在：$targetDirPath');
    }

    final List<Document> documents =
        await StorageService.instance.loadDocuments();
    final Directory books = await LibraryStorage.booksDir();
    final String booksPath = books.path;

    final Archive archive = Archive();
    final List<Map<String, dynamic>> docEntries = <Map<String, dynamic>>[];
    final List<String> missing = <String>[];
    final Set<String> usedNames = <String>{};
    int fileCount = 0;

    for (final Document doc in documents) {
      final String rawPath = doc.path.trim();
      String? entryName;
      if (rawPath.isNotEmpty) {
        final File file = File(rawPath);
        // 只备份书库目录里的文件。外部路径（用户原始文件）不进包：
        // 那种情况用户自己的文件还在，重复打包只会把包撑大。
        final String normalized = rawPath.replaceAll('\\', '/');
        final bool inLibrary = normalized.startsWith(
          booksPath.replaceAll('\\', '/'),
        );
        if (inLibrary) {
          String name = _baseName(normalized);
          // 不同目录下的同名书要各自留住，不能互相覆盖
          if (usedNames.contains(name)) {
            name = _uniqueName(name, usedNames);
          }
          usedNames.add(name);
          if (file.existsSync()) {
            final Uint8List bytes = await file.readAsBytes();
            archive.addFile(ArchiveFile('$booksPrefix$name', bytes.length, bytes));
            fileCount++;
          } else {
            // 记录还在、文件没了：仍把名字写进 meta，
            // 恢复时才能如实报「这条记录缺文件」，而不是静默丢掉。
            missing.add(doc.title);
          }
          entryName = name;
        }
      }

      final Map<String, dynamic> entry = doc.toJson();
      // 只保留相对名；外部路径原样保留（恢复时若不存在会提示，不会假装有）
      if (entryName != null) {
        entry['path'] = entryName;
        entry['pathInLibrary'] = true;
      } else {
        entry['pathInLibrary'] = false;
        if (rawPath.isEmpty) entry.remove('path');
      }
      docEntries.add(entry);
    }

    // 朗读进度与阅读样式
    final Map<String, dynamic> spots = <String, dynamic>{};
    for (final Document doc in documents) {
      final spot = StorageService.instance.pdfReadingSpot(doc.id);
      if (spot != null) {
        spots[doc.id] = <String, int>{
          'page': spot.pageIndex,
          'sentence': spot.sentenceIndex,
        };
      }
    }

    final Map<String, dynamic> meta = <String, dynamic>{
      'schemaVersion': schemaVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'documents': docEntries,
      'readingSpots': spots,
      'readerStyle': StorageService.instance.readerStyle.value.toJson(),
    };
    final Uint8List metaBytes =
        Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(meta)));
    archive.addFile(
      ArchiveFile(metaEntry, metaBytes.length, metaBytes),
    );

    final List<int>? encoded = ZipEncoder().encode(archive);
    if (encoded == null) throw LibraryBackupException('打包失败：压缩器没有返回数据');

    final String stamp = _timestamp();
    String outPath = '${target.path}${Platform.pathSeparator}$_namePrefix$stamp.zip';
    // 极端情况下同一秒导出两次：加序号，别覆盖上一个包
    int seq = 1;
    while (File(outPath).existsSync()) {
      outPath =
          '${target.path}${Platform.pathSeparator}$_namePrefix$stamp-${seq++}.zip';
    }
    await File(outPath).writeAsBytes(encoded, flush: true);

    return LibraryBackupResult(
      path: outPath,
      documentCount: documents.length,
      fileCount: fileCount,
      bytes: encoded.length,
      missingFiles: missing,
    );
  }

  /// 从 [zipPath] 恢复，合并进当前书库
  static Future<LibraryRestoreResult> importFromZip(String zipPath) async {
    final File zip = File(zipPath);
    if (!zip.existsSync()) {
      throw LibraryBackupException('备份包不存在：$zipPath');
    }

    final Uint8List bytes = await zip.readAsBytes();
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: false);
    } catch (e) {
      throw LibraryBackupException('备份包损坏，读不出来：$e');
    }

    final ArchiveFile? metaFile = _findMeta(archive);
    if (metaFile == null) {
      throw LibraryBackupException('这不是本站的备份包：缺少 $metaEntry');
    }

    final Map<String, dynamic> meta;
    try {
      meta = jsonDecode(utf8.decode(metaFile.content as List<int>))
          as Map<String, dynamic>;
    } catch (e) {
      throw LibraryBackupException('备份包的 meta.json 解析失败：$e');
    }

    final int version = (meta['schemaVersion'] as num?)?.toInt() ?? 0;
    if (version <= 0 || version > schemaVersion) {
      throw LibraryBackupException(
        '备份包版本 $version 与当前版本 $schemaVersion 不兼容，请用新版应用恢复',
      );
    }

    final Directory books = await LibraryStorage.booksDir();
    final bool libraryWasEmpty =
        (await StorageService.instance.loadDocuments()).isEmpty;

    // 1) 先把 books/ 落盘，得到「文件名 → 本机绝对路径」
    final Map<String, String> landed = <String, String>{};
    int filesWritten = 0;
    int filesReused = 0;
    for (final ArchiveFile f in archive.files) {
      if (!f.isFile) continue;
      final String name = f.name.replaceAll('\\', '/');
      if (!name.startsWith(booksPrefix)) continue;
      final String fileName = name.substring(booksPrefix.length);
      if (fileName.isEmpty || fileName.contains('..')) continue;

      final Uint8List content =
          f.content is List<int> ? Uint8List.fromList(f.content as List<int>) : f.content as Uint8List;
      final landedFile = await _landFile(books, fileName, content);
      landed[fileName] = landedFile.path;
      if (landedFile.reused) {
        filesReused++;
      } else {
        filesWritten++;
      }
    }

    // 2) 合并文档记录
    final List<Document> local =
        await StorageService.instance.loadDocuments();
    final Map<String, int> localIndex = <String, int>{
      for (int i = 0; i < local.length; i++) local[i].id: i,
    };

    final List<Document> merged = List<Document>.of(local);
    final Map<String, dynamic> spots =
        (meta['readingSpots'] as Map?)?.cast<String, dynamic>() ??
            <String, dynamic>{};

    int added = 0;
    int updated = 0;
    int skipped = 0;
    int missingFiles = 0;

    final List<dynamic> docs =
        (meta['documents'] as List?) ?? const <dynamic>[];
    final List<String> spotsToApply = <String>[];

    for (final dynamic raw in docs) {
      if (raw is! Map) continue;
      final Map<String, dynamic> entry = raw.cast<String, dynamic>();
      final Document incoming;
      try {
        incoming = Document.fromJson(entry);
      } catch (_) {
        skipped++;
        continue;
      }

      // 路径改写：书库内的按落盘结果重建，外部路径保留原样
      String newPath = incoming.path;
      final bool inLibrary = entry['pathInLibrary'] == true;
      if (inLibrary) {
        final String? landedPath = landed[_baseName(incoming.path)];
        if (landedPath != null) {
          newPath = landedPath;
        } else {
          // 备份里就没有这个文件：记录照导入，但路径指着不会存在的位置
          missingFiles++;
          newPath = '${books.path}${Platform.pathSeparator}${_baseName(incoming.path)}';
        }
      }

      final Document? existing =
          localIndex.containsKey(incoming.id) ? merged[localIndex[incoming.id]!] : null;

      if (existing == null) {
        merged.add(incoming.copyWith(path: newPath));
        added++;
        spotsToApply.add(incoming.id);
      } else if (incoming.progress > existing.progress) {
        merged[localIndex[incoming.id]!] =
            incoming.copyWith(path: newPath);
        updated++;
        spotsToApply.add(incoming.id);
      } else {
        skipped++;
      }
    }

    await StorageService.instance.saveDocuments(merged);

    // 3) 进度：只覆盖我们真的采纳了备份记录的那些文档
    for (final String id in spotsToApply) {
      final dynamic spot = spots[id];
      if (spot is! Map) continue;
      final int page = (spot['page'] as num?)?.toInt() ?? -1;
      final int sentence = (spot['sentence'] as num?)?.toInt() ?? -1;
      if (page < 0 || sentence < 0) continue;
      await StorageService.instance.setPdfReadingSpot(
        id,
        pageIndex: page,
        sentenceIndex: sentence,
      );
    }

    // 4) 阅读样式：只在「本来就没有书」（全新安装）时套用
    bool styleApplied = false;
    final dynamic style = meta['readerStyle'];
    if (libraryWasEmpty && style is Map) {
      try {
        final ReaderStyle parsed =
            ReaderStyle.fromJson(style.cast<String, dynamic>());
        StorageService.instance.setReaderStyle(parsed);
        styleApplied = true;
      } catch (e) {
        debugPrint('备份里的阅读样式无法解析，已跳过：$e');
      }
    }

    return LibraryRestoreResult(
      addedDocuments: added,
      updatedDocuments: updated,
      skippedDocuments: skipped,
      filesWritten: filesWritten,
      filesReused: filesReused,
      missingFiles: missingFiles,
      styleApplied: styleApplied,
    );
  }

  // ---------------- 内部工具 ----------------

  static ArchiveFile? _findMeta(Archive archive) {
    for (final ArchiveFile f in archive.files) {
      if (f.isFile && f.name.replaceAll('\\', '/') == metaEntry) return f;
    }
    return null;
  }

  /// 落盘一个书籍文件
  ///
  /// - 同名同大小 → 视为同一本书，**直接复用**，不重复占空间（reused=true）
  /// - 同名不同大小 → 另存为 `名字 (1).ext`，原文件一动不动
  /// - 目标不存在 → 写入（reused=false）
  static Future<({String path, bool reused})> _landFile(
    Directory books,
    String fileName,
    Uint8List content,
  ) async {
    final String sep = Platform.pathSeparator;
    final String target = '${books.path}$sep$fileName';
    final File existing = File(target);
    if (existing.existsSync()) {
      if (existing.lengthSync() == content.length) {
        return (path: target, reused: true);
      }
      final String alt = _uniqueNameOnDisk(
        fileName,
        (String n) => File('${books.path}$sep$n').existsSync(),
      );
      final String altPath = '${books.path}$sep$alt';
      await File(altPath).writeAsBytes(content, flush: true);
      return (path: altPath, reused: false);
    }
    await existing.writeAsBytes(content, flush: true);
    return (path: target, reused: false);
  }

  static String _uniqueName(String name, Set<String> used) {
    final int dot = name.lastIndexOf('.');
    final String stem = dot > 0 ? name.substring(0, dot) : name;
    final String ext = dot > 0 ? name.substring(dot) : '';
    int i = 1;
    String candidate = '$stem ($i)$ext';
    while (used.contains(candidate)) {
      i++;
      candidate = '$stem ($i)$ext';
    }
    return candidate;
  }

  static String _uniqueNameOnDisk(String name, bool Function(String) exists) {
    final int dot = name.lastIndexOf('.');
    final String stem = dot > 0 ? name.substring(0, dot) : name;
    final String ext = dot > 0 ? name.substring(dot) : '';
    int i = 1;
    String candidate = '$stem ($i)$ext';
    while (exists(candidate)) {
      i++;
      candidate = '$stem ($i)$ext';
    }
    return candidate;
  }

  static String _baseName(String path) {
    final String normalized = path.replaceAll('\\', '/');
    final int slash = normalized.lastIndexOf('/');
    return slash >= 0 ? normalized.substring(slash + 1) : normalized;
  }

  static String _timestamp() {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}

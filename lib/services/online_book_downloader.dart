import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/document.dart';
import '../models/source_rule.dart';
import 'cover_fetch.dart';
import 'crash_log.dart';
import 'legado_source_store.dart';
import 'library_storage.dart';
import 'online_download_records.dart';
import 'source_client.dart';
import 'storage_service.dart';

/// 在线书「整本下载」的唯一实现
///
/// ## 为什么抽出来
///
/// 现在有两个地方能点下载：书籍详情页、在线书架列表。
/// 抓章的循环（取目录 → 逐章抓 → 拼 TXT → 收进书库 → 入库）只能有**一份**，
/// 否则两边的「第N章」标题格式、失败计数、进度口径迟早会分叉。
///
/// ## 仍然是「当场下载」，不是队列
///
/// 用户明确要求不要改成后台队列。所以这里只是一个**可等待的函数**：
/// 调用方自己决定是显示进度条（详情页）还是弹提示（书架）。
/// 记账交给 [OnlineDownloadRecords]，发现页的「下载列表」据此展示。
class OnlineBookDownloader {
  OnlineBookDownloader._();

  /// 已经整本下载过的话，返回它在文档库里的 id（否则 null）
  ///
  /// 会顺手校验本地文档是否还在：书架上标着「已下载」但文件被人删了，
  /// 就把标记清掉并返回 null —— 那种情况应该允许重新下载。
  static Future<String?> downloadedDocId(String bookUrl) async {
    final List<OnlineBookRecord> books =
        await LegadoSourceStore.instance.loadBooks();
    OnlineBookRecord? record;
    for (final OnlineBookRecord b in books) {
      if (b.url == bookUrl && b.isDownloaded) {
        record = b;
        break;
      }
    }
    final String? docId = record?.localDocumentId;
    if (docId == null || docId.isEmpty) return null;
    final List<Document> docs = await StorageService.instance.loadDocuments();
    final bool exists = docs.any((Document d) => d.id == docId);
    if (!exists) {
      await LegadoSourceStore.instance.attachLocalDocument(
        bookUrl: bookUrl,
        documentId: '',
      );
      return null;
    }
    return docId;
  }

  /// 下载整本，返回写入文档库的 documentId
  ///
  /// **不重复下载**：这本已经整本下过（且本地文件还在）就直接返回原文档 id，
  /// 不再抓一遍 —— 用户明确要求「已下载的书不可重复下载」。
  ///
  /// [onProgress] 每章回调一次 `(已下章数, 总章数)`，总章数在取到目录后才会 > 0。
  /// 失败会抛异常，调用方负责提示；记账（records）在这里做，不用调用方管。
  static Future<String> download({
    required SourceRule source,
    required OnlineBook book,
    void Function(int done, int total)? onProgress,
    @visibleForTesting
    SourceClient? clientOverride,
  }) async {
    final String? already = await downloadedDocId(book.url);
    if (already != null) {
      CrashLog.mark('在线下载[跳过] 已下载过 ${book.name}');
      return already;
    }
    final OnlineDownloadRecord record =
        OnlineDownloadRecords.instance.start(source: source, book: book);
    final SourceClient client = clientOverride ?? SourceClient(rule: source);
    try {
      final List<OnlineChapter> chapters = await client.toc(book.url);
      if (chapters.isEmpty) {
        throw const SourceOperationException('download', '目录是空的');
      }
      OnlineDownloadRecords.instance.progress(record, done: 0, total: chapters.length);
      onProgress?.call(0, chapters.length);

      final StringBuffer buffer = StringBuffer();
      var failed = 0;
      for (var i = 0; i < chapters.length; i++) {
        final OnlineChapter ch = chapters[i];
        try {
          final String text = await client.content(ch.url);
          if (text.trim().isNotEmpty) {
            // ⚠️ 必须写「第N章 标题」行：`TxtChapterSplitter` 全靠它分章，
            // 少一行整本就会变成一章（朗读目录直接失效）。
            buffer.writeln('第${i + 1}章 ${ch.name}');
            buffer.writeln(text.trim());
            buffer.writeln();
          }
        } catch (_) {
          failed++;
        }
        OnlineDownloadRecords.instance.progress(record, done: i + 1);
        onProgress?.call(i + 1, chapters.length);
      }

      if (buffer.isEmpty) {
        throw const SourceOperationException('download', '一章正文都没抓到');
      }

      final String safeName = _safeFileName(book.name);
      final Directory dir = await LibraryStorage.booksDir();
      final String rawPath = '${dir.path}${Platform.pathSeparator}$safeName.txt';
      await File(rawPath).writeAsString(buffer.toString(), flush: true);
      final AdoptResult adopted =
          await LibraryStorage.adopt(rawPath, name: '$safeName.txt');

      final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
      final String docId = 'online-$stamp';
      await StorageService.instance.upsertDocument(
        Document(
          id: docId,
          title: book.name,
          path: adopted.path,
          type: DocumentType.txt,
          importedAt: DateTime.now(),
        ),
      );
      OnlineDownloadRecords.instance.finish(record, docId, failed: failed);

      // ★v1.22.2：**封面优先用在线详情页那张**
      //
      // 下载下来的是 TXT，本身没有图片；只靠排版画的封面不如原书封面。
      // 而下载它的那个详情页是有封面的（`ruleBookInfo.coverUrl`），
      // 这里顺手抓一张存成文档封面。抓不到就不管 —— 之后 `extractCover`
      // 还会走文字封面那条路，不会出现"没封面"。
      await _attachRemoteCover(docId: docId, book: book);

      // 如果这本在在线书架里，记下「已下载」指向哪个本地文档：
      // 之后从书架点开就直接读本地那份，不再联网解析。
      await LegadoSourceStore.instance.attachLocalDocument(
        bookUrl: book.url,
        documentId: docId,
      );
      return docId;
    } catch (e) {
      OnlineDownloadRecords.instance.fail(record, e);
      rethrow;
    } finally {
      if (clientOverride == null) client.dispose();
    }
  }

  /// 把在线详情页的封面抓下来挂到刚生成的文档上
  ///
  /// 失败一律忽略（封面是装饰，不该影响"书已经下好了"这个事实）。
  static Future<void> _attachRemoteCover({
    required String docId,
    required OnlineBook book,
  }) async {
    try {
      final String coverUrl = book.coverUrl.trim();
      if (coverUrl.isEmpty) return;
      // 与 home_page 那边补封面用的是同一个目录约定
      final Directory base = await getApplicationDocumentsDirectory();
      final String outPath =
          '${base.path}${Platform.pathSeparator}covers'
          '${Platform.pathSeparator}$docId.jpg';
      final String? saved = await CoverFetcher.fetchTo(coverUrl, outPath);
      if (saved == null) return;

      final List<Document> docs =
          await StorageService.instance.loadDocuments();
      for (final Document d in docs) {
        if (d.id != docId) continue;
        await StorageService.instance.upsertDocument(d.copyWith(coverPath: saved));
        break;
      }
    } catch (_) {
      // 封面失败不影响下载结果
    }
  }

  /// 书源被删掉时给一句人话
  static Future<SourceRule?> sourceOf(String sourceUrl) async {
    final List<SourceRule> all = await LegadoSourceStore.instance.load();
    for (final SourceRule r in all) {
      if (r.url == sourceUrl) return r;
    }
    return null;
  }

  static String _safeFileName(String name) {
    final String cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return '未命名';
    return cleaned.length > 80 ? cleaned.substring(0, 80) : cleaned;
  }
}

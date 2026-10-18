import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/document.dart';
import '../models/source_rule.dart';
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

  /// 下载整本，返回写入文档库的 documentId
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

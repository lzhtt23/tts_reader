import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/services/legado_source_store.dart';
import 'package:tts_reader/services/online_book_downloader.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 已下载的书**不可重复下载**（用户要求）
///
/// `downloadedDocId` 就是判据：拿它挡下载。
/// 注意「标记还在但本地文件被删」要视为未下载 —— 那种情况应允许重下。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    LegadoSourceStore.instance.refreshForTest();
  });

  const String bookUrl = 'http://a.com/book/1';

  Future<void> addShelfBook() => LegadoSourceStore.instance.upsertBook(
        const OnlineBookRecord(
          url: bookUrl,
          name: '书',
          sourceUrl: 'http://s.com',
        ),
      );

  Future<void> addDoc(String id) => StorageService.instance.upsertDocument(
        Document(
          id: id,
          title: '书',
          path: '/tmp/$id.txt',
          type: DocumentType.txt,
          importedAt: DateTime(2026, 1, 1),
        ),
      );

  test('没下过 → null', () async {
    await addShelfBook();
    expect(await OnlineBookDownloader.downloadedDocId(bookUrl), isNull);
  });

  test('标记 + 本地文档都在 → 返回文档 id（据此拒绝重复下载）', () async {
    await addShelfBook();
    await addDoc('doc-1');
    await LegadoSourceStore.instance.attachLocalDocument(
      bookUrl: bookUrl,
      documentId: 'doc-1',
    );
    expect(await OnlineBookDownloader.downloadedDocId(bookUrl), 'doc-1');
  });

  test('标记还在但本地文档被删 → 视为未下载（允许重下），且不移出书架', () async {
    await addShelfBook();
    await LegadoSourceStore.instance.attachLocalDocument(
      bookUrl: bookUrl,
      documentId: 'doc-gone',
    );
    expect(await OnlineBookDownloader.downloadedDocId(bookUrl), isNull);

    final List<OnlineBookRecord> books =
        await LegadoSourceStore.instance.loadBooks();
    expect(books, hasLength(1), reason: '不能把书移出书架');
    expect(books.single.isDownloaded, isFalse, reason: '失效标记要清掉');
  });

  test('不在书架里的书 → null（不能被顺手加进书架）', () async {
    expect(await OnlineBookDownloader.downloadedDocId('http://x.com/none'), isNull);
    expect(await LegadoSourceStore.instance.loadBooks(), isEmpty);
  });
}

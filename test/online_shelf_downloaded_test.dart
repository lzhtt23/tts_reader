import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/legado_source_store.dart';

/// 在线书架：下载完成后「优先读本地」
///
/// 用户要求：
/// * 下载好的书，在在线书架打开要**跳本地那份**，不再在线解析；
/// * 列表要显示「已下载」标志。
///
/// 这条链路的关键是「书架记录里记住本地文档 id」，
/// 也就是 [LegadoSourceStore.attachLocalDocument]。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LegadoSourceStore.instance.refreshForTest();
  });

  OnlineBookRecord book(String url) => OnlineBookRecord(
    url: url,
    name: '书$url',
    sourceUrl: 'http://src.com',
  );

  test('新加的书默认不是「已下载」', () async {
    await LegadoSourceStore.instance.upsertBook(book('http://a.com/1'));
    final OnlineBookRecord got =
        (await LegadoSourceStore.instance.loadBooks()).single;
    expect(got.isDownloaded, isFalse);
    expect(got.localDocumentId, isNull);
  });

  test('下载完成回写本地文档 id 后变成「已下载」', () async {
    await LegadoSourceStore.instance.upsertBook(book('http://a.com/1'));
    final bool ok = await LegadoSourceStore.instance.attachLocalDocument(
      bookUrl: 'http://a.com/1',
      documentId: 'online-123',
    );
    expect(ok, isTrue);

    final OnlineBookRecord got =
        (await LegadoSourceStore.instance.loadBooks()).single;
    expect(got.isDownloaded, isTrue);
    expect(got.localDocumentId, 'online-123');
    // 其它字段不能被覆盖
    expect(got.name, '书http://a.com/1');
    expect(got.sourceUrl, 'http://src.com');
  });

  test('不在书架的书：回写返回 false，也不会被顺手加进书架', () async {
    final bool ok = await LegadoSourceStore.instance.attachLocalDocument(
      bookUrl: 'http://a.com/nope',
      documentId: 'online-999',
    );
    expect(ok, isFalse);
    expect(await LegadoSourceStore.instance.loadBooks(), isEmpty);
  });

  test('本地文档被删：清空标记后回到「未下载」', () async {
    await LegadoSourceStore.instance.upsertBook(book('http://a.com/1'));
    await LegadoSourceStore.instance.attachLocalDocument(
      bookUrl: 'http://a.com/1',
      documentId: 'online-123',
    );
    await LegadoSourceStore.instance.attachLocalDocument(
      bookUrl: 'http://a.com/1',
      documentId: '',
    );
    final OnlineBookRecord got =
        (await LegadoSourceStore.instance.loadBooks()).single;
    expect(got.isDownloaded, isFalse);
  });

  test('标记要能持久化（toJson / fromJson 往返）', () {
    const OnlineBookRecord r = OnlineBookRecord(
      url: 'http://a.com/1',
      name: '书',
      sourceUrl: 'http://src.com',
      localDocumentId: 'online-777',
    );
    final OnlineBookRecord back = OnlineBookRecord.fromJson(r.toJson());
    expect(back.localDocumentId, 'online-777');
    expect(back.isDownloaded, isTrue);
  });

  test('删本地文档只清「已下载」标记，书**仍在书架**（用户要求）', () async {
    await LegadoSourceStore.instance.upsertBook(book('http://a.com/1'));
    await LegadoSourceStore.instance.attachLocalDocument(
      bookUrl: 'http://a.com/1',
      documentId: 'online-123',
    );

    final int cleared = await LegadoSourceStore.instance
        .detachLocalDocumentByDocumentId('online-123');
    expect(cleared, 1);

    final List<OnlineBookRecord> books =
        await LegadoSourceStore.instance.loadBooks();
    expect(books, hasLength(1), reason: '不能把书移出书架');
    expect(books.single.isDownloaded, isFalse, reason: '标记要清掉');
    expect(books.single.url, 'http://a.com/1');
  });

  test('删的是别的文档：不碰书架', () async {
    await LegadoSourceStore.instance.upsertBook(book('http://a.com/1'));
    await LegadoSourceStore.instance.attachLocalDocument(
      bookUrl: 'http://a.com/1',
      documentId: 'online-123',
    );
    final int cleared = await LegadoSourceStore.instance
        .detachLocalDocumentByDocumentId('online-别的');
    expect(cleared, 0);
    final OnlineBookRecord got =
        (await LegadoSourceStore.instance.loadBooks()).single;
    expect(got.isDownloaded, isTrue);
  });
}

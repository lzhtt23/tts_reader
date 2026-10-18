import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/legado_source_store.dart';

/// **在线阅读 ≠ 加入在线书架**
///
/// 之前打开阅读页会自动 `upsertBook`，导致「随便点开一本，书架就被塞满」。
/// 现在的语义：
/// - 只有用户点「放入书架」才写记录
/// - 阅读只对**已在书架**的那本更新进度
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LegadoSourceStore.instance.refreshForTest();
  });

  OnlineBookRecord book(String url, {int chapter = 0}) => OnlineBookRecord(
    url: url,
    name: '书$url',
    sourceUrl: 'http://src.com',
    chapterIndex: chapter,
  );

  test('只阅读不加书架：updateBookProgress 对不在书架的书返回 false 且不新增', () async {
    final bool updated = await LegadoSourceStore.instance.updateBookProgress(
      url: 'http://a.com/1',
      chapterIndex: 5,
    );
    expect(updated, isFalse);
    expect(await LegadoSourceStore.instance.loadBooks(), isEmpty);
  });

  test('已在书架的书：只更新进度，不改变名字/来源', () async {
    await LegadoSourceStore.instance.upsertBook(book('http://a.com/1'));
    final bool updated = await LegadoSourceStore.instance.updateBookProgress(
      url: 'http://a.com/1',
      chapterIndex: 9,
      chapterName: '第9章',
    );
    expect(updated, isTrue);

    final List<OnlineBookRecord> books =
        await LegadoSourceStore.instance.loadBooks();
    expect(books, hasLength(1));
    expect(books.single.chapterIndex, 9);
    expect(books.single.chapterName, '第9章');
    expect(books.single.name, '书http://a.com/1');
    expect(books.single.sourceUrl, 'http://src.com');
  });

  test('加入书架（显式 upsertBook）才会出现在列表里', () async {
    await LegadoSourceStore.instance.upsertBook(book('http://a.com/2'));
    final List<OnlineBookRecord> books =
        await LegadoSourceStore.instance.loadBooks();
    expect(books, hasLength(1));
    expect(books.single.url, 'http://a.com/2');
  });

  test('移出书架后，再更新进度不会把它加回来', () async {
    await LegadoSourceStore.instance.upsertBook(book('http://a.com/3'));
    await LegadoSourceStore.instance.removeBook('http://a.com/3');
    final bool updated = await LegadoSourceStore.instance.updateBookProgress(
      url: 'http://a.com/3',
      chapterIndex: 2,
    );
    expect(updated, isFalse);
    expect(await LegadoSourceStore.instance.loadBooks(), isEmpty);
  });
}

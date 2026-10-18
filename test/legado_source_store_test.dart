import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/source_rule.dart';
import 'package:tts_reader/services/legado_source_store.dart';
import 'package:tts_reader/services/source_importer.dart';

SourceRule _rule({
  String url = 'https://a.test',
  String name = 'A',
  int update = 1,
  bool usable = true,
}) => SourceRule.fromJson(<String, dynamic>{
  'bookSourceUrl': url,
  'bookSourceName': name,
  'lastUpdateTime': update,
  'searchUrl': '/s?q={{key}}',
  if (usable) ...<String, dynamic>{
    'ruleSearch': <String, dynamic>{
      'bookList': '.l li',
      'name': 'a@text',
      'bookUrl': 'a@href',
    },
    'ruleToc': <String, dynamic>{
      'chapterList': '.c a',
      'chapterName': '@text',
      'chapterUrl': '@href',
    },
    'ruleContent': <String, dynamic>{'content': '#c@html'},
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LegadoSourceStore.instance.clearAllForTest();
  });

  group('LegadoSourceStore 书源', () {
    test('初始为空', () async {
      expect(await LegadoSourceStore.instance.load(), isEmpty);
    });

    test('保存后能读回，字段完整', () async {
      await LegadoSourceStore.instance.saveAll(<SourceRule>[
        _rule(url: 'https://a.test', name: '甲'),
        _rule(url: 'https://b.test', name: '乙'),
      ]);
      final List<SourceRule> all = await LegadoSourceStore.instance.load();
      expect(all.length, 2);
      expect(all.map((SourceRule r) => r.name), containsAll(<String>['甲', '乙']));
      final SourceRule a = all.firstWhere((SourceRule r) => r.name == '甲');
      expect(a.ruleSearch?['bookList'], '.l li');
    });

    test('upsert 新增与更新并存', () async {
      await LegadoSourceStore.instance.saveAll(<SourceRule>[
        _rule(url: 'https://a.test', name: '旧', update: 1),
      ]);
      await LegadoSourceStore.instance.upsert(<SourceRule>[
        _rule(url: 'https://a.test', name: '新', update: 2),
        _rule(url: 'https://b.test', name: '乙'),
      ]);
      final List<SourceRule> all = await LegadoSourceStore.instance.load();
      expect(all.length, 2);
      expect(
        all.firstWhere((SourceRule r) => r.url == 'https://a.test').name,
        '新',
      );
    });

    test('remove 只删指定条', () async {
      await LegadoSourceStore.instance.saveAll(<SourceRule>[
        _rule(url: 'https://a.test'),
        _rule(url: 'https://b.test'),
      ]);
      await LegadoSourceStore.instance.remove('https://a.test');
      final List<SourceRule> all = await LegadoSourceStore.instance.load();
      expect(all.length, 1);
      expect(all.first.url, 'https://b.test');
    });

    test('loadUsable 过滤掉不支持与禁用的', () async {
      await LegadoSourceStore.instance.saveAll(<SourceRule>[
        _rule(url: 'https://ok.test'),
        _rule(url: 'https://bad.test', usable: false),
        _rule(url: 'https://off.test').copyWith(enabled: false),
      ]);
      final List<SourceRule> usable = await LegadoSourceStore.instance.loadUsable();
      expect(usable.length, 1);
      expect(usable.first.url, 'https://ok.test');
    });

    test('存档损坏时返回空而不是崩', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'legado_sources_v1': '这不是 JSON',
      });
      LegadoSourceStore.instance.refreshForTest();
      expect(await LegadoSourceStore.instance.load(), isEmpty);
    });
  });

  group('LegadoSourceStore 在线书', () {
    test('保存与读回进度', () async {
      await LegadoSourceStore.instance.upsertBook(
        const OnlineBookRecord(
          url: 'https://book/1',
          name: '书一',
          sourceUrl: 'https://a.test',
          author: '甲',
          chapterIndex: 5,
          paragraph: 2,
          sentence: 1,
        ),
      );
      final List<OnlineBookRecord> books = await LegadoSourceStore.instance.loadBooks();
      expect(books.length, 1);
      expect(books.first.chapterIndex, 5);
      expect(books.first.cursor, (5, 2, 1));
    });

    test('同一 url 再次保存是更新不是新增', () async {
      await LegadoSourceStore.instance.upsertBook(
        const OnlineBookRecord(
          url: 'https://book/1',
          name: '书一',
          sourceUrl: 'https://a.test',
          chapterIndex: 1,
        ),
      );
      await LegadoSourceStore.instance.upsertBook(
        const OnlineBookRecord(
          url: 'https://book/1',
          name: '书一',
          sourceUrl: 'https://a.test',
          chapterIndex: 9,
        ),
      );
      final List<OnlineBookRecord> books = await LegadoSourceStore.instance.loadBooks();
      expect(books.length, 1);
      expect(books.first.chapterIndex, 9);
    });

    test('copyWith 保留身份只改进度', () async {
      const OnlineBookRecord r = OnlineBookRecord(
        url: 'https://book/1',
        name: '书一',
        sourceUrl: 'https://a.test',
        chapterIndex: 1,
      );
      final OnlineBookRecord moved = r.copyWith(chapterIndex: 7, sentence: 3);
      expect(moved.url, r.url);
      expect(moved.chapterIndex, 7);
      expect(moved.sentence, 3);
      expect(moved.paragraph, 0);
    });

    test('删除单本', () async {
      await LegadoSourceStore.instance.upsertBook(
        const OnlineBookRecord(
          url: 'https://book/1',
          name: '书一',
          sourceUrl: 'https://a.test',
        ),
      );
      await LegadoSourceStore.instance.removeBook('https://book/1');
      expect(await LegadoSourceStore.instance.loadBooks(), isEmpty);
    });
  });

  group('与旧书源键互不干扰', () {
    test('legado 书源不写进 book_sources', () async {
      await LegadoSourceStore.instance.saveAll(<SourceRule>[_rule()]);
      final SharedPreferences sp = await SharedPreferences.getInstance();
      // 旧键必须没被动过
      expect(sp.getString('book_sources'), isNull);
      expect(sp.getString('legado_sources_v1'), isNotNull);
    });

    test('导入合并后整体可用', () async {
      final String json = jsonEncode(<Map<String, dynamic>>[
        _rule(url: 'https://a.test', name: '甲', update: 100).toJson(),
        _rule(url: 'https://b.test', name: '乙', update: 100).toJson(),
      ]);
      final ParseOutcome out = await SourceImporter.parseText(json);
      final Map<String, SourceRule> local =
          await LegadoSourceStore.instance.loadByUrl();
      final SourceImportResult merged = mergeSourceRules(out.rules, local);
      expect(merged.added.length, 2);

      await LegadoSourceStore.instance.upsert(<SourceRule>[
        ...merged.added,
        ...merged.updated,
      ]);
      expect((await LegadoSourceStore.instance.load()).length, 2);
      expect((await LegadoSourceStore.instance.loadUsable()).length, 2);
    });
  });
}

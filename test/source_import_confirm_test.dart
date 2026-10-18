import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/source_rule.dart';
import 'package:tts_reader/pages/source_import_confirm_page.dart';
import 'package:tts_reader/services/legado_source_store.dart';
import 'package:tts_reader/services/source_link_parser.dart';

/// 「一键导入」全链路：链接 → 解析 → 勾选页 → 写库
///
/// 这组用例回答一个问题：**一键导入到底能不能用**。
/// 不联网（书源 JSON 用内存里的真实结构样本），但每一步都走真实代码路径。
void main() {
  /// 真实书源合集里的一条（字段与线上一致）
  Map<String, dynamic> sampleSource(String name, String url, {int time = 1700000000000}) =>
      <String, dynamic>{
        'bookSourceName': name,
        'bookSourceUrl': url,
        'bookSourceGroup': '测试',
        'bookSourceType': 0,
        'bookSourceComment': '',
        'enabled': true,
        'enabledExplore': true,
        'lastUpdateTime': time,
        'searchUrl': '$url/search?key={{key}}',
        'ruleSearch': <String, dynamic>{
          'bookList': 'class.result@tag.li',
          'name': 'tag.a@text',
          'author': 'class.author@text',
          'bookUrl': 'tag.a@href',
        },
        'ruleToc': <String, dynamic>{
          'chapterList': 'id.list@tag.a',
          'chapterName': 'text',
          'chapterUrl': 'href',
        },
        'ruleContent': <String, dynamic>{'content': 'id.content@textNodes'},
        'ruleBookInfo': <String, dynamic>{'name': 'tag.h1@text'},
      };

  group('链接解析', () {
    test('从书源合集链接里提出 src', () {
      const String link =
          'yuedu://booksource/importonline?src=https://shuyuan-api.yiovc.com/import/book-source-collection/eaedccd4-1252-4962-a565-c7a342f95f90';
      expect(
        SourceLinkParser.extractBookSourceUrl(link),
        'https://shuyuan-api.yiovc.com/import/book-source-collection/eaedccd4-1252-4962-a565-c7a342f95f90',
      );
    });
  });

  group('勾选页', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    final List<SourceRule> parsed = <SourceRule>[
      SourceRule.fromJson(sampleSource('错层小说网', 'https://a.com')),
      SourceRule.fromJson(sampleSource('精华书阁手机版', 'https://b.com')),
      SourceRule.fromJson(sampleSource('笔趣阁', 'https://c.com')),
    ];

    testWidgets('默认全选，显示「新增」，确认返回全部', (tester) async {
      List<SourceRule>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<List<SourceRule>>(
                    MaterialPageRoute<List<SourceRule>>(
                      builder: (_) => SourceImportConfirmPage(
                        sources: parsed,
                        localUrls: const <String>{},
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 三条都列出来了
      expect(find.text('错层小说网'), findsOneWidget);
      expect(find.text('精华书阁手机版'), findsOneWidget);
      expect(find.text('笔趣阁'), findsOneWidget);
      // 默认全选
      expect(find.text('取消全选 (3/3)'), findsOneWidget);
      for (final Checkbox box in tester.widgetList<Checkbox>(find.byType(Checkbox))) {
        expect(box.value, isTrue);
      }

      await tester.tap(find.byKey(SourceImportConfirmPage.confirmKey));
      await tester.pumpAndSettle();
      expect(result, hasLength(3));
    });

    testWidgets('取消全选后确认不可点', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SourceImportConfirmPage(
            sources: parsed,
            localUrls: const <String>{},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(SourceImportConfirmPage.toggleAllKey));
      await tester.pumpAndSettle();

      expect(find.text('全选 (0/3)'), findsOneWidget);
      final FilledButton confirm =
          tester.widget<FilledButton>(find.byKey(SourceImportConfirmPage.confirmKey));
      expect(confirm.onPressed, isNull, reason: '一个都没选时不该能确认');
    });

    testWidgets('已有源标「更新」，新源标「新增」', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SourceImportConfirmPage(
            sources: parsed,
            localUrls: const <String>{'https://a.com'},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('更新'), findsOneWidget);
      expect(find.text('新增'), findsNWidgets(2));
    });

    testWidgets('只勾一条，确认只返回那一条', (tester) async {
      List<SourceRule>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<List<SourceRule>>(
                    MaterialPageRoute<List<SourceRule>>(
                      builder: (_) => SourceImportConfirmPage(
                        sources: parsed,
                        localUrls: const <String>{},
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 取消全选，再单独勾「笔趣阁」
      await tester.tap(find.byKey(SourceImportConfirmPage.toggleAllKey));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(CheckboxListTile, '笔趣阁'),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('全选 (1/3)'), findsOneWidget);

      await tester.tap(find.byKey(SourceImportConfirmPage.confirmKey));
      await tester.pumpAndSettle();
      expect(result, hasLength(1));
      expect(result!.single.displayName, '笔趣阁');
    });
  });

  group('写库', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      // ⚠️ 必需：本类缓存了旧的 SharedPreferences 实例，
      // 不丢掉就会读到上一条用例写进去的数据（单例跨用例串数据）。
      LegadoSourceStore.instance.refreshForTest();
    });

    test('空库导入 3 条 → added=3', () async {
      final List<SourceRule> parsed = <SourceRule>[
        SourceRule.fromJson(sampleSource('A', 'https://a.com')),
        SourceRule.fromJson(sampleSource('B', 'https://b.com')),
        SourceRule.fromJson(sampleSource('C', 'https://c.com')),
      ];
      final ({int added, int updated}) r = await applySelectedSources(parsed);
      expect(r.added, 3);
      expect(r.updated, 0);

      final List<SourceRule> stored = await LegadoSourceStore.instance.load();
      expect(stored, hasLength(3));
      expect(
        stored.map((SourceRule s) => s.url).toSet(),
        <String>{'https://a.com', 'https://b.com', 'https://c.com'},
      );
    });

    test('重复导入同一批 → 全部算更新，不重复存', () async {
      final List<SourceRule> parsed = <SourceRule>[
        SourceRule.fromJson(sampleSource('A', 'https://a.com')),
        SourceRule.fromJson(sampleSource('B', 'https://b.com')),
      ];
      await applySelectedSources(parsed);
      final ({int added, int updated}) again =
          await applySelectedSources(parsed);
      expect(again.added, 0);
      expect(again.updated, 2);
      expect(await LegadoSourceStore.instance.load(), hasLength(2));
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/rss_source.dart';
import 'package:tts_reader/widgets/rss_import_confirm.dart';

/// 「导入订阅源」确认窗（被深链拉起时弹的那个）
///
/// 用户要求：拉起后要弹这种窗 —— 勾选列表 + 「已有」标记 + 全选(n/m) + 取消/确认。
///
/// 关键语义：**默认一个都不选**。这是从别的应用拉起来的，
/// 用户可能只是误点；替他把库改了是不对的。
void main() {
  List<RssSource> sources() => const <RssSource>[
    RssSource(sourceUrl: 'http://a.com/r.json', sourceName: '喵公子书源管理'),
    RssSource(sourceUrl: 'http://b.com/r.json', sourceName: '另一个订阅'),
  ];

  Future<List<RssSource>?> open(
    WidgetTester tester, {
    Set<String> existing = const <String>{},
  }) async {
    List<RssSource>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showRssImportConfirm(
                  context,
                  sources: sources(),
                  existingUrls: existing,
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
    return result;
  }

  testWidgets('列出全部订阅源，默认一个都不选', (tester) async {
    await open(tester);

    expect(find.text('导入订阅源'), findsOneWidget);
    expect(find.text('喵公子书源管理'), findsOneWidget);
    expect(find.text('另一个订阅'), findsOneWidget);
    // 默认不选
    expect(find.text('全选 (0/2)'), findsOneWidget);
    for (final Checkbox box in tester.widgetList<Checkbox>(find.byType(Checkbox))) {
      expect(box.value, isFalse);
    }
    // 一个都没选时不能确认
    final FilledButton confirm =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确认'));
    expect(confirm.onPressed, isNull);
  });

  testWidgets('全选后确认返回全部', (tester) async {
    List<RssSource>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showRssImportConfirm(
                  context,
                  sources: sources(),
                  existingUrls: const <String>{},
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

    await tester.tap(find.text('全选 (0/2)'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();

    expect(result, hasLength(2));
  });

  testWidgets('只勾一条只返回那条', (tester) async {
    List<RssSource>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showRssImportConfirm(
                  context,
                  sources: sources(),
                  existingUrls: const <String>{},
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

    await tester.tap(
      find.descendant(
        of: find.widgetWithText(CheckboxListTile, '另一个订阅'),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('全选 (1/2)'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    expect(result, hasLength(1));
    expect(result!.single.displayName, '另一个订阅');
  });

  testWidgets('库里已有的标「已有」', (tester) async {
    await open(tester, existing: <String>{'http://a.com/r.json'});
    expect(find.text('已有'), findsOneWidget);
  });

  testWidgets('取消返回 null', (tester) async {
    List<RssSource>? result;
    var done = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showRssImportConfirm(
                  context,
                  sources: sources(),
                  existingUrls: const <String>{},
                );
                done = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(done, isTrue);
    expect(result, isNull);
  });
}

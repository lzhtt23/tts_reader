import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/pages/search_entry_page.dart';
import 'package:tts_reader/services/search_history.dart';

/// 搜索入口页：搜索历史 / 精准搜索 / 全部书源
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SearchHistory.instance.refreshForTest();
  });

  testWidgets('有搜索框、精准搜索、全部书源、搜索历史', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SearchEntryPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.byKey(SearchEntryPage.fieldKey), findsOneWidget);
    expect(find.byKey(SearchEntryPage.exactKey), findsOneWidget);
    expect(find.byKey(SearchEntryPage.sourcesKey), findsOneWidget);
    expect(find.text('搜索历史'), findsOneWidget);
  });

  testWidgets('没有历史时给一行提示', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SearchEntryPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text('还没有搜索记录'), findsOneWidget);
  });

  testWidgets('有历史时列出来，可以单条删除、可以删全部', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'search_history_v1': '["国家与革命","黎明之剑"]',
    });
    SearchHistory.instance.refreshForTest();

    await tester.pumpWidget(const MaterialApp(home: SearchEntryPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text('国家与革命'), findsOneWidget);
    expect(find.text('黎明之剑'), findsOneWidget);
    expect(find.byKey(SearchEntryPage.clearHistoryKey), findsOneWidget);

    // 单条删除
    await tester.tap(find.byTooltip('删除').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('国家与革命'), findsNothing);
    expect(find.text('黎明之剑'), findsOneWidget);

    // 删全部
    await tester.tap(find.byKey(SearchEntryPage.clearHistoryKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('还没有搜索记录'), findsOneWidget);
  });

  testWidgets('初始关键词会填进搜索框', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SearchEntryPage(initialKeyword: '异度')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    final TextField field = tester.widget<TextField>(
      find.byKey(SearchEntryPage.fieldKey),
    );
    expect(field.controller?.text, '异度');
  });
}

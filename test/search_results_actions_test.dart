import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/source_rule.dart';
import 'package:tts_reader/pages/search_results_page.dart';

/// 结果页顶部：**搜索框** + 筛选 + 刷新
///
/// 用户明确要求：结果页书名位置依然要是搜索框；右上角画圈处是筛选按钮。
void main() {
  final SourceRule source = SourceRule.fromJson(<String, dynamic>{
    'bookSourceName': '测试源',
    'bookSourceUrl': 'http://127.0.0.1:1',
    'bookSourceType': 0,
    'enabled': true,
    'searchUrl': 'http://127.0.0.1:1/search?key={{key}}',
    'ruleSearch': <String, dynamic>{
      'bookList': 'class.list@tag.li',
      'name': 'tag.a@text',
      'bookUrl': 'tag.a@href',
    },
  });

  testWidgets('顶部是搜索框（不是纯文字标题）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SearchResultsPage(keyword: '钢铁是怎样炼成的', sources: <SourceRule>[source]),
      ),
    );
    await tester.pump();

    final Finder field = find.byKey(SearchResultsPage.searchFieldKey);
    expect(field, findsOneWidget);
    // 搜索框里带着进来的关键词
    final TextField tf = tester.widget<TextField>(field);
    expect(tf.controller?.text, '钢铁是怎样炼成的');
  });

  testWidgets('右上角是筛选 + 刷新（不再有改词放大镜）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SearchResultsPage(keyword: 'x', sources: <SourceRule>[source]),
      ),
    );
    await tester.pump();

    expect(find.byKey(SearchResultsPage.filterKey), findsOneWidget);
    expect(find.byKey(SearchResultsPage.refreshKey), findsOneWidget);
    expect(find.byTooltip('筛选书源'), findsOneWidget);
  });

  testWidgets('点筛选会弹出书源勾选', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SearchResultsPage(keyword: 'x', sources: <SourceRule>[source]),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(SearchResultsPage.filterKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('筛选书源'), findsWidgets);
    expect(find.textContaining('测试源'), findsWidgets);
    expect(find.text('用这些书源搜索'), findsOneWidget);
  });
}

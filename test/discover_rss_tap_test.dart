import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/pages/discover_page.dart';
import 'package:tts_reader/pages/rss_articles_page.dart';

/// 订阅网格：点卡片要能进文章列表
///
/// 用户反馈「点图一（订阅网格）的按钮不跳转」。这里用最小数据复现：
/// 存一个可用的订阅源，点它，断言 push 了 [RssArticlesPage]。
void main() {
  const String source = '''
[{
  "sourceUrl": "http://example.test/list.html",
  "sourceName": "测试订阅",
  "ruleArticles": "class.item",
  "ruleLink": "tag.a@href",
  "ruleTitle": "tag.a@text",
  "enabled": true
}]
''';

  testWidgets('点订阅卡片会打开文章列表页', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'rss_sources_v1': source,
    });

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DiscoverPage())),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 网格里应当出现这个订阅
    expect(find.text('测试订阅'), findsOneWidget);

    await tester.tap(find.text('测试订阅'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byType(RssArticlesPage),
      findsOneWidget,
      reason: '点订阅卡片应当进入文章列表',
    );
  });
}

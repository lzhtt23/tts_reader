import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/pages/legado_sources_page.dart';

/// 书源管理页：右上角的「导入书源」入口
///
/// 用户反馈「在书源管理里找不到导入入口」——原来只有右下角一个悬浮键，
/// 长列表里容易被当成页面内容忽略。这组用例钉住右上角那个按钮真的在、真的能点开菜单。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('没有书源时，右上角有「导入书源」按钮', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LegadoSourcesPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(LegadoSourcesPage.importKey), findsOneWidget);
    expect(find.byTooltip('导入书源'), findsWidgets);
  });

  testWidgets('点右上角按钮会打开导入菜单', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LegadoSourcesPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byKey(LegadoSourcesPage.importKey));
    await tester.pumpAndSettle();

    // 底部弹层里应当出现几个入口（粘贴 / 剪贴板 / 订阅地址）
    expect(find.textContaining('粘贴'), findsWidgets);
  });

  testWidgets('空态提示指向右上角，而不是只说右下角', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LegadoSourcesPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('右上角'), findsOneWidget);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/main.dart';
import 'package:tts_reader/pages/discover_page.dart';
import 'package:tts_reader/pages/home_page.dart';

/// 发现页 + 四 Tab 结构
///
/// 背景：导航栏从三 Tab 变四 Tab，`_index` 原来是硬编码 0/1/2，
/// 散在 6 处（IndexedStack、_visited、浏览器进度条、AppBar、FAB、宽窄两套
/// destinations）。这组用例钉住「顺序正确」和「发现页真的接进去了」。
///
/// ⚠️ 两个测试环境坑：
/// 1. 默认画布 800×600 会命中 `kWideBreakpoint`（720）→ 走左侧 NavigationRail，
///    标签竖排，按坐标比较顺序没意义。所以显式设成手机尺寸。
/// 2. 首次启动会弹新手引导 AlertDialog，**会挡住点击**（点导航栏等于点在遮罩上）。
///    必须先关掉它，否则「切 Tab」永远不生效。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 手机尺寸 + 关掉新手引导
  Future<void> bootPhone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const TtsReaderApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 新手引导挡住了整个页面，先点「开始使用」关掉
    final Finder start = find.byKey(const ValueKey<String>('tutorial-start'));
    if (start.evaluate().isNotEmpty) {
      await tester.tap(start);
      await tester.pumpAndSettle();
    }
  }

  testWidgets('导航栏是四个 Tab，发现排在文档库之后', (tester) async {
    await bootPhone(tester);

    expect(find.text('文档库'), findsWidgets);
    expect(find.text('发现'), findsWidgets);
    expect(find.text('浏览器'), findsWidgets);
    expect(find.text('设置'), findsWidgets);

    // 顺序：文档库 → 发现 → 浏览器 → 设置
    final double libraryX = tester.getCenter(find.text('文档库').last).dx;
    final double discoverX = tester.getCenter(find.text('发现').last).dx;
    final double browserX = tester.getCenter(find.text('浏览器').last).dx;
    final double settingsX = tester.getCenter(find.text('设置').last).dx;
    expect(libraryX, lessThan(discoverX), reason: '发现应当在文档库之后');
    expect(discoverX, lessThan(browserX), reason: '发现应当在浏览器之前');
    expect(browserX, lessThan(settingsX), reason: '设置在最后');
  });

  testWidgets('切到发现页：懒建生效，页面上有搜索框和三个按钮', (tester) async {
    await bootPhone(tester);

    // 没点之前不构建（避免启动就初始化）
    expect(find.byType(DiscoverPage), findsNothing);

    await tester.tap(find.text('发现').last);
    await tester.pumpAndSettle();

    expect(find.byType(DiscoverPage), findsOneWidget);
    expect(find.byKey(DiscoverPage.searchFieldKey), findsOneWidget);
    // 方形「导入订阅源」键（用户指定：搜索栏右侧）
    expect(find.byKey(DiscoverPage.importRssKey), findsOneWidget);
    expect(find.byKey(DiscoverPage.sourcePickerKey), findsOneWidget);
    expect(find.byKey(DiscoverPage.downloadsKey), findsOneWidget);
  });

  testWidgets('没有订阅源时，搜索栏下方给一行提示', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DiscoverPage())),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 工具栏那行 + 空态引导标题都含这几个字，所以用 findsWidgets
    expect(find.textContaining('还没有订阅源'), findsWidgets);
  });

  testWidgets('切到发现页再切回文档库：文档库还在（IndexedStack 不丢状态）', (tester) async {
    await bootPhone(tester);

    await tester.tap(find.text('发现').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('文档库').last);
    await tester.pumpAndSettle();

    expect(find.byKey(HomePage.importButtonKey), findsOneWidget);
  });

  testWidgets('发现页没有订阅源时给引导，不是空白', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DiscoverPage())),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('还没有订阅源'), findsOneWidget);
    expect(find.text('导入订阅源'), findsWidgets);
  });
}

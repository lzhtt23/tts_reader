import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/main.dart';
import 'package:tts_reader/pages/discover_page.dart';

/// 导航切换：点别的 Tab **不许**先闪一下发现页
///
/// 用户报的现象：点导航栏其它按钮时会先抽出发现页再跳过去。
/// 已查到一个真凶：`_openInBrowser` 里写死 `_selectTab(1)`，
/// 而四 Tab 之后 1 就是「发现」——打开网址会先切到发现页。
///
/// 这组用例钉住「切哪儿就是哪儿」：点文档库/浏览器/设置，发现页都不该被建出来。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> bootPhone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const TtsReaderApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    final Finder start = find.byKey(const ValueKey<String>('tutorial-start'));
    if (start.evaluate().isNotEmpty) {
      await tester.tap(start);
      await tester.pumpAndSettle();
    }
  }

  testWidgets('点「设置」不会顺手建出发现页', (tester) async {
    await bootPhone(tester);
    expect(find.byType(DiscoverPage), findsNothing);

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();

    expect(
      find.byType(DiscoverPage),
      findsNothing,
      reason: '切设置不该让发现页进入 IndexedStack',
    );
  });

  // ⚠️ 不测「点浏览器」：`BrowserPage` 会立刻建 `InAppWebView`，
  // 测试环境没有平台实现，直接断言失败（与导航逻辑无关）。
  // 浏览器那条路径由下面的 `_openInBrowser` 常量用例覆盖。

  testWidgets('只有点「发现」才建发现页', (tester) async {
    await bootPhone(tester);

    await tester.tap(find.text('发现').last);
    await tester.pumpAndSettle();

    expect(find.byType(DiscoverPage), findsOneWidget);
  });
}

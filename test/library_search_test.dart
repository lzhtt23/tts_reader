import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/main.dart';
import 'package:tts_reader/pages/home_page.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 文档库搜索栏验证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 造几本书：书名、路径、类型、导入时间各不相同
  Map<String, Object> docs() => <String, Object>{
    // 这些用例测的是文档库本身：把「首次使用教程」标记为已看过，
    // 否则教程弹窗会盖住搜索框，点不到（教程本身由 tutorial_dialog_test 覆盖）。
    'tutorial_done': true,
    'tutorial_content_version': 99,
    'documents': jsonEncode(<Map<String, Object>>[
      <String, Object>{
        'id': '1',
        'title': '红楼梦 (曹雪芹)',
        'path': '/storage/emulated/0/Download/红楼梦 (曹雪芹).epub',
        'type': 'epub',
        'progress': 0.1,
        'importedAt': DateTime(2024, 1, 1).toIso8601String(),
        'lastReadAt': DateTime(2024, 3, 1).toIso8601String(),
      },
      <String, Object>{
        'id': '2',
        'title': '三体 第1部',
        'path': '/storage/emulated/0/Download/三体 第1部.txt',
        'type': 'txt',
        'progress': 0.5,
        'importedAt': DateTime(2024, 2, 1).toIso8601String(),
        'lastReadAt': DateTime(2024, 2, 2).toIso8601String(),
      },
      <String, Object>{
        'id': '3',
        'title': 'Effective Dart',
        'path': '/tmp/effective_dart_notes.pdf',
        'type': 'pdf',
        'progress': 0,
        'importedAt': DateTime(2024, 3, 1).toIso8601String(),
      },
    ]),
  };

  Future<void> pumpLibrary(WidgetTester tester) async {
    // 固定手机竖屏：默认测试窗口是 800x600，会命中平板布局
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await StorageService.instance.init();
    await tester.pumpWidget(const TtsReaderApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> search(WidgetTester tester, String keyword) async {
    await tester.enterText(find.byType(TextField).first, keyword);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(docs());
    StorageService.instance.resetForTest();
  });

  testWidgets('搜索栏存在，并能按书名过滤', (tester) async {
    await pumpLibrary(tester);
    expect(find.text('搜索书名或文件名'), findsOneWidget);
    expect(find.text('红楼梦 (曹雪芹)'), findsWidgets);
    expect(find.text('三体 第1部'), findsOneWidget);
    expect(find.text('Effective Dart'), findsOneWidget);

    await search(tester, '三体');
    expect(find.text('三体 第1部'), findsOneWidget);
    expect(find.text('红楼梦 (曹雪芹)'), findsNothing);
    expect(find.text('Effective Dart'), findsNothing);
    expect(find.text('找到 1 本'), findsOneWidget);
  });

  testWidgets('空格与大小写都不影响匹配', (tester) async {
    await pumpLibrary(tester);
    await search(tester, '  effective  ');
    expect(find.text('Effective Dart'), findsOneWidget);
    expect(find.text('找到 1 本'), findsOneWidget);

    await search(tester, 'EFFECTIVE');
    expect(find.text('Effective Dart'), findsOneWidget);
  });

  testWidgets('也能按文件名匹配（书名与文件名不一致时）', (tester) async {
    await pumpLibrary(tester);
    // 书名是「Effective Dart」，文件名是 effective_dart_notes.pdf
    await search(tester, 'notes');
    expect(find.text('Effective Dart'), findsOneWidget);
    expect(find.text('找到 1 本'), findsOneWidget);

    await search(tester, '.pdf');
    expect(find.text('Effective Dart'), findsOneWidget);
  });

  testWidgets('多个命中都列出来', (tester) async {
    await pumpLibrary(tester);
    await search(tester, '部');
    expect(find.text('三体 第1部'), findsOneWidget);
    expect(find.text('找到 1 本'), findsOneWidget);

    await search(tester, 'a');
    // Effective Dart 命中；中文书名不含 a
    expect(find.text('Effective Dart'), findsOneWidget);
    expect(find.text('找到 1 本'), findsOneWidget);
  });

  testWidgets('没有匹配时给出提示，清空后恢复', (tester) async {
    await pumpLibrary(tester);
    await search(tester, '不存在的书名');
    expect(find.text('没有匹配的文档'), findsWidgets);
    expect(find.text('红楼梦 (曹雪芹)'), findsNothing);

    // 点「清空搜索」按钮（注意 tonalIcon 的运行时类型是私有子类，
    // find.byType(FilledButton) 这种精确匹配找不到它，直接按文案点）
    await tester.tap(find.text('清空搜索'));
    await tester.pump();
    expect(find.text('红楼梦 (曹雪芹)'), findsWidgets);
    expect(find.text('三体 第1部'), findsOneWidget);
    expect(find.text('没有匹配的文档'), findsNothing);
  });

  testWidgets('输入框上的叉号能清空搜索', (tester) async {
    await pumpLibrary(tester);
    await search(tester, '三体');
    expect(find.byIcon(Icons.close), findsWidgets);

    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump();
    expect(find.text('红楼梦 (曹雪芹)'), findsWidgets);
    expect(find.text('找到 1 本'), findsNothing);
  });

  testWidgets('搜索与排序同时生效：过滤后仍按标题排序', (tester) async {
    await pumpLibrary(tester);
    // 切到「标题」排序。
    //
    // v1.22.76：排序按钮从 AppBar 收进了「更多」菜单（顶栏只留导入与更多），
    // 所以每一步都要"打开菜单 → 点排序项"，不能直接点 tooltip 了。
    Future<void> nextSort() async {
      await tester.tap(find.byKey(HomePage.moreMenuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('排序：').last);
      await tester.pumpAndSettle();
    }

    await nextSort(); // 最近阅读 → 导入时间
    await nextSort(); // 导入时间 → 标题

    // 不输入关键字时应当按标题升序（Dart 字符串序：ASCII < 中文）
    //
    // v1.22.76：「继续朗读」卡也会显示一本书名（在列表上方），
    // 所以取书名时要把卡里的那本排除掉，否则顺序断言会多出一项。
    List<String> listTitles() {
      final Set<String> inResume = <String>{};
      final Finder card = find.byKey(HomePage.resumeCardKey);
      if (card.evaluate().isNotEmpty) {
        for (final Text t in tester.widgetList<Text>(
          find.descendant(of: card, matching: find.byType(Text)),
        )) {
          final String? data = t.data;
          if (data != null) inResume.add(data);
        }
      }
      final List<String> out = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data ?? '')
          .where((value) =>
              value == '三体 第1部' ||
              value == '红楼梦 (曹雪芹)' ||
              value == 'Effective Dart')
          .toList();
      // 卡在列表上方 → 同名书**第一次**出现就是卡里的，扣掉一处即可
      for (final String name in inResume) {
        final int at = out.indexOf(name);
        if (at >= 0) out.removeAt(at);
      }
      return out;
    }

    final titles = listTitles();
    expect(titles, <String>['Effective Dart', '三体 第1部', '红楼梦 (曹雪芹)']);

    // 过滤后顺序保持不变（只剩命中项）
    await search(tester, '第1部');
    final filtered = listTitles();
    expect(filtered, <String>['三体 第1部']);
    expect(find.text('找到 1 本'), findsOneWidget);
  });

  testWidgets('文档库为空时不显示搜索栏', (tester) async {
    // 同上：跳过首次教程弹窗
    SharedPreferences.setMockInitialValues(<String, Object>{'tutorial_done': true});
    StorageService.instance.resetForTest();
    await pumpLibrary(tester);
    expect(find.text('文档库还是空的'), findsOneWidget);
    expect(find.text('搜索书名或文件名'), findsNothing);
  });

  testWidgets('平板横屏（网格布局）也有搜索栏', (tester) async {
    tester.view.physicalSize = const Size(2048, 1536);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await StorageService.instance.init();
    await tester.pumpWidget(const TtsReaderApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(SliverGrid), findsOneWidget);
    expect(find.text('搜索书名或文件名'), findsOneWidget);

    await search(tester, '三体');
    expect(find.text('三体 第1部'), findsOneWidget);
    expect(find.text('红楼梦 (曹雪芹)'), findsNothing);
  });
}
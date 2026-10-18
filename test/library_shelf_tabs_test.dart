import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/main.dart';
import 'package:tts_reader/pages/home_page.dart';
import 'package:tts_reader/services/legado_source_store.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 文档库的分类栏：本地书架 / 在线书架
///
/// 用户要求：「在文档库搜索栏下面添加一个分类栏，第一类是本地书架，第二类是在线书架」。
/// 这组用例钉住三件事：
/// 1. 有书时分类栏出现，且在搜索栏**下方**
/// 2. 两个分类能切换
/// 3. 在线书架空时有引导（不是一片空白）
void main() {
  /// 一条本地文档（够让库非空即可）
  String oneDoc() => jsonEncode(<Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'doc-1',
      'title': '测试文档',
      'path': '/tmp/测试文档.txt',
      'type': 'txt',
      'progress': 0.0,
      'importedAt': DateTime(2026, 1, 1).toIso8601String(),
    },
  ]);

  Future<void> bootPhone(WidgetTester tester) async {
    // ⚠️ 必需：StorageService / LegadoSourceStore 都缓存了 SharedPreferences 实例，
    // 每次 setMockInitialValues 换的是底层存储，不丢缓存就会读到上一条用例的数据。
    StorageService.instance.resetForTest();
    LegadoSourceStore.instance.refreshForTest();

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const TtsReaderApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    final Finder start = find.byKey(const ValueKey<String>('tutorial-start'));
    if (start.evaluate().isNotEmpty) {
      await tester.tap(start);
      await tester.pumpAndSettle();
    }
  }

  testWidgets('空库时不显示分类栏（先给导入引导）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await bootPhone(tester);

    expect(find.byKey(HomePage.shelfTabKey), findsNothing);
    expect(find.byKey(HomePage.importButtonKey), findsOneWidget);
  });

  testWidgets('有书时分类栏出现，含「本地书架」「在线书架」', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'documents': oneDoc(),
    });
    await bootPhone(tester);

    expect(find.byKey(HomePage.shelfTabKey), findsOneWidget);
    expect(find.textContaining('本地书架'), findsOneWidget);
    expect(find.textContaining('在线书架'), findsOneWidget);
  });

  testWidgets('分类栏在搜索栏下方（纵向位置更大）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'documents': oneDoc(),
    });
    await bootPhone(tester);

    final double searchY = tester.getCenter(find.byType(TextField).first).dy;
    final double tabY = tester.getCenter(find.byKey(HomePage.shelfTabKey)).dy;
    expect(tabY, greaterThan(searchY), reason: '分类栏应当在搜索栏下面');
  });

  testWidgets('切到在线书架：空时有引导，能回本地', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'documents': oneDoc(),
    });
    await bootPhone(tester);

    // 先确认本地有这本
    expect(find.text('测试文档'), findsOneWidget);

    await tester.tap(find.textContaining('在线书架'));
    await tester.pumpAndSettle();
    expect(find.text('在线书架是空的'), findsOneWidget);
    expect(find.text('测试文档'), findsNothing);

    await tester.tap(find.textContaining('本地书架'));
    await tester.pumpAndSettle();
    expect(find.text('测试文档'), findsOneWidget);
  });

  testWidgets('在线书架有条目时列出来，并能显示读到哪', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'documents': oneDoc(),
      'legado_online_books_v1': jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{
          'url': 'http://a.com/book/1',
          'name': '在线书一',
          'sourceUrl': 'http://a.com',
          'author': '作者甲',
          'chapterIndex': 0,
          'paragraph': 0,
          'sentence': 0,
          'chapterName': '第3章',
          'addedAt': DateTime(2026, 1, 1).toIso8601String(),
        },
      ]),
    });
    await bootPhone(tester);

    expect(find.textContaining('在线书架（1）'), findsOneWidget);
    await tester.tap(find.textContaining('在线书架'));
    await tester.pumpAndSettle();

    expect(find.text('在线书一'), findsOneWidget);
    expect(find.textContaining('读到：第3章'), findsOneWidget);
    // 每行要有下载键（用户要求：在线书架列表上加下载）
    expect(find.byKey(HomePage.onlineDownloadKey), findsOneWidget);
  });
}

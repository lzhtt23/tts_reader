import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:tts_reader/main.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/pages/home_page.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/pages/settings_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 界面冒烟测试：不依赖任何平台通道，验证主题、三 Tab 与文档卡片能正常构建
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'theme_mode': 'dark',
      // 跳过首次使用教程弹窗（它会盖住界面，挡住这些用例要找的控件）；
      // 教程本身由 tutorial_dialog_test 覆盖
      'tutorial_done': true,
      'tutorial_content_version': 99,
      'documents': jsonEncode(<Map<String, Object>>[
        <String, Object>{
          'id': '1',
          'title': '示例文档',
          'path': r'C:\books\demo.pdf',
          'type': 'pdf',
          'progress': 0.25,
          'importedAt': DateTime(2024, 5, 1).toIso8601String(),
        },
      ]),
    });
  });

  testWidgets('首页渲染：Material 3 + 种子色 + 三 Tab + 文档卡片', (tester) async {
    // 固定成手机竖屏尺寸：默认测试窗口是 800x600，会命中平板（宽屏）布局
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await StorageService.instance.init();
    await tester.pumpWidget(const TtsReaderApp());
    // 等待文档库异步载入完成（避免 pumpAndSettle 卡在加载动画上）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final context = tester.element(find.byType(Scaffold).first);
    final theme = Theme.of(context);

    // 主题：useMaterial3 + 0xFF6750A4 种子色（mock 设置里选了暗色）
    expect(theme.useMaterial3, isTrue);
    expect(theme.brightness, Brightness.dark);
    expect(
      theme.colorScheme.primary,
      ColorScheme.fromSeed(
        seedColor: TtsReaderApp.seedColor,
        brightness: Brightness.dark,
      ).primary,
    );

    // 三个 Tab
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('文档库'), findsWidgets);
    expect(find.text('浏览器'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

    // 文档卡片：类型 + 进度
    expect(find.text('示例文档'), findsOneWidget);
    expect(find.text('PDF · 进度 25%'), findsOneWidget);
    // 导入键：2026-10-18 从右下角悬浮按钮挪到搜索行右侧的方形按钮
    expect(find.byKey(HomePage.importButtonKey), findsOneWidget);

    // 未访问过的 Tab 不构建（懒加载，避免启动即初始化 WebView）
    expect(find.byType(SettingsPage), findsNothing);
  });

  testWidgets('平板横屏：换侧边导航栏，文档库变多列网格', (tester) async {
    // 2048x1536 @2x = 1024x768 逻辑像素：宽屏（平板横屏）
    tester.view.physicalSize = const Size(2048, 1536);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await StorageService.instance.init();
    await tester.pumpWidget(const TtsReaderApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 横屏不再用底部导航（离拇指太远），改成左侧导航栏
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('文档库'), findsWidgets);

    // 文档库在宽屏下是多列网格，同一屏能看更多书
    expect(find.byType(GridView), findsOneWidget);
    expect(find.text('示例文档'), findsOneWidget);

    // 侧边栏切到设置：懒加载仍然成立
    await tester.tap(find.text('设置').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(SettingsPage), findsOneWidget);
  });

  testWidgets('阅读页：后台 isolate 解析后渲染正文，目录可按页跳转', (tester) async {
    // 注意：testWidgets 运行在 fake-async 区域，真实文件 IO 必须放进 runAsync
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('tts_reader_widget'));
    final file = File('${dir!.path}/demo.txt')
      ..writeAsStringSync(
        List<String>.generate(90, (i) => '第 $i 段第一句。第 $i 段第二句！').join('\n\n'),
      );
    final document = Document(
      id: 'w1',
      title: '目录测试',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime(2024),
    );

    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      // 解析跑在独立 isolate 中：用 runAsync 让真实事件循环推进
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
      await tester.pump();
      await tester.pump();

      // 正文已渲染
      expect(find.textContaining('第 0 段第一句。'), findsWidgets);
      // 底部控制栏显示章 / 页 / 段 / 句与引擎名
      expect(find.textContaining('第 1 章'), findsOneWidget);

      // 打开目录：90 段按每页 40 段 = 3 页
      await tester.tap(find.byIcon(Icons.list_alt).first);
      await tester.pumpAndSettle();
      expect(find.text('目录'), findsOneWidget);
      expect(find.textContaining('90 段 · 3 页'), findsOneWidget);
      expect(find.text('第 3 页'), findsOneWidget);

      // 点击遮罩关闭，避免触发朗读（测试环境没有 TTS 插件）
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('目录'), findsNothing);
    } finally {
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) await dir.delete(recursive: true);
        } catch (_) {
          // 忽略 Windows 上的句柄占用
        }
      });
    }
  });

  testWidgets('阅读页：PDF 视图在页面重建时保持同一实例（否则会反复重读整个 PDF 直至闪退）', (tester) async {
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('tts_reader_pdf_widget'));
    final file = File('${dir!.path}/demo.pdf');
    final pdf = PdfDocument();
    for (var i = 0; i < 3; i++) {
      pdf.pages.add().graphics.drawString(
        'Page ${i + 1} content.',
        PdfStandardFont(PdfFontFamily.helvetica, 14),
        bounds: const Rect.fromLTWH(20, 20, 300, 60),
      );
    }
    file.writeAsBytesSync(pdf.saveSync());
    pdf.dispose();

    final document = Document(
      id: 'pdfw',
      title: 'pdf 测试',
      path: file.path,
      type: DocumentType.pdf,
      importedAt: DateTime(2024),
    );

    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      // 解析在 isolate 中进行
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
      await tester.pump();
      await tester.pump();

      expect(find.byType(SfPdfViewer), findsOneWidget);
      final before = tester.widget<SfPdfViewer>(find.byType(SfPdfViewer));

      // 触发一次整页重建（朗读推进时会频繁发生同样的事）
      await TtsManager.instance.setGranularity(ReadGranularity.chapter);
      await tester.pump();

      final after = tester.widget<SfPdfViewer>(find.byType(SfPdfViewer));
      // 同一个 widget 实例 → Flutter 在 updateChild 阶段直接复用，
      // SfPdfViewer.didUpdateWidget 不会被调用，也就不会重新读取并逐字节比较整个 PDF
      expect(identical(before, after), isTrue);
    } finally {
      // SfPdfViewer 内部会挂若干延时任务：先卸载视图，再推进时钟把它们清掉，
      // 否则测试收尾会报 “A Timer is still pending”
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
      await TtsManager.instance.setGranularity(ReadGranularity.sentence);
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) await dir.delete(recursive: true);
        } catch (_) {
          // 忽略 Windows 上的句柄占用
        }
      });
    }
  });
}
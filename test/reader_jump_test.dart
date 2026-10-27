import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 本轮修复的回归测试：
/// 1) 目录跳转（点页 / 输入页码）不能抛异常，并要真的跳到目标位置；
/// 2) 底部控制栏的「快进 / 上一页」按页步进，边界处不越界也不停住不动；
/// 3) 朗读游标与块列表错位时不能以 RangeError 闪退。
///
/// 注意：测试环境没有 flutter_tts 平台实现，所有插件调用都会走到超时失败分支。
/// 本文件断言的是「游标与界面状态」，不断言发声。
void main() {
  // SfPdfViewer 析构时会调用平台通道（closeDocument），测试环境没有原生实现，
  // 会以 MissingPluginException 冒出来把测试判失败。它和被测行为无关，过滤掉。
  final previousOnError = FlutterError.onError;
  setUpAll(() {
    FlutterError.onError = (FlutterErrorDetails details) {
      final text = details.exception.toString();
      if (text.contains('MissingPluginException') ||
          text.contains('syncfusion_flutter_pdfviewer')) {
        return;
      }
      previousOnError?.call(details);
    };
  });
  tearDownAll(() {
    FlutterError.onError = previousOnError;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 测试环境没有 flutter_tts 原生实现，所有插件调用都只会走到超时分支。
    // 把兜底超时压到毫秒级，既能验证「不挂住」这条修复，又不用等 30 秒。
    final tts = TtsManager.instance;
    tts
      ..speakTimeout = const Duration(milliseconds: 250)
      ..initTimeout = const Duration(milliseconds: 250)
      ..voiceTimeout = const Duration(milliseconds: 250)
      ..controlTimeout = const Duration(milliseconds: 250);
  });

  tearDown(() {
    TtsManager.instance.resetTimeouts();
  });

  /// 建一个 TXT（段数远超一屏，跳转必须走「估算 + 微调」路径）
  Future<(Directory, Document)> makeTxt(
    WidgetTester tester,
    String tag, {
    int paragraphs = 900,
  }) async {
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('tts_$tag'));
    final file = File('${dir!.path}/$tag.txt')
      ..writeAsStringSync(
        List<String>.generate(paragraphs, (i) => '第 $i 段第一句。第 $i 段第二句！').join('\n\n'),
      );
    return (
      dir,
      Document(
        id: tag,
        title: tag,
        path: file.path,
        type: DocumentType.txt,
        importedAt: DateTime(2024),
      ),
    );
  }

  Future<void> cleanup(WidgetTester tester, Directory dir) async {
    // 每页段数是全局设置：用例改过就要还原，否则会串到后面的用例
    await StorageService.instance.setParagraphsPerPage(
      StorageService.defaultParagraphsPerPage,
    );
    // TtsManager 是单例，测试里点过按钮就会留下朗读循环（它会不停地调插件）。
    // 先让它停下（同步的打断令牌立刻生效），再把兜底超时定时器等真实时间跑到期，
    // 否则测试收尾会报 "A Timer is still pending"。
    unawaited(TtsManager.instance.stop());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.runAsync(() async {
      try {
        if (dir.existsSync()) await dir.delete(recursive: true);
      } catch (_) {
        // Windows 上句柄占用时忽略
      }
    });
  }

  /// 轮询等待条件成立。
  ///
  /// speakFrom / _restart 是「改游标」这条链路上的异步入口（内部先 await 停掉上一段
  /// 声音，再落游标），所以断言前必须让真实事件循环跑一会儿，不能只 pump 一帧。
  Future<void> expectEventually(
    WidgetTester tester,
    bool Function() condition, {
    required String reason,
  }) async {
    for (var i = 0; i < 40; i++) {
      if (condition()) return;
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
    expect(condition(), isTrue, reason: reason);
  }

  /// 底部控制栏按钮：PDF 原版式视图自带同名图标，必须限定在控制栏的 Material 内查找
  Future<void> tapControlBar(WidgetTester tester, IconData icon) async {
    final target = find.descendant(
      of: find.byType(Material),
      matching: find.widgetWithIcon(IconButton, icon),
    );
    expect(target, findsWidgets, reason: '底部控制栏应存在 $icon 按钮');
    await tester.tap(target.last);
  }

  testWidgets('目录跳转：点「第 2 页」真的跳到第 41 段，且不抛异常', (tester) async {
    await StorageService.instance.init();
    final (dir, document) = await makeTxt(tester, 'toc_page');
    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1200)));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('第 0 段第一句。'), findsWidgets);

      // 打开目录：900 段 ÷ 每页 40 段 = 23 页
      await tester.tap(find.byIcon(Icons.list_alt).first);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('目录'), findsOneWidget);

      // v1.22.62：目录改成右侧悬浮卡片（高度 62% 屏高，比原来的 75% 矮），
      // 目标项可能在可视区外 —— 先滚到它再点。断言的仍是"点了就跳"这个行为。
      await tester.ensureVisible(find.text('第 2 页').first);
      await tester.pump();
      await tester.tap(find.text('第 2 页').first);
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1200)));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // 目录已关闭，视图落到第 2 页首段（下标 40）
      expect(find.text('目录'), findsNothing);
      expect(find.textContaining('第 40 段第一句。'), findsWidgets);
      expect(find.textContaining('第 0 段第一句。'), findsNothing);
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('目录跳转：输入页码跳转 + 越界页码不崩', (tester) async {
    await StorageService.instance.init();
    final (dir, document) = await makeTxt(tester, 'toc_input', paragraphs: 400);
    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1200)));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byIcon(Icons.list_alt).first);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // 输入远超总页数的页码：应夹取到最后一页而不是抛异常
      await tester.enterText(find.byType(TextField).first, '9999');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '跳转'));
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1000)));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('目录'), findsNothing);
      // 400 段 / 每页 40 段 = 10 页，最后一页首段下标 360
      expect(find.textContaining('第 360 段第一句。'), findsWidgets);
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('底部控制栏：上一句 / 下一句逐句进退，首尾都不越界', (tester) async {
    await StorageService.instance.init();
    final (dir, document) = await makeTxt(tester, 'ff', paragraphs: 90);
    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1200)));
      await tester.pump();
      await tester.pump();

      final tts = TtsManager.instance;
      // 每段两句：第 i 段第一句 => (0, i, 0)，第二句 => (0, i, 1)
      expect(tts.cursor, (0, 0, 0));

      // 图标统一成 fast_rewind / fast_forward 一对，且不再有按页进退的 skip_previous
      expect(find.byIcon(Icons.fast_rewind), findsOneWidget);
      expect(find.byIcon(Icons.fast_forward), findsOneWidget);
      expect(find.byIcon(Icons.skip_previous), findsNothing);

      await tapControlBar(tester, Icons.fast_forward);
      await expectEventually(
        tester,
        () => tts.cursor == (0, 0, 1),
        reason: '下一句应只走一句（同段第 2 句）',
      );

      await tapControlBar(tester, Icons.fast_forward);
      await expectEventually(
        tester,
        () => tts.cursor == (0, 1, 0),
        reason: '再下一句应跨到下一段第 1 句',
      );

      await tapControlBar(tester, Icons.fast_rewind);
      await expectEventually(
        tester,
        () => tts.cursor == (0, 0, 1),
        reason: '上一句应原路退回',
      );

      await tapControlBar(tester, Icons.fast_rewind);
      await expectEventually(
        tester,
        () => tts.cursor == (0, 0, 0),
        reason: '退回第一段第 1 句',
      );

      // 开头再上一句：夹取在首句，不越界（负下标会让朗读直接失败）
      await tapControlBar(tester, Icons.fast_rewind);
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(tts.cursor, (0, 0, 0), reason: '第一句再上一句不能越界');
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('悬浮定位按钮已删除；朗读推进时自动把正在读的那句拉回可见范围', (tester) async {
    await StorageService.instance.init();
    final (dir, document) = await makeTxt(tester, 'back', paragraphs: 400);
    try {
      // 用假引擎让「正在朗读」这个状态保持住：真引擎在测试环境里会直接超时失败，
      // speaking 变 false 之后自动跟随本来就不该生效（那样测的就不是这个功能了）。
      final tts = TtsManager.instance;
      tts.speakTimeout = const Duration(seconds: 30);
      await tts.registerEngine(_HoldingEngine(), makeActive: true);

      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1200)));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(ReaderPage.pageViewKey), findsOneWidget,
          reason: '文本模式应当是分页版面');
      // 需求：删掉播放页的定位按钮
      expect(find.byKey(ReaderPage.locateButtonKey), findsNothing,
          reason: '悬浮定位按钮应当已经删除');

      tts.speakFrom(0, 0, 0);
      for (var i = 0; i < 40 && !tts.speaking; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(tts.speaking, isTrue, reason: '假引擎下朗读应当处于进行中');
      expect(find.byKey(ReaderPage.locateButtonKey), findsNothing,
          reason: '朗读中也不该出现定位按钮');

      // 快进到本页靠后的句子：高亮框会一路往下走，越出可见范围时应当自动滚回来
      for (var i = 0; i < 24; i++) {
        await tester.tap(find.byKey(ReaderPage.nextSentenceKey));
        for (var j = 0; j < 12; j++) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
      }
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      // 正在读的那一句必须在可见范围内（自动定位生效）
      final cursor = tts.highlightCursor!;
      final anchor = find.textContaining('第 ${cursor.$2} 段第一句。');
      expect(anchor, findsWidgets,
          reason: '正在朗读的那一段应当在视野里（第 ${cursor.$2} 段）');
      final rect = tester.getRect(anchor.first);
      final screen = tester.getRect(find.byType(ReaderPage));
      // ignore: avoid_print
      print('DEVICE_VERIFY[auto-locate] cursor=$cursor '
          'rect=${rect.top.toStringAsFixed(0)}..${rect.bottom.toStringAsFixed(0)} '
          'screen=${screen.top.toStringAsFixed(0)}..${screen.bottom.toStringAsFixed(0)}');
      expect(rect.bottom, greaterThan(screen.top),
          reason: '朗读句不该跑到屏幕上方之外');
      expect(rect.top, lessThan(screen.bottom),
          reason: '朗读句不该掉到屏幕下方之外');
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('快进若干句：朗读位置一路跟随，文本框不乱动', (tester) async {
    await StorageService.instance.init();
    // 用长段落（一段 12 句）：短段落时整段都在屏幕里，测不出「句级跟随」
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('tts_ff'));
    final buffer = StringBuffer();
    for (var p = 0; p < 40; p++) {
      buffer.writeln(List<String>.generate(
        12,
        (s) => '第 $p 段第 $s 句的正文内容在这里写得长一点好占满整行。',
      ).join());
      buffer.writeln();
    }
    final file = File('${dir!.path}/ff.txt')..writeAsStringSync(buffer.toString());
    final document = Document(
      id: 'ff',
      title: '快进验证',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime(2024),
    );

    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
      await tester.pump();
      await tester.pump();

      // 从第 0 段开始读，然后连续「下一句」快进
      // （粒度必须设成「按句」：`_activeSentence` 只在按句时返回句下标，
      //   否则当前段不会挂 activeSentenceKey）
      await TtsManager.instance.setGranularity(ReadGranularity.sentence);
      TtsManager.instance.speakFrom(0, 0, 0);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      }

      final viewportTop = tester.getRect(find.byType(ReaderPage)).top;
      final viewportBottom = tester.getRect(find.byType(ReaderPage)).bottom;
      var samples = 0;
      var offscreen = 0;
      for (var step = 0; step < 28; step++) {
        await tester.tap(
          find.descendant(
            of: find.byType(Material),
            matching: find.widgetWithIcon(IconButton, Icons.fast_forward),
          ).last,
        );
        // 快进按钮与跟随滚动都是异步的：给几帧 + 真实时间
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        }
        final active = find.byKey(ReaderPage.activeSentenceKey);
        if (active.evaluate().isEmpty) continue;
        samples++;
        final rect = tester.getRect(active);
        // 当前句所在段落必须有一部分落在视口内（否则用户看不到读到哪了）
        if (rect.bottom < viewportTop || rect.top > viewportBottom) offscreen++;
      }

      // ignore: avoid_print
      print('DEVICE_VERIFY[ff] samples=$samples offscreen=$offscreen '
          'cursor=${TtsManager.instance.cursor}');
      expect(samples, greaterThan(5), reason: '应当采到多次快进后的当前句');
      expect(offscreen, 0, reason: '快进后当前朗读位置必须留在屏幕内（文本框不能跑丢）');
      expect(tester.takeException(), isNull);
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('连续快进时滚动是「攒几句滚一次」，不是每句都滚', (tester) async {
    await StorageService.instance.init();
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('tts_smooth'));
    // 每段 6 句，句子较长：一段就能占满大半个屏幕
    final buffer = StringBuffer();
    for (var p = 0; p < 60; p++) {
      buffer.writeln(List<String>.generate(
        6,
        (s) => '第 $p 段第 $s 句的正文内容写得长一些，这样每句话都能占满大半行。',
      ).join());
      buffer.writeln();
    }
    final file = File('${dir!.path}/smooth.txt')..writeAsStringSync(buffer.toString());
    final document = Document(
      id: 'smooth',
      title: '滚动平滑验证',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime(2024),
    );

    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1500)),
      );
      await tester.pump();
      await tester.pump();

      double? contentOffset() {
        for (final element in find.byType(Scrollable).evaluate()) {
          final state = (element as StatefulElement).state as ScrollableState;
          if (!state.position.hasContentDimensions) continue;
          // 正文列表是纵向、可滚动范围最大的那个
          if (state.position.axis != Axis.vertical) continue;
          if (state.position.maxScrollExtent <= 0) continue;
          return state.position.pixels;
        }
        return null;
      }

      TtsManager.instance.speakFrom(0, 0, 0);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      }

      // 连续快进，记录滚动幅度与「当前朗读句是否还在屏幕里」
      //
      // 注意：这里**不能**断言 `position.pixels` 单调不减。`ListView.builder`
      // 的高度是惰性测量的，滚动过程中估算值被真实值替换时 `pixels` 会被夹回一点
      // （实测每 6 步出现一次 ~92px 的回退），那是测量口径问题，不是画面在抖。
      // 真正的判据是「当前朗读位置一直看得见」+「不是每句都滚」。
      var changes = 0;
      var total = 0.0;
      var offscreen = 0;
      double? previous = contentOffset();
      for (var step = 0; step < 24; step++) {
        await tester.tap(
          find.descendant(
            of: find.byType(Material),
            matching: find.widgetWithIcon(IconButton, Icons.fast_forward),
          ).last,
        );
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
        }
        final current = contentOffset();
        if (current != null) {
          if (previous != null && (current - previous).abs() > 2) {
            changes++;
            total += (current - previous).abs();
          }
          previous = current;
        }
        final active = find.byKey(ReaderPage.activeSentenceKey);
        if (active.evaluate().isNotEmpty) {
          final rect = tester.getRect(active);
          final screen = tester.getRect(find.byType(ReaderPage));
          if (rect.bottom < screen.top || rect.top > screen.bottom) offscreen++;
        }
      }

      // ignore: avoid_print
      print('DEVICE_VERIFY[smooth] changes=$changes total=${total.toStringAsFixed(0)} '
          'offscreen=$offscreen cursor=${TtsManager.instance.cursor}');
      // 阻尼的效果：24 次快进只滚几次，而不是每句都滚
      expect(
        changes,
        lessThan(24),
        reason: '连续快进时不应每句都触发滚动（那是「页面快速滑动」）',
      );
      // 关键：连续快进过程中，正在读的那一句必须一直看得见（不跑丢、不抖出屏）
      expect(offscreen, 0, reason: '快进过程中当前朗读句不应跑出屏幕');
      expect(tester.takeException(), isNull);
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('原格式（未排版）退出重进：也回到同一句，不跑偏', (tester) async {
    await StorageService.instance.init();
    // 每页 10 段 → 120 段共 12 页，位置偏差会很明显
    await StorageService.instance.setParagraphsPerPage(10);
    final (dir, document) = await makeTxt(tester, 'plain', paragraphs: 120);
    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1400)),
      );
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // 连翻几页（每页 10 段 = 20 句），模拟「用户翻到后面去了」
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byKey(ReaderPage.nextPageKey));
        for (var j = 0; j < 40; j++) {
          await tester.pump(const Duration(milliseconds: 30));
        }
      }
      // 让「停留位置」被记录下来（滚动 / 翻页都会触发）
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );

      // 等翻页动画彻底停稳再取样：动画途中 `PageController.page` 已经指向新页，
      // 而 `onPageChanged`（真正落定的那一刻）还没触发 —— 那时取样会差一页。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // 位置由 controller 决定：读出来核对
      // 注意 `PageController.page` 是**从 0 开始**的，而界面上显示的是「第 N 页」，
      // 两者差 1，别混用（这个测试早先就混过一次）。
      final controller = tester
          .widget<PageView>(find.byKey(ReaderPage.pageViewKey))
          .controller!;
      final pageBefore = controller.page?.round() ?? -1;
      // ignore: avoid_print
      print('DEVICE_VERIFY[plain-return] pageBefore=$pageBefore');

      // 退出：dispose 会把停留位置写回进度
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 800)),
      );

      final stored = await StorageService.instance.loadDocuments();
      final progress = stored
          .where((d) => d.id == 'plain')
          .map((d) => d.progress)
          .toList();
      // ignore: avoid_print
      print('DEVICE_VERIFY[plain-return] storedProgress=$progress');
      expect(progress, isNotEmpty, reason: '退出时应当把进度写回文档库');
      expect(progress.first, greaterThan(0.2),
          reason: '翻到第 6 页（约 42%）后退出，进度不该还是 0');

      // 从存储里读回（真实流程：列表页取 Document 再打开）
      final reopened = stored.firstWhere((d) => d.id == 'plain');
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: reopened)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1400)),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final controller2 = tester
          .widget<PageView>(find.byKey(ReaderPage.pageViewKey))
          .controller!;
      final pageAfter = controller2.page?.round() ?? -1;
      // ignore: avoid_print
      print('DEVICE_VERIFY[plain-return] pageAfter=$pageAfter '
          'cursor=${TtsManager.instance.cursor}');
      expect(pageAfter, pageBefore,
          reason: '原格式下退出在哪一页，重进就该在哪一页');
      expect(pageAfter, greaterThan(0), reason: '不该回到第 1 页');
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('朗读中途中断后重新进入：回到上次中断的那一句', (tester) async {
    await StorageService.instance.init();
    final (dir, document) = await makeTxt(tester, 'resume', paragraphs: 120);
    try {
      // 先打开一次，让文档被解析进 TtsManager
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1200)),
      );
      await tester.pump();
      await tester.pump();

      // 读到第 40 段第 1 句，然后「中断」（停止朗读 + 离开阅读页）
      TtsManager.instance.speakFrom(0, 40, 1);
      await expectEventually(
        tester,
        () {
          final c = TtsManager.instance.cursor;
          return c.$2 == 40 && c.$3 == 1;
        },
        reason: '游标应落到第 40 段第 1 句',
      );
      final before = TtsManager.instance.cursor;

      await TtsManager.instance.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 200));

      // 退出时写回的进度就是「中断处」—— 检查一下，便于定位问题
      final stored = await StorageService.instance.loadDocuments();
      // ignore: avoid_print
      print('DEVICE_VERIFY[resume] storedProgress='
          '${stored.where((d) => d.id == 'resume').map((d) => d.progress).toList()}');

      // 再次进入同一本书：应当回到中断处，而不是从头。
      // 这里刻意用**从存储里读回来的**那条记录（带写回的进度），
      // 而不是原来那个（进度还是 0 的）对象 —— 真实流程就是这样：
      // 列表页重新加载 → 拿到带进度的 Document → 打开。
      final reopened = stored.firstWhere((d) => d.id == 'resume');
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: reopened)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1200)),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      final after = TtsManager.instance.cursor;
      // ignore: avoid_print
      print('DEVICE_VERIFY[resume] before=$before after=$after '
          'docId=${TtsManager.instance.activeDocumentId}');
      expect(after, before, reason: '重新进入应当停在上次中断的那一句');
      expect(after.$2, 40);
      expect(after.$3, 1);
      // 且视图要对齐过去：第 40 段应当已经在视野里
      expect(find.textContaining('第 40 段第一句。'), findsWidgets,
          reason: '视图也要滚到中断位置');
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('退出时在哪，重进就在哪：按写回的进度还原位置', (tester) async {
    await StorageService.instance.init();
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('tts_spot'));
    final buffer = StringBuffer();
    for (var p = 0; p < 300; p++) {
      buffer.writeln('第 $p 段第一句。第 $p 段第二句！');
      buffer.writeln();
    }
    final file = File('${dir!.path}/spot.txt')..writeAsStringSync(buffer.toString());

    // 用户上次停在 60% 处（模拟退出时写回的进度）
    Document fresh(double progress) => Document(
          id: 'spot',
          title: '停留位置验证',
          path: file.path,
          type: DocumentType.txt,
          importedAt: DateTime(2024),
          progress: progress,
        );

    try {
      // 每一段都先把朗读管理器清空，模拟「重启应用」——
      // 只有这样才能干净地验证「按写回的进度还原」这条路径
      // （不清的话上一段留在内存里的游标会参与取靠后位置，那是同一会话内的正常行为）。
      void restartSession() {
        TtsManager.instance.resetSessionForTest();
      }

      // 1) 进度 60% → 应当落到大约第 180 段（300 段 × 0.6），而不是开头
      restartSession();
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: fresh(0.6))));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1500)),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final at60 = TtsManager.instance.cursor;
      // ignore: avoid_print
      print('DEVICE_VERIFY[spot] progress=0.6 -> cursor=$at60');
      expect(at60.$2, greaterThan(150), reason: '应当还原到 60% 附近而不是开头');
      expect(at60.$2, lessThan(210));

      await TtsManager.instance.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 200));

      // 2) 进度接近 100%（读到末尾退出）→ 也要还原，不能扔回开头。
      //    旧实现有「进度 ≥ 99.5% 视为读完，从头开始」的规则，已按需求去掉。
      restartSession();
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: fresh(0.999))));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1500)),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final atEnd = TtsManager.instance.cursor;
      // ignore: avoid_print
      print('DEVICE_VERIFY[spot] progress=0.999 -> cursor=$atEnd');
      expect(atEnd.$2, greaterThan(280), reason: '读到末尾退出，重进也要在末尾');

      await TtsManager.instance.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 200));

      // 3) 进度 0 → 从头（新导入的书）
      restartSession();
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: fresh(0))));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1200)),
      );
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // ignore: avoid_print
      print('DEVICE_VERIFY[spot] progress=0 -> cursor=${TtsManager.instance.cursor}');
      expect(TtsManager.instance.cursor.$2, 0, reason: '新书从头开始');
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('换一本书打开：不会被上一本的朗读游标带走', (tester) async {
    await StorageService.instance.init();
    final (dirA, docA) = await makeTxt(tester, 'bookA', paragraphs: 120);
    final (dirB, docB) = await makeTxt(tester, 'bookB', paragraphs: 120);
    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: docA)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1200)),
      );
      await tester.pump();
      TtsManager.instance.speakFrom(0, 60, 0);
      await expectEventually(
        tester,
        () => TtsManager.instance.cursor.$2 == 60,
        reason: 'A 书游标应落到第 60 段',
      );
      await TtsManager.instance.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 200));

      // 打开另一本书：进度为 0，且朗读游标属于 A 书 → 必须从头开始
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: docB)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1200)),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      final cursor = TtsManager.instance.cursor;
      // ignore: avoid_print
      print('DEVICE_VERIFY[resume-other] cursor=$cursor '
          'activeDoc=${TtsManager.instance.activeDocumentId}');
      expect(TtsManager.instance.activeDocumentId, 'bookB');
      expect(cursor, (0, 0, 0), reason: '换书后应当从头开始，不被上一本的游标带走');
      expect(find.textContaining('第 0 段第一句。'), findsWidgets);
    } finally {
      await cleanup(tester, dirA);
      await cleanup(tester, dirB);
    }
  });
}

/// 假引擎：初始化 / 停止立刻返回，speak 永不完成（让朗读会话一直活着）
class _HoldingEngine with SyntheticTtsEngine implements TtsEngine {
  final Completer<void> _never = Completer<void>();

  @override
  String get id => 'jump-holding';

  @override
  String get displayName => '假引擎（保持朗读中）';

  @override
  bool get isAvailable => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<TtsVoice>> getVoices() async => const <TtsVoice>[];

  @override
  Future<void> setVoice(String voiceId) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  Future<void> speak(String text) => _never.future;

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async {}
}

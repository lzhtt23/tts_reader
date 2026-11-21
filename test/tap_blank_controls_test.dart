// 点正文空白处呼出/收起控制栏（v1.22.73）
//
// 两个必须守住的点：
//   1. 点**空白**（页边距）→ 切控制栏，且**只切 UI**，不动朗读；
//   2. 点**段落/句子**仍然是朗读语义，不能被这一层吃掉。
// 设置里可以关掉这个反应（有人不想要）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // StorageService 是单例：上一个用例把开关关掉后，这里必须重置回默认，
    // 否则下一个用例会"凭空"失效（踩过一次：widget 用例一直不触发）
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    final TtsManager tts = TtsManager.instance;
    tts
      ..speakTimeout = const Duration(milliseconds: 250)
      ..initTimeout = const Duration(milliseconds: 250)
      ..voiceTimeout = const Duration(milliseconds: 250)
      ..controlTimeout = const Duration(milliseconds: 250);
  });

  tearDown(() {
    TtsManager.instance.resetTimeouts();
  });

  group('设置项', () {
    test('默认开启', () async {
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      expect(StorageService.instance.tapBlankTogglesControls.value, isTrue,
          reason: '默认应当是开的，否则用户感觉不到这个改进');
    });

    test('关掉后能持久化', () async {
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      await StorageService.instance.setTapBlankTogglesControls(false);
      expect(StorageService.instance.tapBlankTogglesControls.value, isFalse);

      // 重新读一遍（模拟重启）
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      expect(StorageService.instance.tapBlankTogglesControls.value, isFalse,
          reason: '重启后必须记得用户关掉过');
    });
  });

  group('点空白切换控制栏（文字档）', () {
    Future<(Directory, Document)> makeDoc(WidgetTester tester) async {
      final Directory dir =
          (await tester.runAsync(() => Directory.systemTemp.createTemp('tap_blank')))!;
      final File file = File('${dir.path}/tap.txt')
        ..writeAsStringSync(
          List<String>.generate(8, (int i) => '第 $i 段第一句。第 $i 段第二句。').join('\n\n'),
        );
      return (
        dir,
        Document(
          id: 'tap',
          title: 'tap',
          path: file.path,
          type: DocumentType.txt,
          importedAt: DateTime(2024),
        ),
      );
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1200)));
      await tester.pump();
      await tester.pump();
    }

    /// 测试画布默认 800 宽，正文限宽（≈900）比它还宽 → 正文铺满，没有「页边距」可点。
    /// 所以这里把画布拉宽，留出两侧真正的空白区 —— 那正是用户实际会点的位置。
    void useWideCanvas(WidgetTester tester) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('点页边距 → 控制栏收起；再点 → 展开', (WidgetTester tester) async {
      useWideCanvas(tester);
      final (Directory dir, Document doc) = await makeDoc(tester);
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: doc)));
      await settle(tester);

      // 初始是展开态（没有右下角收起键）
      expect(find.byKey(ReaderPage.collapsedControlKey), findsNothing);

      // 点左页边距（正文限宽居中，最左边属于空白）
      await tester.tapAt(const Offset(20, 400));
      await tester.pump();
      expect(find.byKey(ReaderPage.collapsedControlKey), findsOneWidget,
          reason: '点空白应当把控制栏收起（变成右下角悬浮键）');

      await tester.tapAt(const Offset(20, 400));
      await tester.pump();
      expect(find.byKey(ReaderPage.collapsedControlKey), findsNothing,
          reason: '再点一次应当展开');

      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) await dir.delete(recursive: true);
        } catch (_) {}
      });
    });

    testWidgets('关掉设置后，点空白不再有反应', (WidgetTester tester) async {
      useWideCanvas(tester);
      await tester.runAsync(
          () => StorageService.instance.setTapBlankTogglesControls(false));
      final (Directory dir, Document doc) = await makeDoc(tester);
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: doc)));
      await settle(tester);

      await tester.tapAt(const Offset(20, 400));
      await tester.pump();
      expect(find.byKey(ReaderPage.collapsedControlKey), findsNothing,
          reason: '用户关掉了就不该有任何反应');

      await tester.runAsync(
          () => StorageService.instance.setTapBlankTogglesControls(true));
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) await dir.delete(recursive: true);
        } catch (_) {}
      });
    });
  });
}

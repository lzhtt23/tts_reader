import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/main.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/legado_source_store.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';
import 'package:tts_reader/widgets/reading_control_bar.dart';

/// 窄屏布局溢出巡检。
///
/// 用户报「Flutter 布局溢出」但没说是哪个页面。这组用例把界面放在**比任何真机
/// 都窄**的画布上渲染，让 Flutter 自己在 layout 阶段抛的 overflow 异常浮出来，
/// 而不是靠肉眼看黄黑条猜。
///
/// 浏览器页（Tab 2）不在这里扫：它建的就是 `InAppWebView`，纯 widget 测试环境
/// 没有 `flutter_inappwebview` 的原生实现，一构建就抛「platform implementation
/// has not been set」——那是测试环境限制，跟布局无关。它的溢出要靠真机验证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String oneDoc() => jsonEncode(<Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'doc-1',
      'title': '自动导入测试书_1791720319953 一个非常非常长的书名用来撑爆标题行看看会不会溢出',
      'path': '/tmp/测试文档.txt',
      'type': 'txt',
      'progress': 0.42,
      'importedAt': DateTime(2026, 1, 1).toIso8601String(),
    },
  ]);

  Future<void> bootApp(WidgetTester tester, Size size) async {
    StorageService.instance.resetForTest();
    LegadoSourceStore.instance.refreshForTest();

    tester.view.physicalSize = size;
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

  group('窄屏 320×640 各 Tab 不溢出', () {
    // 只扫不依赖原生平台的页面；浏览器页见文件头说明
    for (final (int index, String name) in <(int, String)>[
      (0, '文档库'),
      (1, '发现'),
      (3, '设置'),
    ]) {
      testWidgets('$name 页不溢出', (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'documents': oneDoc(),
        });
        await bootApp(tester, const Size(320, 640));

        final Finder nav = find.byType(NavigationDestination);
        if (nav.evaluate().length > index) {
          await tester.tap(nav.at(index));
          await tester.pumpAndSettle();
        }

        expect(
          tester.takeException(),
          isNull,
          reason: '[$name] 在 320 宽下布局抛异常',
        );
      });
    }
  });

  group('极窄 280×600 也不溢出', () {
    for (final (int index, String name) in <(int, String)>[
      (0, '文档库'),
      (3, '设置'),
    ]) {
      testWidgets('$name 页不溢出', (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'documents': oneDoc(),
        });
        await bootApp(tester, const Size(280, 600));

        final Finder nav = find.byType(NavigationDestination);
        if (nav.evaluate().length > index) {
          await tester.tap(nav.at(index));
          await tester.pumpAndSettle();
        }

        expect(
          tester.takeException(),
          isNull,
          reason: '[$name] 在 280 宽下布局抛异常',
        );
      });
    }
  });

  group('大字体 textScale 1.3 不溢出', () {
    for (final (int index, String name) in <(int, String)>[
      (0, '文档库'),
      (3, '设置'),
    ]) {
      testWidgets('$name 页不溢出', (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'documents': oneDoc(),
        });

        StorageService.instance.resetForTest();
        LegadoSourceStore.instance.refreshForTest();
        tester.view.physicalSize = const Size(360, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          const MediaQuery(
            data: MediaQueryData(
              size: Size(360, 720),
              textScaler: TextScaler.linear(1.3),
            ),
            child: TtsReaderApp(),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));

        final Finder start =
            find.byKey(const ValueKey<String>('tutorial-start'));
        if (start.evaluate().isNotEmpty) {
          await tester.tap(start);
          await tester.pumpAndSettle();
        }

        final Finder nav = find.byType(NavigationDestination);
        if (nav.evaluate().length > index) {
          await tester.tap(nav.at(index));
          await tester.pumpAndSettle();
        }

        expect(
          tester.takeException(),
          isNull,
          reason: '[$name] 在 1.3 倍字体下布局抛异常',
        );
      });
    }
  });

  group('底部朗读控制栏窄屏不溢出', () {
    final tts = TtsManager.instance;

    setUp(() async {
      tts.resetLocalEngineForTest();
      tts.resetSessionForTest();
      await tts.stop();
      await tts.registerEngine(_HoldingEngine(), makeActive: true);
    });

    Future<void> pumpBar(WidgetTester tester, Size size) async {
      addTearDown(() async {
        unawaited(tts.stop());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 600)),
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
      });

      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      tts.loadDocument(
        StructuredDocument(
          chapters: <Chapter>[
            const Chapter(
              title: '第 1 章 一个很长很长很长的章节名字用来挤控制栏看看会怎样',
              paragraphs: <Paragraph>[
                Paragraph(sentences: <Sentence>[Sentence('第一句。')]),
              ],
            ),
          ],
        ),
        title: '一个非常非常长的书名用来撑爆控制栏',
        documentId: 'doc-1',
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<TtsManager>.value(
          value: tts,
          child: MaterialApp(
            home: Scaffold(
              body: const SizedBox.shrink(),
              // 放在底栏的位置，跟真机上「悬浮在正文下方」一致
              bottomNavigationBar: ReadingControlBar(
                onReturnToReading: () async {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    for (final Size size in <Size>[
      const Size(320, 640),
      const Size(280, 600),
    ]) {
      testWidgets('${size.width.toInt()} 宽收起态不溢出', (tester) async {
        await pumpBar(tester, size);
        expect(
          tester.takeException(),
          isNull,
          reason: '[控制栏 ${size.width}宽] 布局抛异常',
        );
      });
    }

    testWidgets('320 宽展开成整条后不溢出', (tester) async {
      await pumpBar(tester, const Size(320, 640));

      // 收起态点一下向左展开
      final Finder chevron = find.byIcon(Icons.chevron_right);
      if (chevron.evaluate().isNotEmpty) {
        await tester.tap(chevron.first);
        await tester.pumpAndSettle();
      }

      expect(
        tester.takeException(),
        isNull,
        reason: '[控制栏 320宽] 展开后布局抛异常（五个按钮挤在一起）',
      );
    });
  });

  _registerReaderPageScans();
}

/// 朗读页（ReaderPage）窄屏不溢出。
///
/// 这是用户停留最久、布局最复杂的页面：正文 + 页脚进度 + 可折叠控制中心。
/// 装配方式照搬 reader_ui_features_test 里已验证过的那套（临时 txt + 等解析完成）。
void _registerReaderPageScans() {
  group('朗读页窄屏不溢出', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      final tts = TtsManager.instance;
      tts
        ..speakTimeout = const Duration(milliseconds: 250)
        ..initTimeout = const Duration(milliseconds: 250)
        ..voiceTimeout = const Duration(milliseconds: 250)
        ..controlTimeout = const Duration(milliseconds: 250);
    });

    tearDown(() async {
      await TtsManager.instance.stop();
      TtsManager.instance.resetTimeouts();
    });

    for (final Size size in <Size>[
      const Size(320, 640),
      const Size(360, 720),
    ]) {
      for (final String title in <String>[
        '普通书名',
        '一个非常非常非常长的书名用来撑爆朗读页顶栏看看会不会溢出',
      ]) {
        testWidgets(
          '${size.width.toInt()}宽 · ${title.length > 8 ? "超长书名" : "普通书名"}',
          (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);

            final Directory? dir = await tester.runAsync(
              () => Directory.systemTemp.createTemp('layout_scan'),
            );
            final File file = File('${dir!.path}/scan.txt')
              ..writeAsStringSync(
                List<String>.generate(60, (i) => '第 $i 段第一句。第 $i 段第二句！')
                    .join('\n\n'),
              );
            addTearDown(() {
              unawaited(TtsManager.instance.stop());
              try {
                if (dir.existsSync()) dir.deleteSync(recursive: true);
              } catch (_) {
                // Windows 上句柄占用时忽略
              }
            });

            await tester.pumpWidget(
              MaterialApp(
                home: ReaderPage(
                  document: Document(
                    id: 'scan-${size.width.toInt()}-${title.length}',
                    title: title,
                    path: file.path,
                    type: DocumentType.txt,
                    importedAt: DateTime(2024),
                  ),
                ),
              ),
            );

            // 等解析完成（控制栏出现即视为就绪）
            for (var i = 0; i < 30; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 100)),
              );
              await tester.pump();
              if (find
                      .byKey(ReaderPage.controlCenterKey)
                      .evaluate()
                      .isNotEmpty ||
                  find
                      .byKey(ReaderPage.collapsedControlKey)
                      .evaluate()
                      .isNotEmpty) {
                break;
              }
            }

            expect(
              tester.takeException(),
              isNull,
              reason: '[朗读页 ${size.width}宽 · $title] 布局抛异常',
            );            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(seconds: 1));
            await tester
                .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
            await tester.pump(const Duration(seconds: 1));
          },
        );
      }
    }
  });
}

/// 假引擎：单次 speak 迟迟不完成 —— 会话停在「正在朗读」，按钮状态稳定可断言
///
/// 照搬 reading_control_bar_test 里已验证过的那套：`SyntheticTtsEngine` 已经把
/// 事件流 / 音量 / dispose 这些边角实现了，这里只需要覆盖会被用到的几个。
class _HoldingEngine with SyntheticTtsEngine implements TtsEngine {
  static const Duration speakDelay = Duration(milliseconds: 300);

  @override
  String get id => 'fake';

  @override
  String get displayName => '假引擎（测试）';

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
  Future<void> speak(String text) async {
    await Future<void>.delayed(speakDelay);
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async {}
}

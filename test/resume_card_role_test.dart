// 「继续朗读」卡与右下角迷你条的分工（v1.22.79）
//
// 用户要求：两个控件**互补**，不要重复。原问题——
// 书正在读时，迷你条有暂停，续读卡又有一个"播"，而且点续读卡那个会
// 重开阅读页、把正在进行的朗读打断。
//
// 现在守的规则：
//   · 这本书**没在朗读** → 续读卡有播放键（它是唯一的"起播"入口：
//     迷你条在无会话时整条隐藏，否则就没有地方能开始读了）
//   · 这本书**正在朗读** → 续读卡**不放任何按钮**，只显示状态；
//     播放/暂停归迷你条，进入阅读页点整卡
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/pages/home_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late Document doc;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();

    dir = Directory.systemTemp.createTempSync('resume_card_');
    final File file = File('${dir.path}/book.txt')
      ..writeAsStringSync('第一章 测试\n\n这是正文第一句。这是第二句。');
    doc = Document(
      id: 'resume-doc',
      title: '测试书',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime(2024, 1, 1),
      lastReadAt: DateTime(2024, 1, 2),
    );
    await StorageService.instance.upsertDocument(doc);
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(const TtsReaderAppForTest());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('续读卡', () {
    testWidgets('没有朗读时：有播放键（唯一的起播入口）', (WidgetTester tester) async {
      await pumpHome(tester);

      expect(find.byKey(HomePage.resumeCardKey), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(HomePage.resumeCardKey),
          matching: find.byIcon(Icons.play_arrow),
        ),
        findsOneWidget,
        reason: '迷你条在没有会话时整条隐藏，这里必须留一个起播入口',
      );
    });

    testWidgets('正在朗读这本书：不放播放键，只显示状态', (WidgetTester tester) async {
      // 造出「会话存在且正在读这本书」的状态：
      // loadDocument 会让 hasSession 变真（不会真的发声，测试环境没有引擎）
      TtsManager.instance.loadDocument(
        StructuredDocument(
          chapters: const <Chapter>[
            Chapter(
              title: '第一章',
              paragraphs: <Paragraph>[
                Paragraph(sentences: <Sentence>[Sentence('这是正文第一句。')]),
              ],
            ),
          ],
        ),
        at: (0, 0, 0),
        title: doc.title,
        documentId: doc.id,
      );
      await tester.pump();

      await pumpHome(tester);

      final Finder card = find.byKey(HomePage.resumeCardKey);
      expect(card, findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.byIcon(Icons.play_arrow)),
        findsNothing,
        reason: '播放/暂停归迷你条；这里再放一个就是两个控件抢同一动作',
      );
      expect(
        find.descendant(of: card, matching: find.byIcon(Icons.graphic_eq)),
        findsOneWidget,
        reason: '要有状态指示，让用户知道音频在右下角',
      );
    });
  });
}

/// 只装首页的极简 App（避免引入整个 TtsReaderApp 的依赖）
class TtsReaderAppForTest extends StatelessWidget {
  const TtsReaderAppForTest({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<TtsManager>.value(
      value: TtsManager.instance,
      child: const MaterialApp(home: Scaffold(body: HomePage())),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';
import 'package:tts_reader/widgets/reading_control_bar.dart';

/// 底部可折叠朗读控制栏验证。
///
/// 注意必须注入假引擎：测试环境没有 flutter_tts 原生实现，真引擎的
/// stop/speak 都要等超时才返回，状态转换全是异步的，断言会莫名其妙地闪。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final tts = TtsManager.instance;
  late _HoldingEngine engine;

  /// 假引擎：单次 speak 永不完成 —— 会话就停在「正在朗读」，按钮状态稳定可断言
  setUp(() async {
    tts.resetLocalEngineForTest();
    tts.resetSessionForTest();
    await tts.stop();
    engine = _HoldingEngine();
    await tts.registerEngine(engine, makeActive: true);
  });

  Future<void> pumpBar(WidgetTester tester, {required Future<void> Function() onReturn}) async {
    addTearDown(() async {
      // TtsManager 是单例：测试里一点播放就会留下朗读循环（它不停地在调插件）。
      // 收尾顺序照搬 reader_jump_test 里已经验证过的那套：
      // 同步打断令牌先停住循环 → 拆掉控件树 → 推一帧假时间 → 再给一段真实时间，
      // 让兜底超时定时器有機會被取消，否则收尾会报 "A Timer is still pending"。
      unawaited(tts.stop());
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
      // 停下来的那一刻可能刚有一次 speak 越过令牌检查开始跑，
      // 它那 300ms 的「朗读中」延时还挂在假时钟上，再推两帧把循环彻底跑干净
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<TtsManager>.value(
        value: tts,
        child: MaterialApp(
          home: Scaffold(
            body: const SizedBox.shrink(),
            floatingActionButton: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ReadingControlBar(onReturnToReading: onReturn),
                const SizedBox(width: 12),
                FloatingActionButton.extended(onPressed: () {}, label: const Text('导入文件')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// 造一份两章文档并绑定（模拟「打开过一本书」）
  void loadDocument({String title = '红楼梦 (曹雪芹)'}) {
    tts.loadDocument(
      StructuredDocument(
        chapters: <Chapter>[
          for (var c = 0; c < 2; c++)
            Chapter(
              title: '第 ${c + 1} 章 测试章节',
              paragraphs: <Paragraph>[
                Paragraph(
                  sentences: <Sentence>[
                    Sentence('第 ${c + 1} 章第一句。'),
                    Sentence('第 ${c + 1} 章第二句。'),
                  ],
                ),
              ],
            ),
        ],
      ),
      title: title,
      documentId: 'doc-1',
    );
  }

  /// 轮询等待条件成立（朗读状态变化是异步的）
  ///
  /// 先 pump 再判断：管理器的 notify 只是把 Consumer 标脏，
  /// 不 pump 一帧的话界面上还是旧图标。
  Future<void> expectEventually(
    WidgetTester tester,
    bool Function() condition, {
    required String reason,
  }) async {
    for (var i = 0; i < 40; i++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (condition()) return;
    }
    expect(condition(), isTrue, reason: reason);
  }

  /// 主动结束朗读会话，并把假引擎残留的「朗读中」小定时器跑完
  ///
  /// 单例管理器上的朗读循环会一直调插件；留到用例结束再收尾的话，
  /// 那个 300ms 定时器可能正好在最后一帧之后才建出来，收尾检查就会报
  /// 「A Timer is still pending」。
  Future<void> endSession(WidgetTester tester) async {
    await tts.stop();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('没有朗读会话时整条不显示', (tester) async {
    await pumpBar(tester, onReturn: () async {});
    expect(find.byType(ReadingControlBar), findsOneWidget);
    expect(find.text('导入文件'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets('有会话时收起态只有封面，点一下向左展开成整条', (tester) async {
    loadDocument();
    await pumpBar(tester, onReturn: () async {});

    // 收起态（2026-10-18 改）：只有一枚封面方块，没有任何文字和按钮
    expect(find.byTooltip('朗读已暂停 · 点击展开控制栏'), findsOneWidget);
    expect(find.text('红楼梦 (曹雪芹)'), findsNothing);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
    expect(find.byIcon(Icons.fast_forward), findsNothing);
    expect(find.byIcon(Icons.stop), findsNothing);

    await tester.tap(find.byTooltip('朗读已暂停 · 点击展开控制栏'));
    await tester.pumpAndSettle();

    // 展开：一条里有 下一句 / 停止 / 播放 + 书名
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.fast_forward), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.text('红楼梦 (曹雪芹)'), findsOneWidget);
    // 齿轮不再占键位：设置从底部导航进，位置让给「下一句」
    expect(find.byIcon(Icons.settings), findsNothing);

    // 布局顺序：控制栏在「导入文件」左侧
    final barX = tester.getCenter(find.byIcon(Icons.play_arrow)).dx;
    final fabX = tester.getCenter(find.text('导入文件')).dx;
    expect(barX, lessThan(fabX), reason: '控制栏应当在导入按钮左侧');

    // 收起：点封面，回到只剩封面
    await tester.tap(find.byKey(ReadingControlBar.discKey));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.play_arrow), findsNothing);
    expect(find.byTooltip('朗读已暂停 · 点击展开控制栏'), findsOneWidget);
  });

  testWidgets('播放按钮：暂停中继续读，朗读中变暂停', (tester) async {
    loadDocument();
    await pumpBar(tester, onReturn: () async {});
    await tester.tap(find.byTooltip('朗读已暂停 · 点击展开控制栏'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.play_arrow));
    await expectEventually(tester, () => tts.playing, reason: '点播放后应当进入朗读中');
    expect(find.byIcon(Icons.pause), findsOneWidget);

    await tester.tap(find.byIcon(Icons.pause));
    await tester.pump();
    expect(tts.playing, isFalse);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    await endSession(tester);
  });

  testWidgets('下一句按钮推进游标（从第二句开始读）', (tester) async {
    loadDocument();
    await pumpBar(tester, onReturn: () async {});
    await tester.tap(find.byTooltip('朗读已暂停 · 点击展开控制栏'));
    await tester.pumpAndSettle();

    // 先把闸放开：这一轮朗读会立刻读完并收尾，不会留下挂起的超时定时器
    engine.release();
    await tester.tap(find.byIcon(Icons.fast_forward));
    await expectEventually(
      tester,
      () => engine.spoken.isNotEmpty,
      reason: '点下一句应当开始朗读',
    );
    expect(
      engine.spoken.first,
      '第 1 章第二句。',
      reason: '游标应当从第一句前进到第二句',
    );

    await endSession(tester);
  });

  testWidgets('停止按钮结束会话；书本按钮走回调', (tester) async {
    loadDocument();
    var returned = 0;
    await pumpBar(tester, onReturn: () async => returned++);
    await tester.tap(find.byTooltip('朗读已暂停 · 点击展开控制栏'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ReadingControlBar.returnKey));
    await tester.pump();
    expect(returned, 1, reason: '书名那块应当调用「返回朗读页」回调');

    await tester.tap(find.byIcon(Icons.stop));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tts.speaking, isFalse);
    expect(find.byIcon(Icons.pause), findsNothing);
  });

  testWidgets('纯文本队列会话也显示控制栏（没有章节标题时用位置描述）', (tester) async {
    tts.speakLines(<String>['第一段。', '第二段。']);
    await pumpBar(tester, onReturn: () async {});
    await expectEventually(tester, () => tts.speaking, reason: '纯文本队列应当进入朗读中');
    expect(find.byTooltip('正在朗读 · 点击展开控制栏'), findsOneWidget);

    await tester.tap(find.byTooltip('正在朗读 · 点击展开控制栏'));
    await tester.pumpAndSettle();
    expect(find.text('第 1 章 测试章节'), findsNothing);
    expect(find.byIcon(Icons.fast_forward), findsOneWidget);

    await endSession(tester);
  });

  // 用户报的现象：第一次打开文档开始朗读、退回文档库，迷你条不显示；
  // 再进一次才显示。根因是 stop() 内部路径（换书/注册引擎/起读）也会把
  // 「刚被用户结束」的标记置真 —— 现在只有方块键（stopByUser）才置。
  testWidgets('内部 stop 之后开始朗读：迷你条要显示', (tester) async {
    loadDocument();
    await pumpBar(tester, onReturn: () async {});
    await tts.stop(); // 模拟内部收尾（换书 / 注册引擎都会走到）
    await tester.pump();

    tts.playFromCursor();
    await expectEventually(tester, () => tts.playing, reason: '应当开始朗读');
    expect(find.byTooltip('正在朗读 · 点击展开控制栏'), findsOneWidget);

    await endSession(tester);
  });

  testWidgets('用户按方块键结束朗读后：迷你条整条消失', (tester) async {
    loadDocument();
    await pumpBar(tester, onReturn: () async {});
    tts.playFromCursor();
    await expectEventually(tester, () => tts.playing, reason: '应当开始朗读');
    expect(find.byTooltip('正在朗读 · 点击展开控制栏'), findsOneWidget);

    await tts.stopByUser();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byKey(ReadingControlBar.discKey), findsNothing);
    expect(find.byKey(ReadingControlBar.barKey), findsNothing);

    await endSession(tester);
  });

  testWidgets('系统开了「减少动画」时正常显示（碟片不转）', (tester) async {
    loadDocument();
    addTearDown(() async {
      await tts.stop();
    });
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: ChangeNotifierProvider<TtsManager>.value(
          value: tts,
          child: MaterialApp(
            home: Scaffold(
              floatingActionButton: ReadingControlBar(onReturnToReading: () async {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('朗读已暂停 · 点击展开控制栏'), findsOneWidget);
  });
}

/// 假引擎：每次朗读用一小段假时间后自然完成
///
/// 不能用「永不完成的 future」：朗读循环里每次 speak 都挂着 30 秒兜底超时，
/// 操作不结束那个定时器就留在 fake-async 里，测试收尾会报
/// 「A Timer is still pending」。用有限的 Future.delayed，pump 就能把它跑完。
class _HoldingEngine with SyntheticTtsEngine implements TtsEngine {
  final List<String> spoken = <String>[];

  /// 每次朗读占用的假时间（够测试断言「正在朗读」，又不至于让收尾跑很久）
  static const Duration speakDelay = Duration(milliseconds: 300);

  /// 兼容旧调用：现在不需要放闸
  void release() {}

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
    spoken.add(text);
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

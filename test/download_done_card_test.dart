import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/widgets/download_done_card.dart';

/// 「下载完成」悬浮卡（方案 4）
///
/// 行为约定：
/// * 3 秒自动收起（用户要求，与教程 readGate 一致）
/// * 点「关闭」立刻收起
/// * 点「立即朗读」先收起卡片、再跳阅读页（不能把阅读页开在卡片底下）
void main() {
  /// 放一个按钮，点开卡片；返回回调计数与是否已触发阅读
  Future<({List<int> reads})> pumpHost(
    WidgetTester tester, {
    Duration autoClose = const Duration(seconds: 3),
  }) async {
    final List<int> reads = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showDownloadDoneCard(
                context,
                bookName: '钢铁是怎样炼成的',
                onRead: () => reads.add(1),
                autoClose: autoClose,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump(); // 起 dialog
    await tester.pump(const Duration(milliseconds: 200)); // 过过渡动画
    return (reads: reads);
  }

  testWidgets('显示书名、两个按钮和倒计时', (tester) async {
    await pumpHost(tester);

    expect(find.text('下载完成'), findsOneWidget);
    expect(find.text('钢铁是怎样炼成的'), findsOneWidget);
    expect(find.text('已加入文档库，可以直接开始朗读'), findsOneWidget);
    expect(find.text('立即朗读'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    // 倒计时数字（3 秒起）
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('3 秒后自动收起', (tester) async {
    await pumpHost(tester);
    expect(find.text('下载完成'), findsOneWidget);

    // 到点前仍然在
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('下载完成'), findsOneWidget);

    // 3 秒后自动 pop
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('下载完成'), findsNothing);
  });

  testWidgets('点「关闭」立刻收起', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('下载完成'), findsNothing);
  });

  testWidgets('点「立即朗读」会收起卡片并回调', (tester) async {
    final ({List<int> reads}) host = await pumpHost(tester);
    await tester.tap(find.text('立即朗读'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(host.reads, hasLength(1), reason: '要触发阅读回调');
    expect(find.text('下载完成'), findsNothing, reason: '卡片要关掉');
  });
}

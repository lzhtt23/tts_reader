import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/crash_log.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 目录跳转只允许**定位一次**。
///
/// 背景：`_openToc` 里同一段「跳到目标页」的代码写了两遍（旧「跳转即朗读」
/// 逻辑的残留 + 后来「先暂停再跳」的逻辑）。`_revealBlock` 不是幂等的 ——
/// 它每次都会 `_takeScrollOwnership` + `++_jumpToken` + 翻页等待 + 多轮对齐，
/// 调用两次会互相作废对方的 token，正是用户说的「有概率定位失败」。
///
/// 这里用阅读页自己的跟随日志当判据：一次目录跳转，
/// `朗读跟随[定位开始]` 只该出现一次。
class _HoldEngine with SyntheticTtsEngine implements TtsEngine {
  final Completer<void> _pending = Completer<void>();

  @override
  String get id => 'toc-once';

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
  Future<void> speak(String text) => _pending.future;

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async {}
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    TtsManager.instance.resetSessionForTest();
    TtsManager.instance.speakTimeout = const Duration(seconds: 60);
    await TtsManager.instance.registerEngine(_HoldEngine(), makeActive: true);
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.resetSessionForTest();
  });

  Future<(Directory, Document)> makeBook(WidgetTester tester) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('toctwice'),
    );
    final buffer = StringBuffer();
    for (var c = 0; c < 60; c++) {
      buffer.writeln('第 ${c + 1} 章');
      buffer.writeln();
      for (var p = 0; p < 120; p++) {
        buffer.writeln('第 ${c + 1} 章第 ${p + 1} 段。这里是正文内容。');
        buffer.writeln();
      }
    }
    final file = File('${dir!.path}/toctwice.txt')
      ..writeAsStringSync(buffer.toString());
    final document = Document(
      id: 'toctwice',
      title: 'toctwice',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime(2024),
    );
    await StorageService.instance.upsertDocument(document);
    return (dir, document);
  }

  Future<void> settle(WidgetTester tester, {int rounds = 20}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
  }

  testWidgets('目录跳转：一次点击只定位一次（不重复执行跳转逻辑）', (tester) async {
    final (dir, document) = await makeBook(tester);
    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1500)),
      );
      await settle(tester, rounds: 20);
      expect(find.byKey(ReaderPage.pageViewKey), findsOneWidget);

      // 打开目录
      await tester.tap(find.byIcon(Icons.list_alt).first);
      await settle(tester, rounds: 10);

      // 用目录顶部的「跳转到第几页」输入框 —— 比在懒加载的章节列表里滚到
      // 第 50 章稳，也正好是用户「跳到很远的地方」的真实用法。
      final pageField = find.byType(TextField);
      expect(
        pageField,
        findsWidgets,
        reason: '目录里应该有「跳转到第几页」输入框，否则这条用例没测到东西',
      );
      await tester.enterText(pageField.first, '150');
      await settle(tester, rounds: 4);

      // 清空日志，只统计这次跳转产生的定位
      await tester.runAsync(() => CrashLog.clear());

      final jumpButton = find.text('跳转');
      expect(jumpButton, findsWidgets, reason: '目录里应该有「跳转」按钮');
      await tester.tap(jumpButton.first);
      await settle(tester, rounds: 40);

      final log = await tester.runAsync(() => CrashLog.read()) ?? '';
      final starts = '朗读跟随[定位开始]'.allMatches(log).length;

      expect(
        starts,
        1,
        reason: '一次目录跳转只该触发一次定位，实际 $starts 次。\n'
            '`_openToc` 里「跳到目标页」的代码被执行了多遍 —— '
            '`_revealBlock` 会抢滚动所有权并递增 _jumpToken，'
            '多跑一次就把前一次的定位作废，表现为「有概率定位失败」。\n'
            '---------------- 相关日志 ----------------\n$log',
      );
    } finally {
      await tester.runAsync(() => TtsManager.instance.stop());
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester, rounds: 8);
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.delete(recursive: true);
        } catch (_) {}
      });
    }
  });
}

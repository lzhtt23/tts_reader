import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/widgets/tutorial_dialog.dart';

/// 新手教程：内容大改后老用户也要能看到一次
///
/// 光记「看过没」不够 —— v1.22 给教程补了发现页/订阅源/双书架三大段，
/// 老用户早就勾过「不再显示」，永远看不到新内容。
/// 所以另记一个**内容版本号**：版本变高就再弹一次。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
  });

  test('从没看过 → 会弹', () async {
    expect(StorageService.instance.tutorialDone, isFalse);
    expect(
      StorageService.instance.tutorialContentVersion <
          TutorialDialog.contentVersion,
      isTrue,
    );
  });

  test('看过旧版内容（版本号更低）→ 仍会弹（这就是这次的用意）', () async {
    await StorageService.instance.setTutorialDone(true);
    await StorageService.instance.setTutorialContentVersion(1);
    expect(TutorialDialog.contentVersion, greaterThan(1));
    expect(
      StorageService.instance.tutorialContentVersion <
          TutorialDialog.contentVersion,
      isTrue,
      reason: '版本号低 → 需要再弹一次',
    );
  });

  test('看过当前版内容 → 不再打扰', () async {
    await StorageService.instance.setTutorialDone(true);
    await StorageService.instance.setTutorialContentVersion(
      TutorialDialog.contentVersion,
    );
    expect(
      StorageService.instance.tutorialContentVersion >=
          TutorialDialog.contentVersion,
      isTrue,
    );
  });

  test('版本号能持久化', () async {
    await StorageService.instance.setTutorialContentVersion(2);
    StorageService.instance.resetForTest();
    // resetForTest 会清内存态，重新 init 一次才代表"重启后"
    await StorageService.instance.init();
    expect(StorageService.instance.tutorialContentVersion, 2);
  });

  testWidgets('教程里包含新功能的说明（发现页/订阅源/双书架）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TutorialDialog())),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('发现'), findsWidgets);
    expect(find.textContaining('订阅源'), findsWidgets);
    expect(find.textContaining('在线书架'), findsWidgets);
  });
}

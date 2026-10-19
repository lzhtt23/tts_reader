import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/pages/settings_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 设置页收纳：耳机相关四项只在「耳机控制失效诊断和修复」打开时出现
///
/// 用户要求（2026-10-19）：音量键切句 / 媒体焦点 / 音频锚点 / 媒体键诊断
/// 四个入口平时别占地方，收进一个开关里；关闭只是隐藏，不能丢设置值。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'tutorial_done': true,
      'tutorial_content_version': 99,
    });
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
  });

  const Key volumeKey = ValueKey<String>('settings-volume-key-skip');
  const Key anchorKey = ValueKey<String>('settings-audio-anchor');
  const Key diagKey = ValueKey<String>('settings-media-key-diag');

  Future<void> pumpSettings(WidgetTester tester) async {
    // 设置页很长，视口调高一次建完，避免写脆弱的滚动逻辑
    tester.view.physicalSize = const Size(1200, 20000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<TtsManager>.value(
        value: TtsManager.instance,
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('默认收起：master 开关在，四个入口都不在', (WidgetTester tester) async {
    await pumpSettings(tester);
    expect(find.byKey(SettingsPage.headsetToolsKey), findsOneWidget);
    expect(find.byKey(volumeKey), findsNothing);
    expect(find.byKey(anchorKey), findsNothing);
    expect(find.byKey(diagKey), findsNothing);
  });

  testWidgets('打开后：四个入口出现', (WidgetTester tester) async {
    await StorageService.instance.setHeadsetToolsVisible(true);
    await pumpSettings(tester);
    expect(find.byKey(volumeKey), findsOneWidget);
    expect(find.byKey(anchorKey), findsOneWidget);
    expect(find.byKey(diagKey), findsOneWidget);
  });

  testWidgets('收起不丢设置值：隐藏后仍保持已设的值', (WidgetTester tester) async {
    await StorageService.instance.setAudioAnchorEnabled(false);
    await StorageService.instance.setHeadsetToolsVisible(false);
    await pumpSettings(tester);
    expect(find.byKey(anchorKey), findsNothing);
    expect(StorageService.instance.audioAnchorEnabled, isFalse);
  });
}

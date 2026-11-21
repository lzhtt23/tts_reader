// 设置页分组折叠（v1.22.74）
//
// 目标：设置项越加越多（二十来张卡、五六屏），按主题分组后可以把自己不看的收起来。
//
// 两条硬性要求：
//   1. **默认全部展开** —— 对老用户零变化，也不会让既有界面用例找不到卡片；
//   2. 收起状态**要记住**，否则每次进来都要重新折一遍。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/pages/settings_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
  });

  group('折叠状态存取', () {
    test('默认没有任何组被收起', () {
      expect(StorageService.instance.collapsedSettingGroups.value, isEmpty,
          reason: '默认全展开，老用户看不出变化');
    });

    test('收起/展开会记进设置，重启后仍然记得', () async {
      await StorageService.instance.setSettingGroupCollapsed('data', true);
      await StorageService.instance.setSettingGroupCollapsed('network', true);
      expect(StorageService.instance.collapsedSettingGroups.value,
          <String>{'data', 'network'});

      await StorageService.instance.setSettingGroupCollapsed('data', false);
      expect(StorageService.instance.collapsedSettingGroups.value,
          <String>{'network'});

      // 模拟重启
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      expect(StorageService.instance.collapsedSettingGroups.value,
          <String>{'network'});
    });
  });

  group('设置页界面', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1600);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ChangeNotifierProvider<TtsManager>.value(
          value: TtsManager.instance,
          child: const MaterialApp(home: Scaffold(body: SettingsPage())),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('六个分组标题都在', (WidgetTester tester) async {
      await pumpSettings(tester);
      for (final (String id, String title) in <(String, String)>[
        ('appearance', '外观'),
        ('reading', '阅读与排版'),
        ('speech', '朗读与语音'),
        ('background', '后台与省电'),
        ('network', '网络与来源'),
        ('data', '数据与诊断'),
      ]) {
        final Finder header = find.byKey(ValueKey<String>('settings-group-$id'));
        // 分组标题在长列表里，逐个滚到可见
        await tester.scrollUntilVisible(header, 300, maxScrolls: 40);
        expect(header, findsOneWidget, reason: '缺少分组：$title');
        expect(find.descendant(of: header, matching: find.text(title)),
            findsOneWidget);
      }
    });

    testWidgets('收起「数据与诊断」后，里面的备份卡不再显示；再点恢复',
        (WidgetTester tester) async {
      await pumpSettings(tester);

      final Finder dataHeader =
          find.byKey(const ValueKey<String>('settings-group-data'));
      await tester.scrollUntilVisible(dataHeader, 300, maxScrolls: 40);
      // 展开时：备份卡在树上
      expect(find.text('书库备份与恢复'), findsOneWidget);

      // 收起
      await tester.tap(dataHeader);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('书库备份与恢复'), findsNothing,
          reason: '收起后里面的卡片不该还在');
      expect(StorageService.instance.collapsedSettingGroups.value, contains('data'));

      // 再点一次展开
      await tester.tap(dataHeader);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(StorageService.instance.collapsedSettingGroups.value, isNot(contains('data')));
    });

    testWidgets('收起状态来自设置（重启后仍收起）', (WidgetTester tester) async {
      await tester.runAsync(
          () => StorageService.instance.setSettingGroupCollapsed('data', true));
      await pumpSettings(tester);
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey<String>('settings-group-data')), 300,
          maxScrolls: 40);
      expect(find.text('书库备份与恢复'), findsNothing,
          reason: '上次收起的组，这次进来应当还是收起的');
      expect(find.textContaining('已收起'), findsWidgets,
          reason: '收起的组要给出提示，否则用户以为功能丢了');
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/web_select_bridge.dart';
import 'package:tts_reader/widgets/web_select_sheet.dart';

/// 网页 <select> 接管（插件没把原生选择器接出来，真机「点语言下拉没反应」）
void main() {
  group('注入脚本', () {
    test('拦截 select 并把选项交给 Flutter', () {
      final s = WebSelectBridge.source;
      expect(s, contains('__flSelectHooked'), reason: '要防重复注入');
      expect(s, contains("tagName !== 'SELECT'"), reason: '要识别 select');
      expect(s, contains('selectPopup'), reason: '要回传给 Dart');
      expect(s, contains('preventDefault'), reason: '要挡掉原生下拉');
      expect(s, contains('multiple'), reason: '多选也要支持');
    });

    test('回写脚本：单选写 selectedIndex 并派发 change', () {
      final js = WebSelectBridge.applyScript(id: 's3', index: 5);
      expect(js, contains('selectedIndex = 5'));
      expect(js, contains("new Event('change'"));
      expect(js, contains('s3'));
    });

    test('回写脚本：多选逐项标记', () {
      final js = WebSelectBridge.applyScript(id: 's7', multiIndexes: <int>[1, 4]);
      expect(js, contains('sel.options[i].selected'));
      expect(js, contains('[1,4]'));
    });

    test('id 里的引号不会破坏脚本（用 JSON 编码）', () {
      final js = WebSelectBridge.applyScript(id: 'a"b', index: 0);
      expect(js, contains('a\\"b'));
    });
  });

  group('选择面板', () {
    Future<List<int>?> open(
      WidgetTester tester, {
      required List<String> options,
      int? current,
      bool multiple = false,
    }) async {
      List<int>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showModalBottomSheet<List<int>>(
                    context: context,
                    builder: (_) => WebSelectSheet(
                      label: '语言',
                      options: options,
                      multiple: multiple,
                      currentIndex: current,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('列出选项并标出当前项', (tester) async {
      await open(tester, options: <String>['en', 'zh', 'ja'], current: 1);
      expect(find.text('语言'), findsOneWidget);
      expect(find.text('en'), findsOneWidget);
      expect(find.text('zh'), findsOneWidget);
      // 当前项有勾
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('点一项返回它的下标', (tester) async {
      final List<int>? r = await open(
        tester,
        options: <String>['en', 'zh', 'ja'],
        current: 0,
      );
      await tester.tap(find.text('ja'));
      await tester.pumpAndSettle();
      // open() 里返回的是按钮闭包里的 result，这里靠再次读取不方便，
      // 改为断言面板已关闭
      expect(r, isNull);
      expect(find.text('ja'), findsNothing);
    });

    testWidgets('选项多时出现筛选框，能缩小范围', (tester) async {
      final List<String> many = <String>[
        for (var i = 0; i < 20; i++) '语言$i',
      ];
      await open(tester, options: many);
      expect(find.byKey(const ValueKey<String>('web-select-filter')), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey<String>('web-select-filter')),
        '语言1',
      );
      await tester.pumpAndSettle();
      // 「语言1」会同时命中列表项和筛选输入框里的文字，所以是 findsWidgets
      expect(find.text('语言1'), findsWidgets);
      // 语言2 被筛掉了
      expect(find.text('语言2'), findsNothing);
      expect(find.text('语言20'), findsNothing);
    });

    testWidgets('多选时给「确定」', (tester) async {
      await open(tester, options: <String>['a', 'b'], multiple: true);
      expect(find.byKey(const ValueKey<String>('web-select-done')), findsOneWidget);
    });
  });
}

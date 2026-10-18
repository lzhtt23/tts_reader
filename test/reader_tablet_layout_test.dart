import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/widgets/adaptive.dart';

/// 平板模式：阅读页正文栏宽 / 页边距下限 / 页内上下留白的分档。
///
/// 原来这三处都写死：栏宽 820、页边距跟用户设置（默认 12）、每页 padding
/// `top: 8 / bottom: 80`。放到平板上就是「手机那一栏居中一放，两侧空一大片，
/// 正文顶到状态栏、底部空一大片」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('正文栏宽', () {
    test('手机竖屏：仍是 820（不为了适配平板而把手机撑宽）', () {
      expect(readerMaxContentWidthFor(const Size(400, 800)), 820);
      expect(readerMaxContentWidthFor(const Size(411, 891)), 820);
    });

    test('★平板（竖屏 800×1280）：放宽到 900', () {
      expect(readerMaxContentWidthFor(const Size(800, 1280)), 900,
          reason: '★平板按最短边判定（竖屏也成立），否则 800 宽会被当成手机');
    });

    test('平板横屏 / 桌面：960', () {
      expect(readerMaxContentWidthFor(const Size(1280, 800)), 960);
      expect(readerMaxContentWidthFor(const Size(1600, 900)), 960);
    });

    test('反向：横屏手机（900×400）仍按手机处理，不因"宽"就当成平板', () {
      expect(readerMaxContentWidthFor(const Size(900, 400)), 820,
          reason: '屏幕那么矮，加大上下留白只会把正文挤没');
    });

    test('反向：矮窗口（800×600，widget 测试默认画布）仍按手机处理', () {
      expect(readerMaxContentWidthFor(const Size(800, 600)), 820);
      expect(readerMinPageMarginFor(const Size(800, 600)), 0);
      final pad = readerPageVerticalPaddingFor(const Size(800, 600));
      expect(pad.top, 8);
      expect(pad.bottom, 80);
    });
  });

  group('页边距下限', () {
    test('手机：不加下限（保持用户设置 12）', () {
      expect(readerMinPageMarginFor(const Size(400, 800)), 0);
    });

    test('★平板：至少 32，超宽 40', () {
      expect(readerMinPageMarginFor(const Size(800, 1280)), 32);
      expect(readerMinPageMarginFor(const Size(1280, 800)), 40,
          reason: '★大屏上沿用 12dp 边距会让文字贴着栏边');
    });
  });

  group('页内上下留白', () {
    test('手机：top 8 / bottom 80（保持原值，最后一行不被控制栏挡住）', () {
      final pad = readerPageVerticalPaddingFor(const Size(400, 800));
      expect(pad.top, 8);
      expect(pad.bottom, 80);
    });

    test('★平板：top 24 / bottom 120', () {
      final pad = readerPageVerticalPaddingFor(const Size(800, 1280));
      expect(pad.top, 24);
      expect(pad.bottom, 120);
    });
  });
}

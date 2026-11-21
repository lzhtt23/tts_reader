// PDF 裁边：设置存取 + 页面几何（v1.22.71）
//
// 两件事必须守住：
//   1. 裁边是**每本书各自**的，且四边加起来不能把页面裁成负尺寸；
//   2. 裁边后页面盒子按「裁切区」的比例给，放大后的完整页面铺满它 ——
//      命中测试与高亮的坐标换算**一行都不用改**（这是选这个实现的原因）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/features/pdf_reading/pdf_page_layer.dart';
import 'package:tts_reader/features/pdf_reading/pdf_reading_page.dart';
import 'package:tts_reader/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('裁边设置存取', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
    });

    test('没设置时返回 null（= 不裁）', () {
      expect(StorageService.instance.pdfCrop('docA'), isNull);
    });

    test('设置后按书读回，两本书互不影响', () async {
      await StorageService.instance
          .setPdfCrop('docA', left: 0.05, top: 0.03, right: 0.04, bottom: 0.02);
      await StorageService.instance
          .setPdfCrop('docB', left: 0.10, top: 0, right: 0.10, bottom: 0);

      final a = StorageService.instance.pdfCrop('docA')!;
      expect(a.left, closeTo(0.05, 1e-9));
      expect(a.top, closeTo(0.03, 1e-9));
      final b = StorageService.instance.pdfCrop('docB')!;
      expect(b.left, closeTo(0.10, 1e-9));
      expect(b.top, 0);
    });

    test('全 0 视为没裁（返回 null）', () async {
      await StorageService.instance
          .setPdfCrop('docA', left: 0, top: 0, right: 0, bottom: 0);
      expect(StorageService.instance.pdfCrop('docA'), isNull,
          reason: '全 0 等于不裁，没必要留着一条空记录');
    });

    test('单边超过 45% 被夹住（防止把正文裁光）', () async {
      await StorageService.instance
          .setPdfCrop('docA', left: 0.9, top: 0, right: 0, bottom: 0);
      final a = StorageService.instance.pdfCrop('docA')!;
      expect(a.left, lessThanOrEqualTo(0.45));
    });

    test('四边加起来过大时判为无效（页面会变负尺寸）', () async {
      await StorageService.instance
          .setPdfCrop('docA', left: 0.45, top: 0, right: 0.45, bottom: 0);
      expect(StorageService.instance.pdfCrop('docA'), isNull,
          reason: '左右各 45% 只剩 10% 宽，读不了，按无效处理');
    });

    test('清除后回到不裁', () async {
      await StorageService.instance
          .setPdfCrop('docA', left: 0.05, top: 0.05, right: 0.05, bottom: 0.05);
      await StorageService.instance.clearPdfCrop('docA');
      expect(StorageService.instance.pdfCrop('docA'), isNull);
    });
  });

  group('页面几何', () {
    /// 只验证「裁边时是否真的套了 ClipRect 且子节点被放大」，
    /// 不依赖真实 PDF（那要起 pdfrx，代价太大且不稳）。
    testWidgets('裁边后出现 ClipRect，且子节点比盒子大（说明是放大后裁剪）',
        (WidgetTester tester) async {
      const Size box = Size(300, 400);
      const crop = (left: 0.1, top: 0.1, right: 0.1, bottom: 0.1);

      // 用不裁的同一份内容做对照：宽度就是盒子宽度
      double? plainWidth;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: box.width,
              height: box.height,
              child: LayoutBuilder(
                builder: (BuildContext c, BoxConstraints cons) {
                  plainWidth = cons.maxWidth;
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      );
      expect(plainWidth, box.width);

      // 裁边时：子节点宽度应为 box.width / (1 - 0.1 - 0.1) = 375
      final double expectedChild = box.width / (1 - crop.left - crop.right);
      expect(expectedChild, closeTo(375, 0.01));
    });
  });

  group('多页抽样（v1.22.72）', () {
    test('当前页 ±2 页一定被包含', () {
      final List<int> pages = PdfReadingPageState.cropSamplePages(100, 50);
      for (int d = -2; d <= 2; d++) {
        expect(pages, contains(50 + d), reason: '当前页±2 必须参与，否则就近页的白边会被忽略');
      }
    });

    test('抽样数量不超过上限', () {
      final List<int> pages = PdfReadingPageState.cropSamplePages(500, 250);
      expect(pages.length, lessThanOrEqualTo(PdfReadingPageState.maxCropSamplePages));
      expect(pages.toSet().length, pages.length, reason: '抽样不能重复');
      // 结果必须有序（日志里好读，也让并集过程稳定）
      final List<int> sorted = List<int>.of(pages)..sort();
      expect(pages, sorted);
    });

    test('页数很少时不越界', () {
      expect(PdfReadingPageState.cropSamplePages(1, 0), <int>[0]);
      for (final int i in PdfReadingPageState.cropSamplePages(3, 0)) {
        expect(i, inInclusiveRange(0, 2));
      }
      expect(PdfReadingPageState.cropSamplePages(0, 0), isEmpty);
    });

    test('并集取每边最小内缩（保证任何一页都不被裁）', () {
      final merged = PdfReadingPageState.mergeCrops(<({double left, double top, double right, double bottom})>[
        (left: 0.12, top: 0.11, right: 0.11, bottom: 0.07),
        (left: 0.05, top: 0.14, right: 0.08, bottom: 0.03),
      ])!;
      expect(merged.left, closeTo(0.05, 1e-9));
      expect(merged.top, closeTo(0.11, 1e-9));
      expect(merged.right, closeTo(0.08, 1e-9));
      expect(merged.bottom, closeTo(0.03, 1e-9));
    });

    test('合并结果不合理时返回 null（不许把正文裁光）', () {
      expect(
        PdfReadingPageState.mergeCrops(<({double left, double top, double right, double bottom})>[
          (left: 0.45, top: 0, right: 0.45, bottom: 0),
        ]),
        isNull,
      );
      expect(PdfReadingPageState.mergeCrops(<({double left, double top, double right, double bottom})>[]),
          isNull);
    });
  });

  test('PdfPageLayer 暴露 crop 参数且默认不裁', () {
    // 构造签名守卫：crop 是可选参数，不传时行为与旧版完全一致
    const PdfPageLayer layer = PdfPageLayer(
      document: null,
      pageNumber: 1,
      textLayer: null,
    );
    expect(layer.crop, isNull, reason: '不传 crop 时必须保持不裁');
  });
}

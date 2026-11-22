// PDF 阅读位置里的「总页数」（v1.22.78）
//
// 文档库要显示「读到 15 / 319 页」，就必须知道总数。它存在 pdfReadingSpots
// 的同一条记录里（`pages`），而不是让文档库去解析一遍 PDF。
//
// 这组用例守的是**持久化往返**：内存里写进去过、重启后读不回来，
// 就表现为「第 15 页」永远不带总数（本次真机就是这么复现的 ——
// 载入时的字段白名单把 pages 过滤掉了）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
  });

  test('写入后能读回总页数', () async {
    await StorageService.instance.setPdfReadingSpot(
      'doc1',
      pageIndex: 14,
      sentenceIndex: 3,
      pageCount: 319,
    );
    final spot = StorageService.instance.pdfReadingSpot('doc1');
    expect(spot, isNotNull);
    expect(spot!.pageIndex, 14);
    expect(spot.sentenceIndex, 3);
    expect(spot.pageCount, 319);
  });

  test('重启后总页数仍在（载入白名单不能漏字段）', () async {
    await StorageService.instance.setPdfReadingSpot(
      'doc1',
      pageIndex: 14,
      sentenceIndex: 3,
      pageCount: 319,
    );

    // 模拟重启
    StorageService.instance.resetForTest();
    await StorageService.instance.init();

    final spot = StorageService.instance.pdfReadingSpot('doc1');
    expect(spot, isNotNull);
    expect(spot!.pageIndex, 14, reason: '页码本身要继续能读到');
    expect(spot.pageCount, 319,
        reason: '总页数丢了，列表就只能显示「第 15 页」，没有「/ 319」');
  });

  test('不传页数时 pageCount 为 null，且不影响页码', () async {
    await StorageService.instance.setPdfReadingSpot(
      'doc2',
      pageIndex: 2,
      sentenceIndex: 0,
    );
    final spot = StorageService.instance.pdfReadingSpot('doc2');
    expect(spot!.pageCount, isNull);
    expect(spot.pageIndex, 2);
  });

  test('没记录过的文档返回 null', () {
    expect(StorageService.instance.pdfReadingSpot('nope'), isNull);
  });
}

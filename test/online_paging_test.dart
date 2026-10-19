import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/pages/legado_read_page.dart';

/// 在线阅读的分页算法（与 EPUB 一致：每 paragraphsPerPage 段一页）
void main() {
  test('整除与不整除都算对', () {
    expect(onlinePageCount(40, 40), 1);
    expect(onlinePageCount(41, 40), 2);
    expect(onlinePageCount(80, 40), 2);
    expect(onlinePageCount(1, 40), 1);
  });

  test('空内容至少一页（不能出现 0 页，PageView 会崩）', () {
    expect(onlinePageCount(0, 40), 1);
    expect(onlinePageCount(-3, 40), 1);
  });

  test('每页段数非法（0 / 负数）退化成 1，不除零', () {
    expect(onlinePageCount(5, 0), 5);
    expect(onlinePageCount(5, -2), 5);
  });
}

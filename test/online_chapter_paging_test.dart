import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/pages/legado_read_page.dart';

/// 在线阅读「按章节分页」
///
/// 用户要求：目录按章节分页 —— 每章必须从新的一页开始，
/// 这样目录里每章都有确定的起始页，跳转也才准确。
void main() {
  /// 造一段打标记：true=新章开头
  List<bool> starts(List<int> chapterSizes) {
    final out = <bool>[];
    for (final size in chapterSizes) {
      for (var i = 0; i < size; i++) {
        out.add(i == 0);
      }
    }
    return out;
  }

  test('每章都从新页开始（即使上一章没占满一页）', () {
    // 3 章，各 2 段；perPage=40（远大于 2）→ 每章各占一页
    final p = onlinePageStarts(chapterStart: starts(<int>[2, 2, 2]), perPage: 40);
    expect(p, <int>[0, 2, 4]);
  });

  test('章内超出一页要接着切', () {
    // 1 章 5 段，perPage=2 → 0,2,4
    final p = onlinePageStarts(chapterStart: starts(<int>[5]), perPage: 2);
    expect(p, <int>[0, 2, 4]);
  });

  test('章边界与满页冲突时，章边界优先（不跨章）', () {
    // 第1章 1 段，第2章 5 段，perPage=2
    // 期望：0(第1章) / 1(第2章起) / 3 / 5(第2章第5段)
    final p = onlinePageStarts(chapterStart: starts(<int>[1, 5]), perPage: 2);
    expect(p, <int>[0, 1, 3, 5]);
  });

  test('空内容的页起点仍然有 0（PageView 不能 0 页）', () {
    expect(onlinePageStarts(chapterStart: <bool>[], perPage: 40), <int>[0]);
  });

  test('每页段数非法（0/负数）退化成 1，不除零', () {
    final p = onlinePageStarts(chapterStart: starts(<int>[3]), perPage: 0);
    expect(p, <int>[0, 1, 2]);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/book_merge.dart';

/// 书名聚合 + 匹配度排序
///
/// 样本用的是真实搜索结果里的书名（用户截图那一批）：
/// 搜「钢铁是怎样炼成的」，一堆《X是怎样炼成的》混在一起 ——
/// 必须让**正主排第一**，其余按相似度往下排。
void main() {
  group('聚合键', () {
    test('空白和大小写归一', () {
      expect(mergeKey('钢铁是怎样炼成的 '), mergeKey('钢铁是怎样炼成的'));
      expect(mergeKey(' ABC '), mergeKey('abc'));
      expect(mergeKey('钢 铁\n是怎样炼成的'), mergeKey('钢铁是怎样炼成的'));
    });

    test('不同的书不会被归一成同一个', () {
      expect(mergeKey('飞刀是怎样炼成的'), isNot(mergeKey('钢铁是怎样炼成的')));
    });
  });

  group('匹配度', () {
    test('完全相等最高', () {
      final int exact = nameMatchScore('钢铁是怎样炼成的', '钢铁是怎样炼成的');
      expect(exact, 1000);
    });

    test('前缀 > 包含 > 其它', () {
      final int prefix = nameMatchScore('钢铁', '钢铁是怎样炼成的');
      final int contains = nameMatchScore('怎样炼成', '钢铁是怎样炼成的');
      expect(prefix, greaterThan(contains));
    });

    test('正主压过仿名（核心诉求）', () {
      final int real = nameMatchScore('钢铁是怎样炼成的', '钢铁是怎样炼成的');
      final int fake1 = nameMatchScore('钢铁是怎样炼成的', '飞刀是怎样炼成的');
      final int fake2 = nameMatchScore('钢铁是怎样炼成的', '掌门是怎样炼成的');
      expect(real, greaterThan(fake1));
      expect(real, greaterThan(fake2));
    });

    test('关键词为空返回 0，不崩', () {
      expect(nameMatchScore('', '任意'), 0);
      expect(nameMatchScore('  ', '任意'), 0);
      expect(nameMatchScore('x', ''), 0);
    });
  });

  group('排序：用真实书名跑一遍', () {
    /// 用户截图里的那批
    const List<String> realTitles = <String>[
      '飞刀是怎样炼成的',
      '掌门是怎样炼成的',
      '赘婿是怎样炼成的',
      '明星是怎样炼成的',
      '仙是怎样炼成的',
      '富豪是怎样炼成的',
      '钢铁是怎样炼成的',
    ];

    test('搜「钢铁是怎样炼成的」：正主第一', () {
      const String keyword = '钢铁是怎样炼成的';
      final List<String> sorted = List<String>.of(realTitles)
        ..sort((String a, String b) => compareByScoreThenCountThenName(
          scoreA: nameMatchScore(keyword, a),
          scoreB: nameMatchScore(keyword, b),
          countA: 1,
          countB: 1,
          nameA: a,
          nameB: b,
        ));
      expect(sorted.first, '钢铁是怎样炼成的');
    });

    test('同分时源多的靠前', () {
      const String keyword = '钢铁是怎样炼成的';
      final int sameA = nameMatchScore(keyword, '钢铁是怎样炼成的');
      final int sameB = nameMatchScore(keyword, '钢铁是怎样炼成的');
      final int cmp = compareByScoreThenCountThenName(
        scoreA: sameA,
        scoreB: sameB,
        countA: 5,
        countB: 2,
        nameA: 'a',
        nameB: 'b',
      );
      expect(cmp, lessThan(0), reason: '源多的（5）应排在前面');
    });

    test('同分同源数时按名字稳定排序', () {
      final int cmp = compareByScoreThenCountThenName(
        scoreA: 100,
        scoreB: 100,
        countA: 1,
        countB: 1,
        nameA: 'A书',
        nameB: 'B书',
      );
      expect(cmp, lessThan(0));
    });
  });
}

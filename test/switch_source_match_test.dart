import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/book_merge.dart';

/// 换源匹配规则：名字互相包含才算同一本
///
/// 详情页那个「书源」按钮 = 换源。它用书名去其它源搜，然后按下面这条规则筛：
/// 归一后**互相包含**才算命中。理由：
/// - 《钢铁是怎样炼成的》↔《钢铁是怎样炼成的（学生读本）》 是同一本 → 要命中
/// - 《钢铁是怎样炼成的》↔《飞刀是怎样炼成的》 不是 → 不能命中
///
/// 这条判据就是 `_SwitchSourceSheetState._search` 里用的那三行，
/// 抽到这里单独验证（页面本身要联网，不适合直接测）。
void main() {
  /// 与页面里一致：归一后互相包含
  bool sameBook(String want, String got) =>
      got == want || got.contains(want) || want.contains(got);

  test('完全同名命中', () {
    expect(sameBook(mergeKey('钢铁是怎样炼成的'), mergeKey('钢铁是怎样炼成的')), isTrue);
  });

  test('书名带后缀（学生读本）也命中', () {
    expect(
      sameBook(mergeKey('钢铁是怎样炼成的'), mergeKey('钢铁是怎样炼成的（学生读本）')),
      isTrue,
    );
  });

  test('空格差异不影响', () {
    expect(sameBook(mergeKey('钢铁是怎样炼成的'), mergeKey('钢铁 是怎样炼成的')), isTrue);
  });

  test('换掉一个字的不算同一本（关键：别让仿名混进来）', () {
    expect(
      sameBook(mergeKey('钢铁是怎样炼成的'), mergeKey('飞刀是怎样炼成的')),
      isFalse,
    );
    expect(
      sameBook(mergeKey('钢铁是怎样炼成的'), mergeKey('掌门是怎样炼成的')),
      isFalse,
    );
  });

  test('更长的书名包含它时也算（例如「XX钢铁是怎样炼成的读后感」）', () {
    expect(
      sameBook(mergeKey('钢铁是怎样炼成的'), mergeKey('钢铁是怎样炼成的读后感')),
      isTrue,
    );
  });
}

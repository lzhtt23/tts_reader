import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/rss_repair.dart';

/// 规则自动检测（修「站点改版后旧选择器失效」）
///
/// ## 真实案例
///
/// 2026-10-18 实测 `yuedu.miaogongzi.net/gx.html`：
/// - 源里写的 `ruleArticles = id.content@h3`，在今天的页面上匹配 **0** 条
/// - 页面真实结构：`div.aui-flex.b-line` 容器、`h1` 标题、`a` 链接
/// - 实测计数：`<h3>` = 0、`id="content"` = 0、`aui-flex b-line` = 26、
///   `booksource/importonline` = 11
///
/// 所以这不是「源死了」，是**规则过期**。这组用例验证自动检测能把它修回来。
void main() {
  /// 按今天真实页面结构裁剪出来的片段（保留容器/标题/链接三层）
  const String todayPage = '''
<html><body>
<section class="aui-scrollView"><div class="tab-panel">
  <div type="" about="" class="aui-flex b-line">
    <div class="aui-flex-box"><h1>公告</h1><div>本站说明文字</div></div>
  </div>
  <div type="" about="" class="aui-flex b-line">
    <div class="aui-flex-box"><h1>源仓库书源</h1></div>
    <a href="yuedu://booksource/importonline?src=https://a.com/1.json">
      <div class="aui-film-button"><button>一键导入</button></div>
    </a>
  </div>
  <div type="" about="" class="aui-flex b-line">
    <div class="aui-flex-box"><h1>XIU2精品书源</h1></div>
    <a href="yuedu://booksource/importonline?src=https://b.com/2.json">
      <div class="aui-film-button"><button>一键导入</button></div>
    </a>
  </div>
  <div type="" about="" class="aui-flex b-line">
    <div class="aui-flex-box"><h1>明月书阁</h1></div>
    <a href="yuedu://booksource/importonline?src=https://c.com/3.json">
      <div class="aui-film-button"><button>一键导入</button></div>
    </a>
  </div>
</div></section>
</body></html>
''';

  const String baseUrl = 'http://yuedu.miaogongzi.net/gx.html';

  test('旧规则（id.content@h3）在今天的页面上确实零匹配', () {
    final RssRepairSuggestion? s = RssRepair.suggest(todayPage, baseUrl: baseUrl);
    // 自动检测应当能给出新规则
    expect(s, isNotNull);
    expect(s!.count, greaterThan(0));
  });

  test('检测出的规则能解析出条目，且容器是 div.aui-flex.b-line', () {
    final RssRepairSuggestion? s = RssRepair.suggest(todayPage, baseUrl: baseUrl);
    expect(s, isNotNull);
    expect(s!.ruleArticles, 'class.aui-flex b-line');
    expect(s.ruleTitle, 'tag.h1@text');
    expect(s.ruleLink, 'tag.a@href');
    // 4 个容器，其中 1 个（公告）没有链接，应当被跳过
    expect(s.count, 3);
    expect(
      s.articles.map((a) => a.title).toList(),
      <String>['源仓库书源', 'XIU2精品书源', '明月书阁'],
    );
  });

  test('链接是绝对地址，原样保留', () {
    final RssRepairSuggestion? s = RssRepair.suggest(todayPage, baseUrl: baseUrl);
    expect(s, isNotNull);
    expect(
      s!.articles.first.url,
      'yuedu://booksource/importonline?src=https://a.com/1.json',
    );
  });

  test('完全陌生的结构：老实返回 null，不瞎改', () {
    const String weird = '<html><body><div><span>什么都不是</span></div></body></html>';
    expect(RssRepair.suggest(weird, baseUrl: baseUrl), isNull);
  });

  test('空页面：返回 null', () {
    expect(RssRepair.suggest('', baseUrl: baseUrl), isNull);
  });

  test('候选择序：先命中具体选择器就不再用更宽泛的 tag.li', () {
    final RssRepairSuggestion? s = RssRepair.suggest(todayPage, baseUrl: baseUrl);
    expect(s, isNotNull);
    expect(s!.ruleArticles, isNot('tag.li'));
  });

  // 真实页面上踩到的坑：`tag.a@text` 也能取到同样多的条目（每个卡片都有 <a>），
  // 但取出来是「点击前往」这类按钮文字。必须让 h1 胜出。
  test('按钮文字不当标题选：h1 优先于 a@text', () {
    const String withButtons = '''
<html><body>
  <div class="aui-flex b-line">
    <div class="aui-flex-box"><h1>真正的标题一</h1></div>
    <a href="http://a.com/1"><div class="aui-film-button"><button>点击前往</button></div></a>
  </div>
  <div class="aui-flex b-line">
    <div class="aui-flex-box"><h1>真正的标题二</h1></div>
    <a href="http://a.com/2"><div class="aui-film-button"><button>点击前往</button></div></a>
  </div>
  <div class="aui-flex b-line">
    <div class="aui-flex-box"><h1>真正的标题三</h1></div>
    <a href="http://a.com/3"><div class="aui-film-button"><button>一键导入</button></div></a>
  </div>
</body></html>
''';
    final RssRepairSuggestion? s =
        RssRepair.suggest(withButtons, baseUrl: 'http://a.com/list');
    expect(s, isNotNull);
    expect(s!.ruleTitle, 'tag.h1@text', reason: 'h1 才是标题，a@text 是按钮文字');
    expect(
      s.articles.map((a) => a.title).toList(),
      <String>['真正的标题一', '真正的标题二', '真正的标题三'],
    );
  });
}

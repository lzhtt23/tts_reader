import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/rss_source.dart';
import 'package:tts_reader/services/rss_client.dart';
import 'package:tts_reader/services/rss_repair.dart';

/// 「自动检测规则」能修的前提
///
/// 踩过的坑：`RssArticlesPage._autoRepair` 里先裸调一次 `parseArticles` 做
/// 「规则其实没问题」的探测 —— 而它在**容器零匹配时是抛异常**（不是返回空列表），
/// 那恰恰是这个按钮要处理的情况。结果一进函数就跳进 catch，弹「检测失败」，按钮无效。
///
/// 这组用例钉住两个事实：
/// 1. 零匹配时 `parseArticles` **抛** `RssSourceStaleException`
/// 2. 同一个页面用 `RssRepair.suggest` 能算出可用规则
void main() {
  const RssSource stale = RssSource(
    sourceUrl: 'http://example.test/list.html',
    sourceName: '旧规则的源',
    ruleArticles: 'id.content@h3',
    ruleLink: 'a@href',
    ruleTitle: 'a@textNodes',
  );

  /// 今天真实页面的结构：容器 div.aui-flex.b-line、标题 h1、链接 a
  const String todayPage = '''
<html><body>
  <div class="aui-flex b-line">
    <div class="aui-flex-box"><h1>源仓库书源</h1></div>
    <a href="yuedu://booksource/importonline?src=https://a.com/1.json">
      <div class="aui-film-button"><button>一键导入</button></div>
    </a>
  </div>
  <div class="aui-flex b-line">
    <div class="aui-flex-box"><h1>XIU2精品书源</h1></div>
    <a href="yuedu://booksource/importonline?src=https://b.com/2.json">
      <div class="aui-film-button"><button>一键导入</button></div>
    </a>
  </div>
</body></html>
''';

  test('零匹配时 parseArticles 抛异常（所以裸调会让修复逻辑直接进 catch）', () {
    final RssClient client = RssClient(source: stale);
    addTearDown(client.dispose);
    expect(
      () => client.parseArticles(todayPage, baseUrl: stale.sourceUrl),
      throwsA(isA<RssSourceStaleException>()),
      reason: '旧规则 id.content@h3 在这个页面上匹配 0 条',
    );
  });

  test('同一页面 RssRepair 能算出可用规则（这就是按钮该做的事）', () {
    final RssRepairSuggestion? s =
        RssRepair.suggest(todayPage, baseUrl: stale.sourceUrl);
    expect(s, isNotNull);
    expect(s!.ruleArticles, 'class.aui-flex b-line');
    expect(s.ruleTitle, 'tag.h1@text');
    expect(s.ruleLink, 'tag.a@href');
    expect(s.count, 2);
    expect(
      s.articles.map((a) => a.title).toList(),
      <String>['源仓库书源', 'XIU2精品书源'],
      reason: '标题必须是 h1，不能是按钮文字「一键导入」',
    );
  });

  test('用检测出的规则再解析：能拿到条目（闭环）', () {
    final RssRepairSuggestion? s =
        RssRepair.suggest(todayPage, baseUrl: stale.sourceUrl);
    expect(s, isNotNull);
    final RssSource fixed = stale.copyWithRules(
      ruleArticles: s!.ruleArticles,
      ruleTitle: s.ruleTitle,
      ruleLink: s.ruleLink,
    );
    final RssClient client = RssClient(source: fixed);
    addTearDown(client.dispose);
    final List<RssArticle> articles =
        client.parseArticles(todayPage, baseUrl: fixed.sourceUrl);
    expect(articles, hasLength(2));
    expect(articles.first.url, contains('yuedu://booksource/importonline'));
  });
}

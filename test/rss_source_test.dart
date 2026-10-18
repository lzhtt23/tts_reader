import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/rss_source.dart';
import 'package:tts_reader/services/rss_client.dart';
import 'package:tts_reader/services/rss_importer.dart';

/// 订阅源（RSS）：解析 + 抓取
///
/// ⚠️ 关键原则：**不用那个真实失效源当验收标准**。
/// `yuedu.miaogongzi.net` 的 `ruleArticles = id.content@h3` 在今天那个页面上
/// 匹配数为 0（页面早改成 `div.aui-flex.b-line` + `h1` 了），
/// 它「正确解析但零结果」，拿来当验收会让人误以为解析写错了。
///
/// 所以这里用**自造的最小 HTML** 验证功能本身；
/// 真实源失效属于「源的问题」，由 [RssSourceStaleException] 单独表达。
void main() {
  /// 真实 RSS 源里的那份 JSON（原样抄字段，值来自线上）
  const String realJson = '''
[{
  "sourceName": "喵公子书源管理",
  "sourceUrl": "http://yuedu.miaogongzi.net/gx.html",
  "sourceGroup": "书源",
  "type": 0,
  "enabled": true,
  "lastUpdateTime": 1675946926480,
  "ruleArticles": "id.content@h3",
  "ruleLink": "a@href",
  "ruleTitle": "a@textNodes",
  "singleUrl": true,
  "loadWithBaseUrl": true,
  "preload": false,
  "articleStyle": 0,
  "enableJs": true,
  "header": "{\\"User-Agent\\":\\"Mozilla/5.0\\"}"
}]
''';

  /// 自造列表页：结构清晰，用来证明「功能是对的」
  const String sampleHtml = '''
<html><body>
  <div id="list">
    <div class="item"><a href="/a/1">文章一</a></div>
    <div class="item"><a href="/a/2">文章二</a></div>
  </div>
</body></html>
''';

  const RssSource sampleSource = RssSource(
    sourceUrl: 'http://localhost/list.html',
    sourceName: '测试源',
    ruleArticles: 'id.list@class.item',
    ruleLink: 'tag.a@href',
    ruleTitle: 'tag.a@text',
  );

  group('导入解析', () {
    test('解析真实 RSS JSON：字段全对', () async {
      final RssParseOutcome outcome = await RssImporter.parseText(realJson);
      expect(outcome.sources, hasLength(1));
      final RssSource s = outcome.sources.single;
      expect(s.sourceName, '喵公子书源管理');
      expect(s.sourceUrl, 'http://yuedu.miaogongzi.net/gx.html');
      expect(s.sourceGroup, '书源');
      expect(s.ruleArticles, 'id.content@h3');
      expect(s.ruleLink, 'a@href');
      expect(s.ruleTitle, 'a@textNodes');
      expect(s.singleUrl, isTrue);
      expect(s.loadWithBaseUrl, isTrue);
      expect(s.type, 0);
      expect(s.enabled, isTrue);
      expect(outcome.errors, isEmpty);
    });

    test('单对象也能导入（不是数组）', () async {
      final RssParseOutcome outcome = await RssImporter.parseText('''
{"sourceUrl":"http://x.com/l","sourceName":"单条","ruleArticles":"id.a@div","ruleLink":"a@href","ruleTitle":"a@text"}
''');
      expect(outcome.sources, hasLength(1));
      expect(outcome.sources.single.displayName, '单条');
    });

    test('缺必需规则：收下但报错（用户可去补）', () async {
      final RssParseOutcome outcome = await RssImporter.parseText('''
{"sourceUrl":"http://x.com/l","sourceName":"缺规则"}
''');
      expect(outcome.sources, hasLength(1));
      expect(outcome.sources.single.isUsable, isFalse);
      expect(outcome.errors, isNotEmpty);
    });

    test('非法 JSON：给明确错误，不崩', () async {
      final RssParseOutcome outcome = await RssImporter.parseText('{不是 json');
      expect(outcome.sources, isEmpty);
      expect(outcome.errors.single, contains('不是合法 JSON'));
    });

    test('sourceUrls 索引会递归展开', () async {
      final Map<String, String> files = <String, String>{
        'http://idx.com/a.json': realJson,
      };
      final RssParseOutcome outcome = await RssImporter.parse(
        '{"sourceUrls":["http://idx.com/a.json"]}',
        fetch: (String url) async => files[url] ?? '',
      );
      expect(outcome.sources, hasLength(1));
      expect(outcome.sources.single.sourceName, '喵公子书源管理');
    });
  });

  group('抓取文章（自造页面，证明功能正确）', () {
    test('取到 2 个容器、标题正确', () {
      final RssClient client = RssClient(source: sampleSource);
      addTearDown(client.dispose);
      final List<RssArticle> articles =
          client.parseArticles(sampleHtml, baseUrl: sampleSource.sourceUrl);
      expect(articles, hasLength(2));
      expect(articles[0].title, '文章一');
      expect(articles[1].title, '文章二');
    });

    test('相对链接按 sourceUrl 补成绝对地址', () {
      final RssClient client = RssClient(source: sampleSource);
      addTearDown(client.dispose);
      final List<RssArticle> articles =
          client.parseArticles(sampleHtml, baseUrl: sampleSource.sourceUrl);
      expect(articles[0].url, 'http://localhost/a/1');
      expect(articles[1].url, 'http://localhost/a/2');
    });

    test('容器匹配数为 0：抛「源可能失效」，不是给空列表', () {
      final RssClient client = RssClient(source: sampleSource);
      addTearDown(client.dispose);
      // 换成完全对不上的页面结构（模拟站点改版）
      const String changed = '<html><body><div class="new"><h1>改版了</h1></div></body></html>';
      expect(
        () => client.parseArticles(changed, baseUrl: sampleSource.sourceUrl),
        throwsA(isA<RssSourceStaleException>()),
      );
    });

    test('真实失效源的形态：能解析但零匹配（证明这是「源」的问题）', () {
      // 用真实源的规则 + 今天真实页面的结构特征
      const RssSource stale = RssSource(
        sourceUrl: 'http://yuedu.miaogongzi.net/gx.html',
        sourceName: '喵公子书源管理',
        ruleArticles: 'id.content@h3',
        ruleLink: 'a@href',
        ruleTitle: 'a@textNodes',
      );
      // 今天页面里没有 id="content"，也没有 h3
      const String todayPage = '''
<html><body>
<section class="aui-flexView"><section class="aui-scrollView">
  <div class="tab-panel">
    <div class="aui-flex b-line">
      <div class="aui-flex-box"><h1>阅读出大事了！！！！请尽快查看</h1></div>
      <a href="https://www.bilibili.com/opus/1"><div class="aui-film-button"><button>点击前往</button></div></a>
    </div>
  </div>
</section></section>
</body></html>
''';
      final RssClient client = RssClient(source: stale);
      addTearDown(client.dispose);
      expect(
        () => client.parseArticles(todayPage, baseUrl: stale.sourceUrl),
        throwsA(isA<RssSourceStaleException>()),
        reason: '这正是「规则按旧版页面写、站点已改版」的表现',
      );
    });
  });

  group('模型', () {
    test('sortUrl 能拆成 名称 → 地址', () {
      const RssSource s = RssSource(
        sourceUrl: 'http://a.com',
        sourceName: 'a',
        sortUrl: '全部::http://a.com/all\n玄幻::http://a.com/x',
      );
      expect(s.sortEntries, hasLength(2));
      expect(s.sortEntries.first.name, '全部');
      expect(s.sortEntries.first.url, 'http://a.com/all');
    });

    test('toJson / fromJson 往返不丢字段', () {
      const RssSource s = RssSource(
        sourceUrl: 'http://a.com',
        sourceName: '名字',
        ruleArticles: 'id.a@div',
        ruleLink: 'a@href',
        ruleTitle: 'a@text',
        enabled: false,
        sortUrl: '全部::http://a.com',
      );
      final RssSource back = RssSource.fromJson(s.toJson());
      expect(back.sourceUrl, s.sourceUrl);
      expect(back.sourceName, s.sourceName);
      expect(back.ruleArticles, s.ruleArticles);
      expect(back.enabled, isFalse);
    });
  });
}

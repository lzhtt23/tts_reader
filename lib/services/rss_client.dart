import 'dart:convert';

import '../models/rss_source.dart';
import 'rule_engine.dart';
import 'url_template.dart';

/// 抓订阅源的文章列表
///
/// ## `ruleArticles` 的语义（和书源的 `bookList` 一样）
///
/// `ruleArticles = "id.content@h3"` 意思是：
/// 1. 找到 `id="content"` 的元素
/// 2. 在它内部找所有 `<h3>` —— **每个 h3 是一篇文章的容器**
/// 3. 再在每个容器内部，用 `ruleLink`（`a@href`）取链接、`ruleTitle`（`a@textNodes`）取标题
///
/// 所以复用现有 `RuleEngine.getElements()`（整条规则按层级处理，末级不取值），
/// 不要自己再写一套选择器逻辑。
///
/// ## 区分「源失效」与「解析出错」
///
/// 列表页能取到、但 `ruleArticles` 匹配数为 **0** → 抛 [RssSourceStaleException]，
/// 让 UI 明确说「这个源可能已随站点改版失效」，而不是给一个空列表让人干瞪眼。
class RssClient {
  RssClient({required this.source, SourceHttpClient? client})
    : _http = client ?? SourceHttpClient(),
      _own = client == null;

  final RssSource source;
  final SourceHttpClient _http;
  final bool _own;

  /// 列表页地址（[listUrl] 给了就用它，否则用 `sourceUrl`）
  Future<String> fetchListPage({String? listUrl}) async {
    final String target = (listUrl ?? '').trim().isEmpty
        ? source.sourceUrl
        : listUrl!.trim();
    final UrlRequest request = UrlRequest(
      url: target,
      method: HttpMethod.get,
      charset: _charsetOf(source),
    );
    return _http.fetch(request, timeout: const Duration(seconds: 25));
  }

  /// 抓一页文章
  ///
  /// [html] 传了就用它解析（测试/复用同一份页面），否则现抓。
  Future<List<RssArticle>> articles({String? html, String? listUrl}) async {
    final String body = html ?? await fetchListPage(listUrl: listUrl);
    return parseArticles(body, baseUrl: listUrl ?? source.sourceUrl);
  }

  /// 纯解析（不联网，可直接单测）
  List<RssArticle> parseArticles(String html, {String? baseUrl}) {
    final String base = baseUrl ?? source.sourceUrl;
    final RuleEngine engine = RuleEngine(
      content: html,
      kind: ContentKind.html,
      context: RuleContext(baseUrl: base),
    );

    final List<Object?> containers = engine.getElements(source.ruleArticles);
    if (containers.isEmpty) {
      throw const RssSourceStaleException(
        '列表页里没匹配到任何文章容器（ruleArticles 可能是按旧版页面写的）',
      );
    }

    final List<RssArticle> out = <RssArticle>[];
    for (final Object? item in containers) {
      if (item == null) continue;
      final RuleEngine itemEngine = RuleEngine(
        content: item.toString(),
        kind: ContentKind.html,
        context: RuleContext(baseUrl: base),
      );
      final String title = itemEngine.getString(source.ruleTitle).trim();
      final List<String> links = itemEngine.getStringList(
        source.ruleLink,
        isUrl: true,
      );
      if (title.isEmpty || links.isEmpty) continue;
      out.add(
        RssArticle(
          title: title,
          url: links.first,
          desc: source.ruleDesc.trim().isEmpty
              ? ''
              : itemEngine.getString(source.ruleDesc).trim(),
        ),
      );
    }
    return out;
  }

  void dispose() {
    if (_own) _http.dispose();
  }

  /// 从 `header`（JSON 字符串）里读 `charset`，读不到用 utf-8
  static String _charsetOf(RssSource s) {
    final String raw = s.header.trim();
    if (raw.isEmpty) return 'utf-8';
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final MapEntry<Object?, Object?> e in decoded.entries) {
          if (e.key.toString().toLowerCase() != 'charset') continue;
          final String cs = e.value?.toString().trim() ?? '';
          if (cs.isNotEmpty) return cs;
        }
      }
    } catch (_) {
      // header 不是合法 JSON 就当没有
    }
    return 'utf-8';
  }
}

/// 源失效：列表页取到了，但 `ruleArticles` 一条都匹配不上
///
/// 与「网络失败」「解析抛异常」分开，是为了让 UI 能说人话：
/// 「这个源可能随站点改版失效了」比「空列表」有用得多。
class RssSourceStaleException implements Exception {
  const RssSourceStaleException(this.reason);

  final String reason;

  @override
  String toString() => '订阅源可能已失效：$reason';
}

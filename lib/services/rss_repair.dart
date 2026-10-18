import '../models/rss_source.dart';
import 'rule_engine.dart';

/// 订阅源规则「自动检测」
///
/// ## 为什么需要这个
///
/// 站点改版后，源里写死的 `ruleArticles` / `ruleTitle` / `ruleLink` 会全部落空。
/// 表现是「列表页能打开，但一条文章都取不到」——源没死，是选择器过期了。
///
/// 真实案例（2026-10-18 实测 `yuedu.miaogongzi.net/gx.html`）：
/// 源里写的是 `id.content@h3`，而页面早改成 `div.aui-flex.b-line` + `h1` + `a`。
/// 手工改规则对普通用户不现实，所以这里做**候选选择器试算**：
/// 挨个试常见的容器/取法组合，取「能解析出最多条目」的那一组。
///
/// ⚠️ 这是启发式，不是万能：只覆盖常见结构。检测不出来就老实返回 null，
/// 不要瞎改 —— 改错了比不改更糟（用户会以为源彻底坏了）。

/// 一次自动检测的结果
class RssRepairSuggestion {
  const RssRepairSuggestion({
    required this.ruleArticles,
    required this.ruleTitle,
    required this.ruleLink,
    required this.articles,
  });

  final String ruleArticles;
  final String ruleTitle;
  final String ruleLink;

  /// 用这组规则真解析出来的条目（给用户预览）
  final List<RssArticle> articles;

  int get count => articles.length;
}

class RssRepair {
  RssRepair._();

  /// 候选容器选择器（按「由具体到宽泛」排序）
  ///
  /// 前几个覆盖中文站点常见写法；`tag.li` / `tag.article` 兜底。
  static const List<String> containerCandidates = <String>[
    'class.aui-flex b-line', // 喵公子这类 aui 模板
    'class.item',
    'class.article',
    'class.post',
    'class.list-item',
    'class.entry',
    'id.list@tag.div',
    'tag.article',
    'tag.li',
  ];

  /// 候选链接取法（在容器内部取）
  static const List<String> linkCandidates = <String>[
    'tag.a@href',
    'a@href',
    'tag.h1@tag.a@href',
  ];

  /// 候选标题取法（在容器内部取）
  static const List<String> titleCandidates = <String>[
    'tag.h1@text',
    'tag.h2@text',
    'tag.h3@text',
    'tag.a@text',
    'a@textNodes',
    'h1@text',
  ];

  /// 试算一组规则能解析出多少可用条目
  static List<RssArticle> _try({
    required String html,
    required String baseUrl,
    required String container,
    required String linkRule,
    required String titleRule,
  }) {
    final RuleEngine engine = RuleEngine(
      content: html,
      kind: ContentKind.html,
      context: RuleContext(baseUrl: baseUrl),
    );
    final List<Object?> containers = engine.getElements(container);
    if (containers.isEmpty) return const <RssArticle>[];

    final List<RssArticle> out = <RssArticle>[];
    for (final Object? item in containers) {
      if (item == null) continue;
      final RuleEngine itemEngine = RuleEngine(
        content: item.toString(),
        kind: ContentKind.html,
        context: RuleContext(baseUrl: baseUrl),
      );
      final String title = itemEngine.getString(titleRule).trim();
      final List<String> links = itemEngine.getStringList(linkRule, isUrl: true);
      if (title.isEmpty || links.isEmpty) continue;
      // 标题太长多半是把整段正文当标题了，跳过
      if (title.length > 120) continue;
      // 按钮文字不是标题：`tag.a@text` 这类取法会取到「点击前往」「一键导入」，
      // 条目数一样多但标题全是废话 —— 必须挡掉，否则会赢过真正的 h1 标题
      if (buttonLabels.contains(title)) continue;
      out.add(RssArticle(title: title, url: links.first));
    }
    return out;
  }

  /// 正文按钮上那些字：它们不是文章标题
  static const Set<String> buttonLabels = <String>{
    '点击前往',
    '点击阅读',
    '一键导入',
    '立即导入',
    '阅读原文',
    '查看详情',
    '查看更多',
    '更多',
    '详情',
    '继续阅读',
    '前往',
  };

  /// 检测最合适的一组规则
  ///
  /// [html] 是列表页正文，[baseUrl] 用来补全相对链接。
  /// 返回 null 表示所有候选都解析不出东西（那就别乱改）。
  ///
  /// ## 评分：条目数优先，标题取法次序作平手裁判
  ///
  /// 只看条目数会踩坑：`tag.a@text` 常能取到同样多的条目（因为每个卡片都有 `<a>`），
  /// 但取出来的是「点击前往」这类按钮文字。实测过：喵公子那个页面两种取法都是 23 条，
  /// 按「先试到的赢」就会选错。
  /// 所以条目数相同时，**按 [titleCandidates] 的先后**（`h1` 优先）裁决。
  static RssRepairSuggestion? suggest(String html, {required String baseUrl}) {
    RssRepairSuggestion? best;
    int bestTitleRank = 1 << 20;

    for (final String container in containerCandidates) {
      for (final String linkRule in linkCandidates) {
        for (var ti = 0; ti < titleCandidates.length; ti++) {
          final String titleRule = titleCandidates[ti];
          final List<RssArticle> articles = _try(
            html: html,
            baseUrl: baseUrl,
            container: container,
            linkRule: linkRule,
            titleRule: titleRule,
          );
          if (articles.isEmpty) continue;

          final bool better = best == null ||
              articles.length > best.count ||
              // 同条目数时，标题取法更靠前（h1 比 a@text 更像标题）者胜
              (articles.length == best.count && ti < bestTitleRank);
          if (better) {
            bestTitleRank = ti;
            best = RssRepairSuggestion(
              ruleArticles: container,
              ruleTitle: titleRule,
              ruleLink: linkRule,
              articles: articles,
            );
          }
        }
      }
      // 已经找到足够多的条目就不必继续往下试更宽泛的选择器
      // （`tag.li` 这种会把导航栏也算进来，越宽噪音越大）
      if (best != null && best.count >= 3) break;
    }
    return best;
  }
}

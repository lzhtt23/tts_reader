/// 订阅源（RSS）模型 —— 对齐 legado 的 `RssSource`
///
/// ## 为什么不复用 `SourceRule`
///
/// 书源与订阅源是**两套体系**：
///
/// | | 书源 `SourceRule` | 订阅源 `RssSource` |
/// | --- | --- | --- |
/// | 用途 | 搜书 → 目录 → 正文 | 追更：一个站点的最新文章列表 |
/// | 核心规则 | `ruleSearch` / `ruleToc` / `ruleContent` | `ruleArticles` / `ruleLink` / `ruleTitle` |
/// | 阅读单位 | 章节 | 文章 |
///
/// 硬塞进 `SourceRule` 会让字段对不上、污染现有模型与用例。
library;

/// 一条订阅源
class RssSource {
  const RssSource({
    required this.sourceUrl,
    required this.sourceName,
    this.sourceGroup = '',
    this.sourceIcon = '',
    this.type = 0,
    this.enabled = true,
    this.lastUpdateTime = 0,
    this.sortUrl = '',
    this.ruleArticles = '',
    this.ruleLink = '',
    this.ruleTitle = '',
    this.ruleDesc = '',
    this.ruleImage = '',
    this.singleUrl = true,
    this.loadWithBaseUrl = true,
    this.preload = false,
    this.articleStyle = 0,
    this.enableJs = false,
    this.header = '',
  });

  /// 列表页地址（**主键**）
  final String sourceUrl;

  final String sourceName;
  final String sourceGroup;

  /// 图标：base64 data URI 或普通 URL
  final String sourceIcon;

  /// 0 = 文本
  final int type;

  final bool enabled;
  final int lastUpdateTime;

  /// 分类/排序入口，格式 `名称::URL`，多个用换行或 `&&` 分隔
  final String sortUrl;

  /// **文章列表容器**的选择器（返回 N 个元素，每个是一篇文章的容器）
  final String ruleArticles;

  /// 在容器内取**文章链接**（可能是相对地址，需按 [sourceUrl] 补全）
  final String ruleLink;

  /// 在容器内取**标题**
  final String ruleTitle;

  final String ruleDesc;
  final String ruleImage;

  /// true = 只有一页，不分页
  final bool singleUrl;

  /// true = 请求时带 [sourceUrl] 作为 base
  final bool loadWithBaseUrl;

  final bool preload;
  final int articleStyle;
  final bool enableJs;

  /// 请求头 JSON 字符串
  final String header;

  /// 必填字段齐不齐（缺一个就用不了）
  bool get isUsable =>
      sourceUrl.trim().isNotEmpty &&
      ruleArticles.trim().isNotEmpty &&
      ruleLink.trim().isNotEmpty &&
      ruleTitle.trim().isNotEmpty;

  String get displayName =>
      sourceName.trim().isEmpty ? sourceUrl : sourceName.trim();

  /// 分类入口列表：把 `sortUrl` 拆成 `名称 → 地址`
  List<({String name, String url})> get sortEntries {
    final List<({String name, String url})> out = <({String name, String url})>[];
    for (final String raw in sortUrl.split(RegExp(r'\n|&&'))) {
      final String line = raw.trim();
      if (line.isEmpty) continue;
      final int at = line.indexOf('::');
      if (at <= 0) continue;
      final String name = line.substring(0, at).trim();
      final String url = line.substring(at + 2).trim();
      if (url.isEmpty) continue;
      out.add((name: name, url: url));
    }
    return out;
  }

  RssSource copyWith({bool? enabled, String? sourceName}) => RssSource(
    sourceUrl: sourceUrl,
    sourceName: sourceName ?? this.sourceName,
    sourceGroup: sourceGroup,
    sourceIcon: sourceIcon,
    type: type,
    enabled: enabled ?? this.enabled,
    lastUpdateTime: lastUpdateTime,
    sortUrl: sortUrl,
    ruleArticles: ruleArticles,
    ruleLink: ruleLink,
    ruleTitle: ruleTitle,
    ruleDesc: ruleDesc,
    ruleImage: ruleImage,
    singleUrl: singleUrl,
    loadWithBaseUrl: loadWithBaseUrl,
    preload: preload,
    articleStyle: articleStyle,
    enableJs: enableJs,
    header: header,
  );

  /// 站点改版后修规则用：只换三条取值规则，其它字段原样保留
  RssSource copyWithRules({
    required String ruleArticles,
    required String ruleTitle,
    required String ruleLink,
  }) => RssSource(
    sourceUrl: sourceUrl,
    sourceName: sourceName,
    sourceGroup: sourceGroup,
    sourceIcon: sourceIcon,
    type: type,
    enabled: enabled,
    lastUpdateTime: lastUpdateTime,
    sortUrl: sortUrl,
    ruleArticles: ruleArticles,
    ruleLink: ruleLink,
    ruleTitle: ruleTitle,
    ruleDesc: ruleDesc,
    ruleImage: ruleImage,
    singleUrl: singleUrl,
    loadWithBaseUrl: loadWithBaseUrl,
    preload: preload,
    articleStyle: articleStyle,
    enableJs: enableJs,
    header: header,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sourceUrl': sourceUrl,
    'sourceName': sourceName,
    'sourceGroup': sourceGroup,
    'sourceIcon': sourceIcon,
    'type': type,
    'enabled': enabled,
    'lastUpdateTime': lastUpdateTime,
    'sortUrl': sortUrl,
    'ruleArticles': ruleArticles,
    'ruleLink': ruleLink,
    'ruleTitle': ruleTitle,
    'ruleDesc': ruleDesc,
    'ruleImage': ruleImage,
    'singleUrl': singleUrl,
    'loadWithBaseUrl': loadWithBaseUrl,
    'preload': preload,
    'articleStyle': articleStyle,
    'enableJs': enableJs,
    'header': header,
  };

  factory RssSource.fromJson(Map<String, dynamic> json) => RssSource(
    sourceUrl: (json['sourceUrl'] as String? ?? '').trim(),
    sourceName: json['sourceName'] as String? ?? '',
    sourceGroup: json['sourceGroup'] as String? ?? '',
    sourceIcon: json['sourceIcon'] as String? ?? '',
    type: _int(json['type']),
    enabled: _bool(json['enabled'], fallback: true),
    lastUpdateTime: _int(json['lastUpdateTime']),
    sortUrl: json['sortUrl'] as String? ?? '',
    ruleArticles: json['ruleArticles'] as String? ?? '',
    ruleLink: json['ruleLink'] as String? ?? '',
    ruleTitle: json['ruleTitle'] as String? ?? '',
    ruleDesc: json['ruleDesc'] as String? ?? '',
    ruleImage: json['ruleImage'] as String? ?? '',
    singleUrl: _bool(json['singleUrl'], fallback: true),
    loadWithBaseUrl: _bool(json['loadWithBaseUrl'], fallback: true),
    preload: _bool(json['preload'], fallback: false),
    articleStyle: _int(json['articleStyle']),
    enableJs: _bool(json['enableJs'], fallback: false),
    header: _headerText(json['header']),
  );

  /// `header` 在 legado 里既可能是 JSON 字符串，也可能是对象 —— 统一成字符串
  static String _headerText(Object? raw) {
    if (raw == null) return '';
    if (raw is String) return raw;
    return '';
  }

  static int _int(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? 0;
    return 0;
  }

  static bool _bool(Object? raw, {required bool fallback}) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    if (raw is String) {
      final String s = raw.trim().toLowerCase();
      if (s == 'true' || s == '1') return true;
      if (s == 'false' || s == '0') return false;
    }
    return fallback;
  }
}

/// 订阅源里解析出的一篇文章
class RssArticle {
  const RssArticle({required this.title, required this.url, this.desc = ''});

  final String title;

  /// 绝对地址（已按 `sourceUrl` 补全）
  final String url;

  final String desc;

  @override
  String toString() => 'RssArticle($title <$url>)';
}

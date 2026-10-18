/// legado（阅读）书源规则的 Dart 模型
///
/// ## 为什么要单独一套模型
///
/// 工程里已有的「书源」（`models/web_link.dart` 的 `WebLink`）**只是书签**：
/// 存一个网址，点一下用内置浏览器打开。那是「去哪儿」。
///
/// legado 的书源是**爬虫规则**：同一份 JSON 里带着「怎么搜、怎么翻目录、
/// 怎么抽正文」的解析表达式。那是「怎么挖」。两者名词相同、结构完全不兼容，
/// 所以这里另起一套，**绝不塞进 `WebLink`**（会打翻 book_sources_defaults_test）。
///
/// ## 字段名必须与 legado 完全一致
///
/// JSON 键名就是 Kotlin 属性名（`BookSource.kt` 没有 @SerializedName）。
/// 差一个字母，用户现有的书源就导不进来 —— 所以这里逐个对齐，不做「美化」。
///
/// 参见 legado 源码：`data/entities/BookSource.kt` 与 `data/entities/rule/*.kt`
library;

/// 书源类型（对齐 legado `BookSourceType`）
class SourceType {
  SourceType._();

  /// 0 文本
  static const int text = 0;

  /// 1 音频
  static const int audio = 1;

  /// 2 图片（漫画）
  static const int image = 2;

  /// 3 只提供下载服务的网站
  static const int file = 3;

  static String label(int type) => switch (type) {
    text => '文本',
    audio => '音频',
    image => '图片',
    file => '下载',
    _ => '未知',
  };
}

/// 一条书源规则
///
/// 只保留**抓取必需**的字段。legado 实体里还有 `loginCheckJs` /
/// `homepageModules` / `coverDecodeJs` 等实验性字段，这里刻意不收：
/// 它们要么依赖 JS 引擎，要么是 UI 定制，本工程用不到。
/// 导入时遇到这些字段**直接忽略**，不影响解析。
class SourceRule {
  const SourceRule({
    required this.url,
    required this.name,
    this.group,
    this.type = SourceType.text,
    this.lastUpdateTime = 0,
    this.respondTime = 180000,
    this.weight = 0,
    this.enabled = true,
    this.enabledExplore = true,
    this.bookUrlPattern,
    this.searchUrl,
    this.exploreUrl,
    this.header,
    this.ruleSearch,
    this.ruleExplore,
    this.ruleBookInfo,
    this.ruleToc,
    this.ruleContent,
    this.comment,
  });

  /// bookSourceUrl —— **主键**，去重与更新的唯一依据
  final String url;

  /// bookSourceName
  final String name;

  /// bookSourceGroup（逗号分隔的多分组）
  final String? group;

  /// bookSourceType：0 文本 / 1 音频 / 2 图片 / 3 下载
  final int type;

  /// lastUpdateTime —— 导入时判断「更新」还是「已存在」的依据
  ///
  /// ⚠️ 这是**书源作者维护**的字段。缺失时恒为 0，
  /// 会导致所有导入都判为「已存在」（legado 也是这个行为）。
  final int lastUpdateTime;

  /// 响应超时（毫秒）
  final int respondTime;

  /// 权重（搜索排序用，越大越靠前）
  final int weight;

  final bool enabled;
  final bool enabledExplore;

  /// 书籍 URL 匹配正则（浏览器里打开某书页时用来反查书源）
  final String? bookUrlPattern;

  /// 搜索 URL 模板，支持 `{{key}}` / `{{page}}`
  final String? searchUrl;

  /// 发现 URL（分类列表）
  final String? exploreUrl;

  /// 请求头（JSON 字符串，如 `{"User-Agent":"..."}`）
  final String? header;

  /// 五组解析规则（原样保留 JSON 对象，交给规则引擎按需取值）
  final Map<String, dynamic>? ruleSearch;
  final Map<String, dynamic>? ruleExplore;
  final Map<String, dynamic>? ruleBookInfo;
  final Map<String, dynamic>? ruleToc;
  final Map<String, dynamic>? ruleContent;

  /// bookSourceComment（作者备注）
  final String? comment;

  /// 这条源能不能被本工程执行
  ///
  /// 判据：**是否能枚举出全部必需规则**。目前只支持文本源
  /// （音频/图片要走另一套渲染路径，本轮不做）。
  bool get isSupported => type == SourceType.text && _hasRequiredRules;

  bool get _hasRequiredRules {
    final search = ruleSearch;
    final toc = ruleToc;
    final content = ruleContent;
    if (search == null || toc == null || content == null) return false;
    return _nonEmpty(search['bookList']) &&
        _nonEmpty(search['name']) &&
        _nonEmpty(toc['chapterList']) &&
        _nonEmpty(toc['chapterName']) &&
        _nonEmpty(toc['chapterUrl']) &&
        _nonEmpty(content['content']);
  }

  static bool _nonEmpty(Object? value) =>
      value is String && value.trim().isNotEmpty;

  /// 从 legado 的 JSON 对象构造
  ///
  /// 容错策略：**缺字段给默认值，不抛异常**。
  /// 理由：一个合集里常混着几种源，一条坏字段不该让整批失败
  /// （legado 只在 `bookSourceUrl` 为空时才整批失败，见
  /// `BookSourceViewModel.parseImportSources` 里那句 require）。
  factory SourceRule.fromJson(Map<String, dynamic> json) {
    return SourceRule(
      url: _str(json['bookSourceUrl']) ?? '',
      name: _str(json['bookSourceName']) ?? '',
      group: _str(json['bookSourceGroup']),
      type: _int(json['bookSourceType']) ?? SourceType.text,
      lastUpdateTime: _int(json['lastUpdateTime']) ?? 0,
      respondTime: _int(json['respondTime']) ?? 180000,
      weight: _int(json['weight']) ?? 0,
      enabled: _bool(json['enabled']) ?? true,
      enabledExplore: _bool(json['enabledExplore']) ?? true,
      bookUrlPattern: _str(json['bookUrlPattern']),
      searchUrl: _str(json['searchUrl']),
      exploreUrl: _str(json['exploreUrl']),
      header: _str(json['header']),
      ruleSearch: _map(json['ruleSearch']),
      ruleExplore: _map(json['ruleExplore']),
      ruleBookInfo: _map(json['ruleBookInfo']),
      ruleToc: _map(json['ruleToc']),
      ruleContent: _map(json['ruleContent']),
      comment: _str(json['bookSourceComment']),
    );
  }

  /// 导出成 legado 格式（键名与 fromJson 对称，可被阅读 App 直接导入）
  Map<String, dynamic> toJson() => <String, dynamic>{
    'bookSourceUrl': url,
    'bookSourceName': name,
    if (group != null) 'bookSourceGroup': group,
    'bookSourceType': type,
    'lastUpdateTime': lastUpdateTime,
    'respondTime': respondTime,
    'weight': weight,
    'enabled': enabled,
    'enabledExplore': enabledExplore,
    if (bookUrlPattern != null) 'bookUrlPattern': bookUrlPattern,
    if (searchUrl != null) 'searchUrl': searchUrl,
    if (exploreUrl != null) 'exploreUrl': exploreUrl,
    if (header != null) 'header': header,
    if (ruleSearch != null) 'ruleSearch': ruleSearch,
    if (ruleExplore != null) 'ruleExplore': ruleExplore,
    if (ruleBookInfo != null) 'ruleBookInfo': ruleBookInfo,
    if (ruleToc != null) 'ruleToc': ruleToc,
    if (ruleContent != null) 'ruleContent': ruleContent,
    if (comment != null) 'bookSourceComment': comment,
  };

  SourceRule copyWith({
    String? name,
    String? group,
    bool? enabled,
    bool? enabledExplore,
    int? lastUpdateTime,
  }) => SourceRule(
    url: url,
    name: name ?? this.name,
    group: group ?? this.group,
    type: type,
    lastUpdateTime: lastUpdateTime ?? this.lastUpdateTime,
    respondTime: respondTime,
    weight: weight,
    enabled: enabled ?? this.enabled,
    enabledExplore: enabledExplore ?? this.enabledExplore,
    bookUrlPattern: bookUrlPattern,
    searchUrl: searchUrl,
    exploreUrl: exploreUrl,
    header: header,
    ruleSearch: ruleSearch,
    ruleExplore: ruleExplore,
    ruleBookInfo: ruleBookInfo,
    ruleToc: ruleToc,
    ruleContent: ruleContent,
    comment: comment,
  );

  String get displayName => name.trim().isEmpty ? url : name;

  /// 分组标签（拆分 + 去空）
  List<String> get groups => (group ?? '')
      .split(RegExp(r'[,;，；]'))
      .map((String g) => g.trim())
      .where((String g) => g.isNotEmpty)
      .toList();

  @override
  String toString() => 'SourceRule($name <$url> type=$type)';

  // ---------------- JSON 类型容错 ----------------

  static String? _str(Object? v) {
    if (v is String) return v;
    if (v == null) return null;
    // 少数书源把数字/布尔直接写进字符串字段
    return v.toString();
  }

  static int? _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static bool? _bool(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final String s = v.trim().toLowerCase();
      if (s == 'true' || s == '1') return true;
      if (s == 'false' || s == '0') return false;
    }
    return null;
  }

  static Map<String, dynamic>? _map(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return v.map((Object? k, Object? val) => MapEntry(k.toString(), val));
    return null;
  }
}

/// 一次导入的结果（含被跳过的与不支持的）
class SourceImportResult {
  const SourceImportResult({
    required this.added,
    required this.updated,
    required this.existing,
    required this.skipped,
    this.errors = const <String>[],
  });

  /// 新增
  final List<SourceRule> added;

  /// 更新（同 url 且 lastUpdateTime 更大）
  final List<SourceRule> updated;

  /// 已存在（同 url 且不比本地新）
  final List<SourceRule> existing;

  /// 无法执行/格式非法的条目（导入时展示，不阻断其它条）
  final List<SourceRule> skipped;

  /// 解析期的非致命错误（例如某条 JSON 结构异常）
  final List<String> errors;

  int get total => added.length + updated.length + existing.length + skipped.length;

  bool get isEmpty => total == 0;

  /// 实际写库的条数
  int get appliedCount => added.length + updated.length;
}

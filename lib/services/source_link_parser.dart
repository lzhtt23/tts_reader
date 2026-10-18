import 'dart:convert';

/// 从 `yuedu://` / `legado://` 链接里提取「书源导入地址」
///
/// ## 为什么要单独一个纯函数
///
/// 这类链接来自浏览器（点「一键导入」）和粘贴板（用户直接贴），
/// 两处都要解析，而且必须能离线单测 —— 所以不碰网络、不碰 UI。
///
/// ## 真实形态（legado 两种 scheme、大小写混用）
///
/// ```
/// yuedu://booksource/importonline?src=<url>
/// yuedu://bookSource/importonline?src=<url>     ← 大小写变体
/// legado://import/bookSource?src=<url>
/// legado://import/importonline?src=<url>&type=booksource
/// ```
///
/// ⚠️ `src` 参数**必须 URL 解码**：真实链接里常是
/// `https%3A%2F%2Fa.com%2Fb.json`，不解码会 404。
class SourceLinkParser {
  SourceLinkParser._();

  /// 认得出来的 scheme（小写）
  static const Set<String> schemes = <String>{'yuedu', 'legado'};

  /// 看起来像「书源导入链接」的 path 关键字（小写）
  ///
  /// 注意 `rsssource` 不在这里：RSS 订阅源是另一套体系，不能被当成书源。
  static const List<String> bookSourceKeys = <String>[
    'booksource',
    'importonline',
  ];

  /// 是不是「书源导入」链接（用于 UI 提示；不保证 `src` 一定合法）
  static bool isBookSourceLink(String link) =>
      _parse(link, requireSrc: false) != null;

  /// 提取书源地址；不是书源导入链接、或缺 `src` 时返回 null
  static String? extractBookSourceUrl(String link) => _parse(link, requireSrc: true);

  /// 是不是「订阅源（RSS）导入」链接
  ///
  /// 形态与书源那条几乎一样，只是关键字不同：
  /// ```
  /// yuedu://rsssource/importonline?src=<url>
  /// legado://import/rssSource?src=<url>
  /// ```
  static bool isRssSourceLink(String link) => _parseRss(link) != null;

  /// 提取订阅源地址；不是订阅源链接时返回 null
  static String? extractRssSourceUrl(String link) => _parseRss(link);

  static String? _parseRss(String raw) {
    final String link = raw.trim();
    if (link.isEmpty) return null;
    final RegExpMatch? head =
        RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*)://([^?#]*)', caseSensitive: false)
            .firstMatch(link);
    if (head == null) return null;
    final String scheme = head.group(1)!.toLowerCase();
    if (!schemes.contains(scheme)) return null;
    final String body = head.group(2)!.toLowerCase();
    if (!body.contains('rss')) return null;
    final String? src = _queryParam(link, 'src');
    if (src == null || src.trim().isEmpty) return null;
    return _normalizeSrc(src.trim());
  }

  /// 内部解析
  ///
  /// 用 `Uri.parse` 会在这类自定义 scheme 上把 host/path 切得很怪
  /// （`yuedu://booksource/importonline` 里 `booksource` 会被当成 host），
  /// 所以这里先用正则把 scheme、路径、query 三段剥开，再做一遍 `Uri` 兜底。
  static String? _parse(String raw, {required bool requireSrc}) {
    final String link = raw.trim();
    if (link.isEmpty) return null;

    final RegExpMatch? head =
        RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*)://([^?#]*)', caseSensitive: false)
            .firstMatch(link);
    if (head == null) return null;
    final String scheme = head.group(1)!.toLowerCase();
    if (!schemes.contains(scheme)) return null;

    // host + path 一起看，大小写不敏感
    final String body = head.group(2)!.toLowerCase();
    final bool looksBookSource =
        bookSourceKeys.any((String key) => body.contains(key));
    if (!looksBookSource) return null;

    // RSS 订阅源不是书源：`yuedu://rsssource/...` 必须挡掉
    if (body.contains('rsssource') || body.contains('rss')) {
      // 但 `booksource` 里不含 rss，这里只在没有任何 booksource 关键字时才挡
      if (!body.contains('booksource')) return null;
    }

    final String? src = _queryParam(link, 'src');
    if (src == null || src.trim().isEmpty) {
      return requireSrc ? null : null;
    }
    return _normalizeSrc(src.trim());
  }

  /// 取 query 参数（手工解析：自定义 scheme 下 `Uri.queryParameters` 不可靠）
  static String? _queryParam(String link, String name) {
    final int q = link.indexOf('?');
    if (q < 0 || q + 1 >= link.length) return null;
    String query = link.substring(q + 1);
    final int hash = query.indexOf('#');
    if (hash >= 0) query = query.substring(0, hash);

    for (final String pair in query.split('&')) {
      final int eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final String key = Uri.decodeComponent(pair.substring(0, eq));
      if (key.toLowerCase() != name.toLowerCase()) continue;
      // `+` 在 query 里传统上代表空格，但 URL 里也可能是原样的加号；
      // 先按 `%xx` 解码，再把 `+` 换成空格会破坏签名类地址，所以只解百分号。
      return Uri.decodeComponent(pair.substring(eq + 1));
    }
    return null;
  }

  /// 规范成可直接下载的地址
  static String _normalizeSrc(String src) {
    if (src.startsWith('http://') || src.startsWith('https://')) return src;
    // 少数源会再套一层：`src=yuedu://booksource/importonline?src=...`
    final String? nested = extractBookSourceUrl(src);
    if (nested != null) return nested;
    return src;
  }

  /// 把一段文本里**第一个**书源链接提取出来（粘贴场景用）
  ///
  /// 用户经常连说明文字一起复制：「一键导入：yuedu://... 请收藏本站」
  static String? extractFromText(String text) {
    // 字符类里同时有单引号和双引号，只能用三引号 raw 字符串
    final RegExpMatch? m = RegExp(
      r"""(?:yuedu|legado)://[^\s"'<>]+""",
      caseSensitive: false,
    ).firstMatch(text);
    if (m == null) return null;
    return extractBookSourceUrl(m.group(0)!);
  }

  /// 给 UI 用的简短展示：把 URL 里的查询串截断
  static String ellipsize(String url, {int max = 60}) {
    if (url.length <= max) return url;
    return '${url.substring(0, max)}…';
  }

  /// JSON 转义后的地址还原（少数站点把 src 塞进 JSON 再转义一层）
  static String unescapeJson(String src) {
    try {
      final Object? decoded = jsonDecode('"${src.replaceAll('"', r'\"')}"');
      if (decoded is String) return decoded;
    } catch (_) {
      // 解不了就原样返回
    }
    return src;
  }
}

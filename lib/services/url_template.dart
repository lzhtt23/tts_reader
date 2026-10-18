/// URL 模板求值 + 请求（对齐 legado `AnalyzeUrl.kt`）
///
/// ## legado 的 URL 不是普通地址
///
/// 它是一段**模板 + JSON 选项**：
///
/// ```
/// https://a.com/search?q={{key}}&p={{page}},{"method":"POST","body":"..."}
///                          └──── 模板 ────┘ └──── UrlOption JSON ────┘
/// ```
///
/// 逗号后面那段是 `UrlOption`（对齐 `AnalyzeUrl.analyzeUrl` 里的
/// `paramPattern` 切分 + GSON 反序列化）。支持字段：
/// `method` / `body` / `headers` / `charset` / `retry` /
/// `useWebView` / `webJs` / `dnsIp` / `js`。
///
/// ## 本实现的范围
///
/// 只做**纯 HTTP**：`method` / `body` / `header` / `charset` / `retry`。
/// `useWebView` / `webJs` 依赖内嵌浏览器与 JS 执行，本轮不做 ——
/// 遇到时明确抛 `UnsupportedSourceException`，由上层标记该源不可用。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'expression_evaluator.dart';

/// 源不可用（含不支持的选项）
class UnsupportedSourceException implements Exception {
  const UnsupportedSourceException(this.reason);

  final String reason;

  @override
  String toString() => 'UnsupportedSourceException($reason)';
}

/// 请求方法
enum HttpMethod { get, post, head }

/// URL 模板解析后的请求描述
class UrlRequest {
  const UrlRequest({
    required this.url,
    required this.method,
    this.body,
    this.headers = const <String, String>{},
    this.charset = 'utf-8',
    this.retry = 0,
  });

  final String url;
  final HttpMethod method;
  final String? body;
  final Map<String, String> headers;
  final String charset;

  /// 失败重试次数（对齐 legado `UrlOption.retry`）
  final int retry;

  @override
  String toString() => '${method.name.toUpperCase()} $url';
}

/// URL 模板求值器
class UrlTemplate {
  UrlTemplate._();

  /// 把模板 + 变量求值成 [UrlRequest]
  ///
  /// [template] 是书源里 `searchUrl` / `chapterUrl` 的原始值；
  /// [variables] 至少要有 `key`（搜索词）与 `page`（页码）。
  /// [baseUrl] 用于相对地址补全。
  static UrlRequest evaluate(
    String template, {
    required Map<String, Object?> variables,
    String? baseUrl,
    Map<String, Object?> Function(List<Object?>)? hostFn,
    String? extraHeader,
  }) {
    final _ParsedUrl parsed = _parse(template);

    // ① 展开 {{ }}
    final String expanded = _expand(
      parsed.rawUrl,
      variables: variables,
      hostFn: hostFn,
    );

    // ② 补全绝对地址
    //
    // ⚠️ 编码必须在 `Uri.resolve` **之前**：
    // `Uri.parse(base).resolve('/书/1')` 会抛 `Contains invalid characters`，
    // 所以先把非 ASCII 转成 `%XX`，再做相对路径解析。
    String url = _encodeUrl(expanded);
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      if (baseUrl == null || baseUrl.isEmpty) {
        throw const UnsupportedSourceException('相对地址但书源首页为空');
      }
      url = _resolve(_encodeUrl(baseUrl), url);
    }

    // ②' 兜底再编码一次（base 里可能带中文，或 resolve 引入未编码字符）
    url = _encodeUrl(url);

    // ③ 合并请求头（书源级 header 在前，UrlOption 覆盖）
    final Map<String, String> headers = <String, String>{};
    if (extraHeader != null && extraHeader.trim().isNotEmpty) {
      headers.addAll(_parseHeaderJson(extraHeader));
    }
    headers.addAll(parsed.headers);

    return UrlRequest(
      url: url,
      method: parsed.method,
      body: parsed.body,
      headers: headers,
      charset: parsed.charset,
      retry: parsed.retry,
    );
  }

  /// 展开 `{{ }}`（与 `RuleEngine` 里那份逻辑一致，但这里只有变量没有内容）
  static String _expand(
    String text, {
    required Map<String, Object?> variables,
    Map<String, Object?> Function(List<Object?>)? hostFn,
  }) {
    if (!text.contains('{{')) return text;
    final StringBuffer out = StringBuffer();
    var i = 0;
    var last = 0;

    while (i < text.length) {
      if (!text.startsWith('{{', i)) {
        i++;
        continue;
      }
      final int start = i + 2;
      final int end = text.indexOf('}}', start);
      if (end < 0) break;

      final String expr = text.substring(start, end).trim();
      String value = '';
      if (expr.isNotEmpty) {
        try {
          final Object? v = ExpressionEvaluator(
            expr,
            EvalContext(
              variables: variables,
              functions: <String, Object? Function(List<Object?>)>{
                if (hostFn != null) 'java.any': (List<Object?> a) => hostFn(a),
              },
            ),
          ).evaluate();
          value = _stringify(v);
        } on UnsupportedExpression catch (e) {
          throw UnsupportedSourceException('URL 模板里有不支持的表达式：$e');
        }
      }
      out.write(text.substring(last, i));
      out.write(value);
      i = end + 2;
      last = i;
    }

    if (last == 0) return text;
    out.write(text.substring(last));
    return out.toString();
  }

  /// 拆「URL 模板」与「UrlOption JSON」
  ///
  /// 对齐 `AnalyzeUrl.analyzeUrl`：`paramPattern` 找到第一个 `,{`，
  /// 前面是 URL，后面是 JSON 选项。
  static _ParsedUrl _parse(String template) {
    final String t = template.trim();

    // 找顶层的 `,{`（跳过引号与模板内部）
    var inTemplate = false;
    var index = -1;
    for (var i = 0; i < t.length - 1; i++) {
      if (t.startsWith('{{', i)) {
        inTemplate = true;
        i++;
        continue;
      }
      if (inTemplate) {
        if (t.startsWith('}}', i)) {
          inTemplate = false;
          i++;
        }
        continue;
      }
      if (t[i] == ',') {
        // 后面（跳过空白）必须是 `{`
        var j = i + 1;
        while (j < t.length && (t[j] == ' ' || t[j] == '\n' || t[j] == '\r')) {
          j++;
        }
        if (j < t.length && t[j] == '{') {
          index = i;
          break;
        }
      }
    }

    if (index < 0) {
      return _ParsedUrl(rawUrl: t);
    }

    final String rawUrl = t.substring(0, index).trim();
    final String optionJson = t.substring(index + 1).trim();
    return _applyOption(_ParsedUrl(rawUrl: rawUrl), optionJson);
  }

  static _ParsedUrl _applyOption(_ParsedUrl base, String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      // 选项 JSON 写坏了：忽略选项，按纯 GET 走（不阻断整个源）
      return base;
    }
    if (decoded is! Map) return base;

    final Map<String, dynamic> m = decoded.map(
      (Object? k, Object? v) => MapEntry(k.toString(), v),
    );

    // method
    HttpMethod method = base.method;
    final Object? rawMethod = m['method'];
    if (rawMethod is String) {
      switch (rawMethod.toUpperCase()) {
        case 'POST':
          method = HttpMethod.post;
          break;
        case 'HEAD':
          method = HttpMethod.head;
          break;
        default:
          method = HttpMethod.get;
      }
    }

    // 不支持的选项：明确拒绝（不静默降级，否则会拿到空页面却查不出原因）
    if (m['useWebView'] == true) {
      throw const UnsupportedSourceException('源要求 WebView 渲染（暂不支持）');
    }
    final Object? js = m['js'];
    if (js is String && js.trim().isNotEmpty) {
      throw const UnsupportedSourceException('源使用 js 改 URL（暂不支持）');
    }
    final Object? webJs = m['webJs'];
    if (webJs is String && webJs.trim().isNotEmpty) {
      throw const UnsupportedSourceException('源使用 webJs（暂不支持）');
    }

    // body
    String? body;
    final Object? rawBody = m['body'];
    if (rawBody is String) {
      body = rawBody;
    } else if (rawBody is Map) {
      body = jsonEncode(rawBody);
    }

    // header
    final Map<String, String> headers = <String, String>{...base.headers};
    final Object? rawHeader = m['headers'] ?? m['header'];
    if (rawHeader is Map) {
      rawHeader.forEach((Object? k, Object? v) {
        headers[k.toString()] = v.toString();
      });
    }

    // charset
    final String charset =
        (m['charset'] is String && (m['charset'] as String).trim().isNotEmpty)
        ? (m['charset'] as String).trim()
        : base.charset;

    // retry
    final int retry = m['retry'] is num ? (m['retry'] as num).toInt() : base.retry;

    return _ParsedUrl(
      rawUrl: base.rawUrl,
      method: method,
      body: body,
      headers: headers,
      charset: charset,
      retry: retry,
    );
  }

  static Map<String, String> _parseHeaderJson(String text) {
    try {
      final Object? decoded = jsonDecode(text);
      if (decoded is Map) {
        return decoded.map(
          (Object? k, Object? v) => MapEntry(k.toString(), v.toString()),
        );
      }
    } catch (_) {
      // 书源 header 写坏了就当没有
    }
    return const <String, String>{};
  }

  static String _resolve(String base, String relative) {
    try {
      return Uri.parse(base).resolve(relative).toString();
    } catch (_) {
      return relative;
    }
  }

  /// 把 URL 里的非 ASCII 字符转成百分号编码（保留已有的 `%XX`）
  ///
  /// 例：`https://a.test/s?q=斗罗&p=2` → `https://a.test/s?q=%E6%96%97%E7%BD%97&p=2`
  static String _encodeUrl(String url) {
    final StringBuffer out = StringBuffer();
    for (var i = 0; i < url.length; i++) {
      final String ch = url[i];
      final int code = ch.codeUnitAt(0);
      if (code < 0x80) {
        out.write(ch);
      } else {
        // UTF-8 多字节：逐字节百分号编码
        final List<int> bytes = utf8.encode(ch);
        for (final int b in bytes) {
          out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
        }
      }
    }
    return out.toString();
  }

  static String _stringify(Object? v) {
    if (v == null) return '';
    if (v is String) return v;
    if (v is num) {
      if (v is double && v == v.roundToDouble() && v.abs() < 1e15) {
        return v.toInt().toString();
      }
      return v.toString();
    }
    if (v is bool) return v ? 'true' : 'false';
    return '';
  }
}

class _ParsedUrl {
  const _ParsedUrl({
    required this.rawUrl,
    this.method = HttpMethod.get,
    this.body,
    this.headers = const <String, String>{},
    this.charset = 'utf-8',
    this.retry = 0,
  });

  final String rawUrl;
  final HttpMethod method;
  final String? body;
  final Map<String, String> headers;
  final String charset;
  final int retry;
}

/// HTTP 客户端：执行 [UrlRequest] 并解码
class SourceHttpClient {
  SourceHttpClient({http.Client? client})
    : _client = client ?? http.Client(),
      _own = client == null;

  final http.Client _client;
  final bool _own;

  /// 默认超时
  static const Duration defaultTimeout = Duration(seconds: 20);

  /// 默认 UA（对齐 legado 的桌面 UA，很多站按 UA 返回不同页面）
  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 执行请求，返回解码后的正文
  ///
  /// 失败会按 [UrlRequest.retry] 重试；全部失败抛最后一个异常。
  Future<String> fetch(UrlRequest request, {Duration? timeout}) async {
    final Duration limit = timeout ?? defaultTimeout;
    Object? lastError;

    final int attempts = request.retry > 0 ? request.retry + 1 : 1;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        return await _fetchOnce(request, limit);
      } catch (e) {
        lastError = e;
        if (attempt + 1 < attempts) {
          // 简单退避，避免连续轰同一个站
          await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
        }
      }
    }
    throw lastError ?? StateError('请求失败');
  }

  Future<String> _fetchOnce(UrlRequest request, Duration limit) async {
    final Uri uri = Uri.parse(request.url);
    final Map<String, String> headers = <String, String>{
      // 书源自己的 header 优先（在 UrlTemplate 里已合并）
      ...request.headers,
    };
    // 没显式给 UA 时补一个（很多站不认空 UA）
    if (!headers.keys.any((String k) => k.toLowerCase() == 'user-agent')) {
      headers['User-Agent'] = defaultUserAgent;
    }

    http.Response response;
    switch (request.method) {
      case HttpMethod.post:
        final String? body = request.body;
        headers.putIfAbsent(
          'Content-Type',
          () => 'application/x-www-form-urlencoded; charset=${request.charset}',
        );
        response = await _client
            .post(uri, headers: headers, body: body)
            .timeout(limit);
        break;
      case HttpMethod.head:
        response = await _client.head(uri, headers: headers).timeout(limit);
        break;
      case HttpMethod.get:
        response = await _client.get(uri, headers: headers).timeout(limit);
        break;
    }

    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw StateError('HTTP ${response.statusCode} ${request.url}');
    }

    // 编码：**响应头声明的 charset 优先**，其次才是书源里写的。
    // 中文站点经常书源写 utf-8、实际返回 gb2312（或反过来），
    // 只信书源会把整页解成乱码，后面的规则一条都匹配不上。
    final String charset = _charsetFromHeaders(response.headers) ?? request.charset;
    return decodeBytes(response.bodyBytes, charset);
  }

  /// 从 `Content-Type: text/html; charset=gbk` 里取出编码
  static String? _charsetFromHeaders(Map<String, String> headers) {
    for (final MapEntry<String, String> e in headers.entries) {
      if (e.key.toLowerCase() != 'content-type') continue;
      final RegExpMatch? m =
          RegExp(r'charset\s*=\s*"?([\w-]+)"?', caseSensitive: false).firstMatch(e.value);
      final String? cs = m?.group(1);
      if (cs != null && cs.trim().isNotEmpty) return cs.trim().toLowerCase();
    }
    return null;
  }

  /// 按 charset 解码
  ///
  /// 中文站点常见 `gbk` / `gb2312`，Dart 没有内建 GBK，
  /// 这里走可替换的 [gbkDecoder] 钩子（见 `GbkDecoderInstaller`），
  /// 未装钩子时退化为 UTF-8 宽松解码（至少不抛异常）。
  static String decodeBytes(Uint8ListLike bytes, String charset) {
    final String cs = charset.toLowerCase().trim();
    if (cs == 'utf-8' || cs == 'utf8') {
      return utf8.decode(bytes, allowMalformed: true);
    }
    if (cs == 'gbk' || cs == 'gb2312' || cs == 'gb18030' || cs == 'gb-2312') {
      final String? decoded = gbkDecoder?.call(bytes);
      if (decoded != null) return decoded;
      return utf8.decode(bytes, allowMalformed: true);
    }
    if (cs == 'big5' || cs == 'big-5') {
      final String? decoded = big5Decoder?.call(bytes);
      if (decoded != null) return decoded;
      return utf8.decode(bytes, allowMalformed: true);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 可替换的 GBK 解码器（工程里已有 `enough_convert` 依赖）
  ///
  /// 单独抽成静态钩子而不是直接 import，是为了让本文件保持可单测
  /// （测试环境不需要真实 GBK 表）。运行时由 `GbkDecoderInstaller.install()` 装上。
  static String? Function(List<int> bytes)? gbkDecoder;

  /// 可替换的 Big5 解码器（繁体站），同上
  static String? Function(List<int> bytes)? big5Decoder;

  void dispose() {
    if (_own) _client.close();
  }
}

/// `Uint8List` 的最小结构约束（避免本文件 import dart:typed_data 影响可测性）
typedef Uint8ListLike = List<int>;

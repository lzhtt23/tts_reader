/// legado 书源的**导入解析**（对应 legado `BookSourceViewModel.importSources`）
///
/// ## 为什么单独一层
///
/// 解析（文本 → `SourceRule`）与合并（新旧比对 → 写库）是两件事：
/// - 解析是**纯函数**，可以完全离线单测，不碰网络也不碰磁盘
/// - 合并要读本地已有数据，依赖存储层
///
/// 拆开之后，本文件不需要 mock 任何东西就能覆盖全部格式分支。
///
/// ## 与 legado 对齐的三个行为
///
/// 1. 输入三形态：`http(s)` → 下载；`file/content` → 读文件；否则当文本
/// 2. JSON 三形态：数组 / 带 `sourceUrls` 的索引 / 单对象
/// 3. 去重键是 `bookSourceUrl`，新旧判据是 `lastUpdateTime`
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/source_rule.dart';
import 'source_link_parser.dart';

/// 判断输入是绝对 URL（对应 legado `String?.isAbsUrl()`）
bool isAbsoluteUrl(String input) {
  final String s = input.trim().toLowerCase();
  return s.startsWith('http://') || s.startsWith('https://');
}

/// 判断输入是本地 URI（对应 legado `String?.isUri()`）
bool isLocalUri(String input) {
  final String s = input.trim().toLowerCase();
  return s.startsWith('file://') || s.startsWith('content://');
}

/// 解析结果：规则列表 + 非致命错误
class ParseOutcome {
  const ParseOutcome(this.rules, {this.errors = const <String>[]});

  final List<SourceRule> rules;
  final List<String> errors;

  bool get isEmpty => rules.isEmpty;
}

/// 书源导入解析器
///
/// 用法：
/// ```dart
/// final outcome = await SourceImporter.parse(input, fetch: myFetch);
/// ```
class SourceImporter {
  SourceImporter._();

  /// `sourceUrls` 索引文件的递归上限
  ///
  /// ⚠️ legado 自己**没有**这个上限（`parseImportSources` 里直接递归）。
  /// 这里加上是因为恶意/写坏的索引文件可以互相引用成环。
  static const int maxIndexDepth = 3;

  /// 单次导入接受的字节上限（防御超大文件）
  static const int maxBytes = 32 * 1024 * 1024;

  /// 从输入文本/URL/URI 导入
  ///
  /// [fetch] 允许注入假实现，便于单测；默认走 `http.get`。
  static Future<ParseOutcome> parse(
    String input, {
    Future<String> Function(String url)? fetch,
    Future<String> Function(String uri)? readUri,
  }) async {
    final String text = await _resolveInput(
      input,
      fetch: fetch,
      readUri: readUri,
    );
    return parseText(text, fetch: fetch, depth: 0);
  }

  /// 解析已经是文本的内容（不联网，除了 `sourceUrls` 展开）
  static Future<ParseOutcome> parseText(
    String text, {
    Future<String> Function(String url)? fetch,
    int depth = 0,
  }) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const ParseOutcome(<SourceRule>[], errors: <String>['内容为空']);
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException catch (e) {
      return ParseOutcome(
        const <SourceRule>[],
        errors: <String>['不是合法 JSON：${e.message}'],
      );
    }

    if (decoded is List) {
      return _parseArray(decoded);
    }

    if (decoded is Map) {
      final Map<String, dynamic> obj = _asStringMap(decoded);

      // ① 订阅式索引：{ "sourceUrls": [...] }
      final Object? sourceUrls = obj['sourceUrls'];
      if (sourceUrls is List) {
        return _expandIndex(
          sourceUrls,
          fetch: fetch,
          depth: depth,
        );
      }

      // ② 单个书源对象
      if (!obj.containsKey('bookSourceUrl')) {
        // 既不是索引也不是书源 —— 给一条明确的错误而不是静默失败
        return const ParseOutcome(
          <SourceRule>[],
          errors: <String>['JSON 里没有 bookSourceUrl 字段，不是书源格式'],
        );
      }
      final SourceRule rule = SourceRule.fromJson(obj);
      if (rule.url.trim().isEmpty) {
        return const ParseOutcome(
          <SourceRule>[],
          errors: <String>['bookSourceUrl 为空'],
        );
      }
      return ParseOutcome(<SourceRule>[rule]);
    }

    return const ParseOutcome(
      <SourceRule>[],
      errors: <String>['顶层既不是数组也不是对象'],
    );
  }

  static ParseOutcome _parseArray(List<Object?> list) {
    final List<SourceRule> rules = <SourceRule>[];
    final List<String> errors = <String>[];
    var index = 0;

    for (final Object? item in list) {
      index++;
      if (item is! Map) {
        errors.add('第 $index 条不是对象，已跳过');
        continue;
      }
      final Map<String, dynamic> obj = _asStringMap(item);
      final String url = (obj['bookSourceUrl'] ?? '').toString().trim();
      if (url.isEmpty) {
        // 对齐 legado：缺 bookSourceUrl 的条目不收
        errors.add('第 $index 条缺 bookSourceUrl，已跳过');
        continue;
      }
      rules.add(SourceRule.fromJson(obj));
    }

    // 同一份文件里可能出现重复 url：保留 lastUpdateTime 更大的那条
    final Map<String, SourceRule> deduped = <String, SourceRule>{};
    for (final SourceRule rule in rules) {
      final SourceRule? exists = deduped[rule.url];
      if (exists == null || rule.lastUpdateTime > exists.lastUpdateTime) {
        deduped[rule.url] = rule;
      }
    }

    return ParseOutcome(deduped.values.toList(growable: false), errors: errors);
  }

  /// 展开 `sourceUrls` 索引文件
  ///
  /// 这是 legado 生态里的「书源订阅」格式：
  /// ```json
  /// { "sourceUrls": ["https://a.com/b.json", "https://c.com/d.json"] }
  /// ```
  /// 每个 URL 再下载、再解析，结果合并。
  static Future<ParseOutcome> _expandIndex(
    List<Object?> urls, {
    Future<String> Function(String url)? fetch,
    required int depth,
  }) async {
    if (depth >= maxIndexDepth) {
      return const ParseOutcome(
        <SourceRule>[],
        errors: <String>['sourceUrls 嵌套过深（可能是环）'],
      );
    }
    if (fetch == null) {
      return const ParseOutcome(
        <SourceRule>[],
        errors: <String>['索引文件需要联网展开，但未提供网络实现'],
      );
    }

    final List<SourceRule> merged = <SourceRule>[];
    final Map<String, SourceRule> byUrl = <String, SourceRule>{};
    final List<String> errors = <String>[];

    for (final Object? raw in urls) {
      if (raw is! String || raw.trim().isEmpty) {
        errors.add('sourceUrls 里有非字符串项，已跳过');
        continue;
      }
      final String url = raw.trim();
      try {
        final String body = await fetch(url);
        final ParseOutcome sub = await parseText(
          body,
          fetch: fetch,
          depth: depth + 1,
        );
        for (final SourceRule rule in sub.rules) {
          final SourceRule? exists = byUrl[rule.url];
          if (exists == null || rule.lastUpdateTime > exists.lastUpdateTime) {
            byUrl[rule.url] = rule;
          }
        }
        if (sub.errors.isNotEmpty) {
          errors.addAll(sub.errors.map((String e) => '$url: $e'));
        }
      } catch (e) {
        // 单个源失败不影响其它（这点与 legado 一致）
        errors.add('$url 下载失败：$e');
      }
    }

    merged.addAll(byUrl.values);
    return ParseOutcome(merged, errors: errors);
  }

  static Future<String> _resolveInput(
    String input, {
    Future<String> Function(String url)? fetch,
    Future<String> Function(String uri)? readUri,
  }) async {
    final String trimmed = input.trim();

    // ⓪ `yuedu://` / `legado://` 书源导入链接：剥出 src 再按普通地址处理
    //
    // 两条路都要能走：浏览器里点「一键导入」、用户直接把它粘进导入框。
    // 解析器是纯函数（`SourceLinkParser`），这里只负责把结果接回原有流程。
    final String? fromLink = SourceLinkParser.extractBookSourceUrl(trimmed);
    if (fromLink != null) {
      if (fromLink != trimmed) {
        return _resolveInput(fromLink, fetch: fetch, readUri: readUri);
      }
    }

    if (isAbsoluteUrl(trimmed)) {
      final Future<String> Function(String) f = fetch ?? _defaultFetch;
      String url = trimmed;

      // 对齐 legado 的 #requestWithoutUA：某些源站见到 UA 就返回拦截页，
      // 这个后缀让请求不带 UA。判据在 SourceClient 里处理，这里只剥后缀。
      final int hash = url.indexOf('#requestWithoutUA');
      if (hash >= 0) url = url.substring(0, hash);

      // 网络失败（含证书过期 HandshakeException）必须变成**可读的错误**，
      // 不能原样抛给调用方：调用方常在 `unawaited(...)` 里跑，
      // 抛出去就成了「未捕获异常」，日志里只有一串英文栈，用户什么也看不到。
      try {
        return await f(url);
      } catch (e) {
        throw StateError('下载书源失败：${_describeNetworkError(e)}');
      }
    }

    if (isLocalUri(trimmed)) {
      final Future<String> Function(String)? r = readUri;
      if (r == null) {
        throw StateError('需要 readUri 实现才能读取本地文件');
      }
      return r(trimmed);
    }

    return trimmed;
  }

  /// 默认网络实现（生产用）
  static Future<String> _defaultFetch(String url) async {
    final http.Response response = await http.get(
      Uri.parse(url),
      headers: const <String, String>{'User-Agent': 'tts_reader'},
    ).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('HTTP ${response.statusCode}');
    }
    // 书源基本都是 UTF-8：用 bodyBytes 自己解码，不依赖响应头 charset
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  /// 把网络异常翻译成人话
  ///
  /// 实测见过：`HandshakeException: CERTIFICATE_VERIFY_FAILED: certificate has expired`
  /// —— 站点证书过期。这类错误直接抛出去只会在日志里留一串英文栈。
  static String _describeNetworkError(Object e) {
    final String text = e.toString();
    if (text.contains('CERTIFICATE_VERIFY_FAILED')) {
      return '对方站点证书已过期或不受信任（换 http 地址，或换个源）';
    }
    if (text.contains('HandshakeException')) {
      return 'HTTPS 握手失败（证书问题）';
    }
    if (text.contains('SocketException') || text.contains('Failed host lookup')) {
      return '连不上这个地址（域名解析失败或网络不通）';
    }
    if (text.contains('TimeoutException')) {
      return '请求超时';
    }
    return text;
  }

  static Map<String, dynamic> _asStringMap(Map<Object?, Object?> map) {
    final Map<String, dynamic> out = <String, dynamic>{};
    map.forEach((Object? k, Object? v) => out[k.toString()] = v);
    return out;
  }
}

/// 把新导入的规则与本地已有规则合并（**纯函数**，不碰存储）
///
/// 语义对齐 legado `BookSourceViewModel.importSources` 里那段：
/// ```
/// old == null                                -> New
/// source.lastUpdateTime > old.lastUpdateTime -> Update
/// else                                       -> Existing
/// ```
SourceImportResult mergeSourceRules(
  List<SourceRule> incoming,
  Map<String, SourceRule> local,
) {
  final List<SourceRule> added = <SourceRule>[];
  final List<SourceRule> updated = <SourceRule>[];
  final List<SourceRule> existing = <SourceRule>[];
  final List<SourceRule> skipped = <SourceRule>[];

  for (final SourceRule rule in incoming) {
    if (!rule.isSupported) {
      // 不支持 ≠ 已存在：单独归类，UI 要能告诉用户「导进来了但读不了」
      skipped.add(rule);
      continue;
    }
    final SourceRule? old = local[rule.url];
    if (old == null) {
      added.add(rule);
    } else if (rule.lastUpdateTime > old.lastUpdateTime) {
      updated.add(rule);
    } else {
      existing.add(rule);
    }
  }

  return SourceImportResult(
    added: added,
    updated: updated,
    existing: existing,
    skipped: skipped,
  );
}

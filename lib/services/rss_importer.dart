import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/rss_source.dart';

/// 订阅源（RSS）的导入解析
///
/// ## 三形态（和书源导入一致的思路）
///
/// 1. 输入是 `http(s)` → 下载后再解析
/// 2. 输入是 `file/content` URI → 读文件（本轮不接，交给上层）
/// 3. 否则当文本直接解析
///
/// JSON 也三形态：
/// - 数组：`[{...}, {...}]`
/// - 带 `sourceUrls` 的索引：`{ "sourceUrls": ["http://..."] }`
/// - 单对象：`{ "sourceUrl": ... }`
///
/// ## 为什么不直接复用 `SourceImporter`
///
/// 模型不同（`RssSource` vs `SourceRule`），去重键也不同
/// （`sourceUrl` vs `bookSourceUrl`）。**抄结构、不 import**，
/// 这样两边可以各自演进，不会因为改书源导入而弄坏订阅导入。
class RssImporter {
  RssImporter._();

  /// `sourceUrls` 索引的递归上限（防御互相引用成环）
  static const int maxIndexDepth = 3;

  /// 单次导入字节上限
  static const int maxBytes = 32 * 1024 * 1024;

  /// 解析输入（URL / 文本）
  static Future<RssParseOutcome> parse(
    String input, {
    Future<String> Function(String url)? fetch,
  }) async {
    final String text = await _resolve(input, fetch: fetch);
    return parseText(text, fetch: fetch, depth: 0);
  }

  /// 解析文本（`sourceUrls` 会继续联网展开）
  static Future<RssParseOutcome> parseText(
    String text, {
    Future<String> Function(String url)? fetch,
    int depth = 0,
  }) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const RssParseOutcome(<RssSource>[], errors: <String>['内容为空']);
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException catch (e) {
      return RssParseOutcome(
        const <RssSource>[],
        errors: <String>['不是合法 JSON：${e.message}'],
      );
    }

    if (decoded is List) {
      return _parseArray(decoded);
    }

    if (decoded is Map) {
      final Map<String, dynamic> obj = decoded.map(
        (Object? k, Object? v) => MapEntry(k.toString(), v),
      );

      // ① 订阅索引
      final Object? urls = obj['sourceUrls'];
      if (urls is List) {
        if (depth >= maxIndexDepth) {
          return const RssParseOutcome(
            <RssSource>[],
            errors: <String>['订阅索引嵌套太深'],
          );
        }
        final List<RssSource> collected = <RssSource>[];
        final List<String> errors = <String>[];
        for (final Object? item in urls) {
          final String url = item?.toString().trim() ?? '';
          if (url.isEmpty) continue;
          try {
            final String body = await _fetch(url, fetch);
            final RssParseOutcome sub = await parseText(
              body,
              fetch: fetch,
              depth: depth + 1,
            );
            collected.addAll(sub.sources);
            errors.addAll(sub.errors);
          } catch (e) {
            errors.add('$url：$e');
          }
        }
        return RssParseOutcome(collected, errors: errors);
      }

      // ② 单个订阅源
      if (!obj.containsKey('sourceUrl')) {
        return const RssParseOutcome(
          <RssSource>[],
          errors: <String>['既不是订阅源，也不含 sourceUrls 索引'],
        );
      }
      return _parseOne(obj);
    }

    return const RssParseOutcome(
      <RssSource>[],
      errors: <String>['顶层既不是数组也不是对象'],
    );
  }

  static RssParseOutcome _parseArray(List<Object?> items) {
    final List<RssSource> out = <RssSource>[];
    final List<String> errors = <String>[];
    for (var i = 0; i < items.length; i++) {
      final Object? item = items[i];
      if (item is! Map) {
        errors.add('第 ${i + 1} 条不是对象');
        continue;
      }
      final RssParseOutcome one = _parseOne(
        item.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
      );
      out.addAll(one.sources);
      errors.addAll(one.errors);
    }
    return RssParseOutcome(out, errors: errors);
  }

  static RssParseOutcome _parseOne(Map<String, dynamic> obj) {
    final RssSource source = RssSource.fromJson(obj);
    if (source.sourceUrl.isEmpty) {
      return const RssParseOutcome(<RssSource>[], errors: <String>['缺 sourceUrl']);
    }
    if (!source.isUsable) {
      // 字段不齐也收下（用户可能在管理页里补），但明确报一条
      return RssParseOutcome(
        <RssSource>[source],
        errors: <String>['${source.displayName}：缺 ruleArticles / ruleLink / ruleTitle 之一'],
      );
    }
    return RssParseOutcome(<RssSource>[source]);
  }

  static Future<String> _resolve(
    String input, {
    Future<String> Function(String url)? fetch,
  }) async {
    final String trimmed = input.trim();
    if (trimmed.isEmpty) return trimmed;
    if (trimmed.toLowerCase().startsWith('http://') ||
        trimmed.toLowerCase().startsWith('https://')) {
      return _fetch(trimmed, fetch);
    }
    return trimmed;
  }

  static Future<String> _fetch(
    String url,
    Future<String> Function(String url)? fetch,
  ) async {
    final String body = await (fetch ?? _defaultFetch)(url);
    if (body.length > maxBytes) {
      throw StateError('内容超过 ${maxBytes ~/ 1024 ~/ 1024}MB 上限');
    }
    return body;
  }

  static Future<String> _defaultFetch(String url) async {
    final http.Response response = await http
        .get(Uri.parse(url), headers: <String, String>{
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        })
        .timeout(const Duration(seconds: 25));
    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw StateError('HTTP ${response.statusCode} $url');
    }
    // 订阅 JSON 几乎都是 UTF-8；GBK 的情况交给正文抓取那条线处理
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }
}

/// 导入解析结果
class RssParseOutcome {
  const RssParseOutcome(this.sources, {this.errors = const <String>[]});

  final List<RssSource> sources;

  /// 非致命问题（字段不齐、某条坏掉）
  final List<String> errors;

  bool get isEmpty => sources.isEmpty;
}

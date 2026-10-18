/// 规则引擎主调度（对齐 legado `AnalyzeRule.kt`）
///
/// ## 职责
///
/// 把「一条 legado 规则字符串」变成「一组字符串结果」。中间要做四件事：
///
/// ```
/// 规则文本
///   ↓ ① 切分（&& / || / %%，跳过引号与括号）
///   ↓ ② 每段判定类型（@css / @xpath / @json / 默认 CSS / 正则）
///   ↓ ③ 求值（交给对应分析器）
///   ↓ ④ 后处理（## 正则替换、{{ }} 展开、@put/@get、$1 引用）
/// ```
///
/// ## 与 legado 的关键差异（必须知道）
///
/// legado 用 Rhino 执行 JS。本工程**不引 JS 引擎**，改用
/// `ExpressionEvaluator` 覆盖简单表达式（实测覆盖 83%）。
/// 遇到需要控制流的表达式时抛 `UnsupportedExpression`，
/// 由 `SourceClient` 标记「此源不支持」—— **绝不静默返回错数据**。
library;

import 'dart:convert';

import 'package:html/dom.dart' as dom;

import 'css_analyzer.dart';
import 'expression_evaluator.dart';
import 'json_path_analyzer.dart';
import 'rule_analyzer.dart';
import 'xpath_analyzer.dart';

/// 内容形态
enum ContentKind { html, json, text }

/// 一次求值的上下文
class RuleContext {
  RuleContext({
    this.baseUrl,
    this.variables = const <String, Object?>{},
    this.functions = const <String, Object? Function(List<Object?>)>{},
  });

  /// 相对 URL 的基准（书源首页）
  final String? baseUrl;

  /// 可用变量：`page` / `key` / `book` / `result` …
  final Map<String, Object?> variables;

  /// 宿主函数：`java.encodeURI` 等
  final Map<String, Object? Function(List<Object?>)> functions;

  RuleContext copyWith({
    String? baseUrl,
    Map<String, Object?>? variables,
  }) => RuleContext(
    baseUrl: baseUrl ?? this.baseUrl,
    variables: variables ?? this.variables,
    functions: functions,
  );
}

/// 规则求值器
class RuleEngine {
  RuleEngine({
    required this.content,
    required this.kind,
    required this.context,
  });

  /// 当前内容（HTML 文本 / JSON 文本 / 纯文本）
  final String content;

  /// 内容形态
  final ContentKind kind;

  /// 求值上下文
  final RuleContext context;

  /// 变量存储（`@put` / `@get`）
  final Map<String, String> _store = <String, String>{};

  /// 缓存解析后的 HTML/JSON，避免同一条规则链重复解析
  dom.Element? _htmlRoot;
  Object? _jsonRoot;

  /// 求值，返回字符串列表
  List<String> getStringList(String? rule, {bool isUrl = false}) {
    if (rule == null || rule.trim().isEmpty) return const <String>[];

    final SplitResult split = RuleAnalyzer(rule).splitRule(<String>['&&', '||', '%%']);
    final List<List<String>> perSegment = <List<String>>[];

    for (final String segment in split.segments) {
      final List<String> result = _evalSegment(segment);
      perSegment.add(result);
      // `||` 取第一个非空，命中即停
      if (split.elementsType == '||' && result.isNotEmpty) break;
    }

    final List<String> merged = _merge(perSegment, split.elementsType);
    if (!isUrl) return merged;

    // URL 模式：转绝对地址 + 去重
    final List<String> out = <String>[];
    for (final String raw in merged) {
      final String abs = resolveUrl(raw);
      if (abs.isNotEmpty && !out.contains(abs)) out.add(abs);
    }
    return out;
  }

  /// 求值，返回单个字符串（多结果用 `\n` 连接，对齐 legado `getString`）
  String getString(String? rule) {
    final List<String> list = getStringList(rule);
    if (list.isEmpty) return '';
    if (list.length == 1) return list.first;
    return list.join('\n');
  }

  /// 取元素（供 `bookList` / `chapterList` 这类「取 N 个容器」场景）
  ///
  /// ## 与 `getStringList` 的区别（**关键**）
  ///
  /// `getStringList('class.list@tag.a@text')` 的最后一段 `text` 是**取值方式**，
  /// 中间各段才是层级。而 `getElements` 的调用方（`bookList` / `chapterList`）
  /// 想要的是「**最后一段也是层级**」——
  ///
  /// ```
  /// chapterList = class.chapters@tag.a
  ///   → 应该返回所有 <a> 元素（每个 a 是一章）
  ///   → 而不是「在 .chapters 里找 <a> 再取名为 a 的属性」
  /// ```
  ///
  /// 所以这里**整条规则都按层级处理**，不做末级取值分派。
  List<Object?> getElements(String? rule) {
    if (rule == null || rule.trim().isEmpty) return const <Object?>[];

    switch (kind) {
      case ContentKind.json:
        return JsonPathAnalyzer(_json()).evaluateRaw(rule);

      case ContentKind.html:
      case ContentKind.text:
        final CssAnalyzer css = _css();
        final List<dom.Element> elements = css.selectElements(rule.trim());
        return <Object?>[
          for (final dom.Element e in elements) e.outerHtml,
        ];
    }
  }

  // ---------------- 单段求值 ----------------

  List<String> _evalSegment(String rule) {
    final String trimmed = rule.trim();
    if (trimmed.isEmpty) return const <String>[];

    // ① 分离 `##正则##替换[##]`
    final _PostProcess post = _splitPostProcess(trimmed);

    // ② 展开 {{ }}
    final String expanded = _expandTemplates(post.mainRule);

    // ③ **展开后是纯文本的规则**：含模板但展开结果不含选择器语法
    //
    // 典型：`p{{(page-1)*18}}`、`https://a.com/s?q={{key}}&p={{page}}`
    // 展开成 `p54` / `https://a.com/s?q=x&p=2` 之后，
    // 若继续送进 CSS 分析器，`p54` 会被当成「标签 p + 编号 54」→ 匹配不到。
    // legado 里这类规则由 `makeUpRule` 直接产出字符串，不走分析器。
    if (_hasTemplate(post.mainRule) && _looksLikeLiteralAfterExpand(expanded)) {
      final List<String> out = _splitLines(expanded);
      if (post.regex == null || post.regex!.isEmpty) return out;
      return out.map((String s) => _applyReplace(s, post)).toList();
    }

    // ④ 判类型并求值
    final _RuleType type = _detectType(expanded);
    List<String> result;
    switch (type.mode) {
      case _Mode.js:
        result = _evalJs(type.body);
        break;
      case _Mode.regex:
        result = _evalRegex(type.body);
        break;
      case _Mode.json:
        result = JsonPathAnalyzer(_json()).evaluate(type.body);
        break;
      case _Mode.xpath:
        result = _evalXPath(type.body);
        break;
      case _Mode.css:
        result = _css().evaluate(type.body);
        break;
    }

    // ⑤ 后处理替换
    if (post.regex != null && post.regex!.isNotEmpty) {
      result = result.map((String s) => _applyReplace(s, post)).toList();
    }

    return result;
  }

  /// 展开后的文本是否「不是选择器」
  ///
  /// 判据保守：只要不是以 CSS/XPath/JSONPath 的前缀开头，就当纯文本。
  /// 这样 `p54`、`https://...`、`第3页` 都走字面量分支，
  /// 而 `{{selectorRule}}` 这种「模板产出选择器」的罕见写法仍会进入分析器。
  static bool _looksLikeLiteralAfterExpand(String expanded) {
    final String e = expanded.trim();
    if (e.isEmpty) return true;
    if (e.startsWith('@') || e.startsWith(r'$') || e.startsWith('/')) {
      return false;
    }
    return true;
  }

  /// 规则里是否**含有**模板
  ///
  /// `p{{(page-1)*18}}` 这种「前缀/后缀 + 模板」的形态很常见
  /// （搜索结果 URL、分页地址）。展开之后**不能再当 CSS 求值** ——
  /// 展开结果是纯文本，应当整条作为字符串返回。
  static bool _hasTemplate(String rule) => rule.contains('{{');

  /// 展开结果按行拆开（对齐 legado `getStringList` 里 `result.split("\n")`）
  static List<String> _splitLines(String text) {
    if (text.isEmpty) return const <String>[];
    return text
        .split('\n')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList(growable: false);
  }

  /// 判定规则类型（对齐 `SourceRule.init` 的前缀分派）
  _RuleType _detectType(String rule) {
    final String r = rule.trim();
    if (r.startsWith('@CSS:')) {
      return _RuleType(_Mode.css, r.substring(5).trim());
    }
    if (r.startsWith('@@')) {
      return _RuleType(_Mode.css, r.substring(2).trim());
    }
    if (r.startsWith('@XPath:')) {
      return _RuleType(_Mode.xpath, r.substring(7).trim());
    }
    if (r.startsWith('@Json:')) {
      return _RuleType(_Mode.json, r.substring(6).trim());
    }
    if (r.startsWith('@js:')) {
      return _RuleType(_Mode.js, r.substring(4).trim());
    }
    if (r.startsWith('<js>')) {
      final String inner = r.substring(4);
      final int end = inner.indexOf('</js>');
      return _RuleType(_Mode.js, end >= 0 ? inner.substring(0, end) : inner);
    }
    if (r.startsWith(r'$.')) {
      return _RuleType(_Mode.json, r);
    }
    if (r.startsWith(r'$[')) {
      return _RuleType(_Mode.json, r);
    }
    // XPath 特征：以 `/` 开头
    //
    // ⚠️ 但不能一律当 XPath：真实书源里大量 `/正则/` 字面量也在 `##` 之后出现，
    // 例如 `xx@text##/\\s.*/`。判据收紧成「像 XPath 路径」：
    // 必须是 `/` + 字母/星号，或者 `//`，且**不含正则特征字符**（`\\d`/`.*`/`[`）。
    if (r.startsWith('/') && _looksLikeXPath(r)) {
      return _RuleType(_Mode.xpath, r);
    }
    // `:@regex` 或含 `$1` 分组引用的，按正则处理
    if (r.startsWith(':') || RegExp(r'\$\d{1,2}').hasMatch(r)) {
      return _RuleType(_Mode.regex, r.startsWith(':') ? r.substring(1) : r);
    }
    return _RuleType(_Mode.css, r);
  }

  /// 判断 `/` 开头的是 XPath 还是正则字面量
  ///
  /// 真实书源里两种写法都常见：
  /// - XPath：`//div[@class="list"]`、`/html/body/div`、`//*[@id="c"]`
  /// - 正则：`/\s.*/`、`/(\d+)/`、`/[^\u4e00-\u9fa5]+/`
  ///
  /// 判据（保守，宁可当正则）：
  /// - 含 `\` 转义 → 正则
  /// - 含未闭合的 `/`（除开头外还有 `/` 结尾）→ 正则
  /// - `//` 或 `/(字母|星号)` 且不含正则元字符 → XPath
  static bool _looksLikeXPath(String r) {
    // 正则特征：反斜杠转义
    if (r.contains(r'\')) return false;
    // 形如 `/xxx/` 的闭合正则
    if (r.length > 2 && r.endsWith('/') && r.indexOf('/', 1) == r.length - 1) {
      return false;
    }
    if (r.startsWith('//')) return true;
    // `/html`、`/div`、`/*` 这类
    if (r.length > 1 && RegExp(r'^/[A-Za-z*]').hasMatch(r)) return true;
    return false;
  }

  // ---------------- 各模式求值 ----------------

  List<String> _evalJs(String js) {
    // 单表达式：走求值器
    final Object? value = ExpressionEvaluator(
      js,
      EvalContext(
        variables: <String, Object?>{
          ...context.variables,
          'result': content,
          'baseUrl': context.baseUrl,
        },
        functions: context.functions,
      ),
    ).evaluate();
    if (value == null) return const <String>[];
    final List<String> out = <String>[];
    if (value is List) {
      for (final Object? v in value) {
        final String s = _stringify(v);
        if (s.isNotEmpty) out.add(s);
      }
    } else {
      final String s = _stringify(value);
      if (s.isNotEmpty) out.add(s);
    }
    return out;
  }

  /// XPath 求值
  ///
  /// legado 的 XPath 规则可能带末级（`//div/text()` 或 `//div@href`），
  /// 这里把末级拆出来交给 `XPathAnalyzer` 决定取文本还是属性。
  List<String> _evalXPath(String path) {
    final String p = path.trim();
    if (p.isEmpty) return const <String>[];

    // 末级判定：`@href` / `@text` / `@html` 结尾
    String? lastStep;
    String expr = p;
    final RegExpMatch? m = RegExp(r'@(text|html|all|[\w:-]+)$').firstMatch(p);
    if (m != null && m.start > 0) {
      lastStep = m.group(1);
      expr = p.substring(0, m.start);
    }

    final XPathAnalyzer analyzer = XPathAnalyzer(content);
    final List<String> out = analyzer.evaluate(expr, lastStep: lastStep);
    if (out.isEmpty && analyzer.parseError != null) {
      // 解析不了就明确报不支持，让上层把该源标记为不可用
      throw UnsupportedExpression('XPath 无法求值：${analyzer.parseError}');
    }
    return out;
  }

  List<String> _evalRegex(String pattern) {    final RegExp re;
    try {
      re = RegExp(pattern, multiLine: true, dotAll: true);
    } catch (_) {
      return const <String>[];
    }
    final List<String> out = <String>[];
    for (final RegExpMatch m in re.allMatches(content)) {
      if (m.groupCount >= 1 && m.group(1) != null) {
        out.add(m.group(1)!);
      } else {
        out.add(m.group(0)!);
      }
    }
    return out;
  }

  // ---------------- 后处理 ----------------

  /// 拆 `主规则##正则##替换[##]`
  _PostProcess _splitPostProcess(String rule) {
    // 只在顶层的 ## 处拆（跳过引号与括号）
    final List<int> positions = <int>[];
    var square = 0;
    var paren = 0;
    var inSingle = false;
    var inDouble = false;
    for (var i = 0; i < rule.length - 1; i++) {
      final String c = rule[i];
      if (c == "'" && !inDouble) {
        inSingle = !inSingle;
      } else if (c == '"' && !inSingle) {
        inDouble = !inDouble;
      } else if (!inSingle && !inDouble) {
        if (c == '[') square++;
        if (c == ']' && square > 0) square--;
        if (c == '(') paren++;
        if (c == ')' && paren > 0) paren--;
        if (c == '#' && rule[i + 1] == '#' && square == 0 && paren == 0) {
          positions.add(i);
          i++;
        }
      }
    }

    if (positions.isEmpty) {
      return _PostProcess(rule, null, null, false);
    }

    final String main = rule.substring(0, positions[0]);
    final List<String> parts = <String>[];
    for (var k = 0; k < positions.length; k++) {
      final int start = positions[k] + 2;
      final int end = k + 1 < positions.length ? positions[k + 1] : rule.length;
      parts.add(rule.substring(start, end));
    }
    final String? regex = parts.isNotEmpty ? parts[0] : null;
    final String? replacement = parts.length > 1 ? parts[1] : null;
    // 第四段存在 = 只替换第一个（对齐 legado `replaceFirst`）
    final bool replaceFirst = parts.length > 2;
    return _PostProcess(main, regex, replacement, replaceFirst);
  }

  String _applyReplace(String input, _PostProcess post) {
    final String rawPattern = post.regex!;
    if (rawPattern.isEmpty) return input;
    final String replacement = post.replacement ?? '';

    // 书源里 `##` 后的正则常带转义（`\\d`），统一还原一层
    String pattern = rawPattern.replaceAll(r'\\', r'\');

    // 剥掉正则定界符：`##/\d+/##` 的正则体是 `\d+`，不是 `/\d+/`
    //
    // ⚠️ 真实书源大量使用 `/xxx/` 写法（JS 正则字面量习惯）。
    // 不剥的话 `RegExp('/\\d+/')` 会去找字面的 `/123/`，永远匹配不到。
    if (pattern.length > 1 &&
        pattern.startsWith('/') &&
        pattern.endsWith('/')) {
      pattern = pattern.substring(1, pattern.length - 1);
    }

    try {
      final RegExp re = RegExp(pattern, multiLine: true, dotAll: true);
      if (post.replaceFirst) {
        return input.replaceFirst(re, replacement);
      }
      return input.replaceAll(re, replacement);
    } catch (_) {
      return input;
    }
  }

  /// 展开 `{{ }}`
  ///
  /// 注意：真实书源里 `{{ }}` 有 388 种不同内容，其中 201 种是 JSONPath
  /// （如 `{{$..bid}}`），其余是简单表达式。这里先判 JSONPath，再走求值器。
  String _expandTemplates(String rule) {
    if (!rule.contains('{{')) return rule;
    return RuleAnalyzer(rule).replaceInnerBraces((String expr) {
      final String e = expr.trim();
      if (e.isEmpty) return '';
      // JSONPath 形式
      if (e.startsWith(r'$')) {
        final List<String> v = JsonPathAnalyzer(_json()).evaluate(e);
        return v.isEmpty ? '' : v.first;
      }
      try {
        final Object? value = ExpressionEvaluator(
          e,
          EvalContext(
            variables: <String, Object?>{
              ...context.variables,
              'result': content,
              'baseUrl': context.baseUrl,
            },
            functions: context.functions,
          ),
        ).evaluate();
        return _stringify(value);
      } on UnsupportedExpression {
        // 表达式不支持：保留原文，让调用方看到原始规则而不是静默变空
        rethrow;
      }
    });
  }

  // ---------------- 懒加载解析 ----------------

  dom.Element _html() {
    _htmlRoot ??= CssAnalyzer.fromHtml(content).root;
    return _htmlRoot!;
  }

  CssAnalyzer _css() => CssAnalyzer(_html());

  Object? _json() {
    _jsonRoot ??= _decodeJson(content);
    return _jsonRoot;
  }

  static Object? _decodeJson(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  // ---------------- URL ----------------

  /// 把相对地址转绝对地址
  String resolveUrl(String url) {
    final String u = url.trim();
    if (u.isEmpty) return '';
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    final String? base = context.baseUrl;
    if (base == null || base.isEmpty) return u;
    try {
      return Uri.parse(base).resolve(u).toString();
    } catch (_) {
      return u;
    }
  }

  static String _stringify(Object? v) {
    if (v == null) return '';
    if (v is String) return v.trim();
    if (v is num) {
      if (v is double && v == v.roundToDouble() && v.abs() < 1e15) {
        return v.toInt().toString();
      }
      return v.toString();
    }
    if (v is bool) return v ? 'true' : 'false';
    return '';
  }

  /// 存取变量（`@put` / `@get`）
  String putVariable(String key, String value) {
    _store[key] = value;
    return value;
  }

  String getVariable(String key) => _store[key] ?? context.variables[key]?.toString() ?? '';

  // ---------------- 合并 ----------------

  /// 按分隔符语义合并各段结果
  ///
  /// | 分隔符 | 语义 |
  /// |---|---|
  /// | `&&` | 依次追加 |
  /// | `\|\|` | 取第一个非空（调用方已 break） |
  /// | `%%` | 交叉合并（各段第 0 个、再第 1 个…） |
  List<String> _merge(List<List<String>> perSegment, String operator) {
    if (perSegment.isEmpty) return const <String>[];
    if (perSegment.length == 1) return perSegment.first;

    if (operator == '%%') {
      final List<String> out = <String>[];
      final int maxLen =
          perSegment.map((List<String> l) => l.length).fold(0, (int a, int b) => a > b ? a : b);
      for (var i = 0; i < maxLen; i++) {
        for (final List<String> seg in perSegment) {
          if (i < seg.length) out.add(seg[i]);
        }
      }
      return out;
    }

    final List<String> out = <String>[];
    for (final List<String> seg in perSegment) {
      out.addAll(seg);
    }
    return out;
  }
}

enum _Mode { css, json, xpath, js, regex }

class _RuleType {
  const _RuleType(this.mode, this.body);

  final _Mode mode;
  final String body;
}

class _PostProcess {
  const _PostProcess(this.mainRule, this.regex, this.replacement, this.replaceFirst);

  final String mainRule;
  final String? regex;
  final String? replacement;
  final bool replaceFirst;
}

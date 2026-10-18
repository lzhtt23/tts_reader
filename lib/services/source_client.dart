/// 书源客户端：把 `SourceRule` 变成可用的「搜索 / 目录 / 正文」能力
///
/// 这是方案 2 的收口层 —— 上面是规则引擎，下面是 `StructuredDocument`。
///
/// ## 一次抓取的完整链路
///
/// ```
/// search()   searchUrl + ruleSearch   → List<OnlineBook>
/// toc()      bookUrl + ruleToc        → List<OnlineChapter>
/// content()  chapterUrl + ruleContent → String（正文纯文本）
/// toDocument() 把若干章拼成 StructuredDocument
/// ```
///
/// ## 为什么正文要做清洗
///
/// `ruleContent.content` 通常返回 `@html`，里面带 `<br>` / `&nbsp;` /
/// `<p>` 等标签。朗读要用纯文本，所以这里统一走
/// [htmlToParagraphs]：按块级标签切段，去标签，压缩空白。
library;

import 'dart:async';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../models/source_rule.dart';
import '../models/structured_document.dart';
import 'rule_engine.dart';
import 'url_template.dart';

/// 搜索结果里的一本书
class OnlineBook {
  const OnlineBook({
    required this.name,
    required this.url,
    this.author = '',
    this.coverUrl = '',
    this.intro = '',
    this.lastChapter = '',
    this.kind = '',
  });

  final String name;

  /// 书籍详情页绝对地址
  final String url;

  final String author;
  final String coverUrl;
  final String intro;
  final String lastChapter;

  /// 分类/状态（如「连载」）
  final String kind;

  @override
  String toString() => 'OnlineBook($name <$url>)';
}

/// 目录里的一个章节
class OnlineChapter {
  const OnlineChapter({required this.name, required this.url});

  final String name;

  /// 章节页绝对地址
  final String url;

  @override
  String toString() => 'OnlineChapter($name)';
}

/// 抓取失败（带可读原因，便于 UI 直接展示）
class SourceOperationException implements Exception {
  const SourceOperationException(this.operation, this.reason);

  /// 哪一步失败：`search` / `toc` / `content`
  final String operation;
  final String reason;

  @override
  String toString() => '$operation 失败：$reason';
}

/// 书源客户端
class SourceClient {
  SourceClient({
    required this.rule,
    SourceHttpClient? client,
  }) : _http = client ?? SourceHttpClient(),
       _ownClient = client == null;

  final SourceRule rule;
  final SourceHttpClient _http;
  final bool _ownClient;

  /// 单章正文最大字符数（防御异常源返回整站内容）
  static const int maxContentChars = 200000;

  // ---------------- 搜索 ----------------

  /// 搜索
  ///
  /// [keyword] 是用户输入，会按 `{{key}}` 注入；
  /// [page] 从 1 开始（对齐 legado 约定）。
  Future<List<OnlineBook>> search(String keyword, {int page = 1}) async {
    final String? template = rule.searchUrl;
    final Map<String, dynamic>? searchRule = rule.ruleSearch;
    if (template == null || template.trim().isEmpty) {
      throw const SourceOperationException('search', '书源没有 searchUrl');
    }
    if (searchRule == null) {
      throw const SourceOperationException('search', '书源没有 ruleSearch');
    }

    final String body = await _request(
      template,
      operation: 'search',
      variables: <String, Object?>{'key': keyword, 'page': page},
    );

    final RuleEngine engine = RuleEngine(
      content: body,
      kind: _kindOf(body),
      context: RuleContext(
        baseUrl: rule.url,
        variables: <String, Object?>{'key': keyword, 'page': page},
        functions: _defaultFunctions(),
      ),
    );

    // bookList 决定「一本一本书的容器」
    final String? listRule = searchRule['bookList'] as String?;
    if (listRule == null || listRule.trim().isEmpty) {
      throw const SourceOperationException('search', 'searchRule.bookList 为空');
    }

    // 从整页里先取出每本书的片段，再在片段里取字段
    // ⚠️ 必须取 **HTML 片段**（不是纯文本）：字段规则（`tag.a.0@href`）
    // 要在片段里继续选择元素，纯文本里没有标签，全都匹配不到。
    final List<String> items = _extractItemHtml(engine, listRule);
    final List<OnlineBook> books = <OnlineBook>[];

    for (final String item in items) {
      // 片段可能是 HTML 字符串（css 的 html 末级），也可能是纯文本
      final RuleEngine itemEngine = RuleEngine(
        content: item,
        kind: _kindOf(item),
        context: RuleContext(
          baseUrl: rule.url,
          variables: <String, Object?>{'key': keyword, 'page': page},
        ),
      );
      final String name = itemEngine.getString(searchRule['name'] as String?);
      final List<String> urls = itemEngine.getStringList(
        searchRule['bookUrl'] as String?,
        isUrl: true,
      );
      if (name.trim().isEmpty || urls.isEmpty) continue;

      books.add(
        OnlineBook(
          name: name.trim(),
          url: urls.first,
          author: itemEngine.getString(searchRule['author'] as String?).trim(),
          coverUrl: itemEngine
              .getStringList(searchRule['coverUrl'] as String?, isUrl: true)
              .firstOrNull
              ?.toString() ??
              '',
          intro: itemEngine.getString(searchRule['intro'] as String?).trim(),
          lastChapter: itemEngine.getString(searchRule['lastChapter'] as String?).trim(),
          kind: itemEngine.getString(searchRule['kind'] as String?).trim(),
        ),
      );
    }

    return books;
  }

  // ---------------- 详情页 ----------------

  /// 取书籍详情（简介 / 封面 / 作者）
  ///
  /// 为什么需要单独一个方法：`ruleSearch` 里**通常没有简介**，
  /// 只有详情页（`ruleBookInfo`）才有。简介页先用搜索结果渲染，
  /// 再异步调这个补一次；失败就只显示已有字段。
  ///
  /// 书源没配 `ruleBookInfo` 时直接返回空字段（不算错误）。
  Future<OnlineBook> bookInfo(String bookUrl) async {
    final Map<String, dynamic>? info = rule.ruleBookInfo;
    if (info == null) {
      return OnlineBook(name: '', url: bookUrl);
    }
    final String body = await _request(
      bookUrl,
      operation: 'bookInfo',
      variables: <String, Object?>{'page': 1},
    );
    final RuleEngine engine = RuleEngine(
      content: body,
      kind: _kindOf(body),
      context: RuleContext(baseUrl: bookUrl),
    );
    return OnlineBook(
      name: engine.getString(info['name'] as String?).trim(),
      url: bookUrl,
      author: engine.getString(info['author'] as String?).trim(),
      coverUrl: engine
              .getStringList(info['coverUrl'] as String?, isUrl: true)
              .firstOrNull
              ?.toString() ??
          '',
      intro: engine.getString(info['intro'] as String?).trim(),
      lastChapter: engine.getString(info['lastChapter'] as String?).trim(),
      kind: engine.getString(info['kind'] as String?).trim(),
    );
  }

  // ---------------- 目录 ----------------

  /// 取目录
  ///
  /// [bookUrl] 是详情页地址；`ruleBookInfo.tocUrl` 若存在会先补一次详情页
  /// （有些书源的目录在另一个地址上）。
  Future<List<OnlineChapter>> toc(String bookUrl, {int page = 1}) async {
    final Map<String, dynamic>? tocRule = rule.ruleToc;
    if (tocRule == null) {
      throw const SourceOperationException('toc', '书源没有 ruleToc');
    }

    // 先请求详情页，看有没有 tocUrl 指向别的目录页
    String targetUrl = bookUrl;
    try {
      final String detailBody = await _request(
        bookUrl,
        operation: 'toc',
        variables: <String, Object?>{'page': page},
      );
      final String? tocUrlRule = rule.ruleBookInfo?['tocUrl'] as String?;
      if (tocUrlRule != null && tocUrlRule.trim().isNotEmpty) {
        final RuleEngine detailEngine = RuleEngine(
          content: detailBody,
          kind: _kindOf(detailBody),
          context: RuleContext(baseUrl: bookUrl),
        );
        final List<String> tocUrls = detailEngine.getStringList(tocUrlRule, isUrl: true);
        if (tocUrls.isNotEmpty) targetUrl = tocUrls.first;
      }

      // 目录就在详情页上时，省一次请求
      final bool needSeparate = targetUrl != bookUrl;
      final String tocBody = needSeparate
          ? await _request(
              targetUrl,
              operation: 'toc',
              variables: <String, Object?>{'page': page},
            )
          : detailBody;

      return _parseToc(tocBody, baseUrl: targetUrl);
    } catch (e) {
      if (e is SourceOperationException) rethrow;
      throw SourceOperationException('toc', e.toString());
    }
  }

  List<OnlineChapter> _parseToc(String body, {required String baseUrl}) {
    final Map<String, dynamic>? tocRule = rule.ruleToc;
    if (tocRule == null) return const <OnlineChapter>[];

    final RuleEngine engine = RuleEngine(
      content: body,
      kind: _kindOf(body),
      context: RuleContext(baseUrl: baseUrl),
    );

    final String? listRule = tocRule['chapterList'] as String?;
    if (listRule == null || listRule.trim().isEmpty) return const <OnlineChapter>[];

    final List<String> items = _extractItemHtml(engine, listRule);

    // chapterList 若返回的是一个「大容器」，需要再按章节切分。
    // legado 的做法是 chapterList 本身产出多个元素（每个元素代表一章），
    // 这里对「只有一个元素且很长」的情况做一次兜底拆分。
    final List<String> chapters = items.length == 1 && items.first.length > 200
        ? _splitChapterHtml(items.first)
        : items;

    final List<OnlineChapter> out = <OnlineChapter>[];
    for (final String item in chapters) {
      final RuleEngine itemEngine = RuleEngine(
        content: item,
        kind: _kindOf(item),
        context: RuleContext(baseUrl: baseUrl),
      );
      final String name = itemEngine.getString(tocRule['chapterName'] as String?).trim();
      final List<String> urls = itemEngine.getStringList(
        tocRule['chapterUrl'] as String?,
        isUrl: true,
      );
      if (name.isEmpty || urls.isEmpty) continue;
      out.add(OnlineChapter(name: name, url: urls.first));
    }
    return out;
  }

  /// 取出「每个条目」的 HTML 片段
  ///
  /// legado 的 `bookList` / `chapterList` 语义是「选出 N 个容器元素」，
  /// 后续字段规则在这些**容器内部**继续选择。所以这里必须拿到 outerHtml，
  /// 不能拿 `text`。
  ///
  /// 做法：先用 CSS 选择器拿到元素，再逐个序列化。
  /// 如果规则本身已经带了末级（如 `...@html`），就尊重规则结果。
  List<String> _extractItemHtml(RuleEngine engine, String listRule) {
    final String rule = listRule.trim();
    // 规则自带取值末级 → 结果已是片段，直接用
    if (rule.endsWith('@html') ||
        rule.endsWith('@all') ||
        rule.contains('@html@') ||
        rule.startsWith(r'$')) {
      return engine.getStringList(rule);
    }

    // 否则：按 CSS 选择器取元素，序列化成 outerHtml
    final List<Object?> elements = engine.getElements(rule);
    if (elements.isEmpty) {
      // 退化：至少把文本拿出来（有些源 bookList 直接给纯文本行）
      return engine.getStringList(rule);
    }
    return <String>[
      for (final Object? e in elements)
        if (e != null) e.toString(),
    ];
  }

  /// 把一整块章节 HTML 按 `<a>` 拆开（兜底）
  List<String> _splitChapterHtml(String html) {
    try {
      final dom.Document doc = html_parser.parse(html);
      return doc
          .querySelectorAll('a')
          .map((dom.Element e) => e.outerHtml)
          .toList(growable: false);
    } catch (_) {
      return <String>[html];
    }
  }

  // ---------------- 正文 ----------------

  /// 取一章正文（纯文本，按段落用 `\n` 分隔）
  Future<String> content(String chapterUrl, {int page = 1}) async {
    final Map<String, dynamic>? contentRule = rule.ruleContent;
    if (contentRule == null) {
      throw const SourceOperationException('content', '书源没有 ruleContent');
    }
    final String? contentRuleStr = contentRule['content'] as String?;
    if (contentRuleStr == null || contentRuleStr.trim().isEmpty) {
      throw const SourceOperationException('content', 'ruleContent.content 为空');
    }

    final String body = await _request(
      chapterUrl,
      operation: 'content',
      variables: <String, Object?>{'page': page},
    );

    final RuleEngine engine = RuleEngine(
      content: body,
      kind: _kindOf(body),
      context: RuleContext(baseUrl: chapterUrl),
    );

    final List<String> parts = engine.getStringList(contentRuleStr);
    String text = parts.join('\n');

    // 副正文（有些源把后半段放在 subContent）
    final String? subRule = contentRule['subContent'] as String?;
    if (subRule != null && subRule.trim().isNotEmpty) {
      final List<String> sub = engine.getStringList(subRule);
      if (sub.isNotEmpty) text = '$text\n${sub.join('\n')}';
    }

    // 源级替换（`replaceRegex`，格式 `正则##替换`）
    final String? replaceRule = contentRule['replaceRegex'] as String?;
    if (replaceRule != null && replaceRule.contains('##')) {
      final List<String> pieces = replaceRule.split('##');
      if (pieces.length >= 2) {
        try {
          text = text.replaceAll(RegExp(pieces[0], multiLine: true), pieces[1]);
        } catch (_) {
          // 正则写坏了就跳过替换，不影响正文
        }
      }
    }

    final String cleaned = htmlToParagraphs(text);
    if (cleaned.length > maxContentChars) {
      return cleaned.substring(0, maxContentChars);
    }
    return cleaned;
  }

  // ---------------- 组装成可朗读文档 ----------------

  /// 把若干章拼成 `StructuredDocument`（供 `TtsManager.loadDocument` 用）
  ///
  /// [chapterLoader] 负责按需取正文，便于上层的并发/缓存策略。
  Future<StructuredDocument> toDocument(
    List<OnlineChapter> chapters, {
    required Future<String> Function(OnlineChapter chapter) chapterLoader,
    int maxChapters = 30,
    void Function(int done, int total)? onProgress,
  }) async {
    final List<OnlineChapter> take = chapters.length > maxChapters
        ? chapters.sublist(0, maxChapters)
        : chapters;

    final List<Chapter> built = <Chapter>[];
    for (var i = 0; i < take.length; i++) {
      final OnlineChapter chapter = take[i];
      try {
        final String text = await chapterLoader(chapter);
        built.add(_toChapter(chapter.name, text));
      } catch (_) {
        // 单章失败：留一个占位章，避免整本打不开
        built.add(
          Chapter(
            title: chapter.name,
            paragraphs: const <Paragraph>[
              Paragraph(sentences: <Sentence>[Sentence('（本章获取失败）')]),
            ],
          ),
        );
      }
      onProgress?.call(i + 1, take.length);
    }

    return StructuredDocument(chapters: built);
  }

  Chapter _toChapter(String title, String text) {
    final List<String> blocks = text
        .split('\n')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    final List<Paragraph> paragraphs = <Paragraph>[
      for (final String block in blocks) _toParagraph(block),
    ];
    if (paragraphs.isEmpty) {
      paragraphs.add(const Paragraph(sentences: <Sentence>[Sentence('（空章节）')]));
    }
    return Chapter(title: title, paragraphs: paragraphs);
  }

  /// 按句号/问号/感叹号切句（中英文都覆盖）
  static Paragraph _toParagraph(String text) {
    final List<String> raw = text
        .split(RegExp(r'(?<=[。！？!?；;])'))
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    if (raw.isEmpty) {
      return const Paragraph(sentences: <Sentence>[Sentence('')]);
    }
    return Paragraph(sentences: <Sentence>[for (final String s in raw) Sentence(s)]);
  }

  // ---------------- 内部 ----------------

  Future<String> _request(
    String template, {
    required String operation,
    required Map<String, Object?> variables,
  }) async {
    try {
      final UrlRequest request = UrlTemplate.evaluate(
        template,
        variables: variables,
        baseUrl: rule.url,
        extraHeader: rule.header,
      );
      return await _http.fetch(
        request,
        timeout: Duration(milliseconds: rule.respondTime.clamp(5000, 60000)),
      );
    } on UnsupportedSourceException catch (e) {
      throw SourceOperationException(operation, e.reason);
    } catch (e) {
      throw SourceOperationException(operation, e.toString());
    }
  }

  /// 内容形态判定
  static ContentKind _kindOf(String body) {
    final String t = body.trimLeft();
    if (t.startsWith('{') || t.startsWith('[')) return ContentKind.json;
    if (t.startsWith('<')) return ContentKind.html;
    return ContentKind.text;
  }

  /// 宿主函数（`java.*` 的可实现子集）
  ///
  /// ⚠️ 只实现**纯计算**的那些。涉及 IO 的（`java.ajax`）与需要
  /// 完整 JS 语义的（`java.getString` 在 JS 里反向调引擎）**不实现** ——
  /// 它们一旦被调用会抛 `UnsupportedExpression`，源被标记不可用。
  static Map<String, Object? Function(List<Object?>)> _defaultFunctions() {
    return <String, Object? Function(List<Object?>)>{
      'java.encodeURI': (List<Object?> args) {
        if (args.isEmpty) return '';
        final Object? charset = args.length > 1 ? args[1] : null;
        final String s = args.first?.toString() ?? '';
        if (charset != null && charset.toString().toLowerCase() != 'utf-8') {
          // 非 UTF-8 编码需要真实转码表；这里只处理 UTF-8 与 escape
          if (charset.toString().toLowerCase() == 'escape') {
            return Uri.encodeComponent(s).replaceAll('%20', '+');
          }
          return Uri.encodeComponent(s);
        }
        return Uri.encodeComponent(s);
      },
      'java.encodeURI2': (List<Object?> args) =>
          args.isEmpty ? '' : Uri.encodeFull(args.first?.toString() ?? ''),
      'java.randomUUID': (List<Object?> args) {
        // 书源常用它做「反缓存」参数
        final int ms = DateTime.now().microsecondsSinceEpoch;
        final String hex = ms.toRadixString(16).padLeft(12, '0').toUpperCase();
        return '$hex-${hex.substring(0, 4)}-4${hex.substring(4, 7)}-'
            'a${hex.substring(7, 10)}-${hex.substring(0, 12)}';
      },
      'java.timeFormat': (List<Object?> args) {
        if (args.isEmpty) return '';
        final int? ms = int.tryParse(args.first?.toString() ?? '');
        final DateTime t = ms != null
            ? DateTime.fromMillisecondsSinceEpoch(ms)
            : DateTime.now();
        String two(int v) => v.toString().padLeft(2, '0');
        return '${t.year}-${two(t.month)}-${two(t.day)} '
            '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
      },
      'encodeURIComponent': (List<Object?> args) =>
          args.isEmpty ? '' : Uri.encodeComponent(args.first?.toString() ?? ''),
      'encodeURI': (List<Object?> args) =>
          args.isEmpty ? '' : Uri.encodeFull(args.first?.toString() ?? ''),
    };
  }

  void dispose() {
    if (_ownClient) _http.dispose();
  }
}

/// 把 HTML 片段转成「按段落分行」的纯文本
///
/// 规则：
/// 1. `<br>` / `</p>` / `</div>` 等块级结束标签 → 换行
/// 2. 去掉所有剩余标签
/// 3. 反转义 HTML 实体（`&nbsp;` / `&amp;` / 数字实体）
/// 4. 压缩连续空白与空行
String htmlToParagraphs(String input) {
  String text = input;

  // 0. **先整体删掉 script / style**（连同内容）
  //
  // ⚠️ 顺序要紧：如果先做「去标签」，`<script>alert(1)</script>` 会变成
  // 裸文本 `alert(1)` 留在正文里（实测踩到，正文混进 JS 代码）。
  text = text.replaceAll(
    RegExp(r'<script\b[^>]*>[\s\S]*?</script\s*>', caseSensitive: false),
    '',
  );
  text = text.replaceAll(
    RegExp(r'<style\b[^>]*>[\s\S]*?</style\s*>', caseSensitive: false),
    '',
  );
  // 自闭合 / 未闭合的也清掉
  text = text.replaceAll(RegExp(r'<script\b[^>]*/?>', caseSensitive: false), '');
  text = text.replaceAll(RegExp(r'<style\b[^>]*/?>', caseSensitive: false), '');

  // 1. 块级标签 → 换行（注意顺序：先 br，再段落容器）
  text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  text = text.replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n');
  text = text.replaceAll(RegExp(r'</div\s*>', caseSensitive: false), '\n');
  text = text.replaceAll(RegExp(r'</li\s*>', caseSensitive: false), '\n');

  // 2. 去标签
  text = text.replaceAll(RegExp(r'<[^>]+>'), '');

  // 3. 反转义
  text = text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&')
      .replaceAllMapped(RegExp(r'&#(\d+);'), (Match m) {
        final int? code = int.tryParse(m.group(1)!);
        if (code == null || code <= 0 || code > 0x10FFFF) return '';
        return String.fromCharCode(code);
      });

  // 4. 规范化空白：行内多空格压成一个，去掉空行
  final List<String> lines = text
      .replaceAll(RegExp(r'[\u3000\xA0]'), ' ')
      .split('\n')
      .map((String s) => s.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
      .where((String s) => s.isNotEmpty)
      .toList();

  return lines.join('\n');
}

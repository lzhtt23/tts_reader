/// CSS 选择器求值（对齐 legado `AnalyzeByJSoup.kt`）
///
/// ## legado 的 CSS 规则不是纯 CSS
///
/// 它有自己的一层语法，`@` 是最重要的分隔符：
///
/// ```
/// class.book-list@tag.li@tag.a.0@href
///  └─ 前置 ─┘  └─ 层级 ─┘ └索引┘ └末级┘
/// ```
///
/// 每段 `@` 之间是一个「取元素」步骤，最后一段可能是：
/// - 取值关键字（`text` / `html` / `ownText` / `textNodes` / `all`）
/// - 属性名（`href` / `src` / `content` …）
///
/// ## 前置选择器的特殊写法
///
/// 对齐 `AnalyzeByJSoup.kt:314-321`：
/// | 写法 | 含义 |
/// |---|---|
/// | `children` | 直接子元素 |
/// | `class.xxx` | 按 class |
/// | `tag.xxx` | 按标签名 |
/// | `id.xxx` | 按 id |
/// | `text.xxx` | 包含指定文本的元素 |
/// | 其它 | 交给 CSS 选择器 |
///
/// ## 索引语法（两套并存）
///
/// 注释见 `AnalyzeByJSoup.kt:282-292`：
/// - 老写法：`tag.div.-1:10:2`（`.` 选中 / `!` 排除，`:` 区间）
/// - 新写法：`tag.div[-1, 3:-2:-10, 2]`（`[!` 排除）
/// - 特例：`tag.div[-1:0]` **反向整个列表**
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// 索引片段的求值结果
class _IndexSpec {
  const _IndexSpec({
    required this.exclude,
    required this.items,
  });

  /// `!` 前缀 = 排除
  final bool exclude;

  /// 每项：单个下标或 (start, end, step)
  final List<Object> items;
}

/// CSS 规则求值器
class CssAnalyzer {
  CssAnalyzer(this.root);

  final dom.Element root;

  /// 求值，返回字符串列表（空表示没匹配到）
  ///
  /// [rule] 是**单段**规则（不含 `&&`/`||`/`%%`，那些由上层切分）
  List<String> evaluate(String rule) {
    final String trimmed = rule.trim();
    if (trimmed.isEmpty) return const <String>[];

    // 纯后缀规则：`@href` / `@text` / `@html`
    //
    // ⚠️ 这类规则**没有层级**，只作用于当前元素本身。
    // 若按 `@` 切分，开头的 `@` 会被当分隔符切掉，
    // 剩下的 `href` 又被当成元素选择器去查找 → 永远返回空。
    // legado 里 `chapterUrl: "@href"` 是最常见写法，必须走这条捷径。
    if (trimmed.startsWith('@') && !trimmed.startsWith('@@')) {
      final String suffix = trimmed.substring(1).trim();
      if (suffix.isNotEmpty && !suffix.contains('@')) {
        return _extract(<dom.Element>[root], suffix);
      }
    }

    // 按顶层 `@` 切成多级（跳过引号/括号内的 @）
    final List<String> steps = _splitAt(trimmed);
    if (steps.isEmpty) return const <String>[];

    var elements = <dom.Element>[root];

    // 最后一段决定「取什么」
    final int last = steps.length - 1;
    for (var i = 0; i < last; i++) {
      final String step = steps[i];
      final List<dom.Element> next = <dom.Element>[];
      for (final dom.Element el in elements) {
        next.addAll(_selectStep(el, step));
      }
      elements = next;
      if (elements.isEmpty) return const <String>[];
    }

    return _extract(elements, steps[last]);
  }

  /// 取元素（用于需要 Elements 而非字符串的场景，如 `getElement`）
  List<dom.Element> selectElements(String rule) {
    final List<String> steps = _splitAt(rule.trim());
    if (steps.isEmpty) return const <dom.Element>[];

    var elements = <dom.Element>[root];
    for (final String step in steps) {
      final List<dom.Element> next = <dom.Element>[];
      for (final dom.Element el in elements) {
        next.addAll(_selectStep(el, step));
      }
      elements = next;
      if (elements.isEmpty) break;
    }
    return elements;
  }

  // ---------------- 单步选择 ----------------

  List<dom.Element> _selectStep(dom.Element el, String step) {
    final String s = step.trim();
    if (s.isEmpty) return <dom.Element>[el];

    // 分离索引后缀
    final _ParsedStep parsed = _parseIndex(s);

    final List<dom.Element> base = _selectByPrefix(el, parsed.before);
    if (parsed.spec == null) return base;
    return _applyIndex(base, parsed.spec!);
  }

  /// 前置选择器（对齐 legado 的五种特殊写法 + 兜底 CSS）
  ///
  /// ⚠️ **必须包含 root 自身**：`CssAnalyzer.fromHtml` 的 root 已经是
  /// 片段根元素（如 `<div class="chapters">`），而规则写成
  /// `class.chapters@tag.a` 时第一段要匹配的正是这个 root 自己。
  /// `getElementsByClassName` 只查子孙，会漏掉它。
  List<dom.Element> _selectByPrefix(dom.Element el, String before) {
    final String b = before.trim();
    if (b.isEmpty) {
      // 空前置 = 直接子元素（legado: temp.children()）
      return el.children.toList(growable: false);
    }

    final List<String> parts = b.split('.');
    if (parts.length >= 2) {
      final String head = parts[0];
      final String arg = parts.sublist(1).join('.');
      switch (head) {
        case 'children':
          return el.children.toList(growable: false);
        case 'class':
          final List<dom.Element> out = <dom.Element>[];
          if (el.classes.contains(arg)) out.add(el);
          out.addAll(el.getElementsByClassName(arg));
          return out;
        case 'tag':
          final List<dom.Element> out = <dom.Element>[];
          if (el.localName == arg) out.add(el);
          out.addAll(el.getElementsByTagName(arg));
          return out;
        case 'id':
          final List<dom.Element> all = el.getElementsByTagName('*').toList();
          if (el.id == arg) all.insert(0, el);
          return all.where((dom.Element e) => e.id == arg).toList(growable: false);
        case 'text':
          final List<dom.Element> out = <dom.Element>[];
          if (el.text.contains(arg)) out.add(el);
          out.addAll(
            el.getElementsByTagName('*').where((dom.Element e) => e.text.contains(arg)),
          );
          return out;
      }
    }

    // 兜底：当 CSS 选择器（同样把 root 自身纳入候选）
    //
    // `package:html` 的 Element 没有 `matches()`。做法：
    // 用临时容器包住 root 的 outerHtml，然后 `querySelectorAll(b)`，
    // 再判断**结果里除 root 外的元素数**是否与「不含 root 的查询」一致 ——
    // 不一致说明 root 自己也被选中了。
    //
    // 更简单可靠的做法：先只查后代（`el.querySelectorAll`），
    // 再用一个只有 root 的探针判断 root 是否满足。
    try {
      final List<dom.Element> out = <dom.Element>[];

      // ① 判断 root 自身是否满足（探针里把 root 包在一层 div 中）
      //
      // ⚠️ 不能只看「querySelectorAll 非空」—— 后代也会命中。
      // 必须比对元素个数：root 自己的 outerHtml 被包进去后，
      // 若 root 满足选择器，命中数会比「只查后代」多 1。
      final dom.Document probe = html_parser.parse(
        '<div id="__probe__">${el.outerHtml}</div>',
      );
      final dom.Element? probeRoot = probe.getElementById('__probe__');
      if (probeRoot != null) {
        final int withRoot = probeRoot.querySelectorAll(b).length;
        final int withoutRoot = el.querySelectorAll(b).length;
        if (withRoot > withoutRoot) out.add(el);
      }

      // ② 后代
      out.addAll(el.querySelectorAll(b));
      return out;
    } catch (_) {
      return const <dom.Element>[];
    }
  }

  /// 解析索引后缀，返回「前置规则」与「索引规格」
  ///
  /// 支持两种写法：
  /// - `xxx[1, 2:-1, 0:-1:2]` / `xxx[!0, 4]`
  /// - `xxx.-1:10:2` / `xxx!0:3`
  _ParsedStep _parseIndex(String step) {
    final String s = step.trim();

    // ① 方括号写法
    if (s.endsWith(']')) {
      final int open = s.lastIndexOf('[');
      if (open >= 0) {
        final String inside = s.substring(open + 1, s.length - 1);
        // 排除 CSS 属性选择器：`[href="x"]` 里含引号或等号，不可能是索引
        if (!inside.contains('"') &&
            !inside.contains("'") &&
            !inside.contains('=') &&
            RegExp(r'^[\s\d,:\-!]+$').hasMatch(inside)) {
          final bool exclude = inside.trimLeft().startsWith('!');
          final String body = exclude ? inside.trimLeft().substring(1) : inside;
          final List<Object> items = <Object>[];
          for (final String piece in body.split(',')) {
            final Object? item = _parseIndexItem(piece.trim());
            if (item != null) items.add(item);
          }
          if (items.isNotEmpty) {
            return _ParsedStep(
              s.substring(0, open),
              _IndexSpec(exclude: exclude, items: items),
            );
          }
        }
      }
    }

    // ② 老写法：`.-1:10:2` 或 `!0:3`
    //    判据：从末尾往前找到 `!` 或 `.`，其后必须全是数字/冒号/负号
    final RegExpMatch? m = RegExp(r'([.!])([\d:\-\s]+)$').firstMatch(s);
    if (m != null) {
      final String body = m.group(2)!;
      if (RegExp(r'^[\s\d:\-]+$').hasMatch(body)) {
        final bool exclude = m.group(1) == '!';
        final List<Object> items = <Object>[];
        for (final String piece in body.split(',')) {
          final Object? item = _parseIndexItem(piece.trim());
          if (item != null) items.add(item);
        }
        if (items.isNotEmpty) {
          return _ParsedStep(
            s.substring(0, m.start),
            _IndexSpec(exclude: exclude, items: items),
          );
        }
      }
    }

    return _ParsedStep(s, null);
  }

  /// 解析单段索引：`3` 或 `start:end` 或 `start:end:step`
  Object? _parseIndexItem(String piece) {
    if (piece.isEmpty) return null;
    final List<String> parts = piece.split(':');
    if (parts.length == 1) {
      final int? v = int.tryParse(parts[0].trim());
      return v;
    }
    final int? start = parts[0].trim().isEmpty ? null : int.tryParse(parts[0].trim());
    final int? end = parts.length > 1 && parts[1].trim().isNotEmpty
        ? int.tryParse(parts[1].trim())
        : null;
    final int step = parts.length > 2 && parts[2].trim().isNotEmpty
        ? (int.tryParse(parts[2].trim()) ?? 1)
        : 1;
    return _Range(start, end, step);
  }

  /// 按索引规格筛选
  List<dom.Element> _applyIndex(List<dom.Element> elements, _IndexSpec spec) {
    final int len = elements.length;
    if (len == 0) return elements;

    final Set<int> picked = <int>{};
    var reversed = false;
    for (final Object item in spec.items) {
      if (item is int) {
        final int idx = item < 0 ? item + len : item;
        if (idx >= 0 && idx < len) picked.add(idx);
      } else if (item is _Range) {
        // 特殊用法 `[-1:0]`：整个列表反向
        //
        // ⚠️ 必须在「负数归一化」**之前**判断：
        // `-1` 归一化后会变成 `len-1`，就再也认不出这个约定用法了。
        if (item.start == -1 && item.end == 0) {
          reversed = true;
          continue;
        }

        // 区间：对齐 legado —— 负数从尾部数
        int start = item.start ?? 0;
        if (start < 0) start += len;
        int end = item.end ?? (len - 1);
        if (end < 0) end += len;

        if ((start < 0 && end < 0) || (start >= len && end >= len)) continue;
        if (start < 0) start = 0;
        if (start >= len) start = len - 1;
        if (end < 0) end = 0;
        if (end >= len) end = len - 1;

        int step = item.step;
        if (step == 0) step = 1;
        if (step > 0) {
          for (var i = start; i <= end; i += step) {
            picked.add(i);
          }
        } else {
          for (var i = start; i >= end; i += step) {
            picked.add(i);
          }
        }
      }
    }

    if (spec.exclude) {
      return <dom.Element>[
        for (var i = 0; i < len; i++)
          if (!picked.contains(i)) elements[i],
      ];
    }

    // 反向：`[-1:0]` 的约定用法，保持倒序
    if (reversed) {
      return <dom.Element>[for (var i = len - 1; i >= 0; i--) elements[i]];
    }

    // 选中模式：legado 保留索引集合的插入顺序（区间是逆向插入后还原的），
    // 这里按升序输出 —— 对绝大多数用例结果一致且更可预测。
    final List<int> sorted = picked.toList()..sort();
    return <dom.Element>[for (final int i in sorted) if (i < len) elements[i]];
  }

  // ---------------- 末级取值 ----------------

  List<String> _extract(List<dom.Element> elements, String last) {
    final String key = last.trim();
    if (elements.isEmpty) return const <String>[];

    final List<String> out = <String>[];
    switch (key) {
      case 'text':
        for (final dom.Element e in elements) {
          final String t = e.text.trim();
          if (t.isNotEmpty) out.add(t);
        }
        break;
      case 'textNodes':
        for (final dom.Element e in elements) {
          final List<String> lines = e.nodes
              .whereType<dom.Text>()
              .map((dom.Text n) => n.text.trim())
              .where((String s) => s.isNotEmpty)
              .toList();
          if (lines.isNotEmpty) out.add(lines.join('\n'));
        }
        break;
      case 'ownText':
        for (final dom.Element e in elements) {
          final String t = e.nodes
              .whereType<dom.Text>()
              .map((dom.Text n) => n.text)
              .join()
              .trim();
          if (t.isNotEmpty) out.add(t);
        }
        break;
      case 'html':
        for (final dom.Element e in elements) {
          final dom.Element clone = e.clone(true);
          for (final dom.Element s in clone.querySelectorAll('script, style')) {
            s.remove();
          }
          final String html = clone.innerHtml.trim();
          if (html.isNotEmpty) out.add(html);
        }
        break;
      case 'all':
        for (final dom.Element e in elements) {
          final String html = e.outerHtml;
          if (html.isNotEmpty) out.add(html);
        }
        break;
      default:
        // 当属性名
        if (key.isNotEmpty) {
          for (final dom.Element e in elements) {
            final String v = e.attributes[key]?.trim() ?? '';
            if (v.isNotEmpty && !out.contains(v)) out.add(v);
          }
        }
        break;
    }
    return out;
  }

  // ---------------- 工具 ----------------

  /// 按顶层 `@` 切分（跳过引号、方括号、圆括号内的 @）
  static List<String> _splitAt(String rule) {
    final List<String> out = <String>[];
    final StringBuffer buf = StringBuffer();
    var square = 0;
    var paren = 0;
    var inSingle = false;
    var inDouble = false;

    for (var i = 0; i < rule.length; i++) {
      final String c = rule[i];
      if (c == r'\' && i + 1 < rule.length) {
        buf.write(c);
        buf.write(rule[i + 1]);
        i++;
        continue;
      }
      if (c == "'" && !inDouble) {
        inSingle = !inSingle;
      } else if (c == '"' && !inSingle) {
        inDouble = !inDouble;
      } else if (!inSingle && !inDouble) {
        if (c == '[') square++;
        if (c == ']' && square > 0) square--;
        if (c == '(') paren++;
        if (c == ')' && paren > 0) paren--;
        if (c == '@' && square == 0 && paren == 0) {
          out.add(buf.toString());
          buf.clear();
          continue;
        }
      }
      buf.write(c);
    }
    out.add(buf.toString());

    // 去掉首尾空白段
    return out
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList(growable: false);
  }

  /// 从 HTML 文本构造
  ///
  /// ## 为什么要取 body 的第一个子元素
  ///
  /// `html_parser.parse('<a href="/x">文</a>')` 会补成
  /// `<html><head></head><body><a ...>文</a></body></html>`。
  /// 如果拿 `documentElement`（即 `<html>`）当 root，
  /// 那么 `@href` 这种「只作用于当前元素」的规则会取 `<html href>` → 空。
  ///
  /// 书源的字段规则（`@text` / `@href`）都期望作用在**片段根元素**上，
  /// 所以这里取 body 的唯一子元素当 root；片段有多个顶层元素时退回 body。
  static CssAnalyzer fromHtml(String html) {
    final dom.Document doc = html_parser.parse(html);
    final dom.Element? body = doc.body;
    if (body != null) {
      final List<dom.Element> children = body.children;
      if (children.length == 1) {
        return CssAnalyzer(children.first);
      }
      return CssAnalyzer(body);
    }
    return CssAnalyzer(doc.documentElement!);
  }
}

class _ParsedStep {
  const _ParsedStep(this.before, this.spec);

  final String before;
  final _IndexSpec? spec;
}

class _Range {
  const _Range(this.start, this.end, this.step);

  final int? start;
  final int? end;
  final int step;

  @override
  String toString() => 'Range($start,$end,$step)';
}

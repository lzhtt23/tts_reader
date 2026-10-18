/// legado 规则切分器（对应 `RuleAnalyzer.kt`）
///
/// ## 为什么不能简单 `split`
///
/// legado 原注释写得很清楚（`RuleAnalyzer.kt:161-164`）：
///
/// > 解决 jsonPath 自带的 `&&` 和 `||` 与阅读的规则冲突，
/// > 以及规则正则或字符串中包含 `&&`、`||`、`%%`、`@` 导致的冲突
///
/// 举例：`$.a||$.b` 要拆成两段，但 `tag.div[data-x="a||b"]` 里的 `||`
/// **不能**拆 —— 它在引号里。同理 `##正则##替换` 里的 `@` 也不能当层级分隔。
///
/// 所以必须做**括号 + 引号平衡扫描**。本文件是 `RuleAnalyzer` 的等价实现。
///
/// ## 与 Kotlin 版的差异
///
/// - Kotlin 用 `pos`/`start`/`startX` 三个可变字段 + 尾递归；
///   这里改成显式游标参数，行为等价但更易读、无栈风险。
/// - 只保留**规则求值需要**的部分：`splitRule` / `innerRule`。
///   `@put:` 等由 `RuleParser` 处理，不在这里。
library;

/// 切分结果的类型标记（对应 legado `RuleAnalyzer.elementsType`）
class SplitResult {
  const SplitResult(this.segments, this.elementsType);

  /// 切出来的各段
  final List<String> segments;

  /// 实际匹配到的分隔符（`&&` / `||` / `%%` / `@`）；没匹配到时为空串
  ///
  /// 上层靠它决定「取第一个非空」还是「合并」
  final String elementsType;

  @override
  String toString() => 'SplitResult($elementsType, $segments)';
}

/// 规则切分器
class RuleAnalyzer {
  RuleAnalyzer(this.queue);

  /// 被处理的字符串
  final String queue;

  /// 转义字符（对齐 Kotlin `private const val ESC = '\\'`）
  static const String _esc = r'\';

  /// 按多个分隔符切分，**跳过引号内与括号内的分隔符**
  ///
  /// 语义对齐 `RuleAnalyzer.splitRule(vararg split)`：
  /// - 传入多个分隔符时，取**最先出现**的那个作为 `elementsType`
  /// - 之后所有同种分隔符都切
  ///
  /// 例：`'a&&b||c'`（split = `&&`, `||`, `%%`）→ `['a','b||c']`？
  ///
  /// 不 —— legado 的行为是：`&&` 先出现就用 `&&` 切，
  /// 得到 `['a', 'b||c']`。**只切一种**。这是刻意的：
  /// 混用不同运算符的结果没有定义，取先出现的那个。
  SplitResult splitRule(List<String> split) {
    if (split.isEmpty) return SplitResult(<String>[queue], '');

    // 找出第一个「不在引号/括号内」的分隔符出现位置
    final _Hit? first = _findFirstTopLevel(split, 0);
    if (first == null) {
      return SplitResult(<String>[queue], '');
    }

    final String sep = first.separator;
    final List<String> segments = <String>[];
    var start = 0;
    var searchFrom = 0;

    while (true) {
      final _Hit? hit = _findFirstTopLevel(<String>[sep], searchFrom);
      if (hit == null) {
        segments.add(queue.substring(start));
        break;
      }
      segments.add(queue.substring(start, hit.index));
      start = hit.index + sep.length;
      searchFrom = start;
    }

    return SplitResult(
      segments.map((String s) => s.trim()).toList(growable: false),
      sep,
    );
  }

  /// 找出 `from` 之后第一个**顶层**（不在引号/括号内）的任意分隔符
  _Hit? _findFirstTopLevel(List<String> seps, int from) {
    var i = from;
    var depthSquare = 0; // [ ]
    var depthParen = 0; // ( )
    var depthBrace = 0; // { }
    var inSingle = false;
    var inDouble = false;

    while (i < queue.length) {
      final String c = queue[i];

      // 引号优先级最高：引号内一切原样
      if (c == _esc) {
        i += 2; // 跳过转义的下一个字符
        continue;
      }
      if (c == "'" && !inDouble) {
        inSingle = !inSingle;
        i++;
        continue;
      }
      if (c == '"' && !inSingle) {
        inDouble = !inDouble;
        i++;
        continue;
      }
      if (inSingle || inDouble) {
        i++;
        continue;
      }

      // 括号计数（注意 `[` 在正则里也常见，但正则通常在引号或 ## 之后）
      if (c == '[') {
        depthSquare++;
        i++;
        continue;
      }
      if (c == ']') {
        if (depthSquare > 0) depthSquare--;
        i++;
        continue;
      }
      if (c == '(') {
        depthParen++;
        i++;
        continue;
      }
      if (c == ')') {
        if (depthParen > 0) depthParen--;
        i++;
        continue;
      }
      if (c == '{') {
        depthBrace++;
        i++;
        continue;
      }
      if (c == '}') {
        if (depthBrace > 0) depthBrace--;
        i++;
        continue;
      }

      // 只在完全顶层时认分隔符
      if (depthSquare == 0 && depthParen == 0 && depthBrace == 0) {
        for (final String sep in seps) {
          if (queue.startsWith(sep, i)) {
            return _Hit(i, sep);
          }
        }
      }
      i++;
    }
    return null;
  }

  /// 替换内嵌规则，如 `{{ ... }}`
  ///
  /// 语义对齐 `RuleAnalyzer.innerRule(inner, startStep, endStep, fr)`：
  /// - 找到 `inner` 起点后，要求紧跟一个**平衡**的 `{ }` / `( )` 组
  /// - 组内内容交给 [fr] 求值；返回 null/空 时**保留原样**继续找下一个
  ///
  /// ⚠️ legado 的实现里 `startStep`/`endStep` 默认 1，
  /// 即 `{{expr}}` 会取 `expr`（去掉一层花括号）。
  String replaceInnerBraces(String Function(String expr) fr) {
    final StringBuffer out = StringBuffer();
    var i = 0;
    var lastCopied = 0;

    while (i < queue.length) {
      if (!queue.startsWith('{{', i)) {
        i++;
        continue;
      }
      final int contentStart = i + 2;
      final int? close = _findBalancedClose(contentStart, '{', '}');
      if (close == null) {
        // 不平衡：把 `{{` 当普通文本，继续
        i += 2;
        continue;
      }
      // `{{` ... `}}`：结束位置是两个 `}`
      if (close + 1 >= queue.length || queue[close + 1] != '}') {
        i += 2;
        continue;
      }
      final String expr = queue.substring(contentStart, close);
      final String value = fr(expr);
      out.write(queue.substring(lastCopied, i));
      // 求值为空时不写内容，但**必须把原文吃掉** ——
      // 否则 `{{xxx}}` 会原样留在规则里，被当成选择器或 JSONPath 的一部分，
      // 最终整条规则匹配不到东西（实测就是这个症状）。
      out.write(value);
      i = close + 2;
      lastCopied = i;
    }

    if (lastCopied == 0) return queue;
    out.write(queue.substring(lastCopied));
    return out.toString();
  }

  /// 从 [start] 开始找与开的 `{` 配对的 `}` 的位置（不包含）
  ///
  /// 处理嵌套、引号、转义 —— 对齐 `chompCodeBalanced`。
  int? _findBalancedClose(int start, String open, String close) {
    var depth = 0;
    var i = start;
    var inSingle = false;
    var inDouble = false;

    while (i < queue.length) {
      final String c = queue[i];
      if (c == _esc) {
        i += 2;
        continue;
      }
      if (c == "'" && !inDouble) {
        inSingle = !inSingle;
        i++;
        continue;
      }
      if (c == '"' && !inSingle) {
        inDouble = !inDouble;
        i++;
        continue;
      }
      if (inSingle || inDouble) {
        i++;
        continue;
      }
      if (c == open) {
        depth++;
      } else if (c == close) {
        if (depth == 0) return i;
        depth--;
      }
      i++;
    }
    return null;
  }
}

class _Hit {
  const _Hit(this.index, this.separator);

  final int index;
  final String separator;
}

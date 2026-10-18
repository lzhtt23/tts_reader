/// 表达式求值器 —— **不引入 JS 引擎**的替代方案
///
/// ## 为什么自己写而不塞 JS
///
/// 从 194 条真实书源统计（`work/legado-src/real_book_sources.json`）：
///
/// | 分类 | 条数 | 占比 |
/// |---|---|---|
/// | 完全不需要表达式 | 2 | 1% |
/// | **只需简单表达式** | **161** | **83%** |
/// | 需要 JS 控制流（`var`/`if`/`for`/箭头函数） | 31 | 16% |
///
/// 引一个 JS 引擎（flutter_js / flutter_qjs）代价是：APK +5~10 MB、
/// 需要额外原生编译、启动开销。而它换来的是**16% 的额外覆盖**。
///
/// 所以这里实现一个**递归下降表达式求值器**，覆盖那 83%：
/// 算术、字符串、三元、函数调用、属性访问。
/// 遇到控制流（`var ` / `if(` / `=>` / `;` 多条语句）直接抛
/// [UnsupportedExpression]，由上层标记「此源不支持」，**不静默给错结果**。
///
/// ## 支持的能力（均来自真实书源样本）
///
/// ```
/// 算术     page-1, (page-1)*18, 24*(page-1)
/// 字符串   'index_' + page, baseUrl.replace('.htm','/')
/// 三元     page-1==0 ? 'index' : 'index_'+page
/// 成员     book.name, chapter.title, source.getKey()
/// 函数     java.encodeURI(key), java.timeFormat(x)
/// 正则     baseUrl.match(/(\d+).$/)[1]
/// 数组     key[0], String(result[0])
/// ```
library;

/// 表达式里不支持的语法（上层据此判定「此源不可用」）
class UnsupportedExpression implements Exception {
  const UnsupportedExpression(this.reason, [this.expr]);

  final String reason;
  final String? expr;

  @override
  String toString() =>
      'UnsupportedExpression($reason${expr == null ? '' : ': $expr'})';
}

/// 求值上下文：暴露给表达式的变量与宿主函数
class EvalContext {
  EvalContext({
    Map<String, Object?>? variables,
    Map<String, Object? Function(List<Object?> args)>? functions,
  }) : variables = variables ?? <String, Object?>{},
       functions = functions ?? <String, Object? Function(List<Object?>)>{};

  /// 变量（`page` / `key` / `baseUrl` / `result` / `book` …）
  final Map<String, Object?> variables;

  /// 宿主函数（`java.encodeURI` / `java.timeFormat` …）
  ///
  /// 键是**完整路径**：`'java.encodeURI'`
  final Map<String, Object? Function(List<Object?> args)> functions;

  Object? lookup(String name) => variables[name];

  Object? call(String name, List<Object?> args) {
    final Object? Function(List<Object?>)? fn = functions[name];
    if (fn == null) {
      throw UnsupportedExpression('未知函数 $name');
    }
    return fn(args);
  }

  @override
  String toString() => 'EvalContext(vars=${variables.keys.join(",")})';
}

/// 表达式求值器
///
/// 用法：
/// ```dart
/// final v = ExpressionEvaluator('(page-1)*18', ctx).evaluate();
/// ```
class ExpressionEvaluator {
  ExpressionEvaluator(this.source, this.context);

  final String source;
  final EvalContext context;

  late final List<_Token> _tokens = _tokenize(source);
  int _pos = 0;

  /// 求值入口
  Object? evaluate() {
    // 预检：含控制流特征直接拒绝（避免半懂不懂地算错）
    _rejectControlFlow(source);

    if (_tokens.isEmpty) return '';
    final Object? value = _parseExpression();
    if (_pos < _tokens.length) {
      throw UnsupportedExpression('表达式未完全消费', source);
    }
    return value;
  }

  /// 识别「需要 JS 控制流」的表达式，明确拒绝而不是算错
  static void _rejectControlFlow(String expr) {
    final String s = expr;
    // 多条语句
    if (RegExp(r';\s*\S').hasMatch(s)) {
      throw UnsupportedExpression('多条语句', expr);
    }
    // 声明
    if (RegExp(r'\b(var|let|const)\s').hasMatch(s)) {
      throw UnsupportedExpression('变量声明', expr);
    }
    // 条件/循环
    if (RegExp(r'\bif\s*\(').hasMatch(s) ||
        RegExp(r'\bfor\s*\(').hasMatch(s) ||
        RegExp(r'\bwhile\s*\(').hasMatch(s) ||
        RegExp(r'\bfunction\b').hasMatch(s)) {
      throw UnsupportedExpression('控制流', expr);
    }
    // 箭头函数
    if (RegExp(r'=>').hasMatch(s) || RegExp(r'\bArray\.from\b').hasMatch(s)) {
      throw UnsupportedExpression('函数式构造', expr);
    }
  }

  // ---------------- 递归下降 ----------------

  /// expression := ternary
  Object? _parseExpression() => _parseTernary();

  /// ternary := or ( '?' ternary ':' ternary )?
  Object? _parseTernary() {
    final Object? cond = _parseOr();
    if (_match('?')) {
      final Object? a = _parseTernary();
      _expect(':');
      final Object? b = _parseTernary();
      return _truthy(cond) ? a : b;
    }
    return cond;
  }

  Object? _parseOr() {
    Object? left = _parseAnd();
    while (_match('||')) {
      final Object? right = _parseAnd();
      left = _truthy(left) ? left : right;
    }
    return left;
  }

  Object? _parseAnd() {
    Object? left = _parseEquality();
    while (_match('&&')) {
      final Object? right = _parseEquality();
      left = _truthy(left) ? right : left;
    }
    return left;
  }

  Object? _parseEquality() {
    Object? left = _parseComparison();
    while (true) {
      if (_match('===') || _match('==')) {
        final Object? right = _parseComparison();
        left = _looseEquals(left, right);
      } else if (_match('!==') || _match('!=')) {
        final Object? right = _parseComparison();
        left = !_looseEquals(left, right);
      } else {
        return left;
      }
    }
  }

  Object? _parseComparison() {
    Object? left = _parseAdditive();
    while (true) {
      if (_match('<=')) {
        left = _toNum(left) <= _toNum(_parseAdditive());
      } else if (_match('>=')) {
        left = _toNum(left) >= _toNum(_parseAdditive());
      } else if (_match('<')) {
        left = _toNum(left) < _toNum(_parseAdditive());
      } else if (_match('>')) {
        left = _toNum(left) > _toNum(_parseAdditive());
      } else {
        return left;
      }
    }
  }

  Object? _parseAdditive() {
    Object? left = _parseMultiplicative();
    while (true) {
      if (_match('+')) {
        final Object? right = _parseMultiplicative();
        left = _plus(left, right);
      } else if (_match('-')) {
        final Object? right = _parseMultiplicative();
        left = _toNum(left) - _toNum(right);
      } else {
        return left;
      }
    }
  }

  Object? _parseMultiplicative() {
    Object? left = _parseUnary();
    while (true) {
      if (_match('*')) {
        left = _toNum(left) * _toNum(_parseUnary());
      } else if (_match('/')) {
        final num r = _toNum(_parseUnary());
        left = r == 0 ? double.nan : _toNum(left) / r;
      } else if (_match('%')) {
        final num r = _toNum(_parseUnary());
        left = r == 0 ? double.nan : _toNum(left) % r;
      } else {
        return left;
      }
    }
  }

  Object? _parseUnary() {
    if (_match('!')) return !_truthy(_parseUnary());
    if (_match('-')) return -_toNum(_parseUnary());
    if (_match('+')) return _toNum(_parseUnary());
    return _parsePostfix();
  }

  /// 后缀：属性访问 `.x`、下标 `[i]`、调用 `(args)`
  Object? _parsePostfix() {
    Object? value = _parsePrimary();

    while (true) {
      if (_match('.')) {
        final String name = _expectIdentifier();
        // 方法调用：`.replace(a,b)` / `.match(re)`
        // ⚠️ 此处 `_pos` 已指向 `(`，**不要再回退** —— 回退会取到标识符而不是左括号。
        if (_peekIs('(')) {
          final List<Object?> args = _parseArgs();
          value = _callMethod(value, name, args);
        } else {
          value = _getMember(value, name);
        }
      } else if (_peekIs('[')) {
        _match('[');
        final Object? idx = _parseExpression();
        _expect(']');
        value = _getIndex(value, idx);
      } else if (_peekIs('(') && value is _FunctionRef) {
        final List<Object?> args = _parseArgs();
        value = _callGlobal(value.name, args);
      } else {
        return value;
      }
    }
  }

  Object? _parsePrimary() {
    final _Token? t = _current;
    if (t == null) throw UnsupportedExpression('表达式意外结束', source);

    // 括号
    if (t.isOp('(')) {
      _pos++;
      final Object? v = _parseExpression();
      _expect(')');
      return v;
    }

    // 字符串
    if (t.type == _TokenType.string) {
      _pos++;
      return t.value;
    }

    // 数字
    if (t.type == _TokenType.number) {
      _pos++;
      return t.value;
    }

    // 正则字面量（只在参数位置出现，如 `.match(/re/)`）
    if (t.type == _TokenType.regex) {
      _pos++;
      return t.value;
    }

    // 标识符 / 关键字
    if (t.type == _TokenType.identifier) {
      _pos++;
      final String name = t.value! as String;
      switch (name) {
        case 'true':
          return true;
        case 'false':
          return false;
        case 'null':
        case 'undefined':
          return null;
      }
      if (_peekIs('(')) {
        return _FunctionRef(name);
      }
      // `java.xxx` 会被 token 化成 `java` `.` `xxx`，
      // 在 `_parsePostfix` 里拼成 `java.xxx` 再调用。
      //
      // ⚠️ `java` 本身不是变量，必须返回函数引用而不是 null ——
      // 否则 `java.encodeURI(x)` 会在 `.` 断言之前就断掉。
      if (name == 'java' || name == 'Math' || name == 'JSON' || name == 'Date') {
        return _FunctionRef(name);
      }
      final Object? v = context.lookup(name);
      if (v != null) return v;
      return null;
    }

    throw UnsupportedExpression('无法识别 token: ${t.raw}', source);
  }

  List<Object?> _parseArgs() {
    _expect('(');
    final List<Object?> args = <Object?>[];
    if (_match(')')) return args;
    do {
      args.add(_parseExpression());
    } while (_match(','));
    _expect(')');
    return args;
  }

  // ---------------- 全局函数（String / parseInt / encodeURIComponent …） ----------------

  /// 调用全局函数
  ///
  /// 先查宿主函数表（`java.xxx`），再落到内建（`String` / `Number` 等）。
  /// 两者都没有才报错 —— 这样「书源调了未实现的方法」会明确失败，
  /// 而不是静默返回空串污染结果。
  Object? _callGlobal(String name, List<Object?> args) {
    // 宿主函数优先（`java.encodeURI` / `java.timeFormat` …）
    if (context.functions.containsKey(name)) {
      return context.call(name, args);
    }

    switch (name) {
      case 'String':
        return _toString(args.isEmpty ? null : args.first);
      case 'Number':
        return _toNum(args.isEmpty ? null : args.first);
      case 'parseInt':
        if (args.isEmpty) return 0;
        return int.tryParse(_toString(args.first).trim()) ?? 0;
      case 'parseFloat':
        if (args.isEmpty) return 0.0;
        return double.tryParse(_toString(args.first).trim()) ?? 0.0;
      case 'encodeURIComponent':
        return Uri.encodeComponent(args.isEmpty ? '' : _toString(args.first));
      case 'encodeURI':
        // encodeURI 不转义 : / ? # [ ] @ ! $ & ' ( ) * + , ; =
        return Uri.encodeFull(args.isEmpty ? '' : _toString(args.first));
      case 'decodeURIComponent':
        return Uri.decodeComponent(args.isEmpty ? '' : _toString(args.first));
      case 'isNaN':
        final num n = _toNum(args.isEmpty ? null : args.first);
        return n.isNaN;
      case 'Math.round':
        return _toNum(args.isEmpty ? null : args.first).round();
      case 'Math.floor':
        return _toNum(args.isEmpty ? null : args.first).floor();
      case 'Math.ceil':
        return _toNum(args.isEmpty ? null : args.first).ceil();
      case 'Math.max':
        if (args.isEmpty) return 0;
        return args.map(_toNum).reduce((num a, num b) => a > b ? a : b);
      case 'Math.min':
        if (args.isEmpty) return 0;
        return args.map(_toNum).reduce((num a, num b) => a < b ? a : b);
      case 'Math.abs':
        return _toNum(args.isEmpty ? null : args.first).abs();
      case 'Math.random':
        return DateTime.now().microsecondsSinceEpoch % 1000000 / 1000000;
    }

    throw UnsupportedExpression('未知函数 $name');
  }

  // ---------------- 成员与调用 ----------------

  Object? _getMember(Object? target, String name) {
    // `java.xxx`：拼成函数引用
    if (target is _FunctionRef) {
      return _FunctionRef('${target.name}.$name');
    }
    if (target is Map) {
      return target[name];
    }
    if (target is String && name == 'length') {
      return target.length;
    }
    if (target is List && name == 'length') {
      return target.length;
    }
    return null;
  }

  Object? _callMethod(Object? target, String name, List<Object?> args) {
    // `java.encodeURI(...)` —— 被调用者是 _FunctionRef。
    // 此时参数已经解析完，直接按「完整函数名」去调用宿主函数表。
    if (target is _FunctionRef) {
      final String full = '${target.name}.$name';
      if (context.functions.containsKey(full)) {
        return context.call(full, args);
      }
      // 也允许 `Math.round(x)` 这类内建
      return _callGlobal(full, args);
    }

    final String? s = target is String ? target : null;
    switch (name) {
      case 'replace':
        if (s == null && target is! String) break;
        if (args.length < 2) {
          throw const UnsupportedExpression('replace 参数不足');
        }
        final Object? pattern = args[0];
        final String replacement = _toString(args[1]);
        if (pattern is _RegexValue) {
          return _toStr(target).replaceAll(pattern.regex, replacement);
        }
        return _toStr(target).replaceAll(_toString(pattern), replacement);

      case 'replaceAll':
        if (args.length < 2) {
          throw const UnsupportedExpression('replaceAll 参数不足');
        }
        final Object? p = args[0];
        if (p is _RegexValue) {
          return _toStr(target).replaceAll(p.regex, _toString(args[1]));
        }
        return _toStr(target).replaceAll(_toString(p), _toString(args[1]));

      case 'match':
        if (args.isEmpty) {
          throw const UnsupportedExpression('match 参数不足');
        }
        final Object? p = args[0];
        final RegExp re = p is _RegexValue ? p.regex : RegExp(_toString(p));
        final RegExpMatch? m = re.firstMatch(_toStr(target));
        if (m == null) return null;
        final List<Object?> groups = <Object?>[m.group(0)];
        for (var i = 1; i <= m.groupCount; i++) {
          groups.add(m.group(i));
        }
        return groups;

      case 'toString':
        return _toString(target);

      case 'trim':
        return _toStr(target).trim();

      case 'toUpperCase':
        return _toStr(target).toUpperCase();

      case 'toLowerCase':
        return _toStr(target).toLowerCase();

      case 'split':
        if (args.isEmpty) {
          throw const UnsupportedExpression('split 参数不足');
        }
        final Object? p = args[0];
        final RegExp re = p is _RegexValue ? p.regex : RegExp(_escapeRegex(_toString(p)));
        return _toStr(target).split(re);

      case 'join':
        if (target is! List) return '';
        return target.map(_toString).join(args.isEmpty ? ',' : _toString(args[0]));

      case 'substring':
        if (target is! String) break;
        if (args.isEmpty) return target;
        final int start = _toNum(args[0]).toInt();
        final int? end = args.length > 1 ? _toNum(args[1]).toInt() : null;
        final int a = start.clamp(0, target.length);
        final int b = (end ?? target.length).clamp(0, target.length);
        return a <= b ? target.substring(a, b) : '';

      case 'indexOf':
        if (args.isEmpty) return -1;
        return _toStr(target).indexOf(_toString(args[0]));

      case 'includes':
        if (args.isEmpty) return false;
        return _toStr(target).contains(_toString(args[0]));

      case 'slice':
        if (target is String) {
          if (args.isEmpty) return target;
          final int start = _toNum(args[0]).toInt();
          final int? end = args.length > 1 ? _toNum(args[1]).toInt() : null;
          final int a = start < 0 ? (target.length + start).clamp(0, target.length) : start.clamp(0, target.length);
          final int b = end == null
              ? target.length
              : (end < 0 ? (target.length + end).clamp(0, target.length) : end.clamp(0, target.length));
          return a <= b ? target.substring(a, b) : '';
        }
        if (target is List) {
          if (args.isEmpty) return target;
          final int start = _toNum(args[0]).toInt();
          final int a = start < 0 ? (target.length + start).clamp(0, target.length) : start.clamp(0, target.length);
          return target.sublist(a);
        }
        break;

      case 'padStart':
        if (target is! String || args.isEmpty) break;
        final int width = _toNum(args[0]).toInt();
        final String pad = args.length > 1 ? _toString(args[1]) : ' ';
        return target.padLeft(width, pad.isEmpty ? ' ' : pad[0]);

      case 'toFixed':
        if (args.isEmpty) break;
        return _toNum(target).toStringAsFixed(_toNum(args[0]).toInt());
    }

    throw UnsupportedExpression('未实现的方法 .$name()');
  }

  Object? _getIndex(Object? target, Object? index) {
    if (target == null) return null;
    if (target is List) {
      final int? i = int.tryParse(_toString(index));
      if (i == null) return null;
      final int idx = i < 0 ? i + target.length : i;
      return (idx >= 0 && idx < target.length) ? target[idx] : null;
    }
    if (target is String) {
      final int? i = int.tryParse(_toString(index));
      if (i == null) return null;
      final int idx = i < 0 ? i + target.length : i;
      return (idx >= 0 && idx < target.length) ? target[idx] : null;
    }
    if (target is Map) {
      return target[_toString(index)];
    }
    return null;
  }

  // ---------------- 语义辅助 ----------------

  static bool _truthy(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0 && !v.isNaN;
    if (v is String) return v.isNotEmpty;
    if (v is List) return v.isNotEmpty;
    if (v is Map) return v.isNotEmpty;
    return true;
  }

  static num _toNum(Object? v) {
    if (v == null) return 0;
    if (v is num) return v;
    if (v is bool) return v ? 1 : 0;
    if (v is String) {
      final num? n = num.tryParse(v.trim());
      return n ?? 0;
    }
    return 0;
  }

  static bool _looseEquals(Object? a, Object? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a is num && b is num) return a == b;
    // JS 宽松相等：数字与数字字符串视为相等
    final num? na = a is num ? a : num.tryParse(_toString(a));
    final num? nb = b is num ? b : num.tryParse(_toString(b));
    if (na != null && nb != null) return na == nb;
    return _toString(a) == _toString(b);
  }

  static Object? _plus(Object? a, Object? b) {
    // JS 语义：只要一方是字符串就拼接
    if (a is String || b is String) return _toString(a) + _toString(b);
    return _toNum(a) + _toNum(b);
  }

  static String _toString(Object? v) {
    if (v == null) return '';
    if (v is String) return v;
    if (v is num) {
      if (v is double && v == v.roundToDouble() && v.abs() < 1e15) {
        return v.toInt().toString();
      }
      return v.toString();
    }
    if (v is bool) return v ? 'true' : 'false';
    if (v is List) return v.map(_toString).join(',');
    return v.toString();
  }

  static String _toStr(Object? v) => _toString(v);

  static String _escapeRegex(String s) =>
      s.replaceAllMapped(RegExp(r'[.*+?^${}()|\[\]\\]'), (Match m) => '\\${m[0]}');

  // ---------------- Tokenizer ----------------

  List<_Token> _tokenize(String s) {
    final List<_Token> out = <_Token>[];
    var i = 0;

    while (i < s.length) {
      final String c = s[i];

      // 空白
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        i++;
        continue;
      }

      // 字符串
      if (c == "'" || c == '"') {
        final String quote = c;
        i++;
        final StringBuffer buf = StringBuffer();
        while (i < s.length) {
          final String ch = s[i];
          if (ch == r'\' && i + 1 < s.length) {
            final String next = s[i + 1];
            buf.write(switch (next) {
              'n' => '\n',
              'r' => '\r',
              't' => '\t',
              _ => next,
            });
            i += 2;
            continue;
          }
          if (ch == quote) {
            i++;
            break;
          }
          buf.write(ch);
          i++;
        }
        out.add(_Token(_TokenType.string, buf.toString(), s.substring(0, i)));
        continue;
      }

      // 正则字面量：`/.../flags`（仅在特定上下文出现，这里宽松识别）
      if (c == '/' && _regexLikely(out)) {
        final int start = i;
        i++;
        final StringBuffer buf = StringBuffer();
        var closed = false;
        while (i < s.length) {
          final String ch = s[i];
          if (ch == r'\' && i + 1 < s.length) {
            buf.write(ch);
            buf.write(s[i + 1]);
            i += 2;
            continue;
          }
          if (ch == '/') {
            i++;
            closed = true;
            break;
          }
          buf.write(ch);
          i++;
        }
        if (closed) {
          // 吃掉 flags
          while (i < s.length && RegExp(r'[gimsuy]').hasMatch(s[i])) {
            i++;
          }
          out.add(_Token(
            _TokenType.regex,
            _RegexValue(buf.toString()),
            s.substring(start, i),
          ));
          continue;
        }
        // 不是正则，回退成除号
        i = start;
      }

      // 数字
      if (RegExp(r'\d').hasMatch(c) ||
          (c == '.' && i + 1 < s.length && RegExp(r'\d').hasMatch(s[i + 1]))) {
        final int start = i;
        while (i < s.length && RegExp(r'[\d.]').hasMatch(s[i])) {
          i++;
        }
        final String raw = s.substring(start, i);
        out.add(_Token(_TokenType.number, num.tryParse(raw) ?? 0, raw));
        continue;
      }

      // 标识符 / 关键字
      if (RegExp(r'[A-Za-z_$]').hasMatch(c)) {
        final int start = i;
        while (i < s.length && RegExp(r'[A-Za-z0-9_$]').hasMatch(s[i])) {
          i++;
        }
        final String raw = s.substring(start, i);
        out.add(_Token(_TokenType.identifier, raw, raw));
        continue;
      }

      // 运算符（长的优先）
      const List<String> ops = <String>[
        '===', '!==', '==', '!=', '<=', '>=',
        '&&', '||', '?', ':', '+', '-', '*', '/', '%',
        '!', '<', '>', '(', ')', '[', ']', ',', '.',
      ];
      String? matched;
      for (final String op in ops) {
        if (s.startsWith(op, i)) {
          matched = op;
          break;
        }
      }
      if (matched != null) {
        out.add(_Token(_TokenType.op, matched, matched));
        i += matched.length;
        continue;
      }

      throw UnsupportedExpression('无法识别的字符 `$c`', s);
    }

    return out;
  }

  /// 判断当前 `/` 是正则开头还是除号
  ///
  /// 粗判：前一个 token 是 运算符 / 开括号 / 逗号 / 空 时，`/` 更可能是正则。
  static bool _regexLikely(List<_Token> soFar) {
    if (soFar.isEmpty) return true;
    final _Token prev = soFar.last;
    if (prev.type == _TokenType.op) {
      return !(prev.raw == ')' || prev.raw == ']');
    }
    return false;
  }

  // ---------------- token 游标 ----------------

  _Token? get _current => _pos < _tokens.length ? _tokens[_pos] : null;

  bool _peekIs(String op) =>
      _pos < _tokens.length && _tokens[_pos].isOp(op);

  bool _match(String op) {
    if (_peekIs(op)) {
      _pos++;
      return true;
    }
    return false;
  }

  void _expect(String op) {
    if (!_match(op)) {
      throw UnsupportedExpression('期望 `$op`', source);
    }
  }

  String _expectIdentifier() {
    final _Token? t = _current;
    if (t == null || t.type != _TokenType.identifier) {
      throw UnsupportedExpression('期望标识符', source);
    }
    _pos++;
    return t.value! as String;
  }
}

enum _TokenType { number, string, identifier, op, regex }

class _Token {
  const _Token(this.type, this.value, this.raw);

  final _TokenType type;
  final Object? value;
  final String raw;

  bool isOp(String op) => type == _TokenType.op && raw == op;

  @override
  String toString() => '$type($raw)';
}

/// 正则字面量包装
class _RegexValue {
  const _RegexValue(this.pattern);

  final String pattern;

  RegExp get regex => RegExp(pattern, multiLine: true);
}

/// 函数引用（如 `java` / `String` / `encodeURIComponent`）
class _FunctionRef {
  const _FunctionRef(this.name);

  final String name;

  @override
  String toString() => 'fn:$name';
}

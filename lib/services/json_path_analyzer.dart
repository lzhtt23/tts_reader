/// JSONPath 求值（legado `$..x` / `$.a.b` / `$.a[0]` 子集）
///
/// ## 只实现书源实际用到的子集
///
/// 从 194 条真实书源统计（`work/legado-src/real_book_sources.json`），
/// `{{ }}` 里去重后 201 个是 JSONPath 表达式，用到的语法只有四种：
///
/// | 语法 | 例 | 含义 |
/// |---|---|---|
/// | `$.a.b` | `$.bookId` | 逐级取属性 |
/// | `$.a[0]` | `$.album_ids[0]` | 取数组元素 |
/// | `$..a` | `$..bid` | **递归**查找任意层级的 `a` |
/// | 组合 | `$..book..name` | 逐段递归 |
///
/// 不支持（真实书源里也没出现）：过滤器 `[?(@.x>1)]`、切片、脚本表达式。
/// 遇到不支持的语法返回空列表，由上层决定降级。
library;

/// JSONPath 求值器
class JsonPathAnalyzer {
  JsonPathAnalyzer(this.root);

  /// 被搜索的 JSON（Map / List / 标量都行）
  final Object? root;

  /// 求值，返回字符串列表
  List<String> evaluate(String path) {
    final List<Object?> values = evaluateRaw(path);
    final List<String> out = <String>[];
    for (final Object? v in values) {
      final String s = _stringify(v);
      if (s.isNotEmpty && !out.contains(s)) out.add(s);
    }
    return out;
  }

  /// 求值，返回原始值（保留结构，供 `getElement` 用）
  List<Object?> evaluateRaw(String path) {
    final String p = path.trim();
    if (p.isEmpty) return const <Object?>[];

    // 入口：$ 表示根
    List<Object?> current = <Object?>[root];
    var i = 0;

    if (p.startsWith(r'$')) {
      i = 1;
    }

    while (i < p.length) {
      final String c = p[i];

      if (c == '.') {
        // `..` = 递归下降
        if (i + 1 < p.length && p[i + 1] == '.') {
          i += 2;
          final _Segment seg = _readSegment(p, i);
          i = seg.next;
          if (seg.name == '*') {
            current = _expandAll(current);
          } else {
            current = _recursiveFind(current, seg.name);
          }
          continue;
        }
        i++; // 单点
        final _Segment seg = _readSegment(p, i);
        i = seg.next;
        if (seg.name == '*') {
          current = _expandChildren(current);
        } else {
          current = _getProperty(current, seg.name);
        }
        continue;
      }

      if (c == '[') {
        final int close = p.indexOf(']', i);
        if (close < 0) break;
        final String inside = p.substring(i + 1, close).trim();
        i = close + 1;

        if (inside == '*') {
          current = _expandChildren(current);
        } else if (inside.startsWith('?') || inside.contains(':')) {
          // 过滤器 / 切片：不支持，返回空让上层降级
          return const <Object?>[];
        } else {
          // 数字下标或引号键名
          String key = inside;
          if ((key.startsWith('"') && key.endsWith('"')) ||
              (key.startsWith("'") && key.endsWith("'"))) {
            key = key.substring(1, key.length - 1);
          }
          final int? idx = int.tryParse(key);
          current = idx != null
              ? _getIndex(current, idx)
              : _getProperty(current, key);
        }
        continue;
      }

      // 裸标识符（`$name` 之后很少见）：当成属性
      final _Segment seg = _readSegment(p, i);
      i = seg.next;
      current = _getProperty(current, seg.name);
    }

    return current;
  }

  // ---------------- 基础操作 ----------------

  List<Object?> _getProperty(List<Object?> nodes, String key) {
    final List<Object?> out = <Object?>[];
    for (final Object? n in nodes) {
      if (n is Map) {
        if (n.containsKey(key)) out.add(n[key]);
      } else if (n is List) {
        // 数组上取属性：对每个元素尝试（对齐「宽松」语义）
        for (final Object? item in n) {
          if (item is Map && item.containsKey(key)) out.add(item[key]);
        }
      }
    }
    return out;
  }

  List<Object?> _getIndex(List<Object?> nodes, int index) {
    final List<Object?> out = <Object?>[];
    for (final Object? n in nodes) {
      if (n is List) {
        final int idx = index < 0 ? index + n.length : index;
        if (idx >= 0 && idx < n.length) out.add(n[idx]);
      } else if (n is Map) {
        // 有些源把数组包在对象里，尝试常见键
        for (final String k in <String>['data', 'list', 'items']) {
          final Object? v = n[k];
          if (v is List) {
            final int idx = index < 0 ? index + v.length : index;
            if (idx >= 0 && idx < v.length) out.add(v[idx]);
          }
        }
      }
    }
    return out;
  }

  /// `.*`：展开一层所有子值
  List<Object?> _expandChildren(List<Object?> nodes) {
    final List<Object?> out = <Object?>[];
    for (final Object? n in nodes) {
      if (n is Map) {
        out.addAll(n.values);
      } else if (n is List) {
        out.addAll(n);
      }
    }
    return out;
  }

  /// `..*`：展开所有层级
  List<Object?> _expandAll(List<Object?> nodes) {
    final List<Object?> out = <Object?>[];
    void walk(Object? n) {
      if (n is Map) {
        for (final Object? v in n.values) {
          out.add(v);
          walk(v);
        }
      } else if (n is List) {
        for (final Object? v in n) {
          out.add(v);
          walk(v);
        }
      }
    }

    for (final Object? n in nodes) {
      walk(n);
    }
    return out;
  }

  /// `..name`：递归查找所有该键
  List<Object?> _recursiveFind(List<Object?> nodes, String key) {
    final List<Object?> out = <Object?>[];
    void walk(Object? n) {
      if (n is Map) {
        if (n.containsKey(key)) out.add(n[key]);
        for (final Object? v in n.values) {
          walk(v);
        }
      } else if (n is List) {
        for (final Object? v in n) {
          walk(v);
        }
      }
    }

    for (final Object? n in nodes) {
      walk(n);
    }
    return out;
  }

  /// 读一段标识符（到 `.` / `[` 为止）
  static _Segment _readSegment(String p, int start) {
    var i = start;
    final StringBuffer buf = StringBuffer();
    while (i < p.length && p[i] != '.' && p[i] != '[') {
      buf.write(p[i]);
      i++;
    }
    return _Segment(buf.toString(), i);
  }

  static String _stringify(Object? v) {
    if (v == null) return '';
    if (v is String) return v.trim();
    if (v is num) {
      // 与 legado 一致：整数值不带 .0
      if (v is double && v == v.roundToDouble() && v.abs() < 1e15) {
        return v.toInt().toString();
      }
      return v.toString();
    }
    if (v is bool) return v ? 'true' : 'false';
    // 对象/数组：不转 JSON（书源里取到对象通常是规则写错了）
    return '';
  }
}

class _Segment {
  const _Segment(this.name, this.next);

  final String name;
  final int next;
}

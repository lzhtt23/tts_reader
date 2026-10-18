/// XPath 求值（对齐 legado `AnalyzeByXPath.kt`）
///
/// 用工程已有的 `xml` 6.x，它自带 `XPath` 支持，不需要新依赖。
///
/// ## 书源里 XPath 的实际形态
///
/// 从真实合集统计（`real_source_coverage_test.dart` 的输出）：
/// XPath 规则占比很低（不足 3%），写法也很朴素：
/// - `//div[@class="list"]//li`
/// - `//*[@id="content"]`
/// - `/html/body/div[2]/p`
///
/// 所以这里不做「完整 XPath 引擎」，只做：
/// 1. 用 `xml` 的 XPath 求值
/// 2. 结果按 legado 语义取值（`text` / `html` / 属性）
/// 3. 解析失败时明确返回空并记下原因（不抛到上层炸掉整个源）
library;

import 'package:xml/xml.dart';
import 'package:xml/xpath.dart';

/// XPath 求值器
class XPathAnalyzer {
  XPathAnalyzer(this.html);

  /// 原始 HTML 文本
  final String html;

  /// 缓存解析结果
  XmlDocument? _doc;
  String? _parseError;

  /// 求值，返回字符串列表
  ///
  /// [rule] 是 XPath 表达式（不含 `@XPath:` 前缀）
  /// [lastStep] 是末级取值：`text` / `html` / 属性名（null = 取文本）
  List<String> evaluate(String rule, {String? lastStep}) {
    final String path = rule.trim();
    if (path.isEmpty) return const <String>[];

    final XmlDocument? doc = _document();
    if (doc == null) return const <String>[];

    final List<XmlNode> nodes;
    try {
      nodes = doc.xpath(path).toList();
    } catch (e) {
      _parseError = 'XPath 求值失败：$e';
      return const <String>[];
    }

    if (nodes.isEmpty) return const <String>[];

    final String step = (lastStep ?? 'text').trim().toLowerCase();
    final List<String> out = <String>[];

    for (final XmlNode node in nodes) {
      String value;
      switch (step) {
        case 'text':
          value = node.innerText.trim();
          break;
        case 'html':
        case 'all':
          value = node.toXmlString();
          break;
        default:
          // 当属性名
          value = node is XmlElement ? (node.getAttribute(step) ?? '').trim() : '';
          break;
      }
      if (value.isNotEmpty && !out.contains(value)) out.add(value);
    }
    return out;
  }

  /// 解析错误（供上层展示 / 诊断）
  String? get parseError => _parseError;

  XmlDocument? _document() {
    if (_doc != null) return _doc;
    if (_parseError != null) return null;
    try {
      _doc = XmlDocument.parse(html);
    } catch (e) {
      // 源站 HTML 常年不规范（未闭合标签、裸 `<br>` 等），
      // 严格解析失败时直接放弃并把原因记下来 ——
      // 不要用「猜」的方式修补（xpath 结果会错得没边）。
      _parseError = 'HTML 无法解析为 XML：$e';
      return null;
    }
    return _doc;
  }
}

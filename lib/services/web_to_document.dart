/// 方案 0：把网页正文存成本地文档 → 进文档库 → 朗读
///
/// ## 为什么先做这个
///
/// 它不依赖 legado 规则体系，只做一件事：**把一段网页正文变成一本可朗读的书**。
/// 好处是能最快验证「在线内容 → 朗读」这条链路本身是否成立；
/// 如果这一步体验不好（正文抽得不干净、分章错乱），
/// legado 那套规则也救不了。
///
/// ## 与 `web_speak_script.dart` 的分工
///
/// - `WebSpeakScript.extract` 抽一段文本**直接喂 TTS**（一次性，不落盘）
/// - 这里把抽到的正文**落成 TXT**，走完整文档库流程（有分章、有进度、可回读）
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/document.dart';
import 'txt_chapters.dart';

/// 网页转文档的结果
class WebCaptureResult {
  const WebCaptureResult({
    required this.document,
    required this.chapterCount,
    required this.charCount,
  });

  final Document document;
  final int chapterCount;
  final int charCount;
}

/// 把网页正文写成文档库里的 TXT
class WebToDocument {
  WebToDocument._();

  /// 单篇正文上限（防御异常页面塞进整站内容）
  static const int maxChars = 2000000;

  /// 保存
  ///
  /// [title] 书名（一般用网页标题）
  /// [body] 正文纯文本（可含换行）
  /// [chapters] 若调用方已切好章，按章写入；为空则整篇当一章
  static Future<WebCaptureResult> save({
    required String title,
    required String body,
    List<String>? chapters,
  }) async {
    final String safeTitle = title.trim().isEmpty ? '网页摘录' : title.trim();
    final String text = body.length > maxChars ? body.substring(0, maxChars) : body;

    final String content = (chapters != null && chapters.length > 1)
        ? _joinChapters(chapters)
        : text;

    final Directory dir = await getApplicationDocumentsDirectory();
    final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
    final String path = '${dir.path}${Platform.pathSeparator}web_$stamp.txt';
    await File(path).writeAsString(content, flush: true);

    // 分章数：交给现有的 TXT 分章逻辑算，保证与文档库一致
    int count = 1;
    try {
      final int parsed = TxtChapterSplitter.split(content).length;
      if (parsed > 1) count = parsed;
    } catch (_) {
      // 分章失败不影响导入
    }

    return WebCaptureResult(
      document: Document(
        id: 'web-$stamp',
        title: safeTitle,
        path: path,
        type: DocumentType.txt,
        importedAt: DateTime.now(),
      ),
      chapterCount: count,
      charCount: content.length,
    );
  }

  /// 多章拼接：用 `第N章` 这样的标题行分隔，便于 `TxtChapters` 识别
  static String _joinChapters(List<String> chapters) {
    final StringBuffer buffer = StringBuffer();
    for (var i = 0; i < chapters.length; i++) {
      final String text = chapters[i].trim();
      if (text.isEmpty) continue;
      buffer.writeln('第${_cn(i + 1)}章');
      buffer.writeln(text);
      buffer.writeln();
    }
    return buffer.toString();
  }

  /// 1 → 一（只到 99，够用）
  static String _cn(int n) {
    const List<String> digits = <String>[
      '零', '一', '二', '三', '四', '五', '六', '七', '八', '九',
    ];
    if (n < 10) return digits[n];
    if (n < 20) return '十${n % 10 == 0 ? '' : digits[n % 10]}';
    final int tens = n ~/ 10;
    final int ones = n % 10;
    return '${digits[tens]}十${ones == 0 ? '' : digits[ones]}';
  }
}

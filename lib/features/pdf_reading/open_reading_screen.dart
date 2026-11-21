import 'package:flutter/widgets.dart';

import '../../models/document.dart';
import '../../pages/reader_page.dart';
import 'pdf_reading_page.dart';

/// 按文档类型挑朗读界面。
///
/// - **PDF** → [PdfReadingPage]：重构后的 PDF 朗读
///   （pdfrx 渲染 + 透明文本层 + 点句即读 + 高亮定位），完全独立的实现；
/// - **TXT / EPUB** → [ReaderPage]：原有的分页阅读（文本层重排那套）。
///
/// 为什么不把 PDF 也塞进 [ReaderPage]：
/// 两边的坐标体系完全不同 —— 原版式 PDF 的「字在哪儿」要由 PDF 自己的
/// 逐字符盒决定（见 `features/pdf_reading/pdf_text_layer.dart`），
/// 而文本模式是 Flutter 自己排版、位置由 widget 决定。
/// 混在一个页面里就要来回换算，正是之前那批「点句时灵时不灵」的根源。
Widget openReadingScreen(Document document, {bool autoSpeak = false}) {
  if (document.type == DocumentType.pdf) {
    return PdfReadingPage(
      filePath: document.path,
      title: document.title,
      // 传库里的 id：会话用它判「同一本书重进」，从而保留朗读位置
      documentId: document.id,
      autoSpeak: autoSpeak,
    );
  }
  return ReaderPage(document: document, autoSpeak: autoSpeak);
}

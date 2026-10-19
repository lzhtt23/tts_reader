import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 用 Flutter 自己的文字排版画一张封面（**支持中文**）
///
/// ## 为什么不能继续用 `image` 包画字
///
/// `writeDefaultCover` 里用的是 `img.drawString(..., img.arial_24, ...)` ——
/// `image` 包自带的是**位图 ASCII 字体**，只有 Latin 字形。
/// 中文书名的结果是：`drawString` 要么抛异常被 catch 掉，要么画出一串方框，
/// 最终用户看到的就是**一块纯色、没有书名**的封面。
/// TXT 没有内嵌图片，所以它 100% 走这条默认路径 —— 等于所有 TXT 都没封面。
///
/// ## 做法
///
/// 用 `dart:ui` 的 `PictureRecorder` + `ParagraphBuilder` 排版（跟界面上画字同一套
/// 引擎，系统中文字体直接可用），再 `toImage` → PNG 落盘。
/// 不引入新依赖，也不依赖任何平台插件。
class CoverRenderer {
  CoverRenderer._();

  /// 画一张文字封面；失败返回 null（调用方自己兜底）
  static Future<String?> render({
    required String title,
    String author = '',
    required String outPath,
    int width = 480,
    int height = 680,
  }) async {
    try {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(
        recorder,
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      );

      // ① 竖向渐变底（与内置种子色同系）
      final Rect rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
      final Paint bg = Paint()
        ..shader = ui.Gradient.linear(
          rect.topCenter,
          rect.bottomCenter,
          <Color>[const Color(0xFF5B4696), const Color(0xFF2E225C)],
        );
      canvas.drawRect(rect, bg);

      // ② 中间一条更亮的带子，避免整块死色
      final Paint band = Paint()
        ..color = const Color(0x33B9A7E8)
        ..blendMode = BlendMode.srcOver;
      canvas.drawRect(
        Rect.fromLTWH(0, height * 0.40, width.toDouble(), height * 0.22),
        band,
      );

      // ③ 书名（自动换行、最多 4 行，超出省略）
      final String shownTitle = title.trim().isEmpty ? '未命名' : title.trim();
      _drawText(
        canvas,
        shownTitle,
        left: width * 0.10,
        top: height * 0.42,
        maxWidth: width * 0.80,
        fontSize: 44,
        lineHeight: 1.35,
        color: const Color(0xFFF3EFFF),
        maxLines: 4,
        bold: true,
      );

      // ④ 作者（有就画在书名下面）
      final String shownAuthor = author.trim();
      if (shownAuthor.isNotEmpty) {
        _drawText(
          canvas,
          shownAuthor,
          left: width * 0.10,
          top: height * 0.78,
          maxWidth: width * 0.80,
          fontSize: 24,
          lineHeight: 1.3,
          color: const Color(0xCCD9D2F5),
          maxLines: 1,
        );
      }

      // ⑤ 顶部一条细装饰线（让封面有"书"的样子）
      final Paint line = Paint()
        ..color = const Color(0x88FFFFFF)
        ..strokeWidth = 2;
      canvas.drawLine(
        Offset(width * 0.10, height * 0.36),
        Offset(width * 0.90, height * 0.36),
        line,
      );

      final ui.Image image = await recorder.endRecording().toImage(width, height);
      final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return null;
      final File file = File(outPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return outPath;
    } catch (_) {
      return null;
    }
  }

  /// 画一段可换行的文字
  static void _drawText(
    Canvas canvas,
    String text, {
    required double left,
    required double top,
    required double maxWidth,
    required double fontSize,
    required double lineHeight,
    required Color color,
    required int maxLines,
    bool bold = false,
  }) {
    final ui.ParagraphBuilder builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: TextAlign.left,
        fontSize: fontSize,
        height: lineHeight,
        maxLines: maxLines,
        ellipsis: '…',
      ),
    )..pushStyle(
      ui.TextStyle(
        color: color,
        fontSize: fontSize,
        height: lineHeight,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        // 显式给出中文字体回退链：默认字体在部分 ROM 上只有 Latin，
        // 中文会画成方框（测试环境里的 Ahem 就是这样）。
        // ⚠️ 必须放在 **TextStyle** 上：`ParagraphStyle` 没有这个参数。
        fontFamilyFallback: const <String>[
          'Noto Sans CJK SC',
          'Noto Sans SC',
          'Source Han Sans SC',
          'Droid Sans Fallback',
          'sans-serif',
        ],
      ),
    );
    builder.addText(text);
    final ui.Paragraph paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: maxWidth));
    canvas.drawParagraph(paragraph, Offset(left, top));
    paragraph.dispose();
  }
}

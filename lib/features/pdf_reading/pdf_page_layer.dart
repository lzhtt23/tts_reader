import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../services/crash_log.dart';
import 'pdf_text_layer.dart';

/// 一页 PDF 的渲染 + 透明文本层。
///
/// 分层结构与需求一致：
///
/// ```
///   Stack
///   ├─ PdfPageView        渲染出来的页面位图（Canvas）
///   └─ 文本层             覆盖其上：命中测试 + 高亮 + 可拖选
/// ```
///
/// 文本层是**应用自己画的**（CustomPaint），不是 PDF 自带的 —— 这样
/// 「点哪个字」完全由我们说了算，不受引擎内置注释/链接层的干扰。
///
/// 坐标系统一由 [pageSizeCallback] 给出的**实际渲染尺寸**换算：
/// `屏幕像素 = PDF 点 × scale`，其中 `scale = 渲染宽 / page.width`。
/// 早期那套「视口 + scrollOffset」的推算在这里彻底不用了 ——
/// 那一套正是「点句时灵时不灵」的来源。
class PdfPageLayer extends StatefulWidget {
  const PdfPageLayer({
    super.key,
    required this.document,
    required this.pageNumber,
    required this.textLayer,
    this.onReadSentence,
    this.onBlankTap,
    this.highlightSentence,
    this.highlightColor,
    this.showDebugRects = false,
    this.onExtentChanged,
    this.crop,
  });

  final PdfDocument? document;
  final int pageNumber;

  /// 该页的文本层（可能为空 = 扫描件 / 无文本层）
  final PdfPageTextLayer? textLayer;

  /// 点击某一句时回调（下标对应 [textLayer].sentences）
  final void Function(int sentenceIndex)? onReadSentence;

  /// 点在**空白处**（页边距、行间空隙、没有文字层的区域）时回调（v1.22.73）
  ///
  /// 用途：呼出/收起控制栏。命中了句子就**不会**走这里 ——
  /// 点句朗读永远优先，空白处才是兜底。
  final VoidCallback? onBlankTap;

  /// 正在朗读的高亮：**要画的那一句在本页的句索引**；null 表示本页没有高亮
  ///
  /// ★v1.21.43 模型 A 从"字符区间"改成"句索引"，为的是一句跨两页能两页都画。
  final int? highlightSentence;

  /// 高亮块底色（**派生自当前主题**，含透明度；null = 不高亮时忽略）
  ///
  /// 来源必须与文本模式同源：`ReaderStyle.pdfHighlightColor(scheme)`
  /// （v1.21.5 起跟随主题 / 动态取色，不再写死色值，见 HANDOFF §4.53）。
  final Color? highlightColor;

  /// 打开后把每个字符盒画出来（排查命中问题用）
  final bool showDebugRects;

  /// 裁边：四边各内缩多少（0~1，相对页宽 / 页高）；null = 不裁
  ///
  /// ## 为什么要在这里裁（而不是在阅读页缩一缩）
  ///
  /// 页面盒子的**长宽比**由外层 `AspectRatio` 决定（阅读页按裁后的比例给）。
  /// 这里要做的只是「把完整页面放大到裁切区正好铺满盒子，再裁掉外面」：
  ///   · 放大后整页宽度 = 盒宽 / (1 - 左 - 右)
  ///   · 于是 [_rendered]（LayoutBuilder 看到的约束）就是**放大后**的尺寸，
  ///     `_scale = rendered.width / pdfPageWidth` 自然变成放大比例 ——
  ///     点击取句、高亮矩形全都不需要改一行坐标换算。
  ///   · 裁剪只用 ClipRect + 位移，不改任何几何推导。
  final ({double left, double top, double right, double bottom})? crop;

  /// 这一页在滚动内容里占了多高（含内边距）
  ///
  /// 阅读页用它推算「滚到第几页了」—— 纵向连续滚动没有 `onPageChanged`，
  /// 只能自己按页高累加判断（HANDOFF §4.58 的等价物）。
  final ValueChanged<double>? onExtentChanged;

  /// 渲染尺寸诊断（**可选**：设了它才会被调用）
  ///
  /// ## 为什么留这个口子：位图分辨率最容易说不清
  ///
  /// pdfrx 的 `PdfPageView` 渲染尺寸**完全由 `pageSizeCallback` 的返回值决定**
  /// （`pdf_widgets.dart` 的 `_updateImage`：**给了回调就不再乘 dpr**），
  /// 而那张位图会被 `RawImage` 拉伸到**逻辑**尺寸。所以回调返回什么，位图就是什么：
  ///
  /// | 回调返回 | 位图 | 结果 |
  /// | --- | --- | --- |
  /// | 逻辑尺寸 | 只有物理像素的 1/dpr | 被拉伸 dpr 倍 → **糊** |
  /// | 逻辑尺寸 × dpr | 正好物理像素 | 清晰 |
  ///
  /// 位图 / 逻辑 / 显示这三个数凑不齐就没法判断，所以让设备用例能**数值断言**
  /// （截图对比在 CI 里不可靠）。
  static void Function(PdfRenderDiagnostics info)? renderDiagnosticsListener;

  /// 单页位图的像素上限（宽 × 高），默认 400 万像素 ≈ 解码后 16 MB
  ///
  /// ## 为什么要有个上限
  ///
  /// pdfrx 是按**当前布局尺寸**渲染的，而位图字节数按尺寸的**平方**增长。
  /// 现在这个页面是「一页铺满视口宽度」（逻辑 376.7 × 534.6 → 位图
  /// 1036 × 1470 ≈ 152 万像素 ≈ 6 MB），很安全；但下面两种情况会失控：
  ///
  /// - 以后给 PDF 阅读页加**捏合缩放**（`logical` 跟着变大）；
  /// - 平板横屏 / 大屏，单页逻辑尺寸本来就大。
  ///
  /// 拿 200% 缩放 + 大页面举例：`logical` 翻倍 → 像素数 ×4 → 单页 24 MB，
  /// 而 Flutter 的 `imageCache` 默认预算只有 100 MB，几页就把缓存挤爆。
  ///
  /// 400 万像素的依据：当前真机需求约 152 万，留了 2.6 倍余量给缩放；
  /// 同时解码上限 16 MB，`imageCache` 至少能放 6 页，不会一滑就抖。
  ///
  /// 超过上限时**等比缩小**（只降分辨率，不改宽高比 —— 命中测试依赖逻辑
  /// 尺寸，与这里无关）。
  static const double maxPagePixels = 4000000;

  /// 把位图尺寸压到 [maxPagePixels] 以内（等比）
  @visibleForTesting
  static Size capPagePixels(Size size) {
    final pixels = size.width * size.height;
    if (pixels <= maxPagePixels || pixels <= 0) return size;
    final factor = math.sqrt(maxPagePixels / pixels);
    return Size(size.width * factor, size.height * factor);
  }

  @override
  State<PdfPageLayer> createState() => _PdfPageLayerState();
}

class _PdfPageLayerState extends State<PdfPageLayer> {
  /// 页面在屏幕上的**逻辑**尺寸（用于坐标换算）
  ///
  /// ⚠️ 不能用 `pageSizeCallback` 的第一个参数：那是**设备像素**尺寸
  /// （实测 376.7 逻辑宽 → 回调给 1036 物理像素，dpr≈2.75），
  /// 拿它当屏幕尺寸会让缩放算成大 2.75 倍，点击坐标整体偏离 → 点不中任何字。
  /// 正确来源是布局约束（`biggestSize` / LayoutBuilder constraints），
  /// 也就是下面 LayoutBuilder 给的值。
  Size? _rendered;

  /// PDF 点 → 屏幕像素的缩放
  double get _scale {
    final layer = widget.textLayer;
    final rendered = _rendered;
    if (layer == null || rendered == null) return 1;
    if (layer.pageSize.width <= 0) return 1;
    return rendered.width / layer.pageSize.width;
  }

  // ---------------- 指针状态：区分「点」与「拖」 ----------------
  //
  // 需求：`滑动滚动` 与 `点击文字` 要分开；**拖选文字时不触发朗读**。
  // 判据只有位移距离（超过 kTouchSlop 就是拖），按住时长不看 ——
  // 长按在本功能里没有别的用途，没必要再分一档。
  Offset? _downAt;
  bool _dragged = false;
  bool _selecting = false;

  /// 松手后要忽略点击的截止时间（防止拖选的收尾被当成一次点击）
  DateTime? _ignoreTapUntil;

  static const Duration _selectCooldown = Duration(milliseconds: 250);

  void _onPointerDown(PointerDownEvent e) {
    _downAt = e.localPosition;
    _dragged = false;
    _selecting = false;
  }

  void _onPointerMove(PointerMoveEvent e) {
    final down = _downAt;
    if (down == null) return;
    if ((e.localPosition - down).distance <= kTouchSlop) return;
    if (!_dragged) {
      _dragged = true;
      // 拖动 = 用户在选择文字 / 滑动页面：这一轮不朗读
      _selecting = true;
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    final down = _downAt;
    final dragged = _dragged;
    _downAt = null;
    _dragged = false;
    if (down == null) return;
    if (dragged) {
      // 拖选结束：留一小段冷却，收尾的抬手别再触发朗读
      _ignoreTapUntil = DateTime.now().add(_selectCooldown);
      _selecting = false;
      return;
    }
    final until = _ignoreTapUntil;
    if (until != null && DateTime.now().isBefore(until)) return;
    _handleTap(e.localPosition);
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _downAt = null;
    _dragged = false;
    _selecting = false;
  }

  /// 点到了哪一句 → 回调出去
  void _handleTap(Offset localPosition) {
    final layer = widget.textLayer;
    final onRead = widget.onReadSentence;
    if (layer == null || onRead == null) {
      // 没有文字层（扫描件）：整页都是"空白"，点一下就切控制栏
      widget.onBlankTap?.call();
      return;
    }
    final scale = _scale;
    if (scale <= 0) return;
    // 屏幕逻辑像素 → PDF 点
    final pagePoint = Offset(localPosition.dx / scale, localPosition.dy / scale);
    final index = layer.sentenceIndexAt(pagePoint);
    if (index == null) {
      // 没命中任何句子 → 交给"空白处"处理（呼出/收起控制栏）
      widget.onBlankTap?.call();
      return;
    }
    onRead(index);
  }

  /// 量到自己的高度后报给阅读页（推算「滚到第几页」要用）
  void _reportExtent() {
    final callback = widget.onExtentChanged;
    if (callback == null) return;
    final box = context.findRenderObject();
    if (box is! RenderBox) return;
    final height = box.size.height;
    if (height <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback(height);
    });
  }


  void _reportRenderDiagnostics({
    required BuildContext context,
    required Size logical,
    required Size bitmap,
    required Size pixelSize,
    required Size pageSize,
  }) {
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    // ⚠️ 这个回调是 pdfrx 在 **layout 期间**调的（它在 LayoutBuilder 的 builder
    // 里算尺寸）。此刻 `findRenderObject()` 会抛
    // 「RenderBox was not laid out: NEEDS-LAYOUT」—— 实测直接把页面炸掉。
    // 所以量「显示尺寸」必须放到帧后：那时这一页才真正 layout 完。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = context.findRenderObject();
      final display = box is RenderBox && box.hasSize ? box.size : logical;
      final listener = PdfPageLayer.renderDiagnosticsListener;
      if (listener != null) {
        listener(PdfRenderDiagnostics(
          bitmap: bitmap,
          logical: logical,
          display: display,
          pixelSize: pixelSize,
          pageSize: pageSize,
          devicePixelRatio: dpr,
        ));
      }
      // 排查清晰度（位图 vs 显示尺寸 / dpr）走 `renderDiagnosticsListener`
      // 那条正路 —— 它由 test/pdf_page_bitmap_budget_test.dart 消费。
      // 早期这里还有一行每帧渲染都插值格式化的诊断打印，已随 v1.21.5 交付清掉
      // （开发期打印不该进发布包）。
    });
  }

  @override
  Widget build(BuildContext context) {
    final layer = widget.textLayer;
    final content = _buildContent(context, layer);
    final c = widget.crop;
    if (c == null) return content;
    // 裁边：先把「完整页面」按 (1/(1-l-r)) 放大，再平移到裁切区左上角，最后裁掉外面。
    // 用 OverflowBox 让子节点拿到**放大后**的约束（这样内部 LayoutBuilder 量到的
    // 就是放大尺寸），用 ClipRect 把超出盒子部分剪掉。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double boxW = constraints.maxWidth;
        final double boxH = constraints.maxHeight;
        if (!boxW.isFinite || !boxH.isFinite || boxW <= 0 || boxH <= 0) {
          return content;
        }
        final double cropW = (1 - c.left - c.right).clamp(0.1, 1.0);
        final double cropH = (1 - c.top - c.bottom).clamp(0.1, 1.0);
        final double childW = boxW / cropW;
        final double childH = boxH / cropH;
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: childW,
            maxWidth: childW,
            minHeight: childH,
            maxHeight: childH,
            child: Transform.translate(
              offset: Offset(-c.left * childW, -c.top * childH),
              child: content,
            ),
          ),
        );
      },
    );
  }

  Widget _buildContent(BuildContext context, PdfPageTextLayer? layer) {
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        LayoutBuilder(
          builder: (context, constraints) {
            // 页面在屏幕上的**逻辑**尺寸 = 布局约束（见 [_rendered] 的说明）。
            // LayoutBuilder 的 builder 在 layout 期间跑，不能直接 setState，
            // 所以记下来 + 帧后同步。
            final logical = Size(
              constraints.maxWidth.isFinite ? constraints.maxWidth : 0,
              constraints.maxHeight.isFinite ? constraints.maxHeight : 0,
            );
            if (logical.width > 0 && logical != _rendered) {
              _scheduleRendered(logical);
            }
            return PdfPageView(
              document: widget.document,
              pageNumber: widget.pageNumber,
              decoration: const BoxDecoration(color: Colors.white),
              // ⚠️⚠️ 这里返回的尺寸**就是位图尺寸**（pdfrx 的 `_updateImage`：
              // 一旦给了 `pageSizeCallback`，就不再自己乘 dpr），
              // 而位图会被 `RawImage` 拉伸到**逻辑**尺寸显示。
              //
              // 所以必须返回「逻辑尺寸 × dpr」= 物理像素：
              //
              // - 返回逻辑尺寸 → 位图只有物理像素的 1/dpr，被拉伸 dpr 倍 → **糊**
              //   （实测：渲染 376.7、显示 376.7、dpr=2.75，手机上字发虚）
              // - 返回逻辑尺寸 × dpr → 位图正好铺满物理像素 → 清晰
              //
              // 注意与命中测试的关系：`_scale` 用的是 [_rendered]（**逻辑**尺寸，
              // 来自 LayoutBuilder 约束），组件占的逻辑尺寸不因为这个返回值改变
              //（`RawImage` 被 `AspectRatio` 包着），所以屏幕→PDF 点的换算不用动。
              pageSizeCallback: (pixelSize, page) {
                final dpr = MediaQuery.devicePixelRatioOf(context);
                // 清晰度上限：位数按 dpr 拉满，但不让**单页像素数**失控。
                // 见 [maxPagePixels] 的说明 —— 这是「清晰 vs 内存」的取舍点。
                final physical = logical.isEmpty
                    ? pixelSize
                    : PdfPageLayer.capPagePixels(
                        Size(logical.width * dpr, logical.height * dpr),
                      );
                _reportRenderDiagnostics(
                  context: context,
                  logical: logical,
                  bitmap: physical,
                  pixelSize: pixelSize,
                  pageSize: Size(page.width, page.height),
                );
                return physical;
              },
            );
          },
        ),
        // 文本层：自己画的，同时负责命中测试与高亮
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            child: CustomPaint(
              painter: PdfTextLayerPainter(
                layer: layer,
                scale: _scale,
                highlightSentence: widget.highlightSentence,
                highlightColor: widget.highlightColor,
                showDebugRects: widget.showDebugRects,
                selecting: _selecting,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 记录实际渲染尺寸（回调在 layout 期间，必须帧后再 setState）
  void _scheduleRendered(Size size) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (size == _rendered) return;
      setState(() => _rendered = size);
      _reportExtent();
    });
  }
}

/// 文本层的画笔：高亮 + （可选）调试框
///
/// 平时**不画任何东西**（透明）—— 文字已经由下面的位图呈现了，
/// 上面这层只负责「知道每个字在哪」。只有高亮时才画色块。
class PdfTextLayerPainter extends CustomPainter {
  PdfTextLayerPainter({
    required this.layer,
    required this.scale,
    required this.highlightSentence,
    this.highlightColor,
    this.showDebugRects = false,
    this.selecting = false,
  });

  final PdfPageTextLayer? layer;
  final double scale;

  /// 要高亮的那一句在**本页**文本层里的**句索引**（null = 本页不高亮）
  ///
  /// ★v1.21.43 模型 A：原来是"字符下标闭区间 `(first, last)`"。
  /// 改成句索引之后，**一句跨两页可以两页都画** ——
  /// 每页各自拿"本页那一半"的句对象即可（见绘制处的说明）。
  final int? highlightSentence;

  /// 高亮块底色（派生自当前主题，含透明度）
  ///
  /// null 时退回历史默认（同一透明度的琥珀色），保证单独构造画笔的
  /// 老用例不会因为少传一个参数而变色。
  final Color? highlightColor;

  final bool showDebugRects;
  final bool selecting;

  @override
  void paint(Canvas canvas, Size size) {
    final textLayer = layer;
    if (textLayer == null || scale <= 0) return;

    Rect toScreen(Rect r) => Rect.fromLTWH(
          r.left * scale,
          r.top * scale,
          r.width * scale,
          r.height * scale,
        );

    if (showDebugRects) {
      final debugPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x3300AAFF);
      for (final s in textLayer.sentences) {
        for (final c in s.chars) {
          canvas.drawRect(toScreen(c.rect), debugPaint);
        }
      }
    }

    final int? sentenceIndex = highlightSentence;
    if (sentenceIndex == null) return;
    // 上面已经确认过 textLayer 非空（`tl` 就是它）
    final tl = textLayer;
    if (sentenceIndex < 0 || sentenceIndex >= tl.sentences.length) return;

    // 朗读高亮：按**行**逐块画（HANDOFF §4.44 / §4.100）——
    // 每行一个独立 Rect，只覆盖该行内这句话实际占的字符区间；
    // 句子跨 3 行就是 3 块，各块 left 互不相同。
    //
    // ★v1.21.43 模型 A：这里改成**按句索引直接取句对象**（原来是"按字符区间
    // 反查整句"）。两个好处：
    // 1. **一句跨两页可以两页都画** —— 每页各自拿"本页那一半"的句对象；
    //    旧做法传的是 `(first,last)` 字符区间，跨页句在第二页**对不上任何整句**
    //    （`sentenceAtRange` 返回 null）→ 第二页**直接不画**，
    //    这就是用户报的「跨页句只框在上一页」；
    // 2. 顺带免掉"区间扫全页字符"那类坑（页脚下标与视觉顺序无关，
    //    扫区间会把别的行的字符捞进来 —— §4.100 任务 B 的老根因）。
    final sentence = tl.sentences[sentenceIndex];

    final paint = Paint()
      ..color = highlightColor ??
          // 没传派生色时的历史默认（同透明度的琥珀），仅为兼容单独构造的用例
          const Color(0x59FFC107);
    for (final rect in sentence.highlightRects) {
      // 稍微外扩一点，盖住字的下缘（描边、下划线常超出字盒）
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          toScreen(rect).inflate(1.5),
          const Radius.circular(3),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(PdfTextLayerPainter oldDelegate) =>
      oldDelegate.layer != layer ||
      oldDelegate.scale != scale ||
      oldDelegate.highlightSentence != highlightSentence ||
      oldDelegate.highlightColor != highlightColor ||
      oldDelegate.showDebugRects != showDebugRects ||
      oldDelegate.selecting != selecting;
}

/// 一页文字层的**几何体检**结果（★v1.21.45 改动 2/3）
///
/// 两个用途：
/// 1. **诊断探针**：把「字符盒 / 行 / 句 / 页面尺寸」打成一行日志（[logLine]），
///    以后判断"这页到底抽出了什么"不用再靠猜；
/// 2. **异常判据**：字符盒大面积落到页面之外 → 这份 PDF 的文字位置本身有问题，
///    高亮必然对不齐（[anomalous]），界面据此提示一次。
class PdfTextLayerGeometry {
  const PdfTextLayerGeometry({
    required this.pageNumber,
    required this.charBoxes,
    required this.lines,
    required this.sentences,
    required this.pageSize,
    required this.outsideBoxes,
    required this.tolerance,
    required this.anomalyRatio,
  });

  final int pageNumber;

  /// 有效字符盒数（**排除零面积占位盒**：那些是 fragment 之间被引擎丢掉的字符）
  final int charBoxes;
  final int lines;
  final int sentences;
  final Size pageSize;

  /// 落在「页面 + 容忍带」之外的字符盒数
  final int outsideBoxes;

  /// 容忍带：页面尺寸外扩这么多比例仍算"在页面内"（默认 5%）
  final double tolerance;

  /// 越界比例超过这个值就判异常（默认 20%）
  final double anomalyRatio;

  /// 越界比例（0~1）。没有有效字符盒时算 0（无从判断，不误报）
  double get outsideRatio => charBoxes == 0 ? 0 : outsideBoxes / charBoxes;

  /// 是不是「文字位置异常」的 PDF
  bool get anomalous => charBoxes > 0 && outsideRatio > anomalyRatio;

  /// 诊断探针那一行（**纯字符串**，格式由单测钉住）
  String get logLine =>
      'PDF 文字层[第 $pageNumber 页] 字符盒=$charBoxes 行=$lines 句=$sentences '
      '页面=${pageSize.width.toStringAsFixed(0)}x${pageSize.height.toStringAsFixed(0)}';

  /// 异常时的诊断说明（含越界比例与阈值，便于拿日志判案）
  String get anomalyNote =>
      'PDF 文字层[第 $pageNumber 页] 几何异常：$outsideBoxes/$charBoxes 个字符盒在页面外'
      '（${(outsideRatio * 100).toStringAsFixed(1)}% > ${(anomalyRatio * 100).toStringAsFixed(0)}%，'
      '容忍带 ${(tolerance * 100).toStringAsFixed(0)}%）';
}

/// 给一页的字符盒做几何体检（**纯函数**，可单测）
///
/// ## 判据（与施工单一致）
///
/// 1. **零面积盒直接不算**：`loadTextLayer` 会给"没有字符盒的位置"填 `Rect.zero`
///    （fragment 之间被引擎丢掉的字符），它们不是真的错位；
/// 2. 页面外扩 [tolerance]（默认 5%）算**容忍带** —— 版心外的页码、页眉页脚、
///    轻微溢出的最后一个字都在这里，属正常；
/// 3. 用**字符盒中心**判定在不在页面内：某些 PDF 的最后一个字符盒会略微溢出，
///    而"整块版面错位"会让大量盒子的中心都跑到页面外；
/// 4. 越界比例 **> 20%** 才判异常（施工单给的门槛）。
PdfTextLayerGeometry analyzeTextLayerGeometry({
  required int pageNumber,
  required List<Rect> charRects,
  required Size pageSize,
  required int lines,
  required int sentences,
  double tolerance = 0.05,
  double anomalyRatio = 0.20,
}) {
  final double padX = pageSize.width * tolerance;
  final double padY = pageSize.height * tolerance;
  final Rect allowed = Rect.fromLTRB(-padX, -padY, pageSize.width + padX, pageSize.height + padY);

  var boxes = 0;
  var outside = 0;
  for (final r in charRects) {
    if (r.width <= 0 || r.height <= 0) continue; // 零面积占位盒
    boxes++;
    if (!allowed.contains(r.center)) outside++;
  }

  return PdfTextLayerGeometry(
    pageNumber: pageNumber,
    charBoxes: boxes,
    lines: lines,
    sentences: sentences,
    pageSize: pageSize,
    outsideBoxes: outside,
    tolerance: tolerance,
    anomalyRatio: anomalyRatio,
  );
}

/// 从 `pdfrx` 的 `PdfPageText` 构建本页文本层
///
/// ⚠️ **坐标翻转**：pdfrx 1.x 的 `PdfRect` 用的是 **PDF 原生坐标系**
/// （原点在**左下**，`top > bottom`），而 Flutter 是左上原点。
/// 文本层、高亮、命中测试全部按左上原点写，所以这里统一翻一次 Y：
/// `flutterTop = pageHeight - pdfTop`。
/// 不翻的后果是高亮框**上下颠倒**（字的纵向位置整体镜像），
/// 而且点上面的字会命中下面的字 —— 排查起来很费劲，所以在源头就翻好。
///
/// ## ★v1.21.45：抽完必做一次几何体检
///
/// * **永远**打一行诊断探针（[PdfTextLayerGeometry.logLine]）；
/// * 判为异常时再打一条说明，并通过 [onGeometry] 交给调用方 ——
///   弹不弹提示由**界面**决定（`loadTextLayer` 没有 SnackBar 上下文），
///   而且要按文档只弹一次（见 `PdfReadingPage` 的 `_geometryWarnedDocs`）。
Future<PdfPageTextLayer?> loadTextLayer(
  PdfPage page, {
  void Function(PdfTextLayerGeometry geometry)? onGeometry,
}) async {
  final pageText = await page.loadText();
  final fullText = pageText.fullText;
  if (fullText.trim().isEmpty) return null;

  final pageHeight = page.height;
  final pageWidth = page.width;

  Rect flip(PdfRect r) => Rect.fromLTRB(
        r.left.clamp(0.0, pageWidth),
        (pageHeight - r.top).clamp(0.0, pageHeight),
        r.right.clamp(0.0, pageWidth),
        (pageHeight - r.bottom).clamp(0.0, pageHeight),
      );

  // 逐字符盒在 **fragment** 上（1.x 的 PdfPageText 没有整页 charRects）。
  // 按 index 拼回与 fullText 对齐的一维数组：fullText 里有些位置可能没有
  // 对应的字符盒（fragment 之间被引擎丢掉的分隔符），那些位置填零面积盒，
  // buildTextLayer 会把零面积盒跳过。
  final rects = List<Rect>.filled(fullText.length, Rect.zero);
  for (final fragment in pageText.fragments) {
    final charRects = fragment.charRects;
    if (charRects == null || charRects.isEmpty) continue;
    for (var i = 0; i < charRects.length; i++) {
      final at = fragment.index + i;
      if (at < 0 || at >= rects.length) break;
      rects[at] = flip(charRects[i]);
    }
  }

  final layer = buildTextLayer(
    pageNumber: page.pageNumber,
    pageSize: page.size,
    fullText: fullText,
    charRects: rects,
    segment: segmentIntoSentences,
  );

  // ★改动 2 / 3：几何体检（探针永远打；异常交给界面去提示）
  final geometry = analyzeTextLayerGeometry(
    pageNumber: page.pageNumber,
    charRects: rects,
    pageSize: page.size,
    lines: layer.lines.length,
    sentences: layer.sentences.length,
  );
  CrashLog.mark(geometry.logLine);
  if (geometry.anomalous) {
    CrashLog.mark(geometry.anomalyNote);
    onGeometry?.call(geometry);
  }

  return layer;
}

/// 把一个 `ui.Image` 转成可绘制的画布内容（导出 / 缩略图会用）
Future<void> disposeImage(ui.Image? image) async {
  image?.dispose();
}

/// 一次渲染的尺寸快照（[PdfPageLayer.renderDiagnosticsListener] 给出来）
class PdfRenderDiagnostics {
  const PdfRenderDiagnostics({
    required this.bitmap,
    required this.logical,
    required this.display,
    required this.pixelSize,
    required this.pageSize,
    required this.devicePixelRatio,
  });

  /// 交给 pdfrx 的渲染尺寸（也就是位图尺寸，单位是「物理像素」的口径）
  final Size bitmap;

  /// 布局约束给的逻辑尺寸
  final Size logical;

  /// 组件实际占的显示尺寸
  final Size display;

  /// pdfrx 本来算出来的（设备像素）尺寸 —— 就是 `constraints.biggest * dpr`
  final Size pixelSize;

  /// PDF 页面自身的点尺寸
  final Size pageSize;

  final double devicePixelRatio;

  /// 位图相对**显示**尺寸的倍率：< 1 就是被放大、必然糊
  double get bitmapPerDisplayPixel =>
      display.width <= 0 ? 0 : bitmap.width / display.width;

  /// 位图是否达到物理像素（`>= 1` 才算清晰）
  bool get isPhysicalResolution =>
      bitmapPerDisplayPixel >= devicePixelRatio - 0.01;

  @override
  String toString() => 'PdfRenderDiagnostics(bitmap=$bitmap logical=$logical '
      'display=$display dpr=$devicePixelRatio '
      'bitmap/display=${bitmapPerDisplayPixel.toStringAsFixed(3)})';
}

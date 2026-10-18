import 'package:flutter/material.dart';

/// 平板横屏 / 桌面的断点（Material 3 的 compact / medium 分界）
///
/// 达到这个宽度就换成「侧边导航栏 + 更宽的内容区」的布局：
/// 手机竖屏用底部导航，横屏拿在手里底部栏会离拇指很远。
const double kWideBreakpoint = 720;

/// 更宽的断点：内容区可以再分栏（例如文档库双列）
const double kExtraWideBreakpoint = 1000;

/// 当前是不是宽屏（平板横屏 / 桌面）
bool isWideLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kWideBreakpoint;

/// 当前是不是超宽屏
bool isExtraWideLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kExtraWideBreakpoint;

/// 当前是不是平板（按最短边判断，横竖屏都成立）
///
/// 为什么要单独判：PDF 原版式在平板上**竖屏**时视口也很宽（800dp 上下），
/// 但 `isWideLayout` 只看宽不看高，竖屏平板是 800×1280 会被判成宽屏，
/// 而横屏手机（900×400）又不该按平板处理。用最短边更接近「这是不是大屏设备」。
bool isTabletLayout(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.shortestSide >= 600;
}

/// 当前是不是平板或更大的屏幕
bool isLargeScreen(BuildContext context) =>
    isTabletLayout(context) || isWideLayout(context);

/// 文档库网格列数：手机 1 列，平板 2 列，大平板 / 桌面 3 列
int libraryColumns(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width >= 1280) return 3;
  if (width >= kWideBreakpoint) return 2;
  return 1;
}

/// 阅读页是否按「平板画布」处理
///
/// 判据用**最短边 + 高度**，不是单独看宽度：
///   · 只看宽度会把横屏手机（900×400）当成平板 —— 它屏幕那么矮，
///     加大上下留白只会把正文挤没；
///   · 只看最短边会把 800×600 这种矮窗口算进来（widget 测试默认画布就是它）。
/// 所以要求「最短边 ≥600 且高度 ≥700」。
bool _isTabletCanvas(Size size) =>
    size.shortestSide >= 600 && size.height >= 700;

/// 阅读页正文栏宽（纯函数，便于单测）
///
/// 手机上原来的 820 已经够用；平板上真正的毛病是「把手机那一栏居中一放，
/// 左右各空 200+dp」，看着就像没做适配。所以按屏宽分三档：
/// 手机 820 / 平板 900 / 超宽 960。
///
/// 不直接拉满的原因：中文一行超过 ~45 字时回行很容易串行。
double readerMaxContentWidthFor(Size size) {
  if (size.width >= kExtraWideBreakpoint && _isTabletCanvas(size)) return 960;
  if (_isTabletCanvas(size)) return 900;
  return 820;
}

/// 阅读页页边距**下限**（纯函数）
///
/// 大屏上仍然用手机的 12dp 边距会显得文字贴着栏边。这里给一个下限，
/// 用户自己在设置里调得更大时以用户为准。
double readerMinPageMarginFor(Size size) {
  if (size.width >= kExtraWideBreakpoint && _isTabletCanvas(size)) return 40;
  if (_isTabletCanvas(size)) return 32;
  return 0;
}

/// 阅读页每页列表的上下留白（纯函数）
///
/// 手机上顶部 8 / 底部 80 是为了让最后一行不被控制栏挡住；平板屏幕高得多，
/// 沿用这两个值会让正文顶到状态栏、底部空一大片。
({double top, double bottom}) readerPageVerticalPaddingFor(Size size) {
  if (_isTabletCanvas(size)) return (top: 24, bottom: 120);
  return (top: 8, bottom: 80);
}

/// [readerMaxContentWidthFor] 的 context 版本
double readerMaxContentWidth(BuildContext context) =>
    readerMaxContentWidthFor(MediaQuery.sizeOf(context));

/// [readerMinPageMarginFor] 的 context 版本
double readerMinPageMargin(BuildContext context) =>
    readerMinPageMarginFor(MediaQuery.sizeOf(context));

/// [readerPageVerticalPaddingFor] 的 context 版本
({double top, double bottom}) readerPageVerticalPadding(BuildContext context) =>
    readerPageVerticalPaddingFor(MediaQuery.sizeOf(context));

/// 阅读页是否按「平板画布」处理（D2 布局只在平板生效）
bool readerIsTabletCanvas(BuildContext context) =>
    _isTabletCanvas(MediaQuery.sizeOf(context));

/// 内容居中并限制最大宽度
///
/// 平板上最容易忽略的问题不是「显示不下」，而是**一行太长**：
/// 正文铺满 1200dp 时眼睛很难换行，所以正文 / 设置这类纵向内容统一限宽居中。
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth = 760});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

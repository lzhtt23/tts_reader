import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 控制栏的展开形态（v1.22.62 · 用户 2026-10-27 拍板）
///
/// · [capsule] 横胶囊（MD3 风格）—— **默认**
/// · [radial]  扇形环绕（逐键弹出动效）—— 设置里可切换
enum PdfControlStyle { capsule, radial }

/// PDF 朗读页控制栏：**收起 = 悬浮键 / 展开 = 悬浮面板**
///
/// ## 两种形态（设置里切换，默认胶囊）
/// ```
/// 胶囊：  [⏮] [⏯] [⏭] │ [目录] [结束] [⌄]    贴右下，MD3 filled/tonal
/// 扇形：        [目录] [⏭]
///              [⏮]  [⏯]  [结束]              主键不动，四键依次弹出
/// ```
///
/// ## 收起
/// 两种形态都是：**左侧小箭头（展开）+ 右侧圆形暂停键**，悬浮在正文右下角，
/// **不占正文高度**（父页面把它画在 Stack 里，见 `pdf_reading_page.dart`）。
///
/// ## 为什么不再显示书名/页码
/// 用户 2026-10-27：「展开样式也可以悬浮，精简只剩控件即可，不需文件名」。
class PdfControlBar extends StatefulWidget {
  const PdfControlBar({
    super.key,
    required this.collapsed,
    required this.style,
    required this.playing,
    required this.paused,
    required this.onToggleCollapsed,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
    required this.onStop,
    required this.onOpenToc,
    this.onTocOptions,
  });

  /// 是否收起成悬浮键
  final bool collapsed;

  /// 展开形态
  final PdfControlStyle style;

  /// **正在出声**（暂停态为 false）
  final bool playing;

  /// **暂停**（与"方块键停声"区分开）
  ///
  /// ⚠️ v1.21.38：`playing` 与 `paused` 必须分开传（原来只看 `playing` 的二态）。
  /// 通知栏判据是 `hasSession && playing && !paused`（三态），
  /// 栏内看得到 `paused` 才不会把"暂停"和"方块键停声"显示成同一个图标。
  final bool paused;

  final VoidCallback onToggleCollapsed;
  final VoidCallback onPlayPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onStop;
  final VoidCallback onOpenToc;

  /// 「更多」入口（预留；当前未使用，保持可空以免破坏调用点）
  final VoidCallback? onTocOptions;

  static const Key miniBarKey = ValueKey<String>('pdf-control-mini');
  static const Key expandedKey = ValueKey<String>('pdf-control-expanded');
  static const Key playPauseKey = ValueKey<String>('pdf-control-play-pause');
  static const Key stopKey = ValueKey<String>('pdf-control-stop');
  static const Key prevKey = ValueKey<String>('pdf-control-prev');
  static const Key nextKey = ValueKey<String>('pdf-control-next');
  static const Key tocKey = ValueKey<String>('pdf-control-toc');
  static const Key expandKey = ValueKey<String>('pdf-control-expand');
  static const Key collapseKey = ValueKey<String>('pdf-control-collapse');

  /// 悬浮键距底部的高度
  ///
  /// 88 = 「回到朗读位置」FAB（约 64 含外边距）+ 24 间距 ——
  /// 两个都靠右下角，必须错开，否则叠在一起点不到。
  static const double floatingBottomInset = 88;

  /// 主键直径（MD3 大 FAB 尺寸）
  static const double mainButtonSize = 56;

  /// 其余键直径（MD3 标准 icon button）
  static const double smallButtonSize = 40;

  @override
  State<PdfControlBar> createState() => _PdfControlBarState();
}

class _PdfControlBarState extends State<PdfControlBar>
    with SingleTickerProviderStateMixin {
  /// 展开动效（扇形逐键弹出用；胶囊也共用做淡入）
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: widget.collapsed ? 0 : 1,
    );
  }

  @override
  void didUpdateWidget(covariant PdfControlBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.collapsed != widget.collapsed) {
      if (widget.collapsed) {
        _anim.reverse();
      } else {
        _anim.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.collapsed ? _floating(context) : _expanded(context);
  }

  // ───────────────────── 收起态：悬浮键 ─────────────────────

  Widget _floating(BuildContext context) {
    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.only(
          right: 16,
          bottom: PdfControlBar.floatingBottomInset,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _roundButton(
              context,
              key: PdfControlBar.expandKey,
              icon: Icons.keyboard_arrow_up,
              tooltip: '展开控制栏',
              size: PdfControlBar.smallButtonSize,
              tonal: true,
              onTap: widget.onToggleCollapsed,
            ),
            const SizedBox(width: 10),
            _roundButton(
              context,
              key: PdfControlBar.playPauseKey,
              icon: widget.playing ? Icons.pause : Icons.play_arrow,
              tooltip: widget.playing ? '暂停' : '继续朗读',
              size: PdfControlBar.mainButtonSize,
              filled: true,
              onTap: widget.onPlayPause,
            ),
          ],
        ),
      ),
    );
  }

  // ───────────────────── 展开态 ─────────────────────

  Widget _expanded(BuildContext context) {
    return widget.style == PdfControlStyle.radial
        ? _radial(context)
        : _capsule(context);
  }

  /// 胶囊：一行 icon，MD3 filled/tonal + divider
  Widget _capsule(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.bottomRight,
      child: FadeTransition(
        opacity: _anim,
        child: Padding(
          padding: const EdgeInsets.only(
            right: 16,
            bottom: PdfControlBar.floatingBottomInset,
          ),
          child: Material(
            key: PdfControlBar.expandedKey,
            color: cs.surfaceContainerHigh,
            elevation: 6,
            shape: const StadiumBorder(),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _roundButton(context,
                      key: PdfControlBar.prevKey,
                      icon: Icons.skip_previous,
                      tooltip: '上一句',
                      size: PdfControlBar.smallButtonSize,
                      tonal: true,
                      onTap: widget.onPrevious),
                  const SizedBox(width: 6),
                  _roundButton(context,
                      key: PdfControlBar.playPauseKey,
                      icon: widget.playing ? Icons.pause : Icons.play_arrow,
                      tooltip: widget.playing ? '暂停' : '继续朗读',
                      size: PdfControlBar.mainButtonSize,
                      filled: true,
                      onTap: widget.onPlayPause),
                  const SizedBox(width: 6),
                  _roundButton(context,
                      key: PdfControlBar.nextKey,
                      icon: Icons.skip_next,
                      tooltip: '下一句',
                      size: PdfControlBar.smallButtonSize,
                      tonal: true,
                      onTap: widget.onNext),
                  // divider：MD3 里用来分组，比间距更省横向空间
                  Container(
                    width: 1,
                    height: 24,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    color: cs.outlineVariant,
                  ),
                  _roundButton(context,
                      key: PdfControlBar.tocKey,
                      icon: Icons.list_alt,
                      tooltip: '目录',
                      size: PdfControlBar.smallButtonSize,
                      tonal: true,
                      onTap: widget.onOpenToc),
                  const SizedBox(width: 6),
                  _roundButton(context,
                      key: PdfControlBar.stopKey,
                      icon: Icons.stop,
                      tooltip: '结束朗读',
                      size: PdfControlBar.smallButtonSize,
                      tonal: true,
                      onTap: widget.onStop),
                  const SizedBox(width: 6),
                  _roundButton(context,
                      key: PdfControlBar.collapseKey,
                      icon: Icons.keyboard_arrow_down,
                      tooltip: '收起',
                      size: PdfControlBar.smallButtonSize,
                      tonal: true,
                      onTap: widget.onToggleCollapsed),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 扇形：主键不动，四键依次弹出
  ///
  /// ## 为什么主键不动
  /// 用户 2026-10-27：「f 可以加一个按键逐个展开的动效」。
  /// 主键保持原位，视觉锚点不跳，展开/收起都不会点偏。
  Widget _radial(BuildContext context) {
    const double radius = 92;
    const double halfMain = PdfControlBar.mainButtonSize / 2;
    const double halfSmall = PdfControlBar.smallButtonSize / 2;
    // 画布边长：够放最远那个键 + 主键半径
    const double side = radius + halfMain + PdfControlBar.smallButtonSize + 8;

    final List<({double angle, Key key, IconData icon, String tip, VoidCallback onTap})>
        items = <({double angle, Key key, IconData icon, String tip, VoidCallback onTap})>[
      (angle: 180, key: PdfControlBar.prevKey, icon: Icons.skip_previous, tip: '上一句', onTap: widget.onPrevious),
      (angle: 135, key: PdfControlBar.nextKey, icon: Icons.skip_next, tip: '下一句', onTap: widget.onNext),
      (angle: 90, key: PdfControlBar.tocKey, icon: Icons.list_alt, tip: '目录', onTap: widget.onOpenToc),
      (angle: 225, key: PdfControlBar.stopKey, icon: Icons.stop, tip: '结束朗读', onTap: widget.onStop),
    ];

    // 主键圆心在画布右下角内侧
    const double mainCx = side - halfMain;
    const double mainCy = side - halfMain;

    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.only(
          right: 16,
          bottom: PdfControlBar.floatingBottomInset - 24,
        ),
        child: SizedBox(
          key: PdfControlBar.expandedKey,
          width: side,
          height: side + 44, // 底部再留出"收起"箭头的空间
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              for (int i = 0; i < items.length; i++)
                AnimatedBuilder(
                  animation: _anim,
                  builder: (BuildContext context, Widget? child) {
                    // 每个键错开 0.10 的窗口，形成"逐个弹出"
                    final double begin = (i * 0.10).clamp(0.0, 0.6);
                    final double end = (begin + 0.55).clamp(0.01, 1.0);
                    final double raw =
                        ((_anim.value - begin) / (end - begin)).clamp(0.0, 1.0);
                    final double t = Curves.easeOutBack.transform(raw);
                    final double rad = items[i].angle * math.pi / 180;
                    final double cx = mainCx + radius * t * math.cos(rad);
                    final double cy = mainCy - radius * t * math.sin(rad);
                    return Positioned(
                      left: cx - halfSmall,
                      top: cy - halfSmall,
                      child: Opacity(
                        opacity: raw.clamp(0.0, 1.0),
                        child: Transform.scale(scale: 0.6 + 0.4 * t, child: child),
                      ),
                    );
                  },
                  child: _roundButton(context,
                      key: items[i].key,
                      icon: items[i].icon,
                      tooltip: items[i].tip,
                      size: PdfControlBar.smallButtonSize,
                      tonal: true,
                      onTap: items[i].onTap),
                ),
              // 主键：位置固定
              Positioned(
                left: mainCx - halfMain,
                top: mainCy - halfMain,
                child: _roundButton(context,
                    key: PdfControlBar.playPauseKey,
                    icon: widget.playing ? Icons.pause : Icons.play_arrow,
                    tooltip: widget.playing ? '暂停' : '继续朗读',
                    size: PdfControlBar.mainButtonSize,
                    filled: true,
                    onTap: widget.onPlayPause),
              ),
              // 收起：主键正下方
              Positioned(
                left: mainCx - 16,
                top: mainCy + halfMain + 10,
                child: _roundButton(context,
                    key: PdfControlBar.collapseKey,
                    icon: Icons.keyboard_arrow_down,
                    tooltip: '收起',
                    size: 32,
                    tonal: true,
                    onTap: widget.onToggleCollapsed),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ───────────────────── 通用圆形按钮 ─────────────────────

  /// MD3 圆形 icon 按钮
  ///
  /// · [filled] 主色实心（主键）
  /// · [tonal]  secondaryContainer（次键）
  Widget _roundButton(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String tooltip,
    required double size,
    required VoidCallback onTap,
    bool filled = false,
    bool tonal = false,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color bg = filled
        ? cs.primary
        : (tonal ? cs.secondaryContainer : cs.surfaceContainerHighest);
    final Color fg = filled
        ? cs.onPrimary
        : (tonal ? cs.onSecondaryContainer : cs.onSurfaceVariant);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        elevation: filled ? 3 : 0,
        child: InkWell(
          key: key,
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, size: size * 0.5, color: fg, semanticLabel: tooltip),
          ),
        ),
      ),
    );
  }
}

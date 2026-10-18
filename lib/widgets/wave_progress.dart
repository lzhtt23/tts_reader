import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 波浪进度条（2026-10-18）
///
/// 用户给的参考图：**已读那一段不是直线，而是一条起伏的波浪**，右边接一段实心轨道，
/// 轨道尽头有一个圆点，左下角挂一个 `128 / 328` 的页码气泡。
///
/// 之所以单独抽出来：文档库的迷你条要用它，阅读页底部那条进度也要用同一种语言，
/// 否则两处会各画一套，粗细/波形对不上。
///
/// 动画：波浪相位随时间推进（[playing] 为 false 时停在原地，不空转耗电）。
class WaveProgressBar extends StatefulWidget {
  const WaveProgressBar({
    super.key,
    required this.value,
    this.label,
    this.height = 14,
    this.playing = true,
    this.color,
    this.trackColor,
  });

  /// 0~1 的进度
  final double value;

  /// 左下角的页码气泡文字（如 `128 / 328`）；传 null 就不画
  final String? label;

  final double height;

  /// 是否滚动波浪（暂停时静止，尊重省电）
  final bool playing;

  final Color? color;
  final Color? trackColor;

  @override
  State<WaveProgressBar> createState() => _WaveProgressBarState();
}

class _WaveProgressBarState extends State<WaveProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _phase = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant WaveProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) _sync();
  }

  void _sync() {
    final reduceMotion = !widget.playing;
    if (reduceMotion && _phase.isAnimating) {
      _phase.stop();
    } else if (!reduceMotion && !_phase.isAnimating) {
      _phase.repeat();
    }
  }

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = widget.color ?? scheme.primary;
    final track = widget.trackColor ?? scheme.surfaceContainerHighest;

    final bar = AnimatedBuilder(
      animation: _phase,
      builder: (context, _) => CustomPaint(
        size: Size(double.infinity, widget.height),
        painter: _WavePainter(
          value: widget.value.clamp(0.0, 1.0),
          phase: _phase.value,
          color: color,
          trackColor: track,
          dotColor: scheme.onSurfaceVariant,
        ),
      ),
    );

    if (widget.label == null) return bar;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 窄了就不画页码气泡：宁可少一样信息，也不要挤成两行把整条撑高
        final showLabel = constraints.maxWidth >= 120;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(height: widget.height, width: double.infinity, child: bar),
            if (showLabel) ...<Widget>[
              const SizedBox(height: 2),
              SizedBox(
                height: 16,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.label!,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.value,
    required this.phase,
    required this.color,
    required this.trackColor,
    required this.dotColor,
  });

  final double value;
  final double phase;
  final Color color;
  final Color trackColor;
  final Color dotColor;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final r = Radius.circular(h / 2);
    final trackRect = Rect.fromLTWH(0, 0, size.width, h);
    final trackPaint = Paint()..color = trackColor;
    canvas.drawRRect(RRect.fromRectAndRadius(trackRect, r), trackPaint);

    final filledWidth = size.width * value;
    if (filledWidth <= 0) return;

    // 已读段：波浪填充。波形随 phase 平移，看起来像"水在流"
    final wave = Path();
    final amp = h * 0.22;
    final wavelength = math.max(18.0, h * 1.6);
    final dy = h / 2 - amp; // 让波形整体落在条内
    wave.moveTo(0, dy);
    for (double x = 0; x <= filledWidth; x += 1) {
      final t = (x / wavelength + phase) * 2 * math.pi;
      wave.lineTo(x, dy + math.sin(t) * amp);
    }
    wave.lineTo(filledWidth, h);
    wave.lineTo(0, h);
    wave.close();

    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(trackRect, r));
    canvas.drawPath(wave, Paint()..color = color);
    canvas.restore();

    // 已读段的右端封口（贴一条竖线，避免波浪断在半空中显得毛糙）
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(trackRect, r));
    canvas.drawRect(
      Rect.fromLTWH(math.max(0, filledWidth - 1), 0, 1.5, h),
      Paint()..color = color,
    );
    canvas.restore();

    // 轨道尽头的圆点（参考图里那个白点）
    if (value < 1) {
      canvas.drawCircle(
        Offset(size.width - h / 2, h / 2),
        math.max(1.6, h * 0.16),
        Paint()..color = dotColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.value != value ||
      old.phase != phase ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.dotColor != dotColor;
}

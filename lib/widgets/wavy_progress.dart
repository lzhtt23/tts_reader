import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Material 3「Expressive」风格的**波浪形**线性进度条
///
/// ## 参数对齐官方 Compose 实现
///
/// 用户给了 `androidx.compose.material3` 里 `LinearWavyProgressIndicator` 的参考代码：
/// ```
/// stroke = Stroke(width = 4f)   → 线宽 4
/// trackStroke = Stroke(width = 4f)
/// amplitude = 3.5f              → 振幅 3.5
/// wavelength = 28.dp            → 波长 28
/// waveSpeed = 28.dp             → 波浪每秒移动一个波长
/// ```
/// 本类就是照这组数值画的（Flutter 3.24.5 没有这个组件，3.35+ 才有）。
///
/// ## 动效
///
/// * **确定进度**：波浪从左边按 `value` 长出来，剩下那截是平直轨道；
///   波峰本身按 `waveSpeed` 缓慢向右漂移（这是官方实现的"活"感来源）。
/// * **满进度（value ≥ 1）**：收成一条直线 —— 已经结束的东西不该还在动。
/// * **不确定进度**：一段波浪在轨道上来回跑。
class LinearWavyProgressIndicator extends StatefulWidget {
  const LinearWavyProgressIndicator({
    super.key,
    this.value,
    this.minHeight,
    this.color,
    this.backgroundColor,
    this.semanticsLabel,
    this.wavelength = 28,
    this.amplitude = 3.5,
    this.strokeWidth = 4,
    this.waveSpeed = 28,
  });

  /// 0.0–1.0；null = 不确定进度（会自己动）
  final double? value;

  /// 最小高度；实际高度会保证装得下 `2×振幅 + 线宽`
  final double? minHeight;

  final Color? color;
  final Color? backgroundColor;
  final String? semanticsLabel;

  /// 一个完整波长的横向长度
  final double wavelength;

  /// 波峰高度（波峰到中线）
  final double amplitude;

  /// 线宽
  final double strokeWidth;

  /// 波浪漂移速度（单位/秒）；等于 [wavelength] 时每秒走一个波长
  final double waveSpeed;

  /// 装得下波形的最小高度
  double get preferredHeight =>
      math.max(minHeight ?? 0, amplitude * 2 + strokeWidth);

  @override
  State<LinearWavyProgressIndicator> createState() =>
      _LinearWavyProgressIndicatorState();
}

class _LinearWavyProgressIndicatorState extends State<LinearWavyProgressIndicator>
    with SingleTickerProviderStateMixin {
  /// 固定 1 秒一圈：相位按「每秒走 waveSpeed/wavelength 个波长」换算，
  /// 这样改 waveSpeed 不用改动画时长。
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  bool get _indeterminate => widget.value == null;

  @override
  void initState() {
    super.initState();
    // 确定进度也要漂移（官方实现就是这个行为），所以一直跑
    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color active = widget.color ?? scheme.primary;
    // 轨道要看得见：浅色主题下 surfaceContainerHighest 几乎和背景同色
    final Color track = widget.backgroundColor ?? scheme.outlineVariant.withAlpha(150);
    final double height = widget.preferredHeight;
    final double speedRatio = widget.wavelength <= 0
        ? 1.0
        : widget.waveSpeed / widget.wavelength;

    return Semantics(
      label: widget.semanticsLabel,
      value: _indeterminate
          ? null
          : '${((widget.value ?? 0) * 100).round()}%',
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (BuildContext context, Widget? _) {
            return CustomPaint(
              painter: _WavyPainter(
                value: widget.value,
                // 相位（弧度）：一秒走 speedRatio 个波长
                phase: _controller.value * math.pi * 2 * speedRatio,
                shot: _controller.value,
                active: active,
                track: track,
                amplitude: widget.amplitude,
                wavelength: widget.wavelength <= 0 ? 28 : widget.wavelength,
                strokeWidth: widget.strokeWidth,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _WavyPainter extends CustomPainter {
  _WavyPainter({
    required this.value,
    required this.phase,
    required this.shot,
    required this.active,
    required this.track,
    required this.amplitude,
    required this.wavelength,
    required this.strokeWidth,
  });

  final double? value;

  /// 波的相位（弧度）
  final double phase;

  /// 0→1 的循环进度（不确定进度用它算"跑动位置"）
  final double shot;

  final Color active;
  final Color track;
  final double amplitude;
  final double wavelength;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final double midY = size.height / 2;
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    // ① 轨道：平直的圆头线
    canvas.drawLine(
      Offset(strokeWidth / 2, midY),
      Offset(size.width - strokeWidth / 2, midY),
      stroke..color = track,
    );

    final double? v = value;
    if (v == null) {
      // ② 不确定进度：一段波浪来回跑
      const double spanFraction = 0.38;
      final double span = size.width * spanFraction;
      final double t = shot * 2 > 1 ? 2 - shot * 2 : shot * 2;
      final double startX = (size.width + span) * t - span;
      _drawWave(
        canvas,
        midY: midY,
        fromX: startX.clamp(strokeWidth / 2, size.width),
        toX: (startX + span).clamp(0, size.width - strokeWidth / 2),
        paint: stroke..color = active,
        phase: phase,
      );
      return;
    }

    // ③ 确定进度
    final double clamped = v.clamp(0.0, 1.0);
    if (clamped <= 0) return;
    if (clamped >= 1) {
      // 满了 → 直线（波浪收掉）
      canvas.drawLine(
        Offset(strokeWidth / 2, midY),
        Offset(size.width - strokeWidth / 2, midY),
        stroke..color = active,
      );
      return;
    }
    _drawWave(
      canvas,
      midY: midY,
      fromX: strokeWidth / 2,
      toX: size.width * clamped,
      paint: stroke..color = active,
      phase: phase,
    );
  }

  void _drawWave(
    Canvas canvas, {
    required double midY,
    required double fromX,
    required double toX,
    required Paint paint,
    required double phase,
  }) {
    if (toX <= fromX) return;
    final Path path = Path();
    // 采样步长取波长的 1/12：再细看不出差别，反而慢
    final double step = math.max(1.0, wavelength / 12);
    var x = fromX;
    var first = true;
    while (x <= toX) {
      final double y =
          midY + amplitude * math.sin((x / wavelength) * math.pi * 2 + phase);
      if (first) {
        path.moveTo(x, y);
        first = false;
      } else {
        path.lineTo(x, y);
      }
      x += step;
    }
    final double yEnd =
        midY + amplitude * math.sin((toX / wavelength) * math.pi * 2 + phase);
    path.lineTo(toX, yEnd);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _WavyPainter old) =>
      old.value != value ||
      old.phase != phase ||
      old.shot != shot ||
      old.active != active ||
      old.track != track ||
      old.amplitude != amplitude ||
      old.wavelength != wavelength ||
      old.strokeWidth != strokeWidth;
}

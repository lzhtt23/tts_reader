import 'package:flutter/material.dart';

/// 慢速旋转的齿轮（加载指示器）
///
/// 用来对齐「文档库迷你条」上那个转动的造型：那里是 6 秒一圈的碟片，
/// 转起来有"在干活"的感觉又不晃眼。这里用齿轮图标 + 同样的慢速。
///
/// 为什么不直接用 `CircularProgressIndicator`：转圈太快、太"系统"，
/// 和迷你条那种慢悠悠的观感不一致（用户明确要求「动画不要太快」）。
class GearSpinner extends StatefulWidget {
  const GearSpinner({
    super.key,
    this.size = 28,
    this.color,
    this.period = const Duration(seconds: 6),
  });

  final double size;
  final Color? color;

  /// 转一圈的时长（默认 6 秒，与迷你条一致）
  final Duration period;

  @override
  State<GearSpinner> createState() => _GearSpinnerState();
}

class _GearSpinnerState extends State<GearSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.period,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color color = widget.color ?? Theme.of(context).colorScheme.primary;
    return RotationTransition(
      turns: _controller,
      child: Icon(
        Icons.settings,
        size: widget.size,
        color: color,
      ),
    );
  }
}

/// 齿轮 + 一行说明（居中加载态常用）
class GearLoading extends StatelessWidget {
  const GearLoading({
    super.key,
    required this.label,
    this.size = 34,
    this.color,
  });

  final String label;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          GearSpinner(size: size, color: color),
          const SizedBox(height: 14),
          Text(
            label,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

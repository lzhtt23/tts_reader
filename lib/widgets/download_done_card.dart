import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 「下载完成」悬浮卡（方案 4）
///
/// 版式：
/// ```
/// ┌──────────────────────────────┐
/// │ 下载完成              ( 3 )  │   ← 右上倒计时圆环
/// │ 钢铁是怎样炼成的              │
/// │ 已加入文档库，可以直接开始朗读 │
/// │                              │
/// │ [ 立即朗读 ]  [  关闭  ]      │
/// └──────────────────────────────┘
/// ```
///
/// **3 秒自动收起**（用户要求，与新手教程的 readGate 一致），
/// 也可以点「关闭」立刻收起、点「立即朗读」直接进阅读页。
///
/// 为什么不用 SnackBar：SnackBar 撑不出这种大按钮 + 倒计时环的版式，
/// 而且它挤在底部会盖住浏览器的地址栏交互。
Future<void> showDownloadDoneCard(
  BuildContext context, {
  required String bookName,
  required VoidCallback onRead,
  Duration autoClose = const Duration(seconds: 3),
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierLabel: '下载完成',
    barrierColor: Colors.black.withAlpha(24),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (BuildContext dialogContext, Animation<double> a1,
        Animation<double> a2) {
      return _DownloadDoneCard(
        bookName: bookName,
        onRead: onRead,
        autoClose: autoClose,
      );
    },
  );
}

class _DownloadDoneCard extends StatefulWidget {
  const _DownloadDoneCard({
    required this.bookName,
    required this.onRead,
    required this.autoClose,
  });

  final String bookName;
  final VoidCallback onRead;
  final Duration autoClose;

  @override
  State<_DownloadDoneCard> createState() => _DownloadDoneCardState();
}

class _DownloadDoneCardState extends State<_DownloadDoneCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.autoClose,
  );

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((AnimationStatus s) {
      if (s == AnimationStatus.completed) _close();
    });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _close() {
    if (!mounted) return;
    final NavigatorState nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  void _read() {
    // 先关卡片，再跳 —— 否则阅读页会在卡片底下打开，返回时卡片还在
    final NavigatorState nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
    widget.onRead();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double width = math.min(
      380,
      MediaQuery.sizeOf(context).width - 32,
    );

    return Center(
      child: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: width,
          child: Card(
            elevation: 8,
            color: scheme.surfaceContainerHigh,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '下载完成',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      AnimatedBuilder(
                        animation: _controller,
                        builder: (BuildContext context, Widget? _) {
                          final double left =
                              (1 - _controller.value).clamp(0.0, 1.0);
                          final int seconds =
                              (left * widget.autoClose.inMilliseconds / 1000)
                                  .ceil();
                          return _CountdownRing(
                            progress: left,
                            seconds: seconds <= 0 ? 0 : seconds,
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.bookName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '已加入文档库，可以直接开始朗读',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: FilledButton(
                          autofocus: true,
                          onPressed: _read,
                          child: const Text('立即朗读'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: _close,
                          child: const Text('关闭'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 倒计时圆环（右上角，剩几秒就显示几）
class _CountdownRing extends StatelessWidget {
  const _CountdownRing({required this.progress, required this.seconds});

  /// 1 → 0（剩余比例）
  final double progress;
  final int seconds;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 34,
      height: 34,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          CustomPaint(
            size: const Size(34, 34),
            painter: _RingPainter(
              progress: progress,
              color: scheme.primary,
              track: scheme.outlineVariant.withAlpha(120),
            ),
          ),
          Text(
            '$seconds',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: scheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.track,
  });

  final double progress;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = (size.width - 6) / 2;
    final Paint base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..color = track;
    canvas.drawCircle(center, radius, base);

    if (progress <= 0) return;
    final Paint arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      math.pi * 2 * progress,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress || old.color != color || old.track != track;
}

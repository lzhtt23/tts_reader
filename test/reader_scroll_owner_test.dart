import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/pages/reader_page.dart';

/// 回归测试：跟随滚动「完成」的结局判定，以及外推限幅。
///
/// 真机（2026-10-18）：
/// ```
/// 16:08:47.493338  滚动跟随[滚动发起] 起点=2452.6 目标=2843.8
/// 16:08:47.494197  滚动跟随[滚动完成] 落点=2533.8 误差=310.0px ★未到位
/// 16:08:47.495034  朗读跟随[定位完成] 块=2638 ensureVisible（外推后）
/// ```
/// **1 毫秒**就"完成"、落点停在起止点中间 —— 是定位链的
/// `ensureVisible(duration: 0)`（jumpTo）把 `animateTo` 打断了，
/// 而 `animateTo` 被打断时 Future 也会正常完成。原来只按误差判，
/// 「被接管」和「撞界」分不开。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('跟随滚动结局判定', () {
    test('★动画 1ms 就回来、落点半路 → 判为「被打断」，不是「撞界」', () {
      expect(
        classifyFollowScroll(error: 310, elapsedMs: 1, superseded: false),
        FollowScrollOutcome.interrupted,
        reason: '★200ms 的动画跑 1ms 不可能走完：这是被别的路径 jumpTo 掉了，'
            '错报成"撞界"就永远看不出是谁打断了谁',
      );
    });

    test('★已被新目标接管 → 也判「被打断」', () {
      expect(
        classifyFollowScroll(error: 310, elapsedMs: 200, superseded: true),
        FollowScrollOutcome.interrupted,
      );
    });

    test('反向：走满 200ms 仍未到位才是「撞界」', () {
      expect(
        classifyFollowScroll(error: 310, elapsedMs: 200, superseded: false),
        FollowScrollOutcome.clipped,
      );
    });

    test('反向：误差 <1.5px 一律算「已到位」（不管用时）', () {
      expect(
        classifyFollowScroll(error: 0.4, elapsedMs: 1, superseded: false),
        FollowScrollOutcome.arrived,
      );
      expect(
        classifyFollowScroll(error: 0.4, elapsedMs: 200, superseded: true),
        FollowScrollOutcome.arrived,
      );
    });
  });

  group('外推定位单轮限幅', () {
    test('★目标很远时只走 3 个视口高（真机 43.4 → 11396 那条）', () {
      expect(
        clampExtrapolateStep(want: 11396, from: 43.4, viewport: 600, maxViewports: 3),
        closeTo(43.4 + 1800, 0.01),
      );
    });

    test('反向：目标在附近时不做限幅', () {
      expect(
        clampExtrapolateStep(want: 500, from: 43.4, viewport: 600, maxViewports: 3),
        500,
      );
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/features/pdf_reading/pdf_control_bar.dart';

/// **PDF 控制栏的三态口径**（v1.21.38）
///
/// 用户报：「在朗读界面点击方块键停止后，再按通知栏控制，暂停和启动按钮会和
/// 其它控制栏不同步」。
///
/// 根因是**两处对同一状态用了不同判据**：
/// - 通知栏（`tts_audio_handler`）：`hasSession && playing && !paused` → 三态；
/// - 栏内（`pdf_reading_page`）：只有 `isPlaying` → 二态，
///   于是"暂停中"与"方块键停声后"显示同一个 ▶，按下去却走不同分支。
///
/// 修法：栏内也吃三态（[PdfControlBar.playing] = 正在出声、[PdfControlBar.paused] = 暂停），
/// 图标与动作都从同一套判据推出来。这条用例把对应关系钉死。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpBar(
    WidgetTester tester, {
    required bool playing,
    required bool paused,
    VoidCallback? onPlayPause,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: PdfControlBar(
          collapsed: false,
          style: PdfControlStyle.capsule,
          playing: playing,
          paused: paused,
          onToggleCollapsed: () {},
          onPlayPause: onPlayPause ?? () {},
          onPrevious: () {},
          onNext: () {},
          onStop: () {},
          onOpenToc: () {},
        ),
      ),
    ));
  }

  IconData iconOf(WidgetTester tester) {
    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(PdfControlBar.playPauseKey),
        matching: find.byType(Icon),
      ),
    );
    return icon.icon!;
  }

  testWidgets('正在朗读 → 显示暂停图标，不可点（暂停不是"停声"）', (tester) async {
    await pumpBar(tester, playing: true, paused: false);
    expect(iconOf(tester), Icons.pause);
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-bar] playing=true paused=false → 暂停图标');
  });

  testWidgets('暂停中 → 显示播放图标', (tester) async {
    await pumpBar(tester, playing: false, paused: true);
    expect(iconOf(tester), Icons.play_arrow);
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-bar] playing=false paused=true → 播放图标');
  });

  testWidgets('方块键停声后（既不在播也没暂停）→ 播放图标', (tester) async {
    await pumpBar(tester, playing: false, paused: false);
    expect(iconOf(tester), Icons.play_arrow);
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-bar] playing=false paused=false（停声）→ 播放图标');
  });

  testWidgets('三种状态下按一下都会回调 onPlayPause（分派由调用方按同一套三态决定）',
      (tester) async {
    var taps = 0;
    for (final (bool playing, bool paused) in <(bool, bool)>[
      (true, false),
      (false, true),
      (false, false),
    ]) {
      taps = 0;
      await pumpBar(
        tester,
        playing: playing,
        paused: paused,
        onPlayPause: () => taps++,
      );
      await tester.tap(find.byKey(PdfControlBar.playPauseKey));
      await tester.pump();
      expect(taps, 1, reason: 'playing=$playing paused=$paused 时按键必须回调');
    }
  });
}

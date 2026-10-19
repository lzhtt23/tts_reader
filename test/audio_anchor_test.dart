import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/audio_anchor.dart';

/// 静音 WAV 的字节结构要正确（拿它当"音频锚点"占住一条音频轨）
///
/// 关键点：just_audio 要能把它当合法 WAV 播出来；
/// 头写错就是「锚点开不起来」，而这恰恰是修耳机键的那一步。
void main() {
  test('生成的是合法单声道 8bit 静音 WAV', () {
    final b = AudioAnchor.silentWavForTest();
    // RIFF....WAVE
    expect(String.fromCharCodes(b.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(b.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(b.sublist(12, 16)), 'fmt ');
    expect(String.fromCharCodes(b.sublist(36, 40)), 'data');
    // 长度：44 字节头 + 8000 样本
    expect(b.length, 44 + 8000);
    // 静音样本是 0x80（8bit 无符号中值）
    expect(b.sublist(44, 44 + 16).every((int v) => v == 0x80), isTrue);
  });
}

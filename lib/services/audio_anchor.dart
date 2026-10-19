import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'crash_log.dart';

/// 「音频锚点」：朗读时让**本应用自己**持有一个静音音频输出
///
/// ## 为什么需要这个（真机 2026-10-19）
///
/// 平板（ColorOS 系）上：通知栏/音量面板里的暂停键能用，但蓝牙耳机键
/// **一条记录都到不了应用**。原因是我们的声音由**系统 TTS 引擎那个进程**
/// 放出来 —— 系统认为"正在出声的应用"是引擎，媒体键自然不派给我们。
///
/// 补一个「本进程的音频输出」后，系统会把我们当成正在播放的媒体应用，
/// 媒体键就有机会派给我们的 MediaSession。
///
/// ## 关键约束（别把朗读本身弄坏）
///
/// * `handleAudioFocus: false` —— **绝不申请音频焦点**。
///   我们的 TTS 引擎要自己申请焦点读出声；这里再抢一次会把朗读压低或打断。
/// * 音量 0、1 秒静音、单曲循环 —— 听不到，耗电极小。
/// * 只在「正在朗读」时开，停了立刻关。
class AudioAnchor {
  AudioAnchor._();

  static final AudioAnchor instance = AudioAnchor._();

  AudioPlayer? _player;
  bool _starting = false;
  String? _silencePath;

  bool get running => _player != null;

  /// 开始持有音频输出（重复调用安全）
  Future<void> start() async {
    if (_player != null || _starting) return;
    _starting = true;
    try {
      final String path = await _ensureSilenceFile();
      // ⚠️ `handleAudioSessionActivation: false`：**不激活音频会话 = 不申请焦点**。
      // 我们的 TTS 引擎要自己申请焦点读出声；这里再抢一次会把朗读压低或打断。
      final AudioPlayer player =
          AudioPlayer(handleAudioSessionActivation: false);
      await player.setAudioSource(AudioSource.file(path));
      await player.setLoopMode(LoopMode.one);
      await player.setVolume(0);
      // 不 await play()：用户没开声音，播完这行就算"占用中"
      unawaited(player.play());
      _player = player;
      CrashLog.mark('音频锚点[开] 已持有静音音频输出');
    } catch (e) {
      CrashLog.mark('音频锚点[失败] $e');
      _player = null;
    } finally {
      _starting = false;
    }
  }

  /// 释放音频输出（重复调用安全）
  Future<void> stop() async {
    final AudioPlayer? player = _player;
    _player = null;
    if (player == null) return;
    try {
      await player.stop();
      await player.dispose();
      CrashLog.mark('音频锚点[关] 已释放');
    } catch (_) {
      // 释放失败无所谓：下次 start 会重开
    }
  }

  /// 生成（并缓存）一个 1 秒静音的 WAV
  Future<String> _ensureSilenceFile() async {
    final String? cached = _silencePath;
    if (cached != null && File(cached).existsSync()) return cached;
    final Directory dir = await getTemporaryDirectory();
    final String path = '${dir.path}/silence_1s.wav';
    final File file = File(path);
    if (!file.existsSync()) {
      await file.writeAsBytes(_silentWav(), flush: true);
    }
    _silencePath = path;
    return path;
  }

  /// 8kHz / 单声道 / 8bit 的 1 秒静音 WAV（约 8KB）
  static Uint8List _silentWav() {
    const int sampleRate = 8000;
    const int seconds = 1;
    const int dataLength = sampleRate * seconds; // 8bit 单声道：1 字节/样本
    final ByteData header = ByteData(44);
    // RIFF
    header.setUint8(0, 0x52);
    header.setUint8(1, 0x49);
    header.setUint8(2, 0x46);
    header.setUint8(3, 0x46);
    header.setUint32(4, 36 + dataLength, Endian.little); // 文件长度 - 8
    header.setUint8(8, 0x57); // WAVE
    header.setUint8(9, 0x41);
    header.setUint8(10, 0x56);
    header.setUint8(11, 0x45);
    // fmt
    header.setUint8(12, 0x66);
    header.setUint8(13, 0x6D);
    header.setUint8(14, 0x74);
    header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little); // fmt chunk 大小
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, 1, Endian.little); // 单声道
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate, Endian.little); // 字节率
    header.setUint16(32, 1, Endian.little); // 块对齐
    header.setUint16(34, 8, Endian.little); // 位深
    // data
    header.setUint8(36, 0x64);
    header.setUint8(37, 0x61);
    header.setUint8(38, 0x74);
    header.setUint8(39, 0x61);
    header.setUint32(40, dataLength, Endian.little);

    final Uint8List out = Uint8List(44 + dataLength);
    out.setRange(0, 44, header.buffer.asUint8List());
    // 8bit PCM 的静音是 0x80（无符号，中值）
    out.fillRange(44, out.length, 0x80);
    return out;
  }

  @visibleForTesting
  static Uint8List silentWavForTest() => _silentWav();
}

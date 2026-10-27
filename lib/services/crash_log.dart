import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 崩溃 / 异常落盘。
///
/// 为什么需要它：`adb logcat` 是内存环形缓冲，手机重启或长时间运行后内容就没了；
/// 而 Dart 侧未捕获异常（尤其是 await 链里抛出的异步异常）在 release 包里默认
/// 什么都不会留下。这里把异常连同时间、上下文写进应用私有目录的文件，
/// 崩溃后仍然拿得到。
///
/// 取日志：`adb shell run-as com.example.tts_reader cat files/crash.log`
/// 或在应用「设置 → 诊断日志」里查看 / 分享。
class CrashLog {
  CrashLog._();

  static const String fileName = 'crash.log';
  static const int _maxBytes = 256 * 1024;

  static File? _file;
  static bool _installed = false;
  static final List<String> _recent = <String>[];

  /// 最近若干条记录（设置页展示用）
  static List<String> get recent => List<String>.unmodifiable(_recent);

  static Future<File?> get file async => _file;

  /// 安装全局异常钩子，并把 app 启动 / 上次退出标记写进日志
  static Future<void> install() async {
    if (_installed) return;
    _installed = true;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$fileName');
      await f.parent.create(recursive: true);
      _file = f;
      _chain = _chain.then((_) => _append('---- app 启动 ----'));
      await _chain;
    } catch (_) {
      // 拿不到目录就只留内存记录
    }

    // 1) 框架 / 平台未捕获异常
    final previous = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      unawaited(_writeError('FlutterError', details.exception, details.stack));
      previous?.call(details);
    };
    // 2) 不在 Widget 树里的异步异常（root isolate 的兜底）
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      unawaited(_writeError('未捕获异常', error, stack));
      return false;
    };
  }

  /// **写入串行队列**（v1.21.25）
  ///
  /// 为什么必须串行：`mark()` 是同步调用的（埋点散落在各处，可能同一帧里连打几条），
  /// 而 `writeAsString(mode: append)` 在多字节编码下**不保证整行原子** ——
  /// 真机日志实测出现行交错、关键行被吃掉半截
  /// （例：`取="s2026-10-10T23:29:03.987349  媒体控制[pushState→idle...`）。
  /// 串起来之后每条都等上一条写完，日志才可用来定位问题。
  static Future<void> _chain = Future<void>.value();

  /// 主动记一条（关键流程埋点，便于定位「崩在哪一步」）
  static void mark(String message) {
    // ★v1.22.62：**同时打到 logcat**，让 `adb logcat -s flutter` 能实时看到埋点。
    //
    // 为什么必须加：`mark()` 原来只写应用私有目录，而 release 包 `run-as` 被系统
    // 拒绝 → adb 读不到 → 每次排查都得让用户手工"导出日志→发文件"。
    // 定位这种要反复试的问题，这个成本高到无法迭代。
    //
    // release 包里 `print` 仍会进 logcat（flutter 标签），开销只是一次字符串
    // 拼接，可忽略。文件写入保持不变（崩溃后仍可回溯）。
    // ignore: avoid_print
    print(message);
    _chain = _chain.then((_) => _append(message));
  }

  /// 记录异常（与 [mark] 排在同一条队列里）
  static Future<void> record(String tag, Object error, [StackTrace? stack]) {
    final Future<void> next = _chain.then((_) => _writeError(tag, error, stack));
    _chain = next;
    return next;
  }

  static Future<void> _writeError(String tag, Object error, StackTrace? stack) async {
    final buffer = StringBuffer()
      ..writeln('[$tag] $error');
    if (stack != null) {
      buffer.writeln(stack.toString().split('\n').take(30).join('\n'));
    }
    await _append(buffer.toString());
  }

  static Future<void> _append(String text) async {
    final line = '${DateTime.now().toIso8601String()}  $text';
    _recent.insert(0, line);
    if (_recent.length > 200) _recent.removeLast();

    final f = _file;
    if (f == null) return;
    try {
      // 超过上限就截断重开，避免日志无限增长占满存储
      if (await f.exists() && await f.length() > _maxBytes) {
        await f.writeAsString('---- 日志已截断 ----\n');
      }
      await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // 写不进去也不能让应用崩在这
    }
  }

  static Future<String> read() async {
    final f = _file;
    if (f == null) return _recent.join('\n');
    try {
      if (await f.exists()) return await f.readAsString();
    } catch (_) {
      // 落到内存记录
    }
    return _recent.join('\n');
  }

  static Future<void> clear() async {
    _recent.clear();
    try {
      await _file?.writeAsString('');
    } catch (_) {
      // 忽略
    }
  }
}

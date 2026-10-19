import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/download_watcher.dart';

/// 下载文件改名：`.bin` 按文件头纠正成 .pdf / .epub / .txt
///
/// 真机场景（用户 2026-10-19）：annas-archive 的 `/slow_download/<hash>/` 地址
/// 没有文件名、服务器也不给 Content-Disposition，下载器兜底存成 `.bin`。
/// 内容是好的 PDF，但按扩展名判"不支持" → 用户看到「下载完成但打不开」。
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dl_name_');
  });

  tearDown(() async {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<File> write(String name, List<int> bytes) async {
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  test('PDF 头 → 改成 .pdf', () async {
    final f = await write('book.bin', <int>[...'%PDF-1.7'.codeUnits, 0, 1, 2]);
    final String out = await normalizeDownloadedName(f.path);
    expect(out, endsWith('.pdf'));
    expect(File(out).existsSync(), isTrue);
    expect(File(f.path).existsSync(), isFalse, reason: '是改名不是复制');
  });

  test('ZIP 头 → 改成 .epub', () async {
    final f = await write('book.bin', <int>[0x50, 0x4B, 0x03, 0x04, 1, 2, 3, 4]);
    expect(await normalizeDownloadedName(f.path), endsWith('.epub'));
  });

  test('纯文本 → 改成 .txt', () async {
    // ⚠️ 必须 utf8.encode：Dart 的 `codeUnits` 对中文给出 >0xFF 的值，
    // 写进文件会被截断成乱字节，反而判成二进制。
    final f = await write('book.bin', utf8.encode('第一章 正文'));
    expect(await normalizeDownloadedName(f.path), endsWith('.txt'));
  });

  test('已经是 .pdf 的不动', () async {
    final f = await write('ok.pdf', <int>[...'%PDF'.codeUnits, 0]);
    expect(await normalizeDownloadedName(f.path), f.path);
  });

  test('认不出的二进制 → 保持原名（不乱改）', () async {
    final f = await write('blob.bin', <int>[0, 0, 0, 0, 1, 9, 9, 9]);
    expect(await normalizeDownloadedName(f.path), f.path);
  });

  test('目标已存在 → 换带时间戳的名字，不覆盖', () async {
    await write('book.pdf', <int>[1, 2, 3]);
    final f = await write('book.bin', <int>[...'%PDF'.codeUnits, 0]);
    final String out = await normalizeDownloadedName(f.path);
    expect(out, endsWith('.pdf'));
    expect(out == '${dir.path}/book.pdf', isFalse, reason: '不能覆盖已有文件');
    expect(File('${dir.path}/book.pdf').readAsBytesSync(), <int>[1, 2, 3]);
  });

  test('文件不存在 → 原样返回，不抛', () async {
    final String p = '${dir.path}/nope.bin';
    expect(await normalizeDownloadedName(p), p);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tts_reader/services/cover_fetch.dart';

/// 从在线详情页抓封面（TXT 下载完就用它当封面）
///
/// 关键点：**任何失败都不能抛出**，只能返回 null ——
/// 封面是装饰，不能因为封面抓不到而让「书已经下好了」这件事失败。
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cover_fetch_');
  });

  tearDown(() async {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 最小合法 PNG 头（够过文件头判断）
  List<int> pngBytes() => <int>[
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
    ...List<int>.filled(64, 7),
  ];

  test('正常图片会落盘', () async {
    final String out = '${dir.path}/c.jpg';
    final client = MockClient((http.Request req) async {
      expect(req.headers['User-Agent'], isNotNull, reason: '要带 UA，否则很多站 403');
      return http.Response.bytes(pngBytes(), 200);
    });
    final String? path = await CoverFetcher.fetchTo(
      'https://a.com/cover.png',
      out,
      client: client,
    );
    expect(path, out);
    expect(File(out).existsSync(), isTrue);
    expect(File(out).lengthSync(), pngBytes().length);
  });

  test('HTTP 404 → null，不落盘', () async {
    final String out = '${dir.path}/404.jpg';
    final client = MockClient((_) async => http.Response('nope', 404));
    expect(
      await CoverFetcher.fetchTo('https://a.com/x.jpg', out, client: client),
      isNull,
    );
    expect(File(out).existsSync(), isFalse);
  });

  test('返回的是 HTML 错误页（200）→ null', () async {
    final String out = '${dir.path}/html.jpg';
    final client = MockClient(
      (_) async => http.Response('<html>403 Forbidden</html>', 200),
    );
    expect(
      await CoverFetcher.fetchTo('https://a.com/x.jpg', out, client: client),
      isNull,
    );
  });

  test('空地址 / 非 http 地址 → null（不联网）', () async {
    expect(await CoverFetcher.fetchTo('', '${dir.path}/a.jpg'), isNull);
    expect(await CoverFetcher.fetchTo('file:///x.jpg', '${dir.path}/b.jpg'), isNull);
  });

  test('网络异常 → null，不抛给调用方', () async {
    final client = MockClient((_) async => throw const SocketException('boom'));
    expect(
      await CoverFetcher.fetchTo(
        'https://a.com/x.jpg',
        '${dir.path}/err.jpg',
        client: client,
      ),
      isNull,
    );
  });
}

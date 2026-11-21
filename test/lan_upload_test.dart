// 局域网传书服务（v1.22.70）
//
// 这一组守两件事：
//   1. **文件名不可信**——它来自 HTTP 查询参数，直接拼路径就是目录穿越；
//   2. 收完的文件要真的落盘、真的回调，错误类型要给明确状态码。
//
// 用真实 HttpServer（绑 127.0.0.1）+ 真实 HTTP 客户端，不做假替身：
// 这套逻辑的坑全在「流式写盘 + 请求边界」上，替身测不出来。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/lan_upload_server.dart';

void main() {
  // ⚠️ 这个文件**不要**装 TestWidgetsFlutterBinding：
  // 一旦装上，flutter_test 会替换 HttpOverrides，让所有 HttpClient 请求
  // 直接返回 400 且不发包（官方警告："all HTTP requests will return status code 400"）。
  // 本组要测的正是真实 HTTP 往返，所以连「解除拦截」都不用——
  // 只要不初始化 binding 就是真实网络栈。

  group('文件名净化', () {
    test('目录穿越被拍平到最后一段', () {
      expect(LanUploadServer.sanitizeName('../../databases/x.db'), 'x.db');
      expect(LanUploadServer.sanitizeName(r'..\..\windows\win.ini'), 'win.ini');
      expect(LanUploadServer.sanitizeName('/etc/passwd'), 'passwd');
    });

    test('`..` 片段被删掉（防 a..b 之类的绕法）', () {
      expect(LanUploadServer.sanitizeName('a..b.pdf'), 'ab.pdf');
      // '....pdf' 里有两处不重叠的 '..'，replaceAll 全删 → 'pdf'
      expect(LanUploadServer.sanitizeName('....pdf'), 'pdf');
    });

    test('控制字符与非法分隔符被清掉', () {
      expect(LanUploadServer.sanitizeName('a\u0000b\u007f.pdf'), 'ab.pdf');
      expect(LanUploadServer.sanitizeName('a:b*c?.pdf'), 'a_b_c_.pdf');
    });

    test('纯点名字直接判无效', () {
      expect(LanUploadServer.sanitizeName('...'), '');
      expect(LanUploadServer.sanitizeName('  '), '');
    });

    test('正常中文名原样保留', () {
      expect(LanUploadServer.sanitizeName('毛远新的回忆（试编本）.pdf'),
          '毛远新的回忆（试编本）.pdf');
    });
  });

  group('服务行为', () {
    late LanUploadServer server;
    late HttpClient client;

    setUp(() async {
      server = LanUploadServer();
      await server.start(preferredPort: 18080);
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
    });

    test('GET / 返回上传页', () async {
      final HttpClientRequest req =
          await client.get('127.0.0.1', server.port, '/');
      final HttpClientResponse res = await req.close();
      final String body = await res.transform(utf8.decoder).join();
      expect(res.statusCode, 200);
      expect(body, contains('传书到'));
      expect(body, contains('/upload'));
    });

    test('POST 原始字节落盘并回调', () async {
      final List<String> got = <String>[];
      server.onFile = (File file, String name) {
        got.add('$name:${file.readAsStringSync()}');
      };

      final HttpClientRequest req = await client.post(
        '127.0.0.1',
        server.port,
        '/upload?name=${Uri.encodeComponent('测试书.pdf')}',
      );
      req.add(utf8.encode('PDF-CONTENT'));
      final HttpClientResponse res = await req.close();
      await res.drain<void>();

      expect(res.statusCode, 200);
      // 回调是同步发起的，但写盘是异步的 —— 给一点时间
      for (int i = 0; i < 20 && got.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(got, <String>['测试书.pdf:PDF-CONTENT']);
    });

    test('不支持的扩展名被拒（415）', () async {
      final HttpClientRequest req = await client.post(
        '127.0.0.1',
        server.port,
        '/upload?name=${Uri.encodeComponent('坏东西.exe')}',
      );
      req.add(<int>[1, 2, 3]);
      final HttpClientResponse res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, 415);
    });

    test('空文件被拒（400）', () async {
      final HttpClientRequest req = await client.post(
        '127.0.0.1',
        server.port,
        '/upload?name=a.txt',
      );
      final HttpClientResponse res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, 400);
    });

    test('文件名非法被拒（400）', () async {
      final HttpClientRequest req = await client.post(
        '127.0.0.1',
        server.port,
        '/upload?name=${Uri.encodeComponent('...')}',
      );
      req.add(<int>[1]);
      final HttpClientResponse res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, 400);
    });

    test('停止后端口可再次绑定（同号启动不报错）', () async {
      final int port = server.port;
      await server.stop();
      final LanUploadServer again = LanUploadServer();
      await again.start(preferredPort: port);
      expect(again.port, port);
      await again.stop();
    });
  });
}

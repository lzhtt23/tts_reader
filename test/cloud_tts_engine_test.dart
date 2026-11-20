// 云端 TTS 引擎的请求契约与失败分支（v1.22.66 补齐）
//
// 为什么补这一组：`cloud_tts_engine.dart` 是 117 个源文件里**唯一没有测试覆盖
// 的网络模块**（219 行）。它有 60 秒超时和若干失败分支，但一直没人喂过坏响应，
// 等于「出错时的行为」全靠线上撞。
//
// 覆盖范围（都不碰播放器）：
//   · 未配置时不发请求、直接给出可读提示
//   · 非 200 → CloudTtsException，消息里带状态码与响应片段
//   · 超长错误响应被截断到 180 字（避免弹窗被撑爆）
//   · 200 但空体 → 明确报「空音频」而不是喂给播放器
//   · 请求本身：端点补全、鉴权头、body 字段
//
// 不覆盖：真实合成成功的播放链路（需要 just_audio 平台实现），
// 以及 60 秒超时（真实等待太久）。这两条靠真机验证。
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tts_reader/tts/cloud_tts_engine.dart';

/// 构造一个把请求记下来、按给定状态码与响应体作答的引擎
({CloudTtsEngine engine, List<http.Request> requests}) makeEngine({
  required int statusCode,
  String body = '',
  Uint8List? bodyBytes,
  String baseUrl = 'https://api.example.test/v1',
  String apiKey = 'sk-test',
}) {
  final List<http.Request> requests = <http.Request>[];
  final MockClient client = MockClient((http.Request req) async {
    requests.add(req);
    return http.Response.bytes(
      bodyBytes ?? Uint8List.fromList(utf8.encode(body)),
      statusCode,
    );
  });
  return (
    engine: CloudTtsEngine(
      baseUrl: baseUrl,
      apiKey: apiKey,
      client: client,
    ),
    requests: requests,
  );
}

void main() {
  // CloudTtsEngine 的构造器会建 AudioPlayer，而 just_audio 一构造就去问
  // audio_session 要配置（MethodChannel）。单元测试没有原生侧，必须喂一个假实现，
  // 否则连"未配置不该发请求"这种纯逻辑用例都起不来。
  //
  // 这里只回答构造期间会问到的两个方法；播放相关方法本组用例不碰。
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final String channel in <String>[
      'com.ryanheise.audio_session',
      'com.ryanheise.just_audio.methods',
      'com.ryanheise.just_audio.events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (MethodCall call) async => null,
      );
    }
  });

  group('未配置时不发请求', () {
    test('baseUrl 为空 → isAvailable=false，speak 抛出可读提示', () async {
      final r = makeEngine(statusCode: 200, baseUrl: '', body: 'x');
      expect(r.engine.isAvailable, isFalse);
      await expectLater(
        r.engine.speak('你好'),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('云端 TTS 未配置'),
          ),
        ),
      );
      expect(r.requests, isEmpty, reason: '未配置就不该发出任何请求');
    });

    test('apiKey 只有空白字符也算未配置', () async {
      final r = makeEngine(statusCode: 200, apiKey: '   ');
      expect(r.engine.isAvailable, isFalse);
      await expectLater(r.engine.speak('你好'), throwsA(isA<StateError>()));
      expect(r.requests, isEmpty);
    });

    test('updateConfig 之后 isAvailable 变 true', () {
      final r = makeEngine(statusCode: 200, baseUrl: '', apiKey: '');
      expect(r.engine.isAvailable, isFalse);
      r.engine.updateConfig(
        baseUrl: 'https://api.example.test/v1',
        apiKey: 'sk-new',
      );
      expect(r.engine.isAvailable, isTrue);
    });
  });

  group('请求本身', () {
    test('端点补 /audio/speech，带上鉴权与 OpenAI 兼容 body', () async {
      final r = makeEngine(
        statusCode: 500,
        body: 'boom',
      );
      await expectLater(
        r.engine.speak('测试一句'),
        throwsA(isA<CloudTtsException>()),
      );
      expect(r.requests, hasLength(1));
      final http.Request req = r.requests.single;
      expect(req.method, 'POST');
      expect(req.url.toString(), 'https://api.example.test/v1/audio/speech');
      expect(req.headers['Authorization'], 'Bearer sk-test');
      expect(req.headers['Content-Type'], contains('application/json'));
      final Map<String, dynamic> sent =
          jsonDecode(req.body) as Map<String, dynamic>;
      expect(sent['input'], '测试一句');
      expect(sent['model'], 'tts-1');
      expect(sent['voice'], isA<String>());
      expect(sent['speed'], isA<num>());
    });

    test('baseUrl 已带 /audio/speech 时不重复追加', () async {
      final r = makeEngine(
        statusCode: 500,
        body: 'boom',
        baseUrl: 'https://api.example.test/v1/audio/speech',
      );
      await expectLater(
        r.engine.speak('x'),
        throwsA(isA<CloudTtsException>()),
      );
      expect(
        r.requests.single.url.toString(),
        'https://api.example.test/v1/audio/speech',
      );
    });

    test('baseUrl 末尾的多余斜杠被吃掉', () async {
      final r = makeEngine(
        statusCode: 500,
        body: 'boom',
        baseUrl: 'https://api.example.test/v1///',
      );
      await expectLater(
        r.engine.speak('x'),
        throwsA(isA<CloudTtsException>()),
      );
      expect(
        r.requests.single.url.toString(),
        'https://api.example.test/v1/audio/speech',
      );
    });

    test('空文本不发请求（避免白烧一次额度）', () async {
      final r = makeEngine(statusCode: 200, body: 'x');
      await r.engine.speak('   ');
      expect(r.requests, isEmpty);
    });
  });

  group('失败分支', () {
    test('401 → 异常里带状态码与响应片段', () async {
      final r = makeEngine(
        statusCode: 401,
        body: '{"error":"invalid api key"}',
      );
      await expectLater(
        r.engine.speak('x'),
        throwsA(
          isA<CloudTtsException>()
              .having((CloudTtsException e) => e.message, 'message',
                  contains('401'))
              .having((CloudTtsException e) => e.message, 'message',
                  contains('invalid api key')),
        ),
      );
    });

    test('500 且响应超长 → 消息被截断到 180 字并加省略号', () async {
      final String huge = 'E' * 500;
      final r = makeEngine(statusCode: 500, body: huge);
      try {
        await r.engine.speak('x');
        fail('应当抛出 CloudTtsException');
      } on CloudTtsException catch (e) {
        expect(e.message, contains('500'));
        expect(e.message, endsWith('…'));
        // 180 字片段 + 前缀 + 状态码，总量应当远小于原始 500 字
        expect(e.message.length, lessThan(260));
      }
    });

    test('200 但空体 → 明确报「空音频」而不是喂给播放器', () async {
      final r = makeEngine(
        statusCode: 200,
        bodyBytes: Uint8List(0),
      );
      await expectLater(
        r.engine.speak('x'),
        throwsA(
          isA<CloudTtsException>()
              .having((CloudTtsException e) => e.message, 'message',
                  contains('空音频')),
        ),
      );
    });

    test('异常类型可被上层识别（用于降级）', () async {
      final r = makeEngine(statusCode: 503, body: 'unavailable');
      Object? caught;
      try {
        await r.engine.speak('x');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<CloudTtsException>());
      expect(caught!.toString(), contains('503'));
    });
  });
}

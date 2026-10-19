import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/document_service.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/services/web_speak_script.dart';
import 'package:tts_reader/services/web_translate.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 网页「双击正文即读」（T2S 的 browser.js 那套）验证。
///
/// 注入脚本本身跑在 WebView 里，纯 Dart 测试没有 JS 引擎可以执行它，
/// 因此这里验证两件真正会出错、且能确定验证的事：
/// 1. JS 侧回传文本用的桥方法名与原生侧注册的名字是同一个值（不一致就静默失效）；
/// 2. 桥收到的那段文字确实能被切成可朗读片段并逐段读完（双击之后的行为链路）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
  });

  group('注入脚本', () {
    test('桥方法名在脚本与原生侧是同一个值', () {
      expect(WebSpeakScript.handlerName, isNotEmpty);
      expect(
        WebSpeakScript.doubleTap,
        contains("callHandler('${WebSpeakScript.handlerName}'"),
        reason: 'JS 里回传用的名字必须是原生注册的那个，否则双击没反应',
      );
    });

    test('双击判定窗口与静默期都写进了脚本', () {
      expect(WebSpeakScript.doubleTap, contains('< ${WebSpeakScript.doubleTapWindowMs})'));
      expect(WebSpeakScript.doubleTap, contains('${WebSpeakScript.repeatGuardMs})'));
      expect(WebSpeakScript.doubleTapWindowMs, 600, reason: '与 T2S 的取值保持一致');
    });

    test('打标范围只含正文块级元素，并排除导航 / 页眉页脚', () {
      for (final tag in <String>['p', 'li', 'h1', 'blockquote', 'td']) {
        expect(WebSpeakScript.nodeSelector, contains(tag));
      }
      expect(WebSpeakScript.doubleTap, contains("closest('nav,header,footer"));
      expect(WebSpeakScript.doubleTap, contains('data-t2s-node'));
    });

    test('脚本对页面异常是隔离的（不能因为注入把网页搞坏）', () {
      expect(WebSpeakScript.doubleTap, contains('try {'));
      expect(WebSpeakScript.doubleTap, contains('catch (e)'));
      // 重复注入时不能重复打标
      expect(WebSpeakScript.doubleTap, contains('__t2sBound'));
      expect(WebSpeakScript.doubleTap, contains("getAttribute('data-t2s-node') !== null"));
    });

    test('正文抽取脚本仍然剔除脚本 / 样式 / 导航', () {
      expect(
        WebSpeakScript.extract,
        contains('script,style,noscript,nav,header,footer,aside,form,iframe,svg,button'),
      );
      expect(WebSpeakScript.extract, contains("querySelector('article')"));
    });
  });

  group('双击后的朗读链路', () {
    test('双击得到的那段文字会被切片并逐段读完', () async {
      final engine = _RecordingEngine();
      final tts = TtsManager.instance;
      tts.resetTimeouts();
      await tts.registerEngine(engine, makeActive: true);

      // 一段比较长的正文（超过单片上限，必须切片）
      final paragraph = List<String>.generate(
        20,
        (i) => '第 $i 句正文内容，用来把这一段撑到需要切片。',
      ).join();
      final chunks = DocumentService.readChunks(paragraph);
      expect(chunks.length, greaterThan(1), reason: '长段落应当被切成多片');

      tts.speakLines(chunks);
      await tts.whenSessionFinished().timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('双击朗读没有结束（疑似卡住）'),
      );

      // ★v1.22.25：单片上限 300 → 80 字，"一行 = 一次 speak"不再成立
      // （外层的片会被内层再切）。判据改成**内容**：全念完、顺序不乱、拼回原文。
      expect(engine.spoken.length, greaterThanOrEqualTo(chunks.length));
      expect(engine.spoken.join(), paragraph,
          reason: '切片只切不改：拼回去必须与原文一致');
      expect(tts.error, isNull);
      expect(tts.speaking, isFalse);
      expect(tts.plainIndex, chunks.length - 1, reason: '读完后停在最后一片');
    });

    test('双击一段很短的文字也能正常读完', () async {
      final engine = _RecordingEngine();
      final tts = TtsManager.instance;
      tts.resetTimeouts();
      await tts.registerEngine(engine, makeActive: true);

      tts.speakLines(DocumentService.readChunks('短短一句话。'));
      await tts.whenSessionFinished().timeout(const Duration(seconds: 10));

      expect(engine.spoken, <String>['短短一句话。']);
      expect(tts.error, isNull);
    });
  });

  group('网页翻译地址', () {
    test('普通网址整体编码后拼进参数', () {
      final url = WebTranslate.urlFor('https://example.com/a?b=1&c=2');
      expect(url, isNotNull);
      expect(url, startsWith('${WebTranslate.endpoint}?client=gtx&sl=auto&tl=zh-CN&dt=t&q='));
      expect(url, contains(Uri.encodeComponent('https://example.com/a?b=1&c=2')));
      expect(url, isNot(contains('https://example.com/a?b=1&c=2')),
          reason: '原地址必须编码，否则里面的 & 会把参数拼坏');
    });

    test('中文 / 空格网址也能编码', () {
      final url = WebTranslate.urlFor('https://例子.测试/文章 1');
      expect(url, isNotNull);
      expect(url, contains(Uri.encodeComponent('https://例子.测试/文章 1')));
    });

    test('非 http(s) 页面不给翻译地址（起始页 / about:blank）', () {
      expect(WebTranslate.urlFor(''), isNull);
      expect(WebTranslate.urlFor('about:blank'), isNull);
      expect(WebTranslate.urlFor('asset.browser.local/home'), isNull);
      expect(WebTranslate.canTranslate('about:blank'), isFalse);
      expect(WebTranslate.canTranslate('https://example.com'), isTrue);
    });

    test('目标语言可换', () {
      final url = WebTranslate.urlFor('https://example.com', target: 'en', source: 'zh-CN');
      expect(url, contains('sl=zh-CN'));
      expect(url, contains('tl=en'));
    });

    test('目标语言必须用谷歌的代码 zh-CN（不是百度的 zh）', () {
      final url = WebTranslate.urlFor('https://example.com');
      expect(url, isNotNull);
      expect(url, contains('tl=zh-CN'));
      expect(url, isNot(contains('tl=zh&')),
          reason: '谷歌要 zh-CN；传 zh 会退化成不翻译或翻成别的语言');
    });

    test('源语言默认 auto（谷歌认这个词）', () {
      final url = WebTranslate.urlFor('https://example.com');
      expect(url, isNotNull);
      expect(url, contains('sl=auto'));
    });

    test('必带 client=gtx：缺了会被谷歌当非法调用', () {
      final url = WebTranslate.urlFor('https://example.com');
      expect(url, contains('client=gtx'));
      expect(url, contains('dt=t'));
    });

    test('兜底地址用百度的参数与语言码（query / from / to=zh / source=url）', () {
      final url = WebTranslate.urlForFallback('https://example.com/a?b=1&c=2');
      expect(url, isNotNull);
      expect(url, startsWith(WebTranslate.fallbackEndpoint));
      expect(url, contains('from=auto'));
      expect(url, contains('to=zh'), reason: '百度用 zh，不是 zh-CN');
      expect(url, contains('source=url'));
      expect(url, contains(Uri.encodeComponent('https://example.com/a?b=1&c=2')));
      expect(WebTranslate.urlForFallback('about:blank'), isNull);
    });

    // ---- v1.21.36：谷歌优先 + 百度兜底 + 判据收紧 ----
    // 为什么这次要收紧：老实现（微软首选）只要"连得上"就算可达，
    // 而微软在国内是「200 但返回错误页」→ 用户被引到没翻译的页面上。
    test('谷歌可达 → 用谷歌翻译', () async {
      final http.Client client =
          MockClient((http.Request request) async => http.Response('ok', 200));
      final String? url =
          await WebTranslate.resolveUrl('https://example.com/a', client: client);
      // ignore: avoid_print
      print('PROBE[翻译选路-谷歌可达] $url');
      expect(url, startsWith(WebTranslate.endpoint));
      expect(url, contains('client=gtx'));
      expect(url, contains('tl=zh-CN'));
    });

    test('谷歌不可达 → 自动退百度', () async {
      final http.Client client = MockClient(
          (http.Request request) async => throw const SocketException('fail'));
      final String? url =
          await WebTranslate.resolveUrl('https://example.com/a', client: client);
      // ignore: avoid_print
      print('PROBE[翻译选路-谷歌不可达] $url');
      expect(url, isNotNull);
      expect(url, startsWith(WebTranslate.fallbackEndpoint));
      expect(url, contains('to=zh'));
    });

    test('谷歌返回 5xx（不只是连不上）也要退百度', () async {
      // ⚠️ 这条是本次修正的核心回归：微软就是"200 但错误页"，
      //    必须确保判据能识别出"状态码不对就退兜底"
      final http.Client client = MockClient(
          (http.Request request) async => http.Response('error', 503));
      final String? url =
          await WebTranslate.resolveUrl('https://example.com/a', client: client);
      expect(url, startsWith(WebTranslate.fallbackEndpoint));
    });

    test('谷歌 200 但响应体是空的（错误页）也要退百度', () async {
      // 只判状态码会漏掉这种："连上了、也是 200，但什么都没吐"
      final http.Client client = MockClient(
          (http.Request request) async => http.Response('', 200));
      final String? url =
          await WebTranslate.resolveUrl('https://example.com/a', client: client);
      expect(url, startsWith(WebTranslate.fallbackEndpoint),
          reason: '空响应体 = 假成功，必须识别成不可达');
    });

    test('非 http(s) 页面（about:blank）连兜底都不给', () async {
      final http.Client client =
          MockClient((http.Request request) async => http.Response('ok', 200));
      expect(
        await WebTranslate.resolveUrl('about:blank', client: client),
        isNull,
      );
    });
  });
}

/// 假引擎：立刻读完每一段并记录收到的文本
class _RecordingEngine with SyntheticTtsEngine implements TtsEngine {
  final List<String> spoken = <String>[];

  @override
  String get id => 'web-recording';

  @override
  String get displayName => '假引擎（网页双击朗读）';

  @override
  bool get isAvailable => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<TtsVoice>> getVoices() async => const <TtsVoice>[];

  @override
  Future<void> setVoice(String voiceId) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async {}
}

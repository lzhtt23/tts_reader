import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tts_reader/models/source_rule.dart';
import 'package:tts_reader/services/source_client.dart';
import 'package:tts_reader/services/url_template.dart';

/// 造一条可用的文本书源
SourceRule buildRule({
  String baseUrl = 'https://demo.test',
  String? header,
  String searchUrl = 'https://demo.test/search?q={{key}}&page={{page}}',
}) {
  return SourceRule.fromJson(<String, dynamic>{
    'bookSourceUrl': baseUrl,
    'bookSourceName': '演示站',
    'bookSourceType': 0,
    'lastUpdateTime': 1,
    'respondTime': 5000,
    if (header != null) 'header': header,
    'searchUrl': searchUrl,
    'ruleSearch': <String, dynamic>{
      'bookList': 'class.result@tag.li',
      'name': 'tag.a.0@text',
      'author': 'class.author@text',
      'bookUrl': 'tag.a.0@href',
    },
    'ruleBookInfo': <String, dynamic>{
      'name': 'tag.h1@text',
    },
    'ruleToc': <String, dynamic>{
      'chapterList': 'class.chapters@tag.a',
      'chapterName': '@text',
      'chapterUrl': '@href',
    },
    'ruleContent': <String, dynamic>{
      'content': 'id.content@html',
    },
  });
}

void main() {
  group('UrlTemplate', () {
    test('展开 {{key}} 与 {{page}}', () {
      final req = UrlTemplate.evaluate(
        'https://a.test/s?q={{key}}&p={{page}}',
        variables: <String, Object?>{'key': '斗罗', 'page': 2},
        baseUrl: 'https://a.test',
      );
      expect(req.url, contains('q=%E6%96%97%E7%BD%97'));
      expect(req.url, contains('p=2'));
      expect(req.method, HttpMethod.get);
    });

    test('相对地址补全', () {
      final req = UrlTemplate.evaluate(
        '/search?q=x',
        variables: <String, Object?>{},
        baseUrl: 'https://a.test',
      );
      expect(req.url, 'https://a.test/search?q=x');
    });

    test('解析 UrlOption：method/body/headers', () {
      const template =
          'https://a.test/api,{"method":"POST","body":"a=1","headers":{"X-Token":"t"},"charset":"gbk","retry":2}';
      final req = UrlTemplate.evaluate(
        template,
        variables: <String, Object?>{},
        baseUrl: 'https://a.test',
      );
      expect(req.method, HttpMethod.post);
      expect(req.body, 'a=1');
      expect(req.headers['X-Token'], 't');
      expect(req.charset, 'gbk');
      expect(req.retry, 2);
    });

    test('useWebView 明确拒绝', () {
      expect(
        () => UrlTemplate.evaluate(
          'https://a.test/x,{"useWebView":true}',
          variables: <String, Object?>{},
          baseUrl: 'https://a.test',
        ),
        throwsA(isA<UnsupportedSourceException>()),
      );
    });

    test('js 改 URL 明确拒绝', () {
      expect(
        () => UrlTemplate.evaluate(
          'https://a.test/x,{"js":"result"}',
          variables: <String, Object?>{},
          baseUrl: 'https://a.test',
        ),
        throwsA(isA<UnsupportedSourceException>()),
      );
    });

    test('书源级 header 与 UrlOption 合并（后者优先）', () {
      final req = UrlTemplate.evaluate(
        'https://a.test/x,{"headers":{"X-A":"2"}}',
        variables: <String, Object?>{},
        baseUrl: 'https://a.test',
        extraHeader: '{"X-A":"1","X-B":"9"}',
      );
      expect(req.headers['X-A'], '2');
      expect(req.headers['X-B'], '9');
    });

    test('算术表达式模板', () {
      final req = UrlTemplate.evaluate(
        'https://a.test/list/{{(page-1)*18}}.html',
        variables: <String, Object?>{'page': 3},
        baseUrl: 'https://a.test',
      );
      expect(req.url, 'https://a.test/list/36.html');
    });
  });

  group('SourceClient 搜索', () {
    const String searchHtml = '''
      <div class="result">
        <li><a href="/book/1">书一</a><span class="author">甲</span></li>
        <li><a href="/book/2">书二</a><span class="author">乙</span></li>
      </div>
    ''';

    test('解析出书名/作者/地址', () async {
      final MockClient mock = MockClient((http.Request req) async {
        expect(req.url.toString(), contains('/search'));
        return http.Response.bytes(
          utf8.encode(searchHtml), 200,
          headers: <String, String>{'content-type': 'text/html; charset=utf-8'});
      });
      final client = SourceClient(
        rule: buildRule(),
        client: SourceHttpClient(client: mock),
      );
      final books = await client.search('测试');
      expect(books.length, 2);
      expect(books[0].name, '书一');
      expect(books[0].author, '甲');
      expect(books[0].url, 'https://demo.test/book/1');
    });

    test('没有 searchUrl 时给明确错误', () async {
      final rule = SourceRule.fromJson(<String, dynamic>{
        'bookSourceUrl': 'https://a.test',
        'bookSourceName': 'x',
        'ruleSearch': <String, dynamic>{'bookList': 'li'},
      });
      final client = SourceClient(rule: rule);
      expect(
        () => client.search('x'),
        throwsA(isA<SourceOperationException>().having(
          (SourceOperationException e) => e.reason,
          'reason',
          contains('searchUrl'),
        )),
      );
    });

    test('空结果不崩', () async {
      final MockClient mock = MockClient((http.Request req) async {
        return http.Response.bytes(utf8.encode('<div class="nothing"></div>'), 200);
      });
      final client = SourceClient(
        rule: buildRule(),
        client: SourceHttpClient(client: mock),
      );
      expect(await client.search('x'), isEmpty);
    });

    test('HTTP 500 抛 SourceOperationException', () async {
      final MockClient mock = MockClient((http.Request req) async {
        return http.Response('err', 500);
      });
      final client = SourceClient(
        rule: buildRule(),
        client: SourceHttpClient(client: mock),
      );
      expect(
        () => client.search('x'),
        throwsA(isA<SourceOperationException>()),
      );
    });
  });

  group('SourceClient 目录', () {
    const String tocHtml = '''
      <div class="chapters">
        <a href="/c/1">第一章 开端</a>
        <a href="/c/2">第二章 发展</a>
      </div>
    ''';

    test('解析章节名与地址', () async {
      final MockClient mock = MockClient((http.Request req) async {
        return http.Response.bytes(utf8.encode(tocHtml), 200);
      });
      final client = SourceClient(
        rule: buildRule(),
        client: SourceHttpClient(client: mock),
      );
      final chapters = await client.toc('https://demo.test/book/1');
      expect(chapters.length, 2);
      expect(chapters[0].name, '第一章 开端');
      expect(chapters[0].url, 'https://demo.test/c/1');
    });
  });

  group('SourceClient 正文', () {
    test('取正文并转成段落', () async {
      const html = '<div id="content"><p>第一段内容。</p><p>第二段内容。</p></div>';
      final MockClient mock = MockClient((http.Request req) async {
        return http.Response.bytes(utf8.encode(html), 200);
      });
      final client = SourceClient(
        rule: buildRule(),
        client: SourceHttpClient(client: mock),
      );
      final text = await client.content('https://demo.test/c/1');
      expect(text, contains('第一段内容'));
      expect(text, contains('第二段内容'));
      expect(text, isNot(contains('<p>')));
    });

    test('单章正文超长被截断', () async {
      final String huge = '<div id="content">${'字' * 300000}</div>';
      final MockClient mock = MockClient((http.Request req) async {
        return http.Response.bytes(utf8.encode(huge), 200);
      });
      final client = SourceClient(
        rule: buildRule(),
        client: SourceHttpClient(client: mock),
      );
      final text = await client.content('https://demo.test/c/1');
      expect(text.length, lessThanOrEqualTo(SourceClient.maxContentChars));
    });
  });

  group('组装 StructuredDocument', () {
    test('多章拼装，章节名与句子结构正确', () async {
      final client = SourceClient(rule: buildRule());
      final chapters = <OnlineChapter>[
        const OnlineChapter(name: '第一章', url: 'https://demo.test/c/1'),
        const OnlineChapter(name: '第二章', url: 'https://demo.test/c/2'),
      ];
      final doc = await client.toDocument(
        chapters,
        chapterLoader: (OnlineChapter c) async => '这是第一句。这是第二句。\n\n第二段。',
      );
      expect(doc.chapters.length, 2);
      expect(doc.chapters[0].title, '第一章');
      // 三段文字（两句 + 一段）
      expect(doc.chapters[0].paragraphs.length, 2);
      expect(doc.sentenceCount, greaterThan(0));
      // 能用游标定位（朗读流程的硬要求）
      expect(doc.cursorAt(0.5), isNotNull);
    });

    test('单章失败留占位，不影响其它章', () async {
      final client = SourceClient(rule: buildRule());
      final chapters = <OnlineChapter>[
        const OnlineChapter(name: '好的', url: 'u1'),
        const OnlineChapter(name: '坏的', url: 'u2'),
      ];
      var call = 0;
      final doc = await client.toDocument(
        chapters,
        chapterLoader: (OnlineChapter c) async {
          call++;
          if (call == 2) throw StateError('网络挂了');
          return '正常内容。';
        },
      );
      expect(doc.chapters.length, 2);
      expect(doc.chapters[1].text, contains('获取失败'));
    });

    test('maxChapters 限制生效', () async {
      final client = SourceClient(rule: buildRule());
      final chapters = <OnlineChapter>[
        for (var i = 0; i < 10; i++)
          OnlineChapter(name: '第$i章', url: 'u$i'),
      ];
      final doc = await client.toDocument(
        chapters,
        chapterLoader: (OnlineChapter c) async => '内容。',
        maxChapters: 3,
      );
      expect(doc.chapters.length, 3);
    });

    test('空章节不产生空文档', () async {
      final client = SourceClient(rule: buildRule());
      final doc = await client.toDocument(
        <OnlineChapter>[const OnlineChapter(name: '空', url: 'u')],
        chapterLoader: (OnlineChapter c) async => '',
      );
      expect(doc.chapters.length, 1);
      expect(doc.chapters.first.paragraphs, isNotEmpty);
    });
  });

  group('htmlToParagraphs 清洗', () {
    test('br 转换行', () {
      expect(htmlToParagraphs('一<br>二<br/>三'), '一\n二\n三');
    });

    test('去标签保留文本', () {
      expect(htmlToParagraphs('<p>甲</p><p>乙</p>'), '甲\n乙');
    });

    test('实体反转义', () {
      expect(htmlToParagraphs('&nbsp;A&amp;B&lt;C&gt;'), 'A&B<C>');
    });

    test('数字实体', () {
      expect(htmlToParagraphs('&#20013;&#25991;'), '中文');
    });

    test('全角空格被压缩', () {
      expect(htmlToParagraphs('甲\u3000\u3000乙'), '甲 乙');
    });

    test('空行被去掉', () {
      expect(htmlToParagraphs('甲\n\n\n乙'), '甲\n乙');
    });

    test('script 内容被当标签去掉', () {
      final r = htmlToParagraphs('<div>正文</div><script>alert(1)</script>');
      expect(r, contains('正文'));
      expect(r, isNot(contains('alert')));
    });
  });

  group('GBK 解码钩子', () {
    tearDown(() => SourceHttpClient.gbkDecoder = null);

    test('未设置钩子时退化 UTF-8 不崩', () {
      final r = SourceHttpClient.decodeBytes(utf8.encode('中文'), 'gbk');
      expect(r, '中文');
    });

    test('设置钩子后走自定义解码', () {
      SourceHttpClient.gbkDecoder = (List<int> b) => 'GBK:${b.length}';
      final r = SourceHttpClient.decodeBytes(<int>[1, 2, 3], 'gbk');
      expect(r, 'GBK:3');
    });
  });

  group('中文书源端到端（假服务器）', () {
    test('搜索 → 目录 → 正文 → 文档', () async {
      final MockClient mock = MockClient((http.Request req) async {
        final String path = req.url.path;
        if (path == '/search') {
          return http.Response.bytes(
            utf8.encode(
              '<ul class="result"><li><a href="/book/9">测试之书</a>'
              '<span class="author">张三</span></li></ul>',
            ),
            200,
          );
        }
        if (path == '/book/9') {
          return http.Response.bytes(
            utf8.encode(
              '<h1>测试之书</h1><div class="chapters">'
              '<a href="/read/1">第1章</a><a href="/read/2">第2章</a></div>',
            ),
            200,
          );
        }
        if (path == '/read/1' || path == '/read/2') {
          return http.Response.bytes(
            utf8.encode('<div id="content"><p>正文第一句。正文第二句。</p></div>'),
            200,
          );
        }
        return http.Response('not found', 404);
      });

      final client = SourceClient(
        rule: buildRule(),
        client: SourceHttpClient(client: mock),
      );

      final books = await client.search('测试之书');
      expect(books, hasLength(1));
      expect(books.first.name, '测试之书');

      final chapters = await client.toc(books.first.url);
      expect(chapters, hasLength(2));

      final doc = await client.toDocument(
        chapters,
        chapterLoader: (OnlineChapter c) => client.content(c.url),
      );
      expect(doc.chapters.length, 2);
      expect(doc.plainText, contains('正文第一句'));
      expect(doc.sentenceCount, greaterThan(0));
    });
  });
}

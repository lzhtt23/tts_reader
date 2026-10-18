import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/css_analyzer.dart';
import 'package:tts_reader/services/expression_evaluator.dart';
import 'package:tts_reader/services/json_path_analyzer.dart';
import 'package:tts_reader/services/rule_analyzer.dart';
import 'package:tts_reader/services/rule_engine.dart';

void main() {
  group('RuleAnalyzer 切分（跳过引号/括号内的分隔符）', () {
    test('按 || 切分', () {
      final r = RuleAnalyzer(r'$.a||$.b').splitRule(<String>['&&', '||', '%%']);
      expect(r.segments, <String>[r'$.a', r'$.b']);
      expect(r.elementsType, '||');
    });

    test('引号内的 || 不切', () {
      final r = RuleAnalyzer(r'tag.div[data-x="a||b"]||tag.p')
          .splitRule(<String>['&&', '||', '%%']);
      expect(r.segments.length, 2);
      expect(r.segments[0], contains('a||b'));
    });

    test('方括号内的 && 不切', () {
      final r = RuleAnalyzer(r'a[href*="&&"]&&b').splitRule(<String>['&&', '||', '%%']);
      expect(r.segments.length, 2);
    });

    test('没有分隔符时返回原文', () {
      final r = RuleAnalyzer('class.list@tag.li').splitRule(<String>['&&', '||', '%%']);
      expect(r.segments, <String>['class.list@tag.li']);
      expect(r.elementsType, '');
    });

    test('取最先出现的分隔符', () {
      final r = RuleAnalyzer('a&&b||c').splitRule(<String>['&&', '||', '%%']);
      expect(r.elementsType, '&&');
      expect(r.segments, <String>['a', 'b||c']);
    });

    test('%% 交叉合并标记', () {
      final r = RuleAnalyzer('a%%b%%c').splitRule(<String>['&&', '||', '%%']);
      expect(r.elementsType, '%%');
      expect(r.segments.length, 3);
    });
  });

  group('CssAnalyzer 选择器', () {
    const html = '''
      <html><body>
        <div class="book-list">
          <li><a href="/b/1">书一</a><span class="author">甲</span></li>
          <li><a href="/b/2">书二</a><span class="author">乙</span></li>
          <li><a href="/b/3">书三</a><span class="author">丙</span></li>
        </div>
        <div id="content"><p>正文一</p><p>正文二</p></div>
      </body></html>
    ''';

    test('class 前缀 + tag 链 + 末级 text', () {
      final css = CssAnalyzer.fromHtml(html);
      expect(css.evaluate('class.book-list@tag.li@tag.a@text'), <String>['书一', '书二', '书三']);
    });

    test('取属性 href', () {
      final css = CssAnalyzer.fromHtml(html);
      expect(css.evaluate('class.book-list@tag.a@href'), <String>['/b/1', '/b/2', '/b/3']);
    });

    test('id 前缀', () {
      final css = CssAnalyzer.fromHtml(html);
      expect(css.evaluate('id.content@tag.p@text'), <String>['正文一', '正文二']);
    });

    test('索引 .0 取第一个', () {
      final css = CssAnalyzer.fromHtml(html);
      expect(css.evaluate('class.book-list@tag.li.0@tag.a@text'), <String>['书一']);
    });

    test('索引 .-1 取最后一个（负数从尾部）', () {
      final css = CssAnalyzer.fromHtml(html);
      expect(css.evaluate('class.book-list@tag.li.-1@tag.a@text'), <String>['书三']);
    });

    test('方括号索引 [1]', () {
      final css = CssAnalyzer.fromHtml(html);
      expect(css.evaluate('class.book-list@tag.li[1]@tag.a@text'), <String>['书二']);
    });

    test('方括号排除 [!0]', () {
      final css = CssAnalyzer.fromHtml(html);
      expect(
        css.evaluate('class.book-list@tag.li[!0]@tag.a@text'),
        <String>['书二', '书三'],
      );
    });

    test('区间 [0:1]', () {
      final css = CssAnalyzer.fromHtml(html);
      expect(
        css.evaluate('class.book-list@tag.li[0:1]@tag.a@text'),
        <String>['书一', '书二'],
      );
    });

    test('反向 [-1:0]', () {
      final css = CssAnalyzer.fromHtml(html);
      expect(
        css.evaluate('class.book-list@tag.li[-1:0]@tag.a@text'),
        <String>['书三', '书二', '书一'],
      );
    });

    test('CSS 属性选择器不被误当索引', () {
      final css = CssAnalyzer.fromHtml(html);
      // [href] 不是索引，应作为 CSS 选择器
      final r = css.evaluate('a[href]@text');
      expect(r, <String>['书一', '书二', '书三']);
    });

    test('html 末级去掉 script/style', () {
      const withScript = '<div id="c"><p>文字</p><script>x()</script></div>';
      final css = CssAnalyzer.fromHtml(withScript);
      final r = css.evaluate('id.c@html');
      expect(r.first, contains('文字'));
      expect(r.first, isNot(contains('script')));
    });

    test('没匹配到时返回空', () {
      final css = CssAnalyzer.fromHtml(html);
      expect(css.evaluate('class.nothing@tag.a@text'), isEmpty);
    });
  });

  group('JsonPathAnalyzer', () {
    final Map<String, dynamic> data = <String, dynamic>{
      'book': <String, dynamic>{
        'name': '测试书',
        'author': <String, dynamic>{'nickname': '作者甲'},
        'docs': <dynamic>[
          <String, dynamic>{'title': '第一章', 'id': 1},
          <String, dynamic>{'title': '第二章', 'id': 2},
        ],
      },
      'album_ids': <dynamic>[11, 22],
    };

    test(r'$.book.name', () {
      expect(JsonPathAnalyzer(data).evaluate(r'$.book.name'), <String>['测试书']);
    });

    test(r'$.album_ids[0]', () {
      expect(JsonPathAnalyzer(data).evaluate(r'$.album_ids[0]'), <String>['11']);
    });

    test(r'$..bid 递归找不到时为空', () {
      expect(JsonPathAnalyzer(data).evaluate(r'$..bid'), isEmpty);
    });

    test(r'$..title 递归能找到多层', () {
      final r = JsonPathAnalyzer(data).evaluate(r'$..title');
      expect(r, <String>['第一章', '第二章']);
    });

    test(r'$.book.docs[1].title', () {
      expect(
        JsonPathAnalyzer(data).evaluate(r'$.book.docs[1].title'),
        <String>['第二章'],
      );
    });

    test('负数下标', () {
      expect(JsonPathAnalyzer(data).evaluate(r'$.album_ids[-1]'), <String>['22']);
    });

    test('不支持的过滤器返回空（不崩）', () {
      expect(JsonPathAnalyzer(data).evaluate(r'$.book.docs[?(@.id>1)]'), isEmpty);
    });

    test('字符串值原样返回', () {
      expect(
        JsonPathAnalyzer(<String, dynamic>{'x': ' 值 '}).evaluate(r'$.x'),
        <String>['值'],
      );
    });
  });

  group('ExpressionEvaluator 算术', () {
    EvalContext ctx([Map<String, Object?> vars = const <String, Object?>{}]) =>
        EvalContext(variables: vars);

    test('page-1', () {
      expect(ExpressionEvaluator('page-1', ctx(<String, Object?>{'page': 3})).evaluate(), 2);
    });

    test('(page-1)*18', () {
      expect(
        ExpressionEvaluator('(page-1)*18', ctx(<String, Object?>{'page': 3})).evaluate(),
        36,
      );
    });

    test('24*(page-1)', () {
      expect(
        ExpressionEvaluator('24*(page-1)', ctx(<String, Object?>{'page': 2})).evaluate(),
        24,
      );
    });

    test('除法', () {
      expect(ExpressionEvaluator('10/4', ctx()).evaluate(), 2.5);
    });

    test('取模', () {
      expect(ExpressionEvaluator('7%3', ctx()).evaluate(), 1);
    });

    test('一元负号', () {
      expect(ExpressionEvaluator('-5+2', ctx()).evaluate(), -3);
    });
  });

  group('ExpressionEvaluator 字符串与三元', () {
    EvalContext ctx([Map<String, Object?> vars = const <String, Object?>{}]) =>
        EvalContext(variables: vars);

    test('字符串拼接 + 数字', () {
      expect(
        ExpressionEvaluator("'index_' + page", ctx(<String, Object?>{'page': 2})).evaluate(),
        'index_2',
      );
    });

    test('三元（真分支）', () {
      expect(
        ExpressionEvaluator(
          "page-1==0 ? 'index' : 'index_'+page",
          ctx(<String, Object?>{'page': 1}),
        ).evaluate(),
        'index',
      );
    });

    test('三元（假分支）', () {
      expect(
        ExpressionEvaluator(
          "page-1==0 ? 'index' : 'index_'+page",
          ctx(<String, Object?>{'page': 3}),
        ).evaluate(),
        'index_3',
      );
    });

    test('replace 字符串替换', () {
      expect(
        ExpressionEvaluator(
          "baseUrl.replace('.htm','/')",
          ctx(<String, Object?>{'baseUrl': 'https://a.com/b.htm'}),
        ).evaluate(),
        'https://a.com/b/',
      );
    });

    test('链式 replace', () {
      expect(
        ExpressionEvaluator(
          "baseUrl.replace('/txt','').replace('.htm','/')",
          ctx(<String, Object?>{'baseUrl': 'https://a.com/txt/b.htm'}),
        ).evaluate(),
        'https://a.com/b/',
      );
    });

    test('match 后取分组', () {
      expect(
        ExpressionEvaluator(
          r'baseUrl.match(/bookId=(\d+)/)[1]',
          ctx(<String, Object?>{'baseUrl': 'https://a.com/x?bookId=4567'}),
        ).evaluate(),
        '4567',
      );
    });

    test('String() 转换', () {
      expect(
        ExpressionEvaluator('String(page)', ctx(<String, Object?>{'page': 7})).evaluate(),
        '7',
      );
    });

    test('数组下标', () {
      expect(
        ExpressionEvaluator(
          'key[0]',
          ctx(<String, Object?>{'key': <dynamic>['abc', 'def']}),
        ).evaluate(),
        'abc',
      );
    });

    test('成员访问 book.name', () {
      expect(
        ExpressionEvaluator(
          'book.name',
          ctx(<String, Object?>{
            'book': <String, dynamic>{'name': '书名'},
          }),
        ).evaluate(),
        '书名',
      );
    });

    test('未定义变量返回 null（不崩）', () {
      expect(ExpressionEvaluator('notDefined', ctx()).evaluate(), isNull);
    });
  });

  group('ExpressionEvaluator 宿主函数', () {
    test('java.encodeURI 调用', () {
      final ctx = EvalContext(
        variables: <String, Object?>{'key': 'a b'},
        functions: <String, Object? Function(List<Object?>)>{
          'java.encodeURI': (List<Object?> args) =>
              Uri.encodeComponent(args.first.toString()),
        },
      );
      expect(ExpressionEvaluator('java.encodeURI(key)', ctx).evaluate(), 'a%20b');
    });

    test('java.timeFormat 调用', () {
      final ctx = EvalContext(
        variables: <String, Object?>{'ts': 1700000000000},
        functions: <String, Object? Function(List<Object?>)>{
          'java.timeFormat': (List<Object?> args) => 'FMT(${args.first})',
        },
      );
      expect(
        ExpressionEvaluator('java.timeFormat(ts)', ctx).evaluate(),
        'FMT(1700000000000)',
      );
    });
  });

  group('ExpressionEvaluator 明确拒绝控制流', () {
    final EvalContext ctx = EvalContext();

    test('var 声明被拒绝', () {
      expect(
        () => ExpressionEvaluator('var a=1; a', ctx).evaluate(),
        throwsA(isA<UnsupportedExpression>()),
      );
    });

    test('if 被拒绝', () {
      expect(
        () => ExpressionEvaluator("if(x){1}else{2}", ctx).evaluate(),
        throwsA(isA<UnsupportedExpression>()),
      );
    });

    test('箭头函数被拒绝', () {
      expect(
        () => ExpressionEvaluator('list.map(v=>v.name)', ctx).evaluate(),
        throwsA(isA<UnsupportedExpression>()),
      );
    });

    test('多条语句被拒绝', () {
      expect(
        () => ExpressionEvaluator('a; b', ctx).evaluate(),
        throwsA(isA<UnsupportedExpression>()),
      );
    });

    test('for 循环被拒绝', () {
      expect(
        () => ExpressionEvaluator('for(i=0;i<3;i++){}', ctx).evaluate(),
        throwsA(isA<UnsupportedExpression>()),
      );
    });
  });

  group('RuleEngine 端到端', () {
    RuleEngine htmlEngine(String html, {String? baseUrl}) => RuleEngine(
      content: html,
      kind: ContentKind.html,
      context: RuleContext(baseUrl: baseUrl),
    );

    const String listHtml = '''
      <div class="list">
        <li><a href="/book/1">书一</a></li>
        <li><a href="/book/2">书二</a></li>
      </div>
    ''';

    test('CSS 规则取书名列表', () {
      final engine = htmlEngine(listHtml);
      expect(engine.getStringList('class.list@tag.li@tag.a@text'), <String>['书一', '书二']);
    });

    test('|| 取第一个非空', () {
      final engine = htmlEngine(listHtml);
      final r = engine.getStringList('class.nothing@tag.a@text||class.list@tag.a@text');
      expect(r, <String>['书一', '书二']);
    });

    test('&& 合并两组结果', () {
      final engine = htmlEngine(listHtml);
      final r = engine.getStringList('class.list@tag.a@text&&class.list@tag.a@href');
      expect(r.length, 4);
    });

    test('## 正则替换', () {
      final engine = htmlEngine('<p id="t">字数：1234</p>');
      expect(engine.getStringList(r'id.t@text##字数：##'), <String>['1234']);
    });

    test('isUrl 转绝对地址', () {
      final engine = htmlEngine(listHtml, baseUrl: 'https://a.com');
      final r = engine.getStringList('class.list@tag.a@href', isUrl: true);
      expect(r, <String>['https://a.com/book/1', 'https://a.com/book/2']);
    });

    test('JSON 内容 + JSONPath', () {
      final engine = RuleEngine(
        content: '{"data":{"list":[{"name":"甲"},{"name":"乙"}]}}',
        kind: ContentKind.json,
        context: RuleContext(),
      );
      expect(engine.getStringList(r'$.data.list[*].name'), <String>['甲', '乙']);
    });

    test('{{ }} 里是 JSONPath', () {
      final engine = RuleEngine(
        content: '{"page":3}',
        kind: ContentKind.json,
        context: RuleContext(),
      );
      expect(engine.getString(r'{{$.page}}'), '3');
    });

    test('{{ }} 里是算术表达式', () {
      final engine = RuleEngine(
        content: 'x',
        kind: ContentKind.text,
        context: RuleContext(variables: <String, Object?>{'page': 4}),
      );
      expect(engine.getString('p{{(page-1)*18}}'), 'p54');
    });

    test('@css: 前缀与默认等价', () {
      final engine = htmlEngine(listHtml);
      expect(
        engine.getStringList('@CSS:class.list@tag.a@text'),
        engine.getStringList('class.list@tag.a@text'),
      );
    });

    test('@@ 前缀强制 CSS', () {
      final engine = htmlEngine(listHtml);
      expect(engine.getStringList('@@class.list@tag.a@text'), <String>['书一', '书二']);
    });

    test('XPath 规则能求值（// 路径）', () {
      final engine = htmlEngine('<html><body><div id="c"><p>甲</p><p>乙</p></div></body></html>');
      final r = engine.getStringList('//div[@id="c"]//p');
      expect(r, <String>['甲', '乙']);
    });

    test('XPath 取属性', () {
      final engine = htmlEngine(
        '<html><body><a href="/x/1">链接</a></body></html>',
      );
      final r = engine.getStringList('//a@href');
      expect(r, <String>['/x/1']);
    });

    test('说明：正则字面量不会被误判成 XPath', () {
      final engine = htmlEngine('<p id="t">abc123</p>');
      // `/\d+/` 是正则，不是 XPath
      final r = engine.getStringList(r'id.t@text##/\d+/##');
      expect(r, <String>['abc']);
    });

    test('getString 多结果用换行连接', () {
      final engine = htmlEngine(listHtml);
      expect(engine.getString('class.list@tag.a@text'), '书一\n书二');
    });

    test('空格规则返回空串', () {
      final engine = htmlEngine(listHtml);
      expect(engine.getString('   '), '');
      expect(engine.getStringList(null), isEmpty);
    });
  });
}

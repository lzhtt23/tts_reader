import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';

/// P1 文本层的纯逻辑测试。
///
/// 这一层是「点击朗读」的命门：PDF 的文字是**碎片**，分行、合并、分句
/// 任何一步错了，表现都是「点了没反应 / 读半句就停 / 读出一堆空格」。
/// 所以这里用**构造出来的假字盒**把它钉死，不依赖真实 PDF 引擎。
void main() {
  /// 造一行字符盒：从 (x, y) 开始，每字宽 [w]、高 [h]
  List<PdfTextChar> makeChars(
    String text, {
    double x = 0,
    double y = 0,
    double w = 10,
    double h = 12,
    int indexBase = 0,
  }) {
    final chars = <PdfTextChar>[];
    var cx = x;
    for (var i = 0; i < text.length; i++) {
      chars.add(PdfTextChar(
        index: indexBase + i,
        char: text[i],
        rect: Rect.fromLTWH(cx, y, w, h),
      ));
      cx += w;
    }
    return chars;
  }

  group('分行（几何分组）', () {
    test('同一水平带的字符归为一行', () {
      final chars = makeChars('你好世界', y: 100);
      final lines = groupIntoLines(chars);
      expect(lines.length, 1);
      expect(lines.first.text, '你好世界');
    });

    test('纵向错开明显就分成两行（中文 PDF 没有空格也分得开）', () {
      final chars = <PdfTextChar>[
        ...makeChars('第一行', y: 100),
        ...makeChars('第二行', y: 140, indexBase: 3),
      ];
      final lines = groupIntoLines(chars);
      expect(lines.length, 2, reason: '两行文字的 y 差了 40，必须分成两行');
      expect(lines[0].text, '第一行');
      expect(lines[1].text, '第二行');
    });

    test('乱序输入也按阅读顺序还原（PDF 绘制顺序不保证）', () {
      final a = makeChars('先', y: 100);
      final b = makeChars('后', y: 140, indexBase: 1);
      // 故意倒着喂进去
      final lines = groupIntoLines(<PdfTextChar>[...b, ...a]);
      expect(lines[0].text, '先', reason: 'y 小的在前');
      expect(lines[1].text, '后');
    });

    test('零面积盒（纯占位、无字形）被剔除，不参与分行', () {
      final chars = <PdfTextChar>[
        ...makeChars('AB', y: 50),
        // 零面积 = PDF 里表示「没有字形」的占位，不是空格（空格有宽度）
        PdfTextChar(
          index: 2,
          char: '\u0000',
          rect: const Rect.fromLTWH(20, 50, 0, 0),
        ),
      ];
      final layer = buildTextLayer(
        pageNumber: 1,
        pageSize: const Size(200, 300),
        fullText: 'AB\u0000',
        charRects: chars.map((c) => c.rect).toList(),
        segment: segmentIntoSentences,
      );
      expect(layer.lines.length, 1);
      expect(layer.lines.first.chars.length, 2, reason: '零面积占位不该进来');
    });

    test('又宽又偏的空白占位盒不会把一整行切断', () {      // 真实 PDF 常见：一行字后面跟一条很宽的空白（字距/表格留白）。
      // 拿它当行尾参照会误判「下一个字不在右边」→ 行被切碎。
      final chars = <PdfTextChar>[
        ...makeChars('前半', x: 0, y: 100),
        PdfTextChar(
          index: 2,
          char: ' ',
          rect: const Rect.fromLTWH(20, 100, 180, 12), // 宽 180 的空白
        ),
        ...makeChars('后半', x: 200, y: 100, indexBase: 3),
      ];
      final lines = groupIntoLines(chars);
      expect(lines.length, 1,
          reason: '空白盒不该把同一行切成两行（实际 ${lines.map((l) => l.text).toList()}）');
    });

    // §4.100 线索 2 回归：正文行 + 居中标题行（同一 y 带）必须切开
    test('正文行与居中小标题在同一 y 带：x 空档大 → 切成两个行块', () {
      final chars = <PdfTextChar>[
        // 正文行：x 0..100
        ...makeChars('正文内容一二三', x: 0, y: 100, indexBase: 0),
        // 同带但横向远端的小节标题：x 200..280（间隔 100 = 10 个字宽）
        ...makeChars('第一节', x: 200, y: 100, indexBase: 8),
      ];
      final lines = groupIntoLines(chars);
      expect(lines.length, 2,
          reason: '间隔超过 3 个字宽必须切成两个独立行块，不是一行');
      expect(lines[0].text, '正文内容一二三');
      expect(lines[1].text, '第一节',
          reason: '第二段按 x 顺序排在后面（视觉顺序 = 数组顺序）');
    });

    test('切块后朗读顺序 = 视觉顺序（两段不拼成一句）', () {
      final chars = <PdfTextChar>[
        ...makeChars('正文结束。', x: 0, y: 100, indexBase: 0),
        ...makeChars('标题', x: 220, y: 100, indexBase: 5),
      ];
      final s = segmentIntoSentences(groupIntoLines(chars));
      expect(s.map((e) => e.text).toList(), ['正文结束。', '标题'],
          reason: '同带的两段不能拼成一句一起读（用户报的读错顺序）');
    });

    test('字距空格正常排布的整行不会被误切', () {
      // 中文 PDF 常见：字与字之间有小空白占位，但都被空白盒覆盖
      final chars = <PdfTextChar>[];
      var x = 0.0;
      var idx = 0;
      for (final ch in '主 编：米 宁'.split('')) {
        chars.add(PdfTextChar(
          index: idx++,
          char: ch,
          rect: Rect.fromLTWH(x, 100, ch == ' ' ? 4 : 10, 12),
        ));
        x += ch == ' ' ? 4 : 10;
      }
      final lines = groupIntoLines(chars);
      expect(lines.length, 1,
          reason: '空白盒把间隔盖住，未覆盖空档没超阈值（实际 ${lines.map((l) => l.text).toList()}）');
    });
  });

  group('分句（Intl.Segmenter 的等价规则）', () {
    List<PdfTextSentence> seg(String text) =>
        segmentIntoSentences(groupIntoLines(makeChars(text)));

    /// 造一行：字符等距排列，最后一个字的 x 由 [fullWidth] 控制
    /// fullWidth=true → 把这一行拉伸到接近 rightEdge，模拟"被排版排满"
    List<PdfTextChar> makeLine(
      String text, {
      required double y,
      int indexBase = 0,
      double charWidth = 10,
      double rightEdge = 300,
      bool fullWidth = false,
    }) {
      if (text.isEmpty) return const <PdfTextChar>[];
      final n = text.length;
      final lastRight = fullWidth ? rightEdge * 0.95 : n * charWidth;
      final step = n <= 1 ? charWidth : lastRight / n;
      return <PdfTextChar>[
        for (var i = 0; i < n; i++)
          PdfTextChar(
            index: indexBase + i,
            char: text[i],
            rect: Rect.fromLTWH(i * step, y, step, 12),
          ),
      ];
    }

    /// 把若干行按给定 y 拼成一页的行列表
    List<PdfTextLine> page(List<List<PdfTextChar>> lines) =>
        groupIntoLines(<PdfTextChar>[for (final l in lines) ...l]);

    test('按中文句末标点切句', () {
      final s = seg('第一句。第二句！第三句？');
      expect(s.map((e) => e.text).toList(), ['第一句。', '第二句！', '第三句？']);
    });

    test('行尾没有句末标点：整行作为一句（不丢字）', () {
      final s = seg('这一行没有句号');
      expect(s.length, 1);
      expect(s.first.text, '这一行没有句号');
    });

    test('句末标点后的收尾引号归到下一句开头（简单规则，不跨句等待）', () {
      final s = seg('他说：「走吧。」然后离开了。');
      expect(s.map((e) => e.text).toList(),
          ['他说：「走吧。', '」然后离开了。'],
          reason: '句末标点一定断句；收尾引号跟到下一句开头。'
              '（一开始想「等收尾引号一起断」，但那个写法会让整行永远不断句）');
    });

    test('整行以「。」收尾时能正确断句（行尾不该被当成「还有下一个字符」）', () {
      final s = seg('走吧。」然后。');
      expect(s.length, 2, reason: '行尾的句号必须断句，实际=${s.map((e) => e.text).toList()}');
      expect(s[0].text, '走吧。');
      expect(s[1].text, '」然后。');
    });

    test('小数点不断句', () {
      final s = seg('圆周率是 3.14 左右。');
      expect(s.length, 1, reason: '3.14 里的小数点不是句末');
      expect(s.first.text, '圆周率是 3.14 左右。');
    });

    test('缩写 / 网址里的点不断句', () {
      final s = seg('参考 U.S. 的报告。');
      expect(s.first.text, contains('U.S.'));
    });

    test('中文省略号只在第二个「…」处断句', () {
      final s = seg('他犹豫了……然后走了。');
      expect(s.map((e) => e.text).toList(), ['他犹豫了……', '然后走了。']);
    });

    test('多行文本不会跨行合并（换行即断句）', () {
      final chars = <PdfTextChar>[
        ...makeChars('上一行', y: 100),
        ...makeChars('下一行', y: 140, indexBase: 3),
      ];
      final s = segmentIntoSentences(groupIntoLines(chars));
      expect(s.map((e) => e.text).toList(), ['上一行', '下一行']);
      expect(s[0].lineIndex, 0);
      expect(s[1].lineIndex, 1);
    });

    test('★硬折行：行末排满且没有句末标点 → 与下一行接成一句（第 6 页真实排版）', () {
      // 《共产主义ABC》第 6 页真实排版（三行都排满、都被硬折行切断）：
      //   从那时起过了很长时间，一直到十月革命为止，情况发生了很大
      //   变化。俄国的大工业在此期间有了巨大的发展，工人阶级也随着壮大
      //   起来。它在一九〇五年的革命中就显示了威力，而到第二次革命（一
      final List<PdfTextLine> lines = page(<List<PdfTextChar>>[
        makeLine('从那时起过了很长时间，一直到十月革命为止，情况发生了很大',
            y: 100, fullWidth: true),
        makeLine('变化。俄国的大工业在此期间有了巨大的发展，工人阶级也随着壮大',
            y: 120, indexBase: 100, fullWidth: true),
        makeLine('起来。它在一九〇五年的革命中就显示了威力，而到第二次革命（一',
            y: 140, indexBase: 200, fullWidth: true),
      ]);
      final List<PdfTextSentence> s = segmentIntoSentences(lines);

      expect(s.first.text, '从那时起过了很长时间，一直到十月革命为止，情况发生了很大变化。',
          reason: '硬折行处不能断句：第一句必须跨第 1、2 两行'
              '（实际=${s.map((e) => e.text).toList()}）');
      expect(s.first.lineIndex, 0, reason: '句子归属起始行');
      expect(s.first.bounds.height, greaterThan(20),
          reason: '这一句的字符盒横跨两行（y 100~132），高亮框自然跨两行');
      expect(s[1].text, '俄国的大工业在此期间有了巨大的发展，工人阶级也随着壮大起来。',
          reason: '第二句同样跨第 2、3 两行');
    });

    test('★正文行以年份/数字结尾（…1917）：仍然要合并，不能被目录守卫劈开', () {
      // 真机反馈（v1.21.21，用户书《…》）：含"年"的数字被拆开，
      // 读完当前句又**回头补读年代**。根因是硬折行合并里的"目录守卫"
      // 只看"行尾是不是数字"，而正文行常常以年份结尾（这一行的"1917"
      // 是"1917年"的上半截，被换行切开了）。
      const l1 = '第一次世界大战爆发于1917';
      const l2 = '年，俄国随后发生了十月革命，政权更替。';
      const l3 = '此后数年内战不断，经济几近崩溃，直到新经济政策才缓过来。';

      final chars = <PdfTextChar>[
        ...makeLine(l1, y: 100, indexBase: 0, fullWidth: true),
        ...makeLine(l2, y: 130, indexBase: l1.length, fullWidth: true),
        ...makeLine(l3, y: 160, indexBase: l1.length + l2.length, fullWidth: true),
      ];
      final s = segmentIntoSentences(groupIntoLines(chars));
      // ignore: avoid_print
      print('PROBE[年份结尾] ${s.map((e) => e.text).toList()}');

      expect(s.first.text, startsWith('第一次世界大战爆发于1917年'),
          reason: '「1917」+「年，…」必须接成一句；'
              '被劈开就会变成"读完一句又回头读年代"（实际：'
              '${s.map((e) => e.text).toList()}）');
      expect(s.first.text, endsWith('政权更替。'));
    });

    test('目录条目（点引导符 + 页码）：仍然不合并', () {
      const l1 = '第一章 十月革命的前夜 ……………………';
      const l2 = '第二章 革命的发展与挫折 ………………… 25';
      const l3 = '第三章 苏维埃政权的巩固 ………………… 41';

      final chars = <PdfTextChar>[
        ...makeLine(l1, y: 100, indexBase: 0, fullWidth: true),
        ...makeLine(l2, y: 130, indexBase: l1.length, fullWidth: true),
        ...makeLine(l3, y: 160, indexBase: l1.length + l2.length, fullWidth: true),
      ];
      final s = segmentIntoSentences(groupIntoLines(chars));
      // ignore: avoid_print
      print('PROBE[目录守卫] ${s.map((e) => e.text).toList()}');

      expect(s.any((e) => e.text.contains('前夜') && e.text.contains('第二章')),
          isFalse,
          reason: '目录条目不能被接成一句（实际：${s.map((e) => e.text).toList()}）');
    });

    test('硬折行的正文：行尾无标点且排满 → 与下一行合并', () {
      const l1 = '从那时起过了很长时间，一直到十月革命为止，情况发生了很大';
      const l2 = '变化。俄国的大工业在此期间有了巨大的发展，工人阶级也随着壮大';
      const l3 = '起来。它在一九〇五年的革命中就显示了威力，而到第二次革命（一';

      final chars = <PdfTextChar>[
        ...makeLine(l1, y: 100, indexBase: 0, fullWidth: true),
        ...makeLine(l2, y: 130, indexBase: l1.length, fullWidth: true),
        ...makeLine(l3, y: 160, indexBase: l1.length + l2.length, fullWidth: true),
      ];
      final s = segmentIntoSentences(groupIntoLines(chars));

      expect(s.first.text, endsWith('情况发生了很大变化。'),
          reason: '「很大」+「变化。」应当合并成一句（当前会断在「很大」）');
      expect(s[1].text, startsWith('俄国的大工业'),
          reason: '「变化。」结束之后才是下一句的开头');
      expect(s[1].text, endsWith('工人阶级也随着壮大起来。'));
      expect(s.last.text, endsWith('第二次革命（一'),
          reason: '末尾是开括号，这一句还没说完');
      expect(s.length, 3,
          reason: '这段应该 3 句（实际 ${s.length} 句：'
              '${s.map((e) => e.text).toList()}）');
    });

    test('封面/扉页：非空行数 < 4 → 不做跨行合并', () {
      final chars = <PdfTextChar>[
        ...makeLine('莱茵学社共产主义文库系列丛书', y: 100, indexBase: 0, fullWidth: true),
        ...makeLine('二〇一七·哈尔滨', y: 130, indexBase: 14, fullWidth: true),
        ...makeLine('共产主义ABC', y: 160, indexBase: 22),
      ];
      final s = segmentIntoSentences(groupIntoLines(chars));
      expect(s.length, 3,
          reason: '封面页行数 < 4，每行独立成句（实际 ${s.length} 句：'
              '${s.map((e) => e.text).toList()}）');
    });

    test('末尾短行 + 无标点 → 独立成句（不与上一行合并）', () {
      // 上一行排满（长文本被硬折），本行明显短
      final chars = <PdfTextChar>[
        ...makeLine('这是一段被排版折行的长文字，第一行排到接近右边界，',
            y: 100, indexBase: 0, fullWidth: true),
        ...makeLine('完了', y: 130, indexBase: 30),
      ];
      final s = segmentIntoSentences(groupIntoLines(chars));
      expect(s.length, 2,
          reason: '第二行明显短且无标点 → 不合并（实际 ${s.map((e) => e.text).toList()}）');
      expect(s.last.text, '完了');
    });

    test('★排满行只续到「行末没排满」为止：不把下一段也吞进来', () {
      final List<PdfTextLine> lines = page(<List<PdfTextChar>>[
        makeLine('上一段的最后一行排满了所以续到本行，本行是段末', y: 100, fullWidth: true),
        makeLine('短行。', y: 130, indexBase: 100),
        makeLine('下一段的第一行从这里开始，但同样没有排满', y: 160, indexBase: 200),
        makeLine('第四行让本页不算标题页（标题页判据要两个条件）', y: 190, indexBase: 300),
      ]);
      final List<PdfTextSentence> s = segmentIntoSentences(lines);
      expect(s.first.text, '上一段的最后一行排满了所以续到本行，本行是段末短行。',
          reason: '排满行 + 下一行里有句末标点 → 接成一句');
      expect(s[1].text, '下一段的第一行从这里开始，但同样没有排满',
          reason: '没排满的行自己收尾，不往后吞');
    });
  });

  group('文字清理', () {
    test('中文之间被 PDF 塞进来的空格要去掉', () {
      expect(cleanSentenceText('你 好 世 界'), '你好世界');
    });

    test('英文单词之间的空格要保留', () {
      expect(cleanSentenceText('hello world'), 'hello world');
    });

    test('连续空白压成一个、首尾去掉', () {
      expect(cleanSentenceText('  a   b  '), 'a b');
    });
  });

  group('命中测试', () {
    test('点在字上命中该句', () {
      final layer = buildTextLayer(
        pageNumber: 1,
        pageSize: const Size(200, 300),
        fullText: '第一句。第二句。',
        charRects: makeChars('第一句。第二句。', y: 100).map((c) => c.rect).toList(),
        segment: segmentIntoSentences,
      );
      expect(layer.sentences.length, 2);
      // 点第一个字的中心
      final first = layer.sentences[0].chars.first.rect.center;
      expect(layer.sentenceIndexAt(first), 0);
      // 点第二句的字
      final second = layer.sentences[1].chars.first.rect.center;
      expect(layer.sentenceIndexAt(second), 1);
    });

    test('点在行的正下方（同一行的容差带内）仍然命中该行', () {
      final layer = buildTextLayer(
        pageNumber: 1,
        pageSize: const Size(200, 300),
        fullText: '这一行字。',
        charRects: makeChars('这一行字。', y: 100, h: 12).map((c) => c.rect).toList(),
        segment: segmentIntoSentences,
      );
      // 字盒底部 112，点在 116（下方 4pt，行高 12 的容差内）
      expect(layer.sentenceIndexAt(const Offset(25, 116)), isNotNull,
          reason: '手指点在两行之间时也要能命中，否则就是「点了没反应」');
    });

    test('点在很远的空白处不命中', () {
      final layer = buildTextLayer(
        pageNumber: 1,
        pageSize: const Size(200, 300),
        fullText: '这一行字。',
        charRects: makeChars('这一行字。', y: 100, h: 12).map((c) => c.rect).toList(),
        segment: segmentIntoSentences,
      );
      expect(layer.sentenceIndexAt(const Offset(25, 280)), isNull,
          reason: '离文字很远不该误命中');
    });
  });

  group('空页 / 扫描件', () {
    test('没有字符盒时句子为空（用于提示「未检测到可朗读文本」）', () {
      final layer = buildTextLayer(
        pageNumber: 1,
        pageSize: const Size(200, 300),
        fullText: '',
        charRects: const <Rect>[],
        segment: segmentIntoSentences,
      );
      expect(layer.isEmpty, isTrue);
    });

    test('只有空白字符也算空', () {
      final layer = buildTextLayer(
        pageNumber: 1,
        pageSize: const Size(200, 300),
        fullText: '   ',
        charRects: makeChars('   ', y: 10).map((c) => c.rect).toList(),
        segment: segmentIntoSentences,
      );
      expect(layer.isEmpty, isTrue, reason: '全是空格的页不该被当成有文字');
    });
  });

  group('跨页句子（上一页末尾到下一页开头）', () {
    PdfPageTextLayer pageOf(int pageNumber, String text) => buildTextLayer(
          pageNumber: pageNumber,
          pageSize: const Size(200, 300),
          fullText: text,
          charRects:
              makeChars(text, y: 100).map((c) => c.rect).toList(),
          segment: segmentIntoSentences,
        );

    test('本页最后一句没写完 → 接上下一页开头', () {
      final p1 = pageOf(1, '这一句还没写完，');
      final p2 = pageOf(2, '下半句在这里。');
      final whole = buildCrossPageSentence(p1, 0, p2);
      expect(whole.spansPages, isTrue);
      expect(whole.text, '这一句还没写完，下半句在这里。');
      expect(whole.startPage, 1);
      expect(whole.endPage, 2);
      expect(whole.endSentence, 0);
    });

    test('本页最后一句已经写完（句号结尾）→ 不合并', () {
      final p1 = pageOf(1, '这一句写完了。');
      final p2 = pageOf(2, '下一页的内容。');
      final whole = buildCrossPageSentence(p1, 0, p2);
      expect(whole.spansPages, isFalse);
      expect(whole.text, '这一句写完了。');
    });

    test('只合并一页，不会把整本书接成一句', () {
      final p1 = pageOf(1, '没写完的句子，');
      final p2 = pageOf(2, '还是没写完，');
      final whole = buildCrossPageSentence(p1, 0, p2);
      // 只拼下一页的第一句，不会继续往后接
      expect(whole.text, '没写完的句子，还是没写完，');
      expect(whole.endPage, 2);
    });

    test('不是最后一句时不合并（中间句不可能断页）', () {
      final p1 = pageOf(1, '第一句没写完，第二句写完了。');
      final p2 = pageOf(2, '下一页。');
      final whole = buildCrossPageSentence(p1, 0, p2);
      expect(whole.spansPages, isFalse,
          reason: '第 0 句不是本页最后一句，不该去接下一页');
    });

    test('没有下一页文本层时不合并', () {
      final p1 = pageOf(1, '没写完，');
      final whole = buildCrossPageSentence(p1, 0, null);
      expect(whole.spansPages, isFalse);
      expect(whole.text, '没写完，');
    });

    test('英文跨页时补一个空格', () {
      final p1 = pageOf(1, 'this sentence continues');
      final p2 = pageOf(2, 'on the next page.');
      final whole = buildCrossPageSentence(p1, 0, p2);
      expect(whole.text, 'this sentence continues on the next page.');
    });

    test('looksUnfinished 的判据', () {
      expect(looksUnfinished('没写完，'), isTrue);
      expect(looksUnfinished('没标点'), isTrue);
      expect(looksUnfinished('写完了。'), isFalse);
      expect(looksUnfinished('真的吗？'), isFalse);
      expect(looksUnfinished('省略了…'), isFalse);
      expect(looksUnfinished('  '), isFalse);
    });
  });

  group('推进导航（nextPdfSentence / firstSentenceOnPage）', () {
    PdfPageTextLayer page(int pageNumber, String text) => buildTextLayer(
          pageNumber: pageNumber,
          pageSize: const Size(200, 300),
          fullText: text,
          charRects: makeChars(text, y: 100).map((c) => c.rect).toList(),
          segment: segmentIntoSentences,
        );

    // 三页：第 1 页两句、第 2 页一句、第 3 页空（模拟扫描件）
    final p1 = page(1, '第一页第一句。第一页第二句。');
    final p2 = page(2, '第二页唯一一句。');
    final p3 = page(3, '');
    PdfPageTextLayer? layerOf(int pageIndex) => switch (pageIndex) {
          0 => p1,
          1 => p2,
          2 => p3,
          _ => null,
        };

    test('同页下一句', () {
      const ref = PdfSentenceRef(pageIndex: 0, sentenceIndex: 0, text: '第一页第一句。');
      final n = nextPdfSentence(ref, layerOf);
      expect(n, isNotNull);
      expect(n!.pageIndex, 0, reason: '还在第 1 页');
      expect(n.sentenceIndex, 1);
      expect(n.text, '第一页第二句。');
    });

    test('跨页下一句（本章最后一句 → 下一页第一句）', () {
      const ref = PdfSentenceRef(pageIndex: 0, sentenceIndex: 1, text: '第一页第二句。');
      final n = nextPdfSentence(ref, layerOf);
      expect(n, isNotNull, reason: '第 1 页读完了要跳到第 2 页');
      expect(n!.pageIndex, 1, reason: 'PDF 一章即一页：跨页 = 换章');
      expect(n.sentenceIndex, 0);
      expect(n.text, '第二页唯一一句。');
    });

    test('末句返回 null（读到头了）', () {
      const ref = PdfSentenceRef(pageIndex: 1, sentenceIndex: 0, text: '第二页唯一一句。');
      // 第 2 页只有一句，下一页（第 3 页）没有文字 → null
      expect(nextPdfSentence(ref, layerOf), isNull,
          reason: '下一页没有文字层就当读到头，不能瞎跳');
    });

    test('越界页返回 null', () {
      final n = nextPdfSentence(
        const PdfSentenceRef(pageIndex: 99, sentenceIndex: 0, text: 'x'),
        layerOf,
      );
      expect(n, isNull);
    });

    test('firstSentenceOnPage：取该页第一句', () {
      final ref = firstSentenceOnPage(1, p2);
      expect(ref, isNotNull);
      expect(ref!.pageIndex, 1);
      expect(ref.sentenceIndex, 0);
      expect(ref.text, '第二页唯一一句。');
    });

    test('firstSentenceOnPage：空页 / null 层返回 null', () {
      expect(firstSentenceOnPage(2, p3), isNull, reason: '扫描件没有文字');
      expect(firstSentenceOnPage(0, null), isNull);
    });

    test('nextPdfSentence 能一路走到底（模拟自动连读）', () {
      // 从第 1 页第 1 句开始，一直 next，收集所有句子
      PdfSentenceRef? cursor = firstSentenceOnPage(0, p1);
      final walked = <String>[];
      var guard = 0;
      while (cursor != null && guard++ < 20) {
        walked.add(cursor.text);
        cursor = nextPdfSentence(cursor, layerOf);
      }
      expect(walked, <String>['第一页第一句。', '第一页第二句。', '第二页唯一一句。'],
          reason: '自动连读要正好读完有文字的页，然后在第 3 页（空页）停住');
      expect(guard, lessThan(20), reason: '不能无限循环');
    });

    test('⚠️ 跳过空白页继续读（不能把空白页当成读到头）', () {
      // 第 4 页有正文、第 5 页空白（插图/扫描）、第 6 页又有正文。
      // 实测踩到过：真实 319 页的书第 7 页之后有空白页，朗读在第 8 页
      // 就报「整本读完」—— 用户看到的是「书读到一半突然说读完了」。
      final p4 = page(4, '第四页正文。');
      final p5 = page(5, '');
      final p6 = page(6, '第六页正文。');
      final blanks = <int>{4}; // 只有第 5 页（0 起下标 4）是真空白
      PdfPageTextLayer? byIndex(int i) => switch (i) {
            3 => p4,
            4 => p5,
            5 => p6,
            _ => null,
          };

      expect(p5.isEmpty, isTrue, reason: '第 5 页确实抽不出文字');
      final next = nextPdfSentence(
        const PdfSentenceRef(pageIndex: 3, sentenceIndex: 0, text: '第四页正文。'),
        byIndex,
        isEmptyPage: blanks.contains,
        pageCount: 6,
      );
      expect(next, isNotNull, reason: '第 5 页空白不该终止朗读，应当跳到第 6 页');
      expect(next!.pageIndex, 5, reason: '落在第 6 页（0 起下标 5）');
      expect(next.text, '第六页正文。');
    });

    test('末尾的自然空白页仍然算读到头', () {
      final only = page(1, '唯一一页。');
      final blank = page(2, '');
      PdfPageTextLayer? byIndex(int i) => switch (i) {
            0 => only,
            1 => blank,
            _ => null,
          };
      final next = nextPdfSentence(
        const PdfSentenceRef(pageIndex: 0, sentenceIndex: 0, text: '唯一一页。'),
        byIndex,
        isEmptyPage: (i) => i == 1,
        pageCount: 2,
      );
      expect(next, isNull, reason: '末尾空白页 = 读完，不该继续找');
    });

    test('图层还没抽出来时返回 null（**不是**读到头的信号）', () {
      // 关键区分：`isEmptyPage` 说「不是空白」但 `layerOf` 取不到
      // → 是还没抽完 / 抽失败，不是文档结束。调用方要据此重试而不是收尾。
      PdfPageTextLayer? nothing(int i) => null;
      final next = nextPdfSentence(
        const PdfSentenceRef(pageIndex: 0, sentenceIndex: 0, text: 'x'),
        nothing,
        isEmptyPage: (i) => false,
        pageCount: 10,
      );
      expect(next, isNull);
    });

    test('整本都是空白页时不会无限扫（有上限）', () {
      var asked = 0;
      final next = nextPdfSentence(
        const PdfSentenceRef(pageIndex: 0, sentenceIndex: 0, text: 'x'),
        (i) {
          asked++;
          return null;
        },
        isEmptyPage: (i) => true, // 全说成空白
        pageCount: 500,
      );
      expect(next, isNull);
      expect(asked, lessThanOrEqualTo(maxBlankPagesToSkip + 2),
          reason: '不能把 500 页全扫一遍（asked=$asked）');
    });
  });

  // ⚠️ §4.100 任务 B 的回归：高亮**逐行独立画**，绝不合并成大框。
  // 历史教训（§4.44 → v1.21.0 又踩回去）：画笔拿「句子首尾字符下标」去扫
  // 全页字符，而页脚 / 标题在 fullText 里的下标与视觉顺序无关 ——
  // 一个句子的区间会捞到别的行的字，画出来就是「斜跨多行、盖到标题行」的大框。
  group('逐行高亮矩形（§4.100：绝不合并成 bounding box）', () {
    test('一句话跨 3 行 → 3 个独立 Rect，第 2、3 行的 left 互不相等', () {
      final chars = <PdfTextChar>[
        ...makeChars('第一行文字内容', x: 0, y: 100, indexBase: 0),
        ...makeChars('第二行文字内容', x: 40, y: 130, indexBase: 7),
        ...makeChars('尾两字', x: 80, y: 160, indexBase: 14),
      ];
      final s = PdfTextSentence(
        text: '第一行文字内容第二行文字内容尾两字',
        chars: chars,
        lineIndex: 0,
      );
      final rects = s.highlightRects;
      expect(rects.length, 3, reason: '跨 3 行必须返回 3 个 Rect，不能并成 1 个');
      expect(rects[1].left, isNot(rects[0].left),
          reason: '各行 left 不相等 —— 这就是「不是大框」的判据');
      expect(rects[2].left, isNot(rects[1].left));
      // 每个 Rect 只有一行高（±钳制），不会盖到相邻行
      for (var i = 0; i < rects.length; i++) {
        expect(rects[i].height, lessThanOrEqualTo(12 * 1.6),
            reason: 'rect[$i] 高 ${rects[i].height} 不该超过单行高');
      }
      // 第 3 行只有末尾 3 个字：宽度只覆盖 3 个字符，不是整行宽
      expect(rects[2].width, closeTo(30, 0.01),
          reason: '只覆盖该行内这句话实际占的字符区间');
      // 各行的纵向位置互不重叠
      expect(rects[0].bottom, lessThanOrEqualTo(rects[1].top + 1));
      expect(rects[1].bottom, lessThanOrEqualTo(rects[2].top + 1));
    });

    test('单行句子：1 个 Rect，只盖句内字符（同一行两句各自一条）', () {
      final chars = makeChars('第一句。第二句。', x: 0, y: 100);
      final sents = segmentIntoSentences(groupIntoLines(chars));
      expect(sents.length, 2);
      final r0 = sents[0].highlightRects;
      expect(r0.length, 1);
      expect(r0.single.width, closeTo(40, 0.01),
          reason: '只盖 4 个字符宽，不是整行 8 字');
      final r1 = sents[1].highlightRects.single;
      expect(r1.left, closeTo(40, 0.01), reason: '第二句从第 5 个字起');
    });

    test('上下标字符不会把单行底色拽高成斜条', () {
      // 正常字 + 一个更高的字符盒（上下标）混在同一行
      final chars = <PdfTextChar>[
        ...makeChars('正文', x: 0, y: 100, h: 12),
        PdfTextChar(index: 2, char: '注', rect: const Rect.fromLTWH(20, 90, 10, 30)),
      ];
      final s = PdfTextSentence(text: '正文注', chars: chars, lineIndex: 0);
      final rects = s.highlightRects;
      expect(rects.length, 1);
      expect(rects.single.height, lessThanOrEqualTo(12 * 1.6),
          reason: '按字符高中位数钳制，不被个别高盒拉大');
    });

    test('sentenceAtRange：按 (首,尾) 找回那一句；对不上返回 null', () {
      final layer = buildTextLayer(
        pageNumber: 1,
        pageSize: const Size(200, 300),
        fullText: '第一句。第二句。',
        charRects:
            makeChars('第一句。第二句。', y: 100).map((c) => c.rect).toList(),
        segment: segmentIntoSentences,
      );
      final s0 = layer.sentences[0];
      expect(identical(sentenceAtRange(layer, (s0.firstCharIndex, s0.lastCharIndex)), s0),
          isTrue);
      // 跨句拼出来的假区间（0..7 = 两句连起来）不对应任何整句 → null
      // 调用方（画笔）对 null 的处理是**不画**，而不是按区间扫全页凑一个框
      expect(sentenceAtRange(layer, (0, 7)), isNull);
      expect(sentenceAtRange(layer, (0, 0)), isNull);
    });

    test('重复短句：两句文本相同，Rect 各自落在自己的行（§4.44 老坑）', () {
      // 老坑是按**文本**匹配定位 —— 同页两处「好。」会认错。
      // 新实现按 (首,尾) 下标对匹配，与文本无关。
      final chars = <PdfTextChar>[
        ...makeChars('好。', x: 0, y: 100, indexBase: 0),
        ...makeChars('好。', x: 0, y: 130, indexBase: 2),
      ];
      final layer = buildTextLayer(
        pageNumber: 1,
        pageSize: const Size(200, 300),
        fullText: '好。好。',
        charRects: chars.map((c) => c.rect).toList(),
        segment: segmentIntoSentences,
      );
      expect(layer.sentences.length, 2);
      expect(layer.sentences[0].text, layer.sentences[1].text,
          reason: '前提：两句文本确实相同');
      final a = sentenceAtRange(layer, (0, 1))!;
      final b = sentenceAtRange(layer, (2, 3))!;
      expect(identical(a, layer.sentences[0]), isTrue);
      expect(identical(b, layer.sentences[1]), isTrue);
      // 高亮位置必须不同（各在自己的行上）；行带按中位行高钳制，
      // 允许 ±0.75×行高的外扩（12×0.75=9 → top 在 100 上方至多 9）
      expect(a.highlightRects.single.top, isNot(b.highlightRects.single.top));
      expect(a.highlightRects.single.top, closeTo(100, 9));
      expect(b.highlightRects.single.top, closeTo(130, 9));
      expect(a.highlightRects.single.top, lessThan(b.highlightRects.single.top));
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  //  v1.22.61：点空白处不该读同一行（用户 2026-10-25 报的平板现象）
  //
  //  **原漏洞**：就近兜底只有"纵向容差"，横向**没有上限** ——
  //  只要 y 落在某行容差带内，x 在页面最左/最右的页边距也会命中那一行。
  //  于是"点页面上任意空白处"都会开始朗读同一行，看起来像"点哪都读"。
  // ────────────────────────────────────────────────────────────────────────
  group('★命中测试的容差必须有横向上限（点空白不该读同行）', () {
    /// 一行 5 个汉字（每个 10×12），从 (0,100) 起 → 占 x 0..50 / y 100..112
    PdfPageTextLayer oneLine() => buildTextLayer(
          pageNumber: 1,
          pageSize: const Size(200, 300),
          fullText: '这一行字。',
          charRects:
              makeChars('这一行字。', y: 100).map((c) => c.rect).toList(),
          segment: segmentIntoSentences,
        );

    test('★核心：同一行高度、但在很远的右侧空白 → 不命中', () {
      final layer = oneLine();
      // y 正在行内（105），x=200 在行右边界 50 之外 150pt
      expect(layer.sentenceIndexAt(const Offset(200, 105)), isNull,
          reason: '这就是用户报的"点空白处也能控制同行句子"：'
              '纵向落在行内 + 横向无上限 → 页边距任意位置都命中');
    });

    test('★核心：同一行高度、但在左侧页边距（x 负向）→ 不命中', () {
      final layer = oneLine();
      expect(layer.sentenceIndexAt(const Offset(-30, 105)), isNull,
          reason: '左边页边距同理，不该命中');
    });

    test('行尾右侧**一点点**（约半个字宽）→ 仍然命中（保留手感）', () {
      final layer = oneLine();
      // 行右边界 50，点 55 → dx=5 < max(10, 12*1.2=14.4)
      expect(layer.sentenceIndexAt(const Offset(55, 105)), isNotNull,
          reason: '点在行尾标点右侧一点点必须能命中，否则又回到"点了没反应"');
    });

    test('行间缝隙（纵向半个行高内）→ 仍然命中', () {
      final layer = oneLine();
      // 行底 112，点 116 → dy=4 < 12*0.55=6.6
      expect(layer.sentenceIndexAt(const Offset(25, 116)), isNotNull,
          reason: '两行之间的缝隙要能命中（原有容差的目的）');
    });

    test('纵向离得太远（超过半行高）→ 不命中', () {
      final layer = oneLine();
      expect(layer.sentenceIndexAt(const Offset(25, 130)), isNull,
          reason: 'dy=18 > 12*0.55=6.6：不该再靠"纵向 0.9 倍行高"的旧容差命中');
    });

    test('★对照：旧实现（横向无上限）在这些点上会命中 —— 证明用例抓得到 bug', () {
      // 复现修前逻辑：纵向容差 0.9×行高，横向不设限
      bool legacyHits(Rect b, Offset p) {
        final dy = p.dy < b.top
            ? b.top - p.dy
            : (p.dy > b.bottom ? p.dy - b.bottom : 0.0);
        return dy <= b.height * 0.9;
      }

      const Rect b = Rect.fromLTWH(0, 100, 50, 12);
      expect(legacyHits(b, const Offset(200, 105)), isTrue,
          reason: '前提：旧写法在 x=200 处确实会命中（纵向在带内）');
      final layer = oneLine();
      expect(layer.sentenceIndexAt(const Offset(200, 105)), isNull,
          reason: '★修复后必须与旧行为相反，否则这条改动等于没生效');
    });
  });
}

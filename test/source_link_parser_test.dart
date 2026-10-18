import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/source_link_parser.dart';

/// `yuedu://` / `legado://` 书源导入链接解析
///
/// 纯函数，零依赖：不解网络、不碰 UI，所以能完整离线覆盖。
void main() {
  group('能认出来的形态', () {
    test('yuedu://booksource/importonline（src 带百分号编码）', () {
      expect(
        SourceLinkParser.extractBookSourceUrl(
          'yuedu://booksource/importonline?src=https%3A%2F%2Fa.com%2Fb.json',
        ),
        'https://a.com/b.json',
      );
    });

    test('legado://import/bookSource（大小写混用）', () {
      expect(
        SourceLinkParser.extractBookSourceUrl(
          'legado://import/bookSource?src=http://x.com/y.json',
        ),
        'http://x.com/y.json',
      );
    });

    test('/bookSource 与 /booksource 两种大小写都能认', () {
      expect(
        SourceLinkParser.extractBookSourceUrl(
          'yuedu://bookSource/importonline?src=http://a.com/1.json',
        ),
        'http://a.com/1.json',
      );
      expect(
        SourceLinkParser.extractBookSourceUrl(
          'yuedu://booksource/importonline?src=http://a.com/1.json',
        ),
        'http://a.com/1.json',
      );
    });

    test('legado://import/importonline?type=booksource', () {
      expect(
        SourceLinkParser.extractBookSourceUrl(
          'legado://import/importonline?src=http://a.com/z.json&type=booksource',
        ),
        'http://a.com/z.json',
      );
    });

    test('src 里带 https 的完整地址不被二次编码破坏', () {
      const String link =
          'yuedu://booksource/importonline?src=https://shuyuan.nyasama.cc/cdn/5f62.json';
      expect(
        SourceLinkParser.extractBookSourceUrl(link),
        'https://shuyuan.nyasama.cc/cdn/5f62.json',
      );
    });

    test('嵌套一层 src（src 本身又是一个 yuedu 链接）会递归剥开', () {
      const String inner = 'yuedu://booksource/importonline?src=http://a.com/inner.json';
      final String outer =
          'yuedu://booksource/importonline?src=${Uri.encodeComponent(inner)}';
      expect(SourceLinkParser.extractBookSourceUrl(outer), 'http://a.com/inner.json');
    });
  });

  group('不该认的', () {
    test('普通 https 链接', () {
      expect(
        SourceLinkParser.extractBookSourceUrl('https://example.com/book.json'),
        isNull,
      );
    });

    test('yuedu://rsssource 不是书源（订阅源是另一套）', () {
      expect(
        SourceLinkParser.extractBookSourceUrl(
          'yuedu://rsssource/importonline?src=http://a.com/rss.json',
        ),
        isNull,
      );
    });

    test('是书源链接但缺 src：返回 null，不崩', () {
      expect(
        SourceLinkParser.extractBookSourceUrl('yuedu://booksource/importonline'),
        isNull,
      );
      expect(
        SourceLinkParser.extractBookSourceUrl('yuedu://booksource/importonline?src='),
        isNull,
      );
    });

    test('别的 scheme', () {
      expect(
        SourceLinkParser.extractBookSourceUrl('intent://x#Intent;end'),
        isNull,
      );
    });
  });

  group('isBookSourceLink（UI 提示用）', () {
    test('书源链接为 true', () {
      expect(
        SourceLinkParser.isBookSourceLink('yuedu://booksource/importonline?src=x'),
        isTrue,
      );
    });

    test('普通链接为 false', () {
      expect(SourceLinkParser.isBookSourceLink('https://a.com'), isFalse);
    });
  });

  group('从一段文字里捞链接（粘贴场景）', () {
    test('前后带说明文字也能捞出来', () {
      expect(
        SourceLinkParser.extractFromText(
          '一键导入：yuedu://booksource/importonline?src=http://a.com/b.json 请收藏本站',
        ),
        'http://a.com/b.json',
      );
    });

    test('没有链接时返回 null', () {
      expect(SourceLinkParser.extractFromText('就是一段普通文字'), isNull);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/source_link_parser.dart';

/// 订阅源（RSS）深链解析
///
/// 真机日志（2026-10-19 02:10）：
/// `UNSUPPORTED_SCHEME: net::ERR_UNKNOWN_URL_SCHEME @ legado://import/rssSource?src=...`
/// 原因是浏览器只拦了书源链接，没拦订阅源链接 → 落到 WebView 的错误页。
void main() {
  test('yuedu://rsssource 能取出地址', () {
    expect(
      SourceLinkParser.extractRssSourceUrl('yuedu://rsssource/importonline?src=http://a.com/r.json'),
      'http://a.com/r.json',
    );
  });

  test('legado://import/rssSource（线上真实形态）能取出地址', () {
    const String link =
        'legado://import/rssSource?src=https://legado.aoaostar.com/sources/9955b83c.json';
    expect(
      SourceLinkParser.extractRssSourceUrl(link),
      'https://legado.aoaostar.com/sources/9955b83c.json',
    );
    expect(SourceLinkParser.isRssSourceLink(link), isTrue);
  });

  test('书源链接不会被当成订阅源（两套库分开）', () {
    expect(
      SourceLinkParser.isRssSourceLink('yuedu://booksource/importonline?src=http://a.com/b.json'),
      isFalse,
    );
  });

  test('订阅源链接不会被当成书源', () {
    expect(
      SourceLinkParser.isBookSourceLink('yuedu://rsssource/importonline?src=http://a.com/r.json'),
      isFalse,
    );
  });

  test('缺 src 返回 null', () {
    expect(SourceLinkParser.extractRssSourceUrl('legado://import/rssSource'), isNull);
  });
}

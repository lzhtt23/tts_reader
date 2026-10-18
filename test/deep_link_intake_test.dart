import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/deep_link_intake.dart';

/// 深链（被系统拉起来）→ 提取书源地址
///
/// 「一键导入」在 legado 生态里就是一条 `yuedu://` 深链：网页把链接交给系统，
/// 系统找声明了这个 scheme 的 App。我们声明之后也能被拉起。
///
/// ⚠️ 与阅读 App 抢同一个 scheme：系统会弹「用哪个应用打开」，
/// 这不能绕过也不该绕过。本用例只验证「收到链接后能正确提取」。
void main() {
  setUp(() {
    DeepLinkIntake.instance.consume();
  });

  test('yuedu:// 链接能提出书源地址', () {
    DeepLinkIntake.instance.submitForTest(
      'yuedu://booksource/importonline?src=https%3A%2F%2Fa.com%2Fb.json',
    );
    expect(DeepLinkIntake.instance.pendingSourceUrl.value, 'https://a.com/b.json');
  });

  test('legado:// 链接也能', () {
    DeepLinkIntake.instance.submitForTest(
      'legado://import/bookSource?src=http://x.com/y.json',
    );
    expect(DeepLinkIntake.instance.pendingSourceUrl.value, 'http://x.com/y.json');
  });

  test('不是书源链接：不设待办，也不崩', () {
    DeepLinkIntake.instance.submitForTest('https://example.com/foo');
    expect(DeepLinkIntake.instance.pendingSourceUrl.value, isNull);
  });

  test('订阅源链接（rsssource）不当作书源', () {
    DeepLinkIntake.instance.submitForTest(
      'yuedu://rsssource/importonline?src=http://a.com/rss.json',
    );
    expect(DeepLinkIntake.instance.pendingSourceUrl.value, isNull);
  });

  test('取走之后清空（不重复弹确认框）', () {
    DeepLinkIntake.instance.submitForTest(
      'yuedu://booksource/importonline?src=http://a.com/1.json',
    );
    expect(DeepLinkIntake.instance.pendingSourceUrl.value, isNotNull);
    DeepLinkIntake.instance.consume();
    expect(DeepLinkIntake.instance.pendingSourceUrl.value, isNull);
  });

  test('空文本忽略', () {
    DeepLinkIntake.instance.submitForTest('   ');
    expect(DeepLinkIntake.instance.pendingSourceUrl.value, isNull);
  });
}

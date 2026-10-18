import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/gbk_decoder.dart';
import 'package:tts_reader/services/url_template.dart';

/// P0：GBK 解码钩子
///
/// 背景：`SourceHttpClient.decodeBytes` 早就留了 `gbkDecoder` 钩子，但**没人赋值**。
/// 书源声明 `charset: gbk` 的中文站点会被当 UTF-8 宽松解码 → 整页乱码，
/// 规则匹配全部落空。这组用例钉住「装了钩子之后能解对」和「没装时不会崩」。
void main() {
  // "中文" 的 GBK 编码：D6 D0 CE C4
  final Uint8List gbkBytes = Uint8List.fromList(<int>[0xD6, 0xD0, 0xCE, 0xC4]);

  tearDown(GbkDecoderInstaller.uninstall);

  test('装钩子之前：GBK 字节被当 UTF-8 宽松解码（这就是乱码的来源）', () {
    GbkDecoderInstaller.uninstall();
    final String text = SourceHttpClient.decodeBytes(gbkBytes, 'gbk');
    expect(text, isNot('中文'), reason: '没装钩子时必须解不出正确中文');
    expect(text.contains('\uFFFD'), isTrue, reason: '应当是替换字符');
  });

  test('装钩子之后：charset=gbk 能解出正确中文', () {
    GbkDecoderInstaller.install();
    expect(SourceHttpClient.decodeBytes(gbkBytes, 'gbk'), '中文');
  });

  test('gb2312 / gb18030 也走同一条路', () {
    GbkDecoderInstaller.install();
    expect(SourceHttpClient.decodeBytes(gbkBytes, 'gb2312'), '中文');
    expect(SourceHttpClient.decodeBytes(gbkBytes, 'gb18030'), '中文');
    // 大小写不敏感
    expect(SourceHttpClient.decodeBytes(gbkBytes, 'GBK'), '中文');
  });

  test('utf-8 不受影响', () {
    GbkDecoderInstaller.install();
    final Uint8List utf8Bytes = Uint8List.fromList(utf8.encode('中文'));
    expect(SourceHttpClient.decodeBytes(utf8Bytes, 'utf-8'), '中文');
  });

  test('非法字节不抛异常（allowInvalid）', () {
    GbkDecoderInstaller.install();
    final Uint8List broken = Uint8List.fromList(<int>[0x81, 0x40, 0xFF, 0xFE]);
    expect(() => SourceHttpClient.decodeBytes(broken, 'gbk'), returnsNormally);
  });
}

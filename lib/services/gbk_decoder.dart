import 'package:enough_convert/enough_convert.dart';

import 'url_template.dart';

/// 给 `SourceHttpClient` 装一个真正的 GBK 解码器（P0）
///
/// 背景：`SourceHttpClient.decodeBytes` 早就留了 `gbkDecoder` 钩子，但**没人赋值**，
/// 所以书源声明 `charset: gbk` 的中文站点会被当 UTF-8 宽松解码 → 整页乱码，
/// 后面的规则匹配全部落空（表现为「搜不到书 / 章节正文是问号」）。
///
/// 这里用工程已有的 `enough_convert`（纯 Dart，无平台通道，isolate 里也能跑）。
///
/// 为什么单独一个文件而不是直接写进 `url_template.dart`：
/// 那个文件目前不 import 任何编码库，好让它的单测不依赖 GBK 表；
/// 装钩子是**运行时副作用**，放 main() 里显式调用一次更清楚。
class GbkDecoderInstaller {
  const GbkDecoderInstaller._();

  /// `allowInvalid: true`：GBK 里混进非法字节时解成 U+FFFD，不抛异常。
  /// 抓网页时宁可留几个替换字符，也不要整章失败。
  static const GbkCodec _gbk = GbkCodec(allowInvalid: true);

  /// 繁体站常见的 Big5
  static const Big5Codec _big5 = Big5Codec(allowInvalid: true);

  /// 装一次即可；重复调用无副作用（直接覆盖同一个静态钩子）
  static void install() {
    SourceHttpClient.gbkDecoder = _decode;
    SourceHttpClient.big5Decoder = _decodeBig5;
  }

  /// 拆成具名函数而不是内联闭包：避免每次 install 都新建闭包
  static String _decode(List<int> bytes) => _gbk.decode(bytes);

  static String _decodeBig5(List<int> bytes) => _big5.decode(bytes);

  /// 仅供测试：把钩子摘掉，避免用例之间互相影响
  static void uninstall() {
    SourceHttpClient.gbkDecoder = null;
    SourceHttpClient.big5Decoder = null;
  }

  /// 解码一段 GBK 字节（测试与本地诊断用）
  static String decode(List<int> bytes) => _gbk.decode(bytes);
}

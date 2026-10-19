import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'crash_log.dart';

/// 从网络抓一张封面图存到本地
///
/// ## 用在哪
///
/// 在线书整本下载成 TXT 之后，TXT 本身**没有图片**，只能靠排版画一张。
/// 但下载它的那个在线详情页其实**有封面**（`ruleBookInfo.coverUrl`），
/// 那就先用真封面，抓不到再退回排版封面。
///
/// ## 防御
///
/// 书源的图片地址经常是：防盗链 403、http 403 混合内容、几十 MB 的大图、
/// 或者干脆 404。这里逐条挡住，**任何一步失败都返回 null**（调用方兜底），
/// 不让下载流程因为封面失败而失败。
class CoverFetcher {
  CoverFetcher._();

  /// 单张封面上限（超过就放弃：正常封面几百 KB，几十 MB 的是原图或错误页）
  static const int maxBytes = 8 * 1024 * 1024;

  /// 抓取并落盘；成功返回 [outPath]，失败 null
  static Future<String?> fetchTo(
    String url,
    String outPath, {
    http.Client? client,
  }) async {
    final String raw = url.trim();
    if (raw.isEmpty) return null;
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) return null;

    final http.Client httpClient = client ?? http.Client();
    final bool own = client == null;
    try {
      final http.Response response = await httpClient
          .get(
            Uri.parse(raw),
            headers: const <String, String>{
              // 不少站点没有 Referer/UA 就直接 403
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 400) {
        CrashLog.mark('封面抓取[跳过] HTTP ${response.statusCode} $raw');
        return null;
      }
      final Uint8List bytes = response.bodyBytes;
      if (bytes.isEmpty || bytes.length > maxBytes) {
        CrashLog.mark('封面抓取[跳过] 大小不合适 ${bytes.length} $raw');
        return null;
      }
      // 只认图片：有的源会返回 HTML 错误页（200 但内容是网页）
      if (!_looksLikeImage(bytes)) {
        CrashLog.mark('封面抓取[跳过] 不是图片 $raw');
        return null;
      }
      final File file = File(outPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return outPath;
    } catch (e) {
      CrashLog.mark('封面抓取[失败] $raw $e');
      return null;
    } finally {
      if (own) httpClient.close();
    }
  }

  /// 按文件头判断是不是图片（jpg / png / gif / webp / bmp）
  static bool _looksLikeImage(Uint8List b) {
    if (b.length < 12) return false;
    // JPEG: FF D8 FF
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return true;
    // PNG: 89 50 4E 47
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return true;
    // GIF: 47 49 46
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true;
    // WEBP: RIFF....WEBP
    if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46) {
      return b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50;
    }
    // BMP: 42 4D
    if (b[0] == 0x42 && b[1] == 0x4D) return true;
    return false;
  }
}

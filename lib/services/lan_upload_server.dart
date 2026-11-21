import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 局域网传书的 HTTP 服务（v1.22.70）
///
/// ## 为什么这样做
///
/// 从电脑往手机传书，最烦的是「插线找目录」或「先传网盘再下载」。
/// 这里在手机上起一个临时 HTTP 服务，电脑浏览器打开就能拖文件进来，
/// 落盘后直接进文档库 —— 全程不依赖任何第三方库（`dart:io` 自带 `HttpServer`）。
///
/// ## 为什么不用 multipart
///
/// Dart 标准库没有 multipart 解析器，自己解析边界字符串是典型的「看着简单、
/// 边界情况一堆」的活（文件名里的引号、CRLF、多文件混排）。
/// 这里改成**原始字节直传**：页面用
/// ```js
/// fetch('/upload?name=' + encodeURIComponent(file.name), {method:'POST', body:file})
/// ```
/// 服务端把请求体直接当文件内容写盘。零解析、零依赖、大文件也能流式落盘。
///
/// ## 安全边界（写清楚，别以后越界）
///
/// - **只监听局域网**（绑定 0.0.0.0 由系统选网卡），不对外网开放；
/// - 文件名做净化：去目录分隔符、去 `..`、保留原扩展名；
/// - 只接受 pdf / epub / txt；
/// - 单文件上限 [maxFileBytes]；
/// - 停止后端口立即释放。
///
/// 它不是一个通用文件服务器：没有目录浏览、没有下载、没有删除。
class LanUploadServer {
  LanUploadServer();

  /// 单文件上限：600MB（够放绝大多数 PDF，又不至于把手机写满）
  static const int maxFileBytes = 600 * 1024 * 1024;

  /// 允许的扩展名（与文档库一致）
  static const Set<String> allowedExtensions = <String>{'pdf', 'epub', 'txt'};

  HttpServer? _server;

  /// 每个落盘文件都会回调这个（参数为已落盘的临时文件与原始文件名）
  void Function(File file, String name)? onFile;

  /// 出错时回调（用于界面提示）
  void Function(String message)? onError;

  bool get isRunning => _server != null;

  int get port => _server?.port ?? 0;

  /// 访问地址（`http://<局域网IP>:<端口>`）；未启动或拿不到 IP 时返回空串
  Future<String> url() async {
    final HttpServer? server = _server;
    if (server == null) return '';
    final String ip = await _lanIpv4();
    if (ip.isEmpty) return '';
    return 'http://$ip:${server.port}';
  }

  /// 启动服务；[preferredPort] 被占用会自动往后找（最多试 20 个）
  Future<void> start({int preferredPort = 8080}) async {
    if (_server != null) return;
    Object? lastError;
    for (int i = 0; i < 20; i++) {
      final int port = preferredPort + i;
      try {
        final HttpServer server = await HttpServer.bind(
          InternetAddress.anyIPv4,
          port,
          shared: false,
        );
        _server = server;
        _server!.listen(_handle, onError: (Object e) {
          onError?.call('服务异常：$e');
        });
        return;
      } catch (e) {
        lastError = e;
        // 端口被占 → 换下一个；其它错误直接抛
        final String msg = e.toString();
        if (!msg.contains('address already in use') && !msg.contains('errno = 98')) {
          throw LanUploadException('无法启动传书服务：$e');
        }
      }
    }
    throw LanUploadException('端口 8080~8099 都被占用：$lastError');
  }

  Future<void> stop() async {
    final HttpServer? server = _server;
    _server = null;
    if (server == null) return;
    try {
      await server.close(force: true);
    } catch (_) {
      // 关闭失败不影响下次启动
    }
  }

  // ---------------- 请求处理 ----------------

  Future<void> _handle(HttpRequest request) async {
    try {
      final String path = request.uri.path;
      if (request.method == 'GET' && (path == '/' || path == '/index.html')) {
        await _servePage(request);
        return;
      }
      if (request.method == 'POST' && path == '/upload') {
        await _receiveFile(request);
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (e) {
      onError?.call('处理请求失败：$e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _servePage(HttpRequest request) async {
    request.response.headers.contentType =
        ContentType('text', 'html', charset: 'utf-8');
    request.response.write(_pageHtml);
    await request.response.close();
  }

  /// 收文件：请求体就是文件字节，文件名走 `?name=`
  Future<void> _receiveFile(HttpRequest request) async {
    final String rawName = request.uri.queryParameters['name'] ?? '';
    final String name = sanitizeName(rawName);
    if (name.isEmpty) {
      await _reply(request, HttpStatus.badRequest, '文件名无效');
      return;
    }
    final String ext = _extensionOf(name);
    if (!allowedExtensions.contains(ext)) {
      await _reply(request, HttpStatus.unsupportedMediaType,
          '不支持的文件类型：.$ext（只收 pdf / epub / txt）');
      return;
    }

    final Directory dir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}lan_upload',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final File out = File('${dir.path}${Platform.pathSeparator}$name');

    int total = 0;
    // 故意用非空局部变量：`IOSink?` 在 await 之间的类型提升会被打断
    // （Dart 不会跨 await 保持可空变量的提升），写成可空反而全是 null 检查噪音
    final IOSink sink = out.openWrite();
    bool sinkClosed = false;
    Future<void> closeSink() async {
      if (sinkClosed) return;
      sinkClosed = true;
      try {
        await sink.close();
      } catch (_) {}
    }

    try {
      await for (final List<int> chunk in request) {
        total += chunk.length;
        if (total > maxFileBytes) {
          await closeSink();
          if (out.existsSync()) out.deleteSync();
          await _reply(request, HttpStatus.requestEntityTooLarge,
              '文件超过 ${maxFileBytes ~/ (1024 * 1024)}MB');
          return;
        }
        sink.add(chunk);
      }
      await closeSink();
    } catch (e) {
      await closeSink();
      if (out.existsSync()) {
        try {
          out.deleteSync();
        } catch (_) {}
      }
      await _reply(request, HttpStatus.internalServerError, '写入失败：$e');
      return;
    }

    if (total == 0) {
      if (out.existsSync()) out.deleteSync();
      await _reply(request, HttpStatus.badRequest, '收到空文件');
      return;
    }
    onFile?.call(out, name);
    await _reply(request, HttpStatus.ok, '已收到 $name（${_humanBytes(total)}）');
  }

  Future<void> _reply(HttpRequest request, int code, String message) async {
    request.response.statusCode = code;
    request.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.response.write(jsonEncode(<String, Object>{
      'ok': code == HttpStatus.ok,
      'message': message,
    }));
    await request.response.close();
  }

  // ---------------- 工具 ----------------

  /// 文件名净化：去路径分隔符、去 `..`、去控制字符，保留扩展名
  ///
  /// 为什么必须做：文件名来自 HTTP 查询参数，直接拼路径就是目录穿越
  /// （`../../databases/x.db` 这种）。这里只留最后一段并剔除危险字符。
  static String sanitizeName(String raw) {
    String name = raw.replaceAll('\\', '/');
    final int slash = name.lastIndexOf('/');
    if (slash >= 0) name = name.substring(slash + 1);
    name = name.replaceAll('..', '');
    name = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
    name = name.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
    name = name.trim();
    // 全是点的名字（`.` / `...`）没有意义
    if (name.replaceAll('.', '').isEmpty) return '';
    return name;
  }

  static String _extensionOf(String name) {
    final int dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  static String _humanBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  /// 取本机局域网 IPv4（优先 192.168 / 10. / 172.16-31）
  static Future<String> _lanIpv4() async {
    try {
      final List<NetworkInterface> ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      String fallback = '';
      for (final NetworkInterface iface in ifaces) {
        for (final InternetAddress addr in iface.addresses) {
          final String ip = addr.address;
          if (ip.startsWith('192.168.')) return ip;
          if (ip.startsWith('10.')) return ip;
          if (RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip)) return ip;
          if (fallback.isEmpty) fallback = ip;
        }
      }
      return fallback;
    } catch (e) {
      debugPrint('取局域网 IP 失败：$e');
      return '';
    }
  }

  /// 上传页（自包含：内联 CSS/JS，不引用任何外部资源）
  static const String _pageHtml = '''
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>传书到 桃花源阅读器</title>
<style>
  :root { color-scheme: light dark; }
  body { margin:0; font:15px/1.6 system-ui,-apple-system,"Segoe UI",sans-serif;
         background:#f4f2f8; color:#1c1b1f; }
  main { max-width:640px; margin:0 auto; padding:28px 20px 48px; }
  h1 { font-size:20px; margin:0 0 6px; }
  p.sub { margin:0 0 20px; color:#5a5760; font-size:13px; }
  #drop { border:2px dashed #b9b3c7; border-radius:16px; padding:40px 16px;
          text-align:center; background:#fbfaff; transition:.15s; cursor:pointer; }
  #drop.hot { border-color:#6750a4; background:#efe7ff; }
  #drop b { color:#6750a4; }
  ul { list-style:none; padding:0; margin:18px 0 0; }
  li { display:flex; gap:10px; align-items:flex-start; padding:10px 12px;
       background:#fbfaff; border-radius:12px; margin-bottom:8px; font-size:13px; }
  .st { font-weight:600; white-space:nowrap; }
  .ok { color:#1b6e3c; } .err { color:#b3261e; } .run { color:#6750a4; }
  .name { word-break:break-all; }
  footer { margin-top:26px; color:#5a5760; font-size:12px; }
</style>
</head>
<body>
<main>
  <h1>传书到 桃花源阅读器</h1>
  <p class="sub">支持 PDF / EPUB / TXT。选好或拖进来即开始上传，传完会自动进手机文档库。</p>
  <div id="drop">把文件拖到这里，或 <b>点一下选择文件</b></div>
  <ul id="list"></ul>
  <footer>传完记得在手机上点「停止接收」关掉服务。</footer>
</main>
<script>
const drop = document.getElementById('drop');
const list = document.getElementById('list');
const input = Object.assign(document.createElement('input'),
  { type:'file', multiple:true, accept:'.pdf,.epub,.txt' });
drop.onclick = () => input.click();
input.onchange = () => { send([...input.files]); input.value = ''; };
['dragenter','dragover'].forEach(e => drop.addEventListener(e, ev => {
  ev.preventDefault(); drop.classList.add('hot'); }));
['dragleave','drop'].forEach(e => drop.addEventListener(e, ev => {
  ev.preventDefault(); drop.classList.remove('hot'); }));
drop.addEventListener('drop', ev => send([...ev.dataTransfer.files]));

function row(name) {
  const li = document.createElement('li');
  const st = document.createElement('span');
  st.className = 'st run'; st.textContent = '上传中';
  const nm = document.createElement('span');
  nm.className = 'name'; nm.textContent = name;
  li.append(st, nm); list.prepend(li); return { li, st };
}

async function send(files) {
  for (const f of files) {
    const { st } = row(f.name);
    try {
      const res = await fetch('/upload?name=' + encodeURIComponent(f.name),
        { method:'POST', body:f });
      const data = await res.json().catch(() => ({ ok:false, message:'响应异常' }));
      st.textContent = data.ok ? '完成' : '失败';
      st.className = 'st ' + (data.ok ? 'ok' : 'err');
      if (!data.ok) st.title = data.message || '';
    } catch (e) {
      st.textContent = '失败';
      st.className = 'st err';
      st.title = String(e);
    }
  }
}
</script>
</body>
</html>
''';
}

/// 传书服务相关的可预期错误
class LanUploadException implements Exception {
  LanUploadException(this.message);

  final String message;

  @override
  String toString() => message;
}

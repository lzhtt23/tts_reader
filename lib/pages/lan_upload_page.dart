import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/document.dart';
import '../services/crash_log.dart';
import '../services/lan_upload_server.dart';
import '../services/library_import.dart';

/// 局域网传书（v1.22.70）
///
/// 电脑浏览器打开页面 → 拖文件 → 自动进文档库。见 [LanUploadServer] 的说明。
///
/// 界面只做三件事：显示地址（可复制）、列出收到的文件与结果、随时停止服务。
class LanUploadPage extends StatefulWidget {
  const LanUploadPage({super.key});

  @override
  State<LanUploadPage> createState() => _LanUploadPageState();
}

/// 一条收到记录
class _Received {
  _Received(this.name);

  final String name;
  String status = '处理中…';
  bool ok = false;
}

class _LanUploadPageState extends State<LanUploadPage> {
  final LanUploadServer _server = LanUploadServer();
  final List<_Received> _items = <_Received>[];
  String _url = '';
  String? _error;
  bool _starting = true;
  int _imported = 0;

  @override
  void initState() {
    super.initState();
    _server
      ..onFile = _onFile
      ..onError = (String message) {
        CrashLog.mark('局域网传书[服务] $message');
        if (!mounted) return;
        setState(() => _error = message);
      };
    unawaited(_start());
  }

  @override
  void dispose() {
    unawaited(_server.stop());
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      await _server.start();
      final String url = await _server.url();
      if (!mounted) return;
      setState(() {
        _url = url;
        _starting = false;
        _error = url.isEmpty ? '没取到局域网 IP，请确认手机连着 WiFi' : null;
      });
      CrashLog.mark('局域网传书[启动] port=${_server.port} url=$url');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = e.toString();
      });
    }
  }

  /// 收到文件：先落一条「处理中」，入库后改状态
  Future<void> _onFile(File file, String name) async {
    final _Received row = _Received(name);
    if (mounted) setState(() => _items.insert(0, row));
    try {
      final Document doc = await LibraryImport.importPath(file.path, name: name);
      _imported++;
      CrashLog.mark('局域网传书[入库] ${doc.id}/${doc.title}');
      if (!mounted) return;
      setState(() {
        row.ok = true;
        row.status = '已入库';
      });
    } catch (e) {
      CrashLog.mark('局域网传书[入库失败] $name → $e');
      if (!mounted) return;
      setState(() {
        row.ok = false;
        row.status = '入库失败：$e';
      });
    }
  }

  Future<void> _stopAndClose() async {
    await _server.stop();
    if (!mounted) return;
    Navigator.of(context).pop(_imported);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        unawaited(_stopAndClose());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('局域网传书'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: '停止并返回',
            onPressed: () => unawaited(_stopAndClose()),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: <Widget>[
            if (_starting)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_url.isNotEmpty)
              _addressCard(scheme)
            else
              _errorCard(),
            const SizedBox(height: 12),
            _howtoCard(scheme),
            if (_items.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              Text('收到的文件', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              for (final _Received r in _items) _itemTile(r, scheme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _addressCard(ColorScheme scheme) {
    return Card.filled(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.wifi_tethering, color: scheme.primary),
                const SizedBox(width: 8),
                Text('在电脑浏览器打开', style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 10),
            // 地址要能长按复制：这是这个页面最重要的一个字符串
            SelectableText(
              _url,
              style: TextStyle(
                fontSize: 20,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '手机和电脑必须在同一个 WiFi 下。关掉这个页面服务就停了。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _url));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('地址已复制')),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('复制地址'),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: () => unawaited(_stopAndClose()),
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  label: const Text('停止接收'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorCard() {
    return Card.filled(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
                const SizedBox(width: 8),
                const Text('服务没能启动'),
              ],
            ),
            const SizedBox(height: 8),
            Text(_error ?? '未知原因',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            OutlinedButton(onPressed: () => unawaited(_start()), child: const Text('重试')),
          ],
        ),
      ),
    );
  }

  Widget _howtoCard(ColorScheme scheme) {
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('怎么用', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              '1. 电脑连同一个 WiFi\n'
              '2. 浏览器打开上面的地址\n'
              '3. 把 PDF / EPUB / TXT 拖进去（可多选）\n'
              '4. 传完自动进手机文档库，回上一页就能看到',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              '只接收局域网内电脑发来的文件；传完点「停止接收」关掉服务。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _itemTile(_Received r, ColorScheme scheme) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        r.ok ? Icons.check_circle_outline : Icons.error_outline,
        color: r.ok ? scheme.primary : scheme.error,
      ),
      title: Text(r.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(r.status),
    );
  }
}

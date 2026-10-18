import 'package:flutter/material.dart';

import '../models/source_rule.dart';
import '../models/structured_document.dart';
import '../services/legado_source_store.dart';
import '../services/source_client.dart';
import '../tts/tts_manager.dart';

/// 在线书阅读页：拉目录 → 按需取正文 → 交给 TtsManager 朗读
///
/// ## 设计取向：**不碰借声**
///
/// 在线阅读最"正统"的做法是像 PDF 那样借 `TtsManager` 发声（按章懒加载）。
/// 但 `docs/v1.21.65-交接.md` 记着借声那条线刚稳定，且「引擎 stop 卡住」
/// 还没修。这里改用更笨但安全的办法：
///
/// **一次只把「当前章 + 后面若干章」装进 StructuredDocument**，
/// 走正常的 `loadDocument`。翻过这个窗口就重新装一次。
///
/// 代价是不会预读太远；好处是**完全走既有朗读路径**，
/// 不引入新的换源语义，也不动音频焦点。
class LegadoReadPage extends StatefulWidget {
  const LegadoReadPage({
    super.key,
    required this.source,
    required this.book,
    this.initialChapter = 0,
  });

  final SourceRule source;
  final OnlineBook book;

  /// 从第几章开始（书架续读）
  final int initialChapter;

  /// 一次装载的章数（窗口大小）
  static const int windowSize = 20;

  @override
  State<LegadoReadPage> createState() => _LegadoReadPageState();
}

class _LegadoReadPageState extends State<LegadoReadPage> {
  late final SourceClient _client = SourceClient(rule: widget.source);

  List<OnlineChapter> _chapters = const <OnlineChapter>[];
  StructuredDocument? _document;

  bool _loadingToc = true;
  bool _loadingContent = false;
  String? _error;
  int _windowStart = 0;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _loadToc();
  }

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }

  Future<void> _loadToc() async {
    setState(() {
      _loadingToc = true;
      _error = null;
    });
    try {
      final List<OnlineChapter> toc = await _client.toc(widget.book.url);
      if (!mounted) return;
      setState(() {
        _chapters = toc;
        _loadingToc = false;
      });
      if (toc.isEmpty) {
        setState(() => _error = '没取到目录（书源规则可能已失效）');
        return;
      }
      await _loadWindow(widget.initialChapter);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingToc = false;
        _error = e.toString();
      });
    }
  }

  /// 装载一窗章节（从 [start] 开始，向后 [windowSize] 章）
  Future<void> _loadWindow(int start) async {
    if (_chapters.isEmpty) return;

    final int safeStart = start.clamp(0, _chapters.length - 1);
    final int end = (safeStart + LegadoReadPage.windowSize) > _chapters.length
        ? _chapters.length
        : safeStart + LegadoReadPage.windowSize;
    final List<OnlineChapter> window = _chapters.sublist(safeStart, end);

    setState(() {
      _loadingContent = true;
      _windowStart = safeStart;
      _status = '正在取正文 0/${window.length}';
    });

    try {
      final StructuredDocument doc = await _client.toDocument(
        window,
        chapterLoader: (OnlineChapter c) => _client.content(c.url),
        onProgress: (int done, int total) {
          if (!mounted) return;
          setState(() => _status = '正在取正文 $done/$total');
        },
      );
      if (!mounted) return;
      setState(() {
        _document = doc;
        _loadingContent = false;
        _status = '';
      });
      TtsManager.instance.loadDocument(
        doc,
        title: widget.book.name,
        documentId: widget.book.url,
      );
      // ⚠️ 不自动加入书架：在线阅读 ≠ 收藏。
      // 只对**已经在书架里**的那本更新进度；不在就不写。
      await LegadoSourceStore.instance.updateBookProgress(
        url: widget.book.url,
        chapterIndex: safeStart,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingContent = false;
        _status = '';
        _error = '取正文失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          if (_chapters.isNotEmpty)
            IconButton(
              tooltip: '目录',
              icon: const Icon(Icons.list),
              onPressed: _showToc,
            ),
          IconButton(
            tooltip: '刷新目录',
            icon: const Icon(Icons.refresh),
            onPressed: _loadingToc ? null : _loadToc,
          ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loadingToc) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline, color: theme.colorScheme.error, size: 40),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _loadToc, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    if (_loadingContent) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(_status, style: theme.textTheme.bodySmall),
          ],
        ),
      );
    }

    final StructuredDocument? doc = _document;
    if (doc == null || doc.isEmpty) {
      return Center(child: Text('没有内容', style: theme.textTheme.bodyMedium));
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        Card.filled(
          margin: const EdgeInsets.only(bottom: 16),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(widget.book.name, style: theme.textTheme.titleMedium),
                if (widget.book.author.isNotEmpty)
                  Text(
                    widget.book.author,
                    style: theme.textTheme.bodySmall,
                  ),
                const SizedBox(height: 8),
                Text(
                  '第 ${_windowStart + 1}–${_windowStart + doc.chapters.length} 章 / '
                  '共 ${_chapters.length} 章',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: () => _playFrom(0),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('从本窗开头朗读'),
                    ),
                    OutlinedButton(
                      onPressed: _windowStart > 0
                          ? () => _loadWindow(_windowStart - 1)
                          : null,
                      child: const Text('上一批'),
                    ),
                    OutlinedButton(
                      onPressed: _windowStart + doc.chapters.length < _chapters.length
                          ? () => _loadWindow(_windowStart + doc.chapters.length)
                          : null,
                      child: const Text('下一批'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        for (var i = 0; i < doc.chapters.length; i++) ...<Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Text(
              doc.chapters[i].title,
              style: theme.textTheme.titleSmall,
            ),
          ),
          for (final Paragraph p in doc.chapters[i].paragraphs)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(p.text, style: theme.textTheme.bodyMedium),
            ),
        ],
      ],
    );
  }

  void _playFrom(int chapterIndex) {
    final StructuredDocument? doc = _document;
    if (doc == null || doc.isEmpty) return;
    // `loadDocument` 之后用 `speakFrom` 起读：
    // `loadDocument` 只负责换文档与游标，不自动开口
    // （对齐 ReaderPage 的调用方式）。
    TtsManager.instance.loadDocument(
      doc,
      at: (chapterIndex, 0, 0),
      title: widget.book.name,
      documentId: widget.book.url,
    );
    TtsManager.instance.speakFrom(chapterIndex, 0, 0);
  }

  void _showToc() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (BuildContext ctx, ScrollController controller) => ListView.builder(
          controller: controller,
          itemCount: _chapters.length,
          itemBuilder: (BuildContext ctx, int i) {
            final OnlineChapter c = _chapters[i];
            final bool inWindow =
                i >= _windowStart && i < _windowStart + (_document?.chapters.length ?? 0);
            return ListTile(
              dense: true,
              leading: Text('${i + 1}'),
              title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: inWindow
                  ? Icon(
                      Icons.play_circle_outline,
                      color: Theme.of(ctx).colorScheme.primary,
                    )
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                // 章节不在当前窗口 → 重新装一窗
                if (inWindow) {
                  _playFrom(i - _windowStart);
                } else {
                  _loadWindow(i);
                }
              },
            );
          },
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Size, PixelFormat;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:epubx/epubx.dart' as epub;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
// pdfrx：PDF 首页渲染成封面用（v1.21.17 第 4 件）。
// ⚠️ 必须带前缀：它也有 `PdfDocument`，会与下面 Syncfusion 的那个撞名。
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:syncfusion_flutter_pdf/pdf.dart'
    show PdfDocument, PdfTextExtractor;
import 'package:xml/xml.dart' as xml;

import '../models/document.dart';
import '../models/pdf_line_box.dart';
import '../models/structured_document.dart';
import 'crash_log.dart';
import 'cover_renderer.dart';
import 'document_cache.dart';
import 'epub_toc.dart';
import 'file_naming.dart';
import 'pdf_outline.dart';
import 'txt_chapters.dart';
import 'txt_decoder.dart';

/// 一次「并行抽取文字行」的任务参数
///
/// 必须放在顶层：`compute` 的入参要能跨 isolate 传递，不能是闭包。
class _PdfLineRequest {
  const _PdfLineRequest({
    required this.bytes,
    required this.start,
    required this.end,
  });

  final Uint8List bytes;
  final int start;
  final int end;
}

/// 并行抽取的一批结果
class _PdfLineChunk {
  const _PdfLineChunk({required this.lines, required this.pageCount});

  /// 页号（0 起）→ 该页的文字行
  final Map<int, List<PdfLineBox>> lines;

  /// 这一批包含多少页（用于进度上报）
  final int pageCount;
}

/// 在独立 isolate 里抽取 [start]..[end] 页的文字行
///
/// 顶层函数：`compute` 要求可跨 isolate 调用。
_PdfLineChunk _extractPdfLinesChunk(_PdfLineRequest request) {
  final lines = <int, List<PdfLineBox>>{};
  PdfDocument? document;
  try {
    document = PdfDocument(inputBytes: request.bytes);
    final extractor = PdfTextExtractor(document);
    for (var page = request.start; page <= request.end; page++) {
      try {
        final extracted = extractor.extractTextLines(
          startPageIndex: page,
          endPageIndex: page,
        );
        final boxes = <PdfLineBox>[];
        for (final line in extracted) {
          final text = line.text.trim();
          if (text.isEmpty) continue;
          boxes.add(PdfLineBox(text: text, bounds: line.bounds));
        }
        if (boxes.isNotEmpty) lines[page] = boxes;
      } catch (_) {
        // 单页失败不影响整批
      }
    }
  } catch (_) {
    // 打开失败：这一批返回空
  } finally {
    document?.dispose();
  }
  return _PdfLineChunk(
    lines: lines,
    pageCount: request.end - request.start + 1,
  );
}

/// 解析进度：0.0 ~ 1.0 与阶段文案
class ParseProgress {  const ParseProgress(this.value, this.stage);

  final double value;
  final String stage;

  /// 0 ~ 100 的整数百分比
  int get percent => (value * 100).clamp(0, 100).toInt();
}

/// 解析被调用方取消
class ParseCancelledException implements Exception {
  const ParseCancelledException();

  @override
  String toString() => '解析已取消';
}

/// 可取消的解析任务：解析在独立 isolate 中执行，主线程不会卡顿
///
/// 命中磁盘缓存时不会有 isolate（[isolateFuture] 为空），此时 [cancel] 只是
/// 让等待方收到取消异常。
class DocumentParseTask {
  DocumentParseTask._(
    this._receivePort,
    this._completer, {
    this.coverOutPath,
    this.document,
    this.cachePath,
  }) : result = _completer.future;

  /// 缓存命中：直接完成，不起 isolate
  factory DocumentParseTask.cached(ParseResult value, String cachePath) {
    final completer = Completer<ParseResult>()..complete(value);
    return DocumentParseTask._(null, completer, cachePath: cachePath);
  }

  /// 异步完成（**不阻塞主线程**）：用于「在 isolate 里读解析缓存」
  ///
  /// ★v1.22.23（低性能设备优化）：原来缓存是**在主线程同步读**的 ——
  /// 一本 60 万字的书，JSON 解码 + 重建章节在低端平板上能卡住好几百毫秒，
  /// 表现就是「点书之后界面一动不动」。放到 isolate 里读，UI 不再掉帧。
  factory DocumentParseTask.deferred(
    Future<ParseResult> future,
    String cachePath,
  ) {
    final completer = Completer<ParseResult>();
    future.then<void>(
      completer.complete,
      onError: (Object error, StackTrace stack) =>
          completer.completeError(error, stack),
    );
    return DocumentParseTask._(null, completer, cachePath: cachePath);
  }

  final ReceivePort? _receivePort;
  final Completer<ParseResult> _completer;

  /// 解析结果（含封面路径 / 文本层信息）
  final Future<ParseResult> result;

  /// 本次解析对应的文档与封面输出路径（缓存命中时用来补封面 / 落盘）
  final Document? document;
  final String? coverOutPath;

  /// 磁盘缓存路径（为空表示不启用缓存）
  final String? cachePath;

  Isolate? _isolate;
  Future<Isolate>? isolateFuture;
  StreamSubscription<dynamic>? subscription;

  bool _cancelled = false;
  bool _settled = false;

  /// 本次结果是否来自缓存（用于跳过重复落盘）
  bool get fromCache => _completer.isCompleted && _receivePort == null;

  /// 用户中途退出时调用：立即终止 isolate，并让等待方收到取消异常
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    unawaited(subscription?.cancel());
    _receivePort?.close();
    // isolate 可能还在启动过程中：等它起来后立刻杀掉，避免白跑一次完整解析
    unawaited(
      (isolateFuture ?? Future<Isolate?>.value(_isolate))
          .then((isolate) => isolate?.kill(priority: Isolate.immediate))
          .catchError((Object _) {}),
    );
    if (!_completer.isCompleted) _completer.completeError(const ParseCancelledException());
  }

  /// 解析成功后把结果写入缓存（只在真解析过、且任务未被取消时执行）
  void _cacheIfNeeded(ParseResult value) {
    if (_cancelled || _settled) return;
    _settled = true;
    final path = cachePath;
    final doc = document;
    if (path == null || doc == null || value.fromCache) return;
    if (value.document.isEmpty) return;
    DocumentService.writeCache(path, doc, value);
  }
}

/// 解析产物：结构化文档 + 封面 + 文本层检测结果
class ParseResult {
  const ParseResult(
    this.document, {
    this.coverPath,
    this.hasTextLayer = true,
    this.pageCount = 0,
    this.textCharCount = 0,
    this.fileSize = 0,
    this.pdfLines,
    this.encoding,
    this.fromCache = false,
    this.pageSize,
    this.linesChunks,
  });

  final StructuredDocument document;
  final String? coverPath;

  /// 是否抽到可朗读的文本层（PDF 为 false 说明是扫描件）
  final bool hasTextLayer;

  /// PDF 页数（其它类型为章节数）
  final int pageCount;

  /// 抽到的正文字符数
  final int textCharCount;

  /// 源文件字节数（isolate 解析时顺手量取，供界面决定渲染策略）
  final int fileSize;

  /// TXT 实际使用的编码名（UTF-8 / GBK / Big5 …）；其它类型为空
  final String? encoding;

  /// 本次结果是否直接来自磁盘缓存（没有重新解析）
  final bool fromCache;

  /// PDF 页面尺寸（PDF 点为单位）；非 PDF 或没抽到行信息时为空
  ///
  /// 由文字行外框推算（取所有行右下角的最大值），不额外解析一遍 PDF。
  /// 阅读页拿它算「平板按屏幕放大多少倍」与「朗读高亮框在屏幕上的位置」。
  final Size? pageSize;

  /// PDF 每页的文字行位置：页下标（0 开始）→ 该页的文字行
  ///
  /// 只有 PDF 才有；过大（行数超上限）时为 null，此时原版式下点句即读不可用。
  ///
  /// ⚠️ v1.21.35 / L2b-2 起：**命中缓存时它恒为 null**（主缓存不再存整份行表），
  /// 阅读页要靠 [linesChunks] + 缓存目录按块读；只有真解析（`fromCache == false`）
  /// 才会带出整份行表。
  final Map<int, List<PdfLineBox>>? pdfLines;

  /// 行表分块索引（v1.21.35 / L2b-2 起是阅读页的**读取地图**）
  ///
  /// 命中缓存时由主缓存给出；真解析时由这里用 `DocumentCache.chunksOf` 现算。
  /// 它同时也是"这份文档有没有行表"的判据（空 = 没有行表）。
  final List<LinesChunkRef>? linesChunks;
}

/// 文档解析：PDF / EPUB / TXT -> StructuredDocument
class DocumentService {
  DocumentService._();

  /// 解析器版本：**任何影响解析结果的改动都要 +1**
  ///
  /// 它写进缓存文件头，旧缓存会因版本不符被丢弃。
  /// 忘了改的后果是「升级后还在用老结构」——比如分章规则改了却看不出变化。
  ///
  /// ## ⚠️ v2 → v3（2026-10-14，分句规则重写）
  ///
  /// 这一轮把 `DocumentTextSplitter.splitSentences` 从"一个正则"换成逐字符扫描
  /// （不再把缩写 `H.` / 小数点 `3.14` / 句尾引号 / 省略号切成句），
  /// **句子总数变了**（实测那本 63 章的 epub：19949 → 15799 句）。
  ///
  /// **忘了涨这个版本的后果是真机事故**：新包读到的还是旧缓存（19949 句），
  /// 而朗读循环按新规则在文档里定位 → 两边对不上，表现为
  /// 「句子游标来回跳（2→5→4→6→0→1→0）、朗读反复重启、最后卡住」。
  /// 现场日志 `index=926/19949` 里的 `19949` 就是这个旧缓存留下的证据。
  static const int parseRevision = 3;

  /// 分句 / 分段规则统一放在 [DocumentTextSplitter]，这里只保留块级标签等解析用常量
  /// 块级标签（转换纯文本时补换行）
  static const Set<String> _blockTags = {
    'p', 'div', 'li', 'ul', 'ol', 'tr', 'td', 'th', 'table', 'section',
    'article', 'header', 'footer', 'blockquote', 'pre', 'h1', 'h2', 'h3',
    'h4', 'h5', 'h6', 'hr', 'figure', 'figcaption', 'dd', 'dt', 'dl',
  };

  /// 单个朗读片段的最大长度（系统 TTS 单次输入有限，避免超长文本被截断）
  static const int maxChunkLength = 240;

  /// 文本层判定：至少这么多字符，且至少 20% 的页有文字
  static const int _minTextChars = 20;

  /// 最多保留多少条 PDF 文字行位置
  ///
  /// 一本书动辄几万行，全留着白占内存；超过上限后原版式的「点哪行读哪句」失效，
  /// 但朗读本身不受影响（文本模式照常逐句高亮）。
  static const int _maxPdfLines = 40000;

  /// 解析入口（等待结果，不提供取消）
  static Future<ParseResult> parse(
    Document document, {
    void Function(ParseProgress)? onProgress,
    String? cacheDir,
  }) async {
    final task = parseAsync(document, onProgress: onProgress, cacheDir: cacheDir);
    try {
      return await task.result;
    } catch (_) {
      task.cancel();
      rethrow;
    }
  }

  /// 在独立 isolate 中解析；[coverOutPath] 非空时会尝试写出封面
  ///
  /// [cacheDir] 非空时启用解析结果缓存：命中缓存则**不创建 isolate**，直接
  /// `Future.value` 返回，大文件第二次打开是毫秒级。
  static DocumentParseTask parseAsync(
    Document document, {
    void Function(ParseProgress)? onProgress,
    String? coverOutPath,
    String? cacheDir,
  }) {
    final cachePath = cacheDir == null || cacheDir.isEmpty
        ? null
        : '$cacheDir${Platform.pathSeparator}${DocumentCache.fileNameFor(document.id)}';
    if (cachePath != null) {
      // ★v1.22.23：先做一次**极轻**的存在性检查（一次 stat），
      // 命中则把「读 + 解码」整个扔进 isolate，主线程不卡；
      // 未命中照旧起解析 isolate（那本来就是 isolate 里跑的）。
      bool exists = false;
      try {
        exists = File(cachePath).existsSync();
      } catch (_) {
        exists = false;
      }
      if (exists) {
        return DocumentParseTask.deferred(
          _readCachedAsync(
            document,
            cachePath,
            onProgress: onProgress,
            coverOutPath: coverOutPath,
          ),
          cachePath,
        );
      }
    }
    return _spawnParse(
      document,
      onProgress: onProgress,
      coverOutPath: coverOutPath,
      cachePath: cachePath,
    );
  }

  /// 在 isolate 里读缓存；缓存不可用（版本不符 / 损坏 / 空）时退回真解析
  static Future<ParseResult> _readCachedAsync(
    Document document,
    String cachePath, {
    void Function(ParseProgress)? onProgress,
    String? coverOutPath,
  }) async {
    ParseResult? cached;
    try {
      // 闭包只捕获可跨 isolate 的值（Document 本来就要进解析 isolate）
      cached = await Isolate.run(() => _readCache(document, cachePath, null));
    } catch (_) {
      cached = null;
    }
    if (cached != null) {
      onProgress?.call(const ParseProgress(1, '读取缓存'));
      return cached;
    }
    // 缓存文件在、但内容不可用：退回正常解析（不阻塞，仍在 isolate 里）
    final ParseResult parsed =
        await _spawnParse(document, coverOutPath: coverOutPath, cachePath: cachePath)
            .result;
    return parsed;
  }

  /// 尝试读缓存；未命中返回 null（调用方照常起 isolate 真解析）
  static ParseResult? _readCache(
    Document document,
    String cachePath,
    void Function(ParseProgress)? onProgress,
  ) {
    try {
      final snapshot = DocumentCache.read(cachePath, DocumentCache.identityOf(document));
      if (snapshot == null) return null;
      if (snapshot.textRevision != parseRevision) return null;
      if (snapshot.document.isEmpty) return null;
      onProgress?.call(const ParseProgress(1, '读取缓存'));
      return ParseResult(
        snapshot.document,
        hasTextLayer: snapshot.hasTextLayer,
        pageCount: snapshot.pageCount,
        textCharCount: snapshot.textCharCount,
        fileSize: snapshot.fileSize,
        // v1.21.35 / L2b-2：主缓存不再存整份行表 → `snapshot.pdfLines` 恒为 null，
        // 行表由阅读页**按块读**（靠下面的分块索引 + 缓存目录）。
        pdfLines: snapshot.pdfLines,
        encoding: snapshot.encoding,
        fromCache: true,
        // ⚠️ 这两个字段以前漏传了：命中缓存时 `result.pageSize` 恒为 null →
        // 阅读页 `_pdfPageSize` 为空 → 点句 / 跳页的坐标换算全废（静默失效）。
        // pageSize 是"必需元数据"，别再从行表推（见交接文档 §⑦ 第 2 条）。
        pageSize: snapshot.pageSize,
        linesChunks: snapshot.linesChunks,
      );
    } catch (_) {
      return null;
    }
  }

  /// 把解析结果落盘；失败不影响调用方（缓存只是加速层）
  static void writeCache(String cachePath, Document document, ParseResult result) {
    try {
      DocumentCache.write(
        cachePath,
        DocumentCache.identityOf(document),
        ParsedSnapshot(
          document: result.document,
          hasTextLayer: result.hasTextLayer,
          pageCount: result.pageCount,
          textCharCount: result.textCharCount,
          fileSize: result.fileSize,
          encoding: result.encoding,
          pdfLines: result.pdfLines,
          textRevision: parseRevision,
          pageSize: result.pageSize,
          // v1.21.35 / L2b-2：落在主缓存里的"读取地图"。真解析时现算一份，
          // 命中缓存时（根本不会走到这里）由 _decodePayload 读回。
          linesChunks: result.linesChunks ??
              DocumentCache.chunksOf(result.pdfLines),
        ),
      );
      // v1.21.33 / L2a：**行表另外按 50 页一块落盘**（`.ttsl`）。
      //
      // 为什么：主缓存里那份行表是**整份**的，812 页读回时要全量进内存；
      // 分块之后，阅读页将来只读"当前页所在块"（L2b 接读路径）。
      // 这里是**纯增量**：写失败/缺块都不影响主缓存与本次解析结果。
      if (result.pdfLines != null && result.pdfLines!.isNotEmpty) {
        DocumentCache.writeLineChunks(
          _dirOf(cachePath),
          document.id,
          result.pdfLines,
        );
      }
    } catch (_) {
      // 忽略
    }
  }

  static DocumentParseTask _spawnParse(
    Document document, {
    void Function(ParseProgress)? onProgress,
    String? coverOutPath,
    String? cachePath,
  }) {
    final receivePort = ReceivePort();
    final completer = Completer<ParseResult>();
    final task = DocumentParseTask._(
      receivePort,
      completer,
      coverOutPath: coverOutPath,
      document: document,
      cachePath: cachePath,
    );

    task.subscription = receivePort.listen((dynamic message) {
      if (message is Map) {
        if (message['p'] != null) {
          onProgress?.call(ParseProgress((message['p'] as num).toDouble(), '${message['s'] ?? ''}'));
          return;
        }
        if (message['error'] != null) {
          if (!completer.isCompleted) completer.completeError(Exception('${message['error']}'));
          receivePort.close();
          return;
        }
        final payload = message['doc'];
        if (payload is StructuredDocument && !completer.isCompleted) {
          final Map<int, List<PdfLineBox>>? lines = _asLineMap(message['lines']);
          final result = ParseResult(
            payload,
            coverPath: message['cover'] as String?,
            hasTextLayer: message['text'] as bool? ?? true,
            pageCount: (message['pages'] as num?)?.toInt() ?? 0,
            textCharCount: (message['chars'] as num?)?.toInt() ?? 0,
            fileSize: (message['size'] as num?)?.toInt() ?? 0,
            pdfLines: lines,
            encoding: message['encoding'] as String?,
            pageSize: _asSize(message['pageW'], message['pageH']),
            // v1.21.35 / L2b-2：真解析也要带出"读取地图" —— 阅读页拿到结果后
            // 立刻只装当前页所在块，剩下的页等翻到再读盘。
            linesChunks: DocumentCache.chunksOf(lines),
          );
          completer.complete(result);
          // 落盘放在 complete 之后：写缓存不能拖慢「界面已经拿到结果」这件事
          task._cacheIfNeeded(result);
        }
        receivePort.close();
        return;
      }
      // onExit 的 null 通知，或 isolate 的未捕获错误 [error, stackTrace]
      if (!completer.isCompleted) {
        final reason = message is List && message.isNotEmpty ? '${message.first}' : '解析进程意外结束';
        completer.completeError(Exception(reason));
      }
      receivePort.close();
    });

    final isolateFuture = Isolate.spawn<List<Object?>>(
      _parseIsolateEntry,
      <Object?>[receivePort.sendPort, document.path, document.type.name, coverOutPath],
      onError: receivePort.sendPort,
      onExit: receivePort.sendPort,
      errorsAreFatal: true,
    );
    task.isolateFuture = isolateFuture;
    // 记下 isolate 句柄供 cancel() 兜底（启动失败时忽略：错误由下面的 catchError 处理）
    isolateFuture.then<void>((isolate) => task._isolate = isolate).ignore();
    isolateFuture.catchError((Object error) {
      if (!completer.isCompleted) completer.completeError(error);
      receivePort.close();
      return Future<Isolate>.error(error);
    });
    return task;
  }

  /// isolate 入口：只依赖纯 Dart，不能使用任何插件
  static Future<void> _parseIsolateEntry(List<Object?> args) async {
    final SendPort port = args[0]! as SendPort;
    final String path = args[1]! as String;
    final String typeName = args[2]! as String;
    final String? coverOutPath = args[3] as String?;

    var lastReported = -1.0;
    void report(double value, String stage) {
      final clamped = value < 0 ? 0.0 : (value > 1 ? 1.0 : value);
      if (clamped - lastReported < 0.01 && clamped < 1) return;
      lastReported = clamped;
      port.send(<String, Object>{'p': clamped, 's': stage});
    }

    try {
      var fileSize = 0;
      try {
        final file = File(path);
        if (await file.exists()) fileSize = await file.length();
      } catch (_) {
        fileSize = 0;
      }
      final result = switch (DocumentType.fromName(typeName)) {
        DocumentType.pdf => await _parsePdf(path, report),
        DocumentType.epub => await _parseEpub(path, report, coverOutPath),
        DocumentType.txt => await _parseTxt(path, report),
      };
      port.send(<String, Object?>{
        'doc': result.document,
        'cover': result.coverPath,
        'text': result.hasTextLayer,
        'pages': result.pageCount,
        'chars': result.textCharCount,
        'size': fileSize,
        'lines': result.pdfLines,
        'encoding': result.encoding,
        // 页面尺寸拆成两个数传：Map 里放自定义对象要额外过一遍类型检查
        'pageW': result.pageSize?.width,
        'pageH': result.pageSize?.height,
      });
    } catch (error) {
      port.send(<String, Object?>{'error': _describe(error)});
    }
  }

  /// PDF：逐页抽取文本层，一页一章（章号 == PDF 页号，供按页朗读与原版式翻页对齐）
  ///
  /// 同时把 PDF 自带的**书签（大纲）**读出来当目录：章名优先用书签标题
  /// （目录面板里也按层级显示），没有书签时退回「第 N 页」。
  /// 扫描件没有文本层时仍然一页一章 —— 章号与页号的对应关系不能破。
  ///
  /// 性能（v1.16 改）：**每页只抽一次文字**。
  /// 旧实现每页要调三次抽取（`extractText` 取正文 + `extractTextLines` 取行位置，
  /// 而 `extractTextLines` 内部又会为每页重复做一遍完整的字距/行合并计算），
  /// 一本 800 页的 PDF 等于白抽 1500 多页。现在正文与行位置都从同一次
  /// `extractTextLines` 的结果派生（正文 = 各行按行拼接），既省时间也保证
  /// 「页面上的行」与「正文里的句子」天然对齐。
  static Future<ParseResult> _parsePdf(String path, ProgressSink report) async {
    report(0.02, '读取文件');
    final bytes = await File(path).readAsBytes();
    report(0.08, '解析 PDF');
    final document = PdfDocument(inputBytes: bytes);
    final chapters = <Chapter>[];
    final lineMap = <int, List<PdfLineBox>>{};
    var lineCount = 0;
    var pagesWithText = 0;
    var textChars = 0;
    try {
      report(0.1, '读取 PDF 目录');
      final outline = PdfOutlineReader.read(document);
      final titlesByPage = PdfOutlineReader.titlesByPage(outline);
      final extractor = PdfTextExtractor(document);
      final count = document.pages.count;
      // 进度上报不必每页都发（接收端还有 1% 去抖），每 1% 左右发一次即可
      final step = count <= 100 ? 1 : (count / 100).ceil();

      // 先试**并行**抽取全部文字行（见 [_extractAllLinesParallel]）。
      // 文字抽取是解析里唯一的大头（319 页实测 4523/4557ms），
      // 而它与调用方式无关，只能靠多核。并行失败就退回下面的单线程逐页。
      report(0.12, '并行解析文字层');
      final parallel = await _extractAllLinesParallel(
        path,
        count,
        (done, total) =>
            report(0.12 + 0.80 * done / (total == 0 ? 1 : total), '解析第 $done/$total 页'),
      );

      for (var i = 0; i < count; i++) {
        // 一次抽取同时拿到「这一页的文字行」与「这一页的文字」
        List<PdfLineBox> lines;
        if (parallel != null) {
          lines = parallel[i] ?? const <PdfLineBox>[];
        } else {
          lines = _extractPdfLines(extractor, i);
        }
        final pageText = lines.isEmpty
            ? ''
            : lines.map((box) => box.text).join('\n').trim();
        if (pageText.isNotEmpty) {
          pagesWithText++;
          textChars += pageText.length;
        }
        // 空白页也保留为章，保证章号与 PDF 页号一一对应
        final title = titlesByPage[i];
        chapters.add(
          Chapter(
            title: title == null || title.isEmpty ? '第 ${i + 1} 页' : title,
            paragraphs: _splitParagraphs(pageText),
          ),
        );
        // 文字行位置：原版式下「点哪一行就从哪一句读」要用
        if (lines.isNotEmpty && lineCount < _maxPdfLines) {
          lineMap[i] = lines;
          lineCount += lines.length;
        }
        if (parallel == null && (i % step == 0 || i == count - 1)) {
          report(0.12 + 0.86 * (i + 1) / (count == 0 ? 1 : count), '解析第 ${i + 1}/$count 页');
        }
      }
      final hasTextLayer =
          textChars >= _minTextChars && pagesWithText * 5 >= (count == 0 ? 1 : count);
      // 页面尺寸由文字行外框推算：PDF 页面上的文字都落在页面内，
      // 取所有行的最大右下角就是页面尺寸（比再解析一遍 PDF 便宜得多）
      final pageSize = _inferPageSize(lineMap);
      report(1, hasTextLayer ? '完成' : '未检测到文本层');
      return ParseResult(
        StructuredDocument(chapters: chapters, chapterIsPage: true, outline: outline),
        hasTextLayer: hasTextLayer,
        pageCount: count,
        textCharCount: textChars,
        pdfLines: lineMap.isEmpty ? null : lineMap,
        pageSize: pageSize,
      );
    } finally {
      document.dispose();
    }
  }

  /// isolate 传回来的页面尺寸（两个数都得有效才算）
  static Size? _asSize(Object? width, Object? height) {
    if (width is! num || height is! num) return null;
    final w = width.toDouble();
    final h = height.toDouble();
    if (w <= 0 || h <= 0) return null;
    return Size(w, h);
  }

  /// 由文字行外框推算 PDF 页面尺寸
  ///
  /// 取所有行里最大的 `right` / `bottom`：文字都在页面内，所以这是一个**下界**，
  /// 但对「按屏幕放大多少倍」这种用途足够（顶多保守一点）。
  /// 页边距会带来一点低估，所以额外按经验补一点（PDF 正文页边距常见 5% 上下）。
  static Size? _inferPageSize(Map<int, List<PdfLineBox>> lineMap) {
    var maxRight = 0.0;
    var maxBottom = 0.0;
    for (final lines in lineMap.values) {
      for (final line in lines) {
        if (line.bounds.right > maxRight) maxRight = line.bounds.right;
        if (line.bounds.bottom > maxBottom) maxBottom = line.bounds.bottom;
      }
    }
    if (maxRight < 50 || maxBottom < 50) return null; // 数值明显不合理：不猜
    return Size(maxRight * 1.04, maxBottom * 1.04);
  }

  /// isolate 传回来的文字行表；结构不对就当作没有
  static Map<int, List<PdfLineBox>>? _asLineMap(Object? raw) {
    if (raw is! Map) return null;
    final result = <int, List<PdfLineBox>>{};
    raw.forEach((key, value) {
      if (key is int && value is List) {
        final lines = value.whereType<PdfLineBox>().toList();
        if (lines.isNotEmpty) result[key] = lines;
      }
    });
    return result.isEmpty ? null : result;
  }

  /// 抽取某一页的文字行与位置；失败按「这页没有行信息」处理（不影响朗读）
  static List<PdfLineBox> _extractPdfLines(PdfTextExtractor extractor, int pageIndex) {
    try {
      final pages = extractor.extractTextLines(startPageIndex: pageIndex, endPageIndex: pageIndex);
      final boxes = <PdfLineBox>[];
      for (final line in pages) {
        final text = line.text.trim();
        if (text.isEmpty) continue;
        boxes.add(PdfLineBox(text: text, bounds: line.bounds));
      }
      return boxes;
    } catch (_) {
      return const <PdfLineBox>[];
    }
  }

  /// 并行抽取整份 PDF 的**文字行**
  ///
  /// 背景：文字抽取是 PDF 解析里**唯一的大头** —— 实测《共产主义ABC》
  /// （319 页）解析 4557ms 里，抽取占 4523ms，分段只占 22ms。
  /// 而抽取本身与「调用方式」无关（逐页 4204ms、一次性 3860ms、分块 3744ms，
  /// 都是同一份真实工作量），所以只能靠**多核并行**。
  ///
  /// 做法：把页码切成 N 段（N = 核数，上限 4），每段在**独立 isolate** 里
  /// 各自打开一份 PDF 抽取。内存代价是 N 份 PDF 字节（几 MB × 4），
  /// 换来接近线性的加速。
  ///
  /// 失败（isolate 起不来 / 任何异常）返回 null，调用方退回单线程逐页抽取 ——
  /// 慢一点但一定能出结果。
  static Future<Map<int, List<PdfLineBox>>?> _extractAllLinesParallel(
    String path,
    int pageCount,
    void Function(int done, int total) onProgress,
  ) async {
    if (pageCount <= 0) return <int, List<PdfLineBox>>{};
    // 页数太少不值得起 isolate（启动开销比抽取还大）
    if (pageCount < 24) return null;
    try {
      // 每个 isolate 一份 PDF 字节：读一次，复用同一份 Uint8List 传进去
      final bytes = await File(path).readAsBytes();
      // v1.21.31：worker 数还要看**文件多大**（大文件少开，见 _parallelWorkerCount）
      final workers = _parallelWorkerCount(pageCount, bytes.length);
      if (workers < 2) return null;
      final perWorker = (pageCount / workers).ceil();
      final futures = <Future<_PdfLineChunk>>[];
      for (var w = 0; w < workers; w++) {
        final start = w * perWorker;
        if (start >= pageCount) break;
        var end = start + perWorker - 1;
        if (end > pageCount - 1) end = pageCount - 1;
        futures.add(
          compute(
            _extractPdfLinesChunk,
            _PdfLineRequest(bytes: bytes, start: start, end: end),
          ),
        );
      }
      final chunks = await Future.wait(futures);
      final result = <int, List<PdfLineBox>>{};
      var done = 0;
      for (final chunk in chunks) {
        result.addAll(chunk.lines);
        done += chunk.pageCount;
        onProgress(done, pageCount);
      }
      return result;
    } catch (e) {
      CrashLog.mark('PDF 并行抽取失败，退回单线程：$e');
      return null;
    }
  }

  /// 并行度：按 CPU 核数，夹在 2~4 之间
  ///
  /// 上限 4 是内存与收益的折中：每个 isolate 各持一份 PDF 字节并各自解析，
  /// 核再多也不值得（PDF 解析本身也有内存峰值）。
  /// 并行 worker 数（v1.21.31 / P1：**加了"文件多大"这一维**）
  ///
  /// 原来只看 CPU 核数（夹在 2–4）。每个 isolate 都会**各持一份 PDF 字节**，
  /// 大文件多开 worker 会把内存打爆，所以按文件大小分档，越大越少开。
  ///
  /// ⚠️ 小文件**仍然封顶 4**（没有按任务书建议放宽到 6）：实测 319 页基准
  /// 放宽到 6 之后冷启动从 1584ms 涨到 1893ms（isolate 启动开销 > 抽取收益），
  /// 而"319 页不退化"是本项的硬底线。
  ///
  /// [fileSizeBytes] 传 0（未知）时按核数走老逻辑。
  static int _parallelWorkerCount(int pageCount, [int fileSizeBytes = 0]) {
    var cores = 4;
    try {
      cores = Platform.numberOfProcessors;
    } catch (_) {
      cores = 4;
    }
    // 内存优先：大文件少开；小文件维持原来的 2–4
    var workers = fileSizeBytes > 256 * 1024 * 1024
        ? 2
        : (fileSizeBytes > 64 * 1024 * 1024 ? 3 : cores.clamp(2, 4));
    if (workers > pageCount) workers = pageCount < 1 ? 1 : pageCount;
    return workers < 1 ? 1 : workers;
  }

  /// EPUB：先用自己读 zip 的路径（spine 保正文完整、nav/NCX 提目录），再用 epubx 兜底
  ///
  /// 为什么把顺序反过来：epubx 是**按 NCX 建章**的（见它的 `ChapterReader`），
  /// NCX 只列了部分文件时正文会缺、同一文件的多个锚点还会把内容重复读一遍；
  /// 没有 NCX 的 EPUB3（越来越常见）它直接返回空章列表。
  /// 自己读 spine 能保证「每个正文文件都被读到」，目录标题再从 nav/NCX 取。
  static Future<ParseResult> _parseEpub(String path, ProgressSink report, String? coverOutPath) async {
    report(0.05, '读取文件');
    ParseResult? manual;
    Object? manualError;
    try {
      report(0.2, '解析 EPUB');
      manual = await parseEpubManually(path, coverOutPath: coverOutPath, report: report);
      if (manual.document.sentenceCount > 0) return manual;
      report(0.7, '结构异常，改用兼容解析');
    } catch (error) {
      manualError = error;
      report(0.7, '改用兼容解析');
    }
    try {
      final result = await _parseEpubWithEpubx(path, report, coverOutPath);
      if (result.document.sentenceCount > 0) return result;
    } catch (_) {
      // epubx 也失败：下面按「兜底路径的结果 / 错误」返回
    }
    if (manual != null) return manual;
    throw manualError ?? const FormatException('这本 EPUB 没有解析出正文');
  }

  /// epubx 解析路径
  static Future<ParseResult> _parseEpubWithEpubx(
    String path,
    ProgressSink report,
    String? coverOutPath,
  ) async {
    final bytes = await File(path).readAsBytes();
    final book = await epub.EpubReader.readBook(bytes);
    report(0.3, '解析章节');

    String? coverPath;
    if (coverOutPath != null) {
      coverPath = await _writeEpubCover(book, coverOutPath);
    }

    final chapters = <Chapter>[];
    final outline = <DocumentOutlineEntry>[];
    var textChars = 0;

    // 递归遍历（保留层级）：原来是把 SubChapters 拍平的，目录里的卷 / 部层级会丢
    void walk(List<epub.EpubChapter>? list, int depth) {
      for (final item in list ?? const <epub.EpubChapter>[]) {
        final html = item.HtmlContent;
        final title = (item.Title ?? '').trim();
        if (html != null && html.trim().isNotEmpty) {
          final plain = htmlToPlainText(html);
          textChars += plain.length;
          final heading = _epubChapterTitle(html);
          final chapterTitle = title.isEmpty ? (heading ?? '第 ${chapters.length + 1} 章') : title;
          // 正文首段常与章节标题重复（<h1>），去掉可避免朗读时标题读两遍
          final paragraphs = _dropDuplicateHeading(_splitParagraphs(plain), chapterTitle);
          if (paragraphs.isNotEmpty) {
            if (title.isNotEmpty) {
              outline.add(
                DocumentOutlineEntry(title: chapterTitle, chapter: chapters.length, depth: depth),
              );
            }
            chapters.add(Chapter(title: chapterTitle, paragraphs: paragraphs));
          }
          report(0.3 + 0.65 * (chapters.length / (chapters.length + 1)), '解析第 ${chapters.length} 章');
        }
        walk(item.SubChapters, depth + 1);
      }
    }

    walk(book.Chapters, 0);
    report(1, '完成');
    final document = StructuredDocument(chapters: chapters, outline: outline);
    return ParseResult(
      document,
      coverPath: coverPath,
      hasTextLayer: document.sentenceCount > 0,
      pageCount: chapters.length,
      textCharCount: textChars,
    );
  }

  /// EPUB 兜底解析：自己读 zip（container.xml → OPF → spine → XHTML）
  ///
  /// 只要 EPUB 是合法的 zip + OPF，就能抽到正文，不依赖 epubx 的封面解码等步骤。
  static Future<ParseResult> parseEpubManually(
    String path, {
    String? coverOutPath,
    ProgressSink? report,
  }) async {
    void stage(double value, String text) => report?.call(value, text);
    stage(0.05, '读取文件');
    final bytes = await File(path).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);
    String? coverPath; // 抽到封面时回报给调用方（v1.21.30 / P0）
    // v1.21.30 / P0：EPUB 路径大小写回退在 [_resolveArchiveName] 里做
    // （精确优先，失败后按小写名回退；映射按需自建，见那里的说明）。

    stage(0.2, '定位 OPF 清单');
    final containerText = _readArchiveText(archive, 'META-INF/container.xml');
    String? opfPath;
    if (containerText != null) {
      try {
        final container = xml.XmlDocument.parse(containerText);
        for (final node in container.findAllElements('rootfile')) {
          final fullPath = node.getAttribute('full-path');
          if (fullPath != null && fullPath.trim().isNotEmpty) {
            opfPath = fullPath.trim();
            break;
          }
        }
      } catch (_) {
        // 忽略，走下面的兜底扫描
      }
    }
    opfPath ??= _findOpfPath(archive);
    if (opfPath == null) throw const FormatException('EPUB 缺少 OPF 清单（container.xml 无效）');

    final opfText = _readArchiveText(archive, opfPath);
    if (opfText == null) throw FormatException('无法读取 EPUB 清单：$opfPath');
    final opf = xml.XmlDocument.parse(opfText);
    final base = opfPath.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) : '';

    // manifest：id -> href / media-type
    final hrefById = <String, String>{};
    final typeById = <String, String>{};
    for (final item in opf.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id == null || href == null) continue;
      hrefById[id] = href;
      typeById[id] = item.getAttribute('media-type') ?? '';
    }

    // spine：阅读顺序
    final ordered = <String>[];
    for (final ref in opf.findAllElements('itemref')) {
      final idref = ref.getAttribute('idref');
      final href = idref == null ? null : hrefById[idref];
      if (href != null && !ordered.contains(href)) ordered.add(href);
    }
    if (ordered.isEmpty) {
      // 没有 spine 时退化为按 manifest 顺序取所有 html/xhtml
      for (final entry in hrefById.entries) {
        final href = entry.value.toLowerCase();
        if (href.endsWith('.xhtml') || href.endsWith('.html') || href.endsWith('.htm')) {
          ordered.add(entry.value);
        }
      }
    }

    // 封面：EPUB3 的 properties="cover-image"，或 EPUB2 的 <meta name="cover" content="id">
    if (coverOutPath != null) {
      String? coverHref;
      for (final item in opf.findAllElements('item')) {
        final props = item.getAttribute('properties') ?? '';
        if (props.contains('cover-image')) {
          coverHref = item.getAttribute('href');
          if (coverHref != null) break;
        }
      }
      if (coverHref == null) {
        for (final meta in opf.findAllElements('meta')) {
          if ((meta.getAttribute('name') ?? '').toLowerCase() == 'cover') {
            final id = meta.getAttribute('content');
            if (id != null) coverHref = hrefById[id];
            if (coverHref != null) break;
          }
        }
      }
      coverHref ??= hrefById.values.firstWhere(
        (href) {
          final lower = href.toLowerCase();
          return lower.contains('cover') &&
              (lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') || lower.endsWith('.webp'));
        },
        orElse: () => '',
      );
      if (coverHref.isNotEmpty) {
        await _copyArchiveFile(archive, '$base$coverHref', coverOutPath);
        // v1.21.30 / P0：写成功才回报（文件不在/是空文件时保持 null，界面用占位封面）
        final File written = File(coverOutPath);
        if (await written.exists() && await written.length() > 0) {
          coverPath = coverOutPath;
        }
      }
    }

    stage(0.4, '抽取正文');
    // 目录：EPUB3 的 nav 文档优先，其次 EPUB2 的 NCX；按 href 映射到正文文件
    final toc = _readEpubToc(
      archive: archive,
      opf: opf,
      base: base,
      hrefById: hrefById,
    );
    final tocByFile = EpubTocParser.byFile(toc);
    final chapters = <Chapter>[];
    final outline = <DocumentOutlineEntry>[];
    var textChars = 0;
    final total = ordered.isEmpty ? 1 : ordered.length;
    for (var i = 0; i < ordered.length; i++) {
      final entry = ordered[i];
      final html = _readArchiveText(archive, '$base$entry') ?? _readArchiveText(archive, entry);
      if (html != null && html.trim().isNotEmpty) {
        final plain = htmlToPlainText(html);
        textChars += plain.length;
        final normalized = EpubTocParser.normalizePath(entry, baseDir: base);
        final tocEntries = tocByFile[normalized] ?? tocByFile[entry];
        final fromToc = tocEntries == null || tocEntries.isEmpty ? null : tocEntries.first.title;
        // 标题优先级：目录标题 > 正文里的标题标签 > <title> > 第 N 章
        // （很多 EPUB 每个文件的 <title> 都是同一个书名，直接用它会出现一堆重复章名）
        final title = (fromToc != null && fromToc.isNotEmpty)
            ? fromToc
            : (_epubChapterTitle(html) ?? '第 ${chapters.length + 1} 章');
        final body = _dropDuplicateHeading(_splitParagraphs(plain), title);
        if (body.isNotEmpty) {
          final index = chapters.length;
          chapters.add(Chapter(title: title, paragraphs: body));
          if (tocEntries != null && tocEntries.isNotEmpty) {
            outline.add(
              DocumentOutlineEntry(
                title: title,
                chapter: index,
                depth: tocEntries.first.depth,
              ),
            );
            // 同一文件里还有别的目录条目（指向文件内的锚点）：标题是真的，一并列出来，
            // 只是都跳到这一章开头（正文没有按锚点再切分）
            final seen = <String>{title};
            for (final extra in tocEntries.skip(1)) {
              if (extra.title.isEmpty || !seen.add(extra.title)) continue;
              outline.add(
                DocumentOutlineEntry(
                  title: extra.title,
                  chapter: index,
                  depth: extra.depth,
                ),
              );
            }
          }
        }
      }
      stage(0.4 + 0.55 * (i + 1) / total, '解析第 ${i + 1}/$total 章');
    }

    stage(1, '完成');
    final document = StructuredDocument(chapters: chapters, outline: outline);
    return ParseResult(
      document,
      hasTextLayer: document.sentenceCount > 0,
      pageCount: chapters.length,
      textCharCount: textChars,
      // v1.21.30 / P0：手动路径原来**写完封面却不回报路径** ——
      // `ParseResult.coverPath` 恒为 null，界面就不会把封面记进文档库，
      // 用户看到的是"这本 EPUB 明明有封面却一直显示占位图"。
      coverPath: coverPath,
    );
  }

  /// 读出 EPUB 的目录条目（EPUB3 nav 文档优先，其次 EPUB2 NCX）
  ///
  /// 找目录的顺序：manifest 里 `properties="nav"` → `spine@toc` 指向的 NCX →
  /// manifest 里 media-type 是 `application/x-dtbncx+xml` 的项 → 按常见文件名猜。
  static List<EpubTocEntry> _readEpubToc({
    required Archive archive,
    required xml.XmlDocument opf,
    required String base,
    required Map<String, String> hrefById,
  }) {
    String? navHref;
    String? ncxHref;
    for (final item in opf.findAllElements('item')) {
      final href = (item.getAttribute('href') ?? '').trim();
      if (href.isEmpty) continue;
      final props = (item.getAttribute('properties') ?? '').toLowerCase();
      if (navHref == null && props.split(RegExp(r'\s+')).contains('nav')) navHref = href;
      final type = (item.getAttribute('media-type') ?? '').toLowerCase();
      if (ncxHref == null && type.contains('dtbncx')) ncxHref = href;
    }
    if (ncxHref == null) {
      for (final spine in opf.findAllElements('spine')) {
        final tocId = spine.getAttribute('toc');
        final href = tocId == null ? null : hrefById[tocId];
        if (href != null && href.trim().isNotEmpty) {
          ncxHref = href.trim();
          break;
        }
      }
    }
    navHref ??= _guessArchiveFile(archive, base, const <String>['nav.xhtml', 'nav.html', 'toc.xhtml']);
    ncxHref ??= _guessArchiveFile(archive, base, const <String>['toc.ncx']);

    final entries = <EpubTocEntry>[];
    if (navHref != null) {
      final path = _archivePathFor(archive, base, navHref);
      final text = path == null ? null : _readArchiveText(archive, path);
      if (path != null && text != null) {
        entries.addAll(EpubTocParser.parseNav(text, navDir: _dirOf(path)));
      }
    }
    if (entries.isEmpty && ncxHref != null) {
      final path = _archivePathFor(archive, base, ncxHref);
      final text = path == null ? null : _readArchiveText(archive, path);
      if (path != null && text != null) {
        entries.addAll(EpubTocParser.parseNcx(text, ncxDir: _dirOf(path)));
      }
    }
    if (entries.isEmpty) {
      // 连清单都没写对：全盘扫一遍 .ncx / nav 文件
      for (final file in archive.files) {
        if (!file.isFile) continue;
        final name = file.name;
        final lower = name.toLowerCase();
        final isNcx = lower.endsWith('.ncx');
        final isNav = lower.endsWith('nav.xhtml') || lower.endsWith('nav.html');
        if (!isNcx && !isNav) continue;
        final text = _readArchiveText(archive, name);
        if (text == null) continue;
        final found = isNcx
            ? EpubTocParser.parseNcx(text, ncxDir: _dirOf(name))
            : EpubTocParser.parseNav(text, navDir: _dirOf(name));
        if (found.isNotEmpty) {
          entries.addAll(found);
          break;
        }
      }
    }
    return entries;
  }

  /// 小写名 → 精确名（EPUB 大小写回退用，v1.21.30 / P0）
  ///
  /// 为什么需要：EPUB 规范要求路径**大小写敏感**，但实际文件常有出入 ——
  /// `META-INF/container.xml` vs `meta-inf/container.xml`、
  /// `OEBPS/Images/cover.jpg` vs `oebps/images/Cover.jpg`。
  /// 只做精确匹配时这些书会静默退化成「没有封面 / 没有目录」。
  static Map<String, String> _buildLowerNameMap(Archive archive) {
    final Map<String, String> map = <String, String>{};
    for (final ArchiveFile file in archive.files) {
      if (!file.isFile) continue;
      map[file.name.toLowerCase()] = file.name;
    }
    return map;
  }

  /// 在 zip 里解析出**真实存在的条目名**：先精确匹配，全失败再走小写回退
  ///
  /// [lowerToName] 由调用方一次性建好传入（`parseEpubManually` 就是这么做的）；
  /// 不传时就地建一份（给零散调用点兜底，代价只是一次 O(n) 扫描）。
  static String? _resolveArchiveName(
    Archive archive,
    String name, [
    Map<String, String>? lowerToName,
  ]) {
    if (name.isEmpty) return null;
    for (final ArchiveFile file in archive.files) {
      if (file.isFile && file.name == name) return file.name; // ① 精确
    }
    final Map<String, String> map = lowerToName ?? _buildLowerNameMap(archive);
    return map[name.toLowerCase()]; // ② 小写回退（可能是 null）
  }

  /// 在 zip 里按「OPF 目录 + 文件名」找一个存在的条目
  static String? _archivePathFor(
    Archive archive,
    String base,
    String href, [
    Map<String, String>? lowerToName,
  ]) {
    final normalized = EpubTocParser.normalizePath(href, baseDir: base);
    for (final candidate in <String>[normalized, '$base$href', href]) {
      if (candidate.isEmpty) continue;
      // v1.21.30：这里改成「解析真实条目名」，精确不中时会走小写回退
      final String? resolved = _resolveArchiveName(archive, candidate, lowerToName);
      if (resolved != null) return resolved;
    }
    return null;
  }

  /// 猜一个常见的目录文件名
  static String? _guessArchiveFile(Archive archive, String base, List<String> names) {
    for (final name in names) {
      if (_resolveArchiveName(archive, '$base$name') != null) return name;
      if (_resolveArchiveName(archive, name) != null) return name;
    }
    return null;
  }

  /// 取路径的目录部分（**带结尾分隔符**）
  ///
  /// ⚠️ v1.21.35 / L2b-2 修：原来是"只找 `/`，找不到返回空串"——
  /// 在 Windows 上路径用 `\`，于是**任何时候都返回空串**：
  /// 拼出来的块文件路径成了 `\<名字>.ttsl`（写到盘根，写失败被静默吞掉），
  /// 表现就是「分块行表一个都没生成、阅读页按块读永远读不到」。
  /// Android 上缓存路径恰好用 `/`，所以这个坑一直没露头。
  ///
  /// 返回带结尾分隔符的目录（保持原有契约：调用方是拼字符串用的，
  /// EPUB 的 `navDir` / `ncxDir` 也按这个约定消费）。
  static String _dirOf(String path) {
    String separator = Platform.pathSeparator;
    int cut = path.lastIndexOf(separator);
    // 两种分隔符都认（Windows 下 `/` 也是合法分隔符，缓存路径来自插件的可能混用）
    final int other = path.lastIndexOf(separator == '/' ? r'\' : '/');
    if (other > cut) {
      cut = other;
      separator = separator == '/' ? r'\' : '/';
    }
    if (cut < 0) return '';
    return path.substring(0, cut + 1);
  }

  /// 章节标题：<title> → 第一个 h1~h6 → null
  static String? _epubChapterTitle(String html) {
    try {
      final document = html_parser.parse(html);
      final title = document.querySelector('title')?.text.trim() ?? '';
      if (title.isNotEmpty) return title;
      for (final tag in const <String>['h1', 'h2', 'h3', 'h4']) {
        final text = document.querySelector(tag)?.text.trim() ?? '';
        if (text.isNotEmpty && text.length <= 80) return text;
      }
    } catch (_) {
      // 忽略
    }
    return null;
  }

  /// 首段与章节标题重复时去掉首段，避免朗读时标题读两遍
  static List<Paragraph> _dropDuplicateHeading(List<Paragraph> paragraphs, String title) {
    if (paragraphs.isEmpty) return paragraphs;
    final first = paragraphs.first.text.trim();
    if (first.isEmpty || first.length > 40) return paragraphs;
    String normalize(String value) =>
        value.replaceAll(RegExp(r'[\s。．.!！?？:：、,，\-—_]'), '');
    final heading = normalize(first);
    final normalizedTitle = normalize(title);
    if (normalizedTitle.isEmpty || heading.isEmpty) return paragraphs;
    if (heading == normalizedTitle || normalizedTitle.startsWith(heading)) {
      return paragraphs.sublist(1);
    }
    return paragraphs;
  }

  /// 在 zip 里找 .opf 文件（container.xml 缺失时的兜底）
  static String? _findOpfPath(Archive archive) {
    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (file.name.toLowerCase().endsWith('.opf')) return file.name;
    }
    return null;
  }

  /// 按名字读取 zip 内的文本文件（容错：编码异常不抛）
  static String? _readArchiveText(Archive archive, String name) {
    // v1.21.30 / P0：先解析**真实条目名**（精确 → 小写回退），
    // 否则大小写不一致的书会读不到 container.xml / OPF / 正文。
    final String? resolved = _resolveArchiveName(archive, name);
    if (resolved == null) return null;
    for (final file in archive.files) {
      if (!file.isFile || file.name != resolved) continue;
      final content = file.content;
      if (content is List<int>) return utf8.decode(content, allowMalformed: true);
      if (content is List) return utf8.decode(content.cast<int>(), allowMalformed: true);
      return null;
    }
    return null;
  }

  /// 把 zip 内的图片原样写到目标路径（不做解码，避免图片格式不受支持时失败）
  static Future<void> _copyArchiveFile(Archive archive, String name, String outPath) async {
    // v1.21.30 / P0：同样先解析真实条目名，否则封面会**静默丢失**
    final String? resolved = _resolveArchiveName(archive, name);
    if (resolved == null) return;
    for (final file in archive.files) {
      if (!file.isFile || file.name != resolved) continue;
      final content = file.content;
      final data = content is List<int> ? content : (content is List ? content.cast<int>() : null);
      if (data == null || data.isEmpty) return;
      final target = File(outPath);
      await target.parent.create(recursive: true);
      await target.writeAsBytes(data, flush: false);
      return;
    }
  }

  /// TXT：按章节标题切分（识别不到时退回单章「全文」）
  ///
  /// 编码交给 [TxtDecoder]：BOM → 严格 UTF-8 → GBK / Big5 / UTF-16 / Latin-1 按分选。
  /// 原来「UTF-8 不行就 Latin-1」的写法会让 GBK 小说整本乱码
  /// （更麻烦的是字节恰好合法时连异常都不抛，见 txt_decoder.dart 的注释）。
  static Future<ParseResult> _parseTxt(String path, ProgressSink report) async {
    report(0.05, '读取文件');
    final bytes = await File(path).readAsBytes();
    report(0.25, '识别编码');
    final decoding = TxtDecoder.decode(bytes);
    final text = decoding.text;
    // 注意：解析跑在 isolate 里，不能碰插件（CrashLog 要 path_provider），
    // 编码信息随 ParseResult 回主 isolate，由界面写日志（见 reader_page）。
    report(0.4, '识别章节');
    // 章节识别 + 段落切分都在这里做完：一行一段、硬折行合并（小说 TXT 两种排法都照顾到）
    final chapters = TxtChapterSplitter.split(
      text,
      paragraphSplitter: DocumentTextSplitter.splitTextParagraphs,
    );
    report(0.9, chapters.length > 1 ? '整理 ${chapters.length} 章' : '切分段落');
    final document = StructuredDocument(chapters: chapters);
    report(1, '完成');
    return ParseResult(
      document,
      hasTextLayer: document.sentenceCount > 0,
      pageCount: chapters.length,
      textCharCount: text.length,
      encoding: decoding.encoding,
    );
  }

  /// 诊断日志里只留文件名，别把整条路径写进去
  static String shortPath(String path) {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? path : parts.last;
  }

  /// 抽 EPUB 封面并缩放到 400px 宽，返回写出的文件路径
  static Future<String?> _writeEpubCover(epub.EpubBook book, String outPath) async {
    try {
      final cover = book.CoverImage;
      if (cover == null) return null;
      return _writeCoverImage(cover, outPath);
    } catch (_) {
      return null; // 封面失败不影响解析
    }
  }

  static Future<String?> _writeCoverImage(img.Image cover, String outPath) async {
    try {
      final resized = cover.width > 400 ? img.copyResize(cover, width: 400) : cover;
      List<int> data;
      try {
        data = img.encodeJpg(resized, quality: 82);
      } catch (_) {
        data = img.encodePng(resized);
      }
      final file = File(outPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data, flush: false);
      return outPath;
    } catch (_) {
      return null;
    }
  }

  /// 抽取 / 生成封面（PDF、EPUB、TXT 都支持）
  ///
  /// 需求：「自动解析文件（PDF，TXT，EPUB）封面，没有就使用默认样式」。
  /// 三类文档各有来源：
  /// - **EPUB**：书里自带封面图（用 openBook 读元数据，避免为封面解析整本书）；
  /// - **PDF**：看第一页有没有「够大的整页图」（扫描件 / 封面页），有就抽出来；
  /// - **TXT**：没有任何图源 —— 直接生成默认样式封面（标题 + 主题色底）。
  ///
  /// 任何一步失败都退到默认样式；再失败返回 null（界面本来就有占位图）。
  static Future<String?> extractCover(Document document, String outPath) async {
    try {
      switch (document.type) {
        case DocumentType.epub:
          final extracted = await _extractEpubCover(document, outPath);
          if (extracted != null) return extracted;
        case DocumentType.pdf:
          final extracted = await _extractPdfCover(document, outPath);
          if (extracted != null) return extracted;
        case DocumentType.txt:
          // ★v1.22.1：TXT 也要有封面
          //
          // 现状核对过：TXT 原来走到 `break` → `writeDefaultCover`，
          // 而那个函数用 `image` 包自带的**位图 ASCII 字体**画书名，
          // 中文一个字也画不出来 → 用户看到的就是一块纯色、没有书名。
          // TXT 本身没有内嵌图片，所以只能自己排版：这里先试 TXT 头部的
          // 「书名/作者」行，再交给 [CoverRenderer] 用 Flutter 排版引擎画（支持中文）。
          final meta = await _readTxtHeaderMeta(document.path);
          final rendered = await CoverRenderer.render(
            title: meta.title ?? document.title,
            author: meta.author ?? '',
            outPath: outPath,
          );
          if (rendered != null) return rendered;
      }
    } catch (_) {
      // 抽取失败不影响功能，落到默认样式
    }
    return writeDefaultCover(document.title, outPath);
  }

  /// 从 TXT 开头几行里认「书名 / 作者」
  ///
  /// 中文 TXT 常见的头部约定：
  /// ```
  /// 书名：钢铁是怎样炼成的
  /// 作者：奥斯特洛夫斯基
  /// ```
  /// 或者只有一行书名。认不出来就返回 null（调用方用文件名）。
  ///
  /// 只读前 4KB：TXT 可能几百 MB，不能整个读进来。
  static Future<({String? title, String? author})> _readTxtHeaderMeta(
    String path,
  ) async {
    try {
      final File file = File(path);
      if (!await file.exists()) return (title: null, author: null);
      final RandomAccessFile raf = await file.open();
      try {
        final int length = await raf.length();
        final int take = length > 4096 ? 4096 : length;
        final Uint8List bytes = await raf.read(take);
        // 编码未知：先按 UTF-8 宽松解，解出乱码也没关系（只用来认「书名：」这种标记）
        final String head = utf8.decode(bytes, allowMalformed: true);
        String? title;
        String? author;
        for (final String rawLine in head.split('\n').take(20)) {
          final String line = rawLine.replaceAll('\uFEFF', '').trim();
          if (line.isEmpty) continue;
          final String? t = _afterMarker(line, const <String>['书名', '名称', '作品名']);
          if (t != null && t.isNotEmpty) title ??= t;
          final String? a = _afterMarker(line, const <String>['作者', '著者']);
          if (a != null && a.isNotEmpty) author ??= a;
          if (title != null && author != null) break;
        }
        return (title: title, author: author);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return (title: null, author: null);
    }
  }

  /// `书名：xxx` / `书名:xxx` / `书名 xxx` → `xxx`
  static String? _afterMarker(String line, List<String> markers) {
    for (final String marker in markers) {
      if (!line.startsWith(marker)) continue;
      final String rest = line.substring(marker.length).trim();
      final String cleaned = rest.replaceFirst(RegExp(r'^[：:～~\-\s]+'), '').trim();
      if (cleaned.isEmpty) return null;
      // 「作者简介」这种不是作者行
      if (cleaned.length > 40) return null;
      return cleaned;
    }
    return null;
  }

  /// EPUB 自带封面（v1.21.17 第 3 件：**手动解 OPF 优先**）
  ///
  /// 手动方案（`parseEpubManually`）直接读 zip 里的 OPF：
  /// EPUB3 的 `properties="cover-image"` → EPUB2 的 `<meta name="cover">` →
  /// 文件名兜底（`document_service.dart` 里那段 `coverHref` 逻辑）。
  /// 它不依赖 epubx 的封面解码，**失败面更小**，所以放在前面；
  /// epubx 的 `readCover()` 退居兜底（它对某些书的 OPF 结构会解码失败）。
  static Future<String?> _extractEpubCover(
    Document document,
    String outPath,
  ) async {
    // ① 手动解 OPF（Cmbok 方案）
    debugCoverAttempts.add('opf');
    try {
      await parseEpubManually(document.path, coverOutPath: outPath);
      final file = File(outPath);
      if (await file.exists() && await file.length() > 0) return outPath;
    } catch (_) {
      // 手动解析失败 → 交给 epubx
    }
    // ② epubx 兜底
    debugCoverAttempts.add('epubx');
    try {
      final bytes = await File(document.path).readAsBytes();
      final ref = await epub.EpubReader.openBook(bytes);
      final cover = await ref.readCover();
      if (cover != null) return _writeCoverImage(cover, outPath);
    } catch (_) {
      // 两条路都失败：交给默认样式封面
    }
    return null;
  }

  /// 测试用：EPUB 封面**尝试顺序**（`['opf']` / `['opf','epubx']`）
  @visibleForTesting
  static final List<String> debugCoverAttempts = <String>[];

  /// 测试用：PDF 封面最后是从哪来的（`'render'` = pdfrx 渲染首页成功）
  @visibleForTesting
  static String? debugPdfCoverSource;

  /// PDF 封面：用 **pdfrx 渲染第 1 页**（v1.21.17 第 4 件）
  ///
  /// 为什么用渲染而不是"抽页面里的原图"：Syncfusion 26.2 没有读取已有图片的
  /// 公开 API（见下面的历史注释），而 pdfrx 能把整页渲成位图 —— 对扫描件 /
  /// 有封面的 PDF 来说，渲染结果**就是**用户想看到的封面。
  ///
  /// ⚠️ pdfrx 走平台通道，**只能在主 isolate 调用**（解析 isolate 里用不了插件），
  /// 所以这里只从 [extractCover]（主线程）进来，不参与 `parse` 的 isolate 流程。
  static Future<String?> _extractPdfCover(
    Document document,
    String outPath,
  ) async {
    pdfrx.PdfDocument? doc;
    try {
      doc = await pdfrx.PdfDocument.openFile(document.path);
      if (doc.pages.isEmpty) return null;
      final pdfrx.PdfPage page = doc.pages.first;
      // 封面最终按 400px 宽输出（`_writeCoverImage` 会缩），这里渲 2 倍余量
      const double targetWidth = 900;
      final double scale = page.width > 0 ? targetWidth / page.width : 1;
      final pdfrx.PdfImage? rendered = await page.render(
        fullWidth: page.width * scale,
        fullHeight: page.height * scale,
      );
      if (rendered == null) return null;
      final img.Image? image = _pdfImageToImage(rendered);
      rendered.dispose();
      if (image == null) return null;
      debugPdfCoverSource = 'render';
      return _writeCoverImage(image, outPath);
    } catch (e) {
      // 渲染失败（加密 / 损坏 / 平台不支持）→ 交给默认样式封面
      CrashLog.mark('PDF 封面渲染失败：$e');
      return null;
    } finally {
      await doc?.dispose();
    }
  }

  /// pdfrx 的 `PdfImage` → `package:image`（零逐像素循环：直接按字节序取用）
  ///
  /// ⚠️ 本工程锁在 `image: ^3.3.0`（与 epubx 的 image 3.x 对齐），
  /// 它的 API 是 `Image.fromBytes(w, h, bytes, format: Format.rgba|bgra)` ——
  /// 没有 4.x 的 `numChannels/order` 具名参数。
  static img.Image? _pdfImageToImage(pdfrx.PdfImage src) {
    try {
      final bool bgra = src.format == PixelFormat.bgra8888;
      return img.Image.fromBytes(
        src.width,
        src.height,
        src.pixels,
        format: bgra ? img.Format.bgra : img.Format.rgba,
        channels: img.Channels.rgba,
      );
    } catch (_) {
      return null;
    }
  }

  /// PDF 首页里的整页图（**历史注释**：Syncfusion 路线为何没做）
  ///
  /// Syncfusion PDF 26.2 不提供读取已有图片的公开 API（只有 `PdfImage` 基类与
  /// 内部的 `PdfImageHelper`，没有遍历页面图片的入口），所以早期这里直接返回
  /// null、由调用方落到「默认样式封面」。v1.21.17 起改用 pdfrx 渲染整页。

  /// 默认样式封面：主题色渐变底 + 一条亮带 + 书名（能画多少画多少）
  ///
  /// 纯本地绘制，不依赖网络与外部字体。书名用 image 包自带的位图字体，
  /// **只支持 Latin** —— 中文标题会缺字形，所以整段绘制 try 住：
  /// 画不出来就保留「渐变底 + 亮带」的纯色封面，仍然比一块空占位好看，
  /// 也绝不会因为缺字形而崩。
  static Future<String?> writeDefaultCover(
    String title,
    String outPath, {
    int width = 480,
    int height = 680,
  }) async {
    try {
      final image = img.Image(width, height);
      // 底色：与内置种子色同系（0xFF6750A4）的深紫渐变
      const topR = 0x5B, topG = 0x46, topB = 0x96;
      const botR = 0x2E, botG = 0x22, botB = 0x5C;
      final lastRow = height - 1;
      for (var y = 0; y < height; y++) {
        final t = lastRow <= 0 ? 0.0 : y / lastRow;
        final r = (topR + (botR - topR) * t).round();
        final g = (topG + (botG - topG) * t).round();
        final b = (topB + (botB - topB) * t).round();
        for (var x = 0; x < width; x++) {
          image.setPixelRgba(x, y, r, g, b, 255);
        }
      }
      // 中间一条更亮的横带，让封面不至于是一块死色
      final bandTop = (height * 0.42).round();
      final bandBottom = (height * 0.58).round();
      for (var y = bandTop; y < bandBottom; y++) {
        final t = lastRow <= 0 ? 0.0 : y / lastRow;
        final r = (topR + (botR - topR) * t).round();
        final g = (topG + (botG - topG) * t).round();
        final b = (topB + (botB - topB) * t).round();
        for (var x = 0; x < width; x++) {
          image.setPixelRgba(
            x,
            y,
            (r * 0.7 + 0x9A * 0.3).round(),
            (g * 0.7 + 0x86 * 0.3).round(),
            (b * 0.7 + 0xD6 * 0.3).round(),
            255,
          );
        }
      }
      // 书名（位图字体只有 Latin 字形；画不出就跳过）
      final text = title.trim();
      if (text.isNotEmpty) {
        try {
          final shown = text.length > 20 ? '${text.substring(0, 20)}...' : text;
          img.drawString(
            image,
            img.arial_24,
            24,
            bandTop + 10,
            shown,
            color: 0xFFF2EEFF,
          );
        } catch (_) {
          // 缺字形 / 编码不支持：忽略，保留纯色封面
        }
      }
      final resized =
          image.width > 400 ? img.copyResize(image, width: 400) : image;
      List<int> data;
      try {
        data = img.encodeJpg(resized, quality: 84);
      } catch (_) {
        data = img.encodePng(resized);
      }
      final file = File(outPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data, flush: false);
      return outPath;
    } catch (_) {
      return null;
    }
  }

  /// 段落切分：先按空行拆块；块超过 400 字且含换行时再按行拆
  ///
  /// 与 [DocumentTextSplitter.splitParagraphs] 是同一份实现（单一事实来源）。
  static List<Paragraph> _splitParagraphs(String raw) =>
      DocumentTextSplitter.splitParagraphs(raw);

  /// 把任意文本切成适合逐条朗读的片段（网页朗读用）
  ///
  /// 先按空行分段，再按句合并到 [maxLength] 以内，保证每次朗读不会被系统 TTS 截断。
  static List<String> readChunks(String raw, {int maxLength = maxChunkLength}) {
    final chunks = <String>[];
    final buffer = StringBuffer();
    void flush() {
      final text = buffer.toString().trim();
      buffer.clear();
      if (text.isNotEmpty) chunks.add(text);
    }

    for (final paragraph in _splitParagraphs(raw)) {
      for (final sentence in paragraph.sentences) {
        var text = sentence.text;
        // 单句就超长时优先在标点处断开，实在找不到才硬切
        //
        // v1.22.48：原来是死板地 substring(0, maxLength) —— 一刀切常在词中间
        // （「无产阶|级革命」），读起来会卡一下。现在先回退到最近的标点断句。
        while (text.length > maxLength) {
          flush();
          final int cut = _splitPoint(text, maxLength);
          chunks.add(text.substring(0, cut).trim());
          text = text.substring(cut);
        }
        if (buffer.length + text.length > maxLength) flush();
        buffer.write(text);
      }
      flush();
    }
    flush();
    return chunks;
  }

  /// 在 [limit] 以内找一个「像样的断句点」
  ///
  /// 优先：句末标点（。！？；…）> 逗号类（，、：）> 空格 > 硬切。
  /// 只在后半段找（避免把 200 字切成两半、前一半只有 10 个字那种极端）。
  static int _splitPoint(String text, int limit) {
    const String strong = '。！？!?；;…\n';
    const String weak = '，,、：:·\u3000 ';
    final int floor = (limit * 0.5).round();
    for (int i = limit; i > floor; i--) {
      final String ch = text[i - 1];
      if (strong.contains(ch)) return i;
    }
    for (int i = limit; i > floor; i--) {
      final String ch = text[i - 1];
      if (weak.contains(ch)) return i;
    }
    return limit;
  }

  /// HTML -> 纯文本：块级标签补换行，丢弃脚本与样式
  static String htmlToPlainText(String source) {
    final document = html_parser.parse(source);
    for (final element in document.querySelectorAll('script, style, head, title, noscript')) {
      element.remove();
    }
    final buffer = StringBuffer();
    _walkNodes(document.nodes, buffer);
    return buffer
        .toString()
        .replaceAll('\r\n', '\n')
        .replaceAll('\u00A0', ' ')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r' *\n *'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  static void _walkNodes(List<dom.Node> nodes, StringBuffer buffer) {
    for (final node in nodes) {
      if (node is dom.Text) {
        buffer.write(node.data);
      } else if (node is dom.Element) {
        final tag = node.localName ?? '';
        if (tag == 'script' || tag == 'style') continue;
        if (tag == 'br') {
          buffer.write('\n');
          continue;
        }
        final isBlock = _blockTags.contains(tag);
        if (isBlock) buffer.write('\n');
        _walkNodes(node.nodes, buffer);
        if (isBlock) buffer.write('\n');
      }
    }
  }

  /// 由文件路径取标题：去目录、去扩展名（命名规则统一在 [FileNaming]）
  static String titleFromPath(String path) => FileNaming.titleOf(path);

  /// 解析缓存所在目录：`<应用文档目录>/parse_cache`
  ///
  /// 目录必须由**主线程**解析出来（path_provider 是插件，isolate 里用不了），
  /// 然后作为字符串传给 [parseAsync]。
  ///
  /// 两条防挂措施（都踩过）：
  /// 1. [warmUpCacheDirectory] 在启动时先求一次，之后这里只是
  ///    **读静态变量 + 建目录**，不再碰平台通道；
  /// 2. 预热没成功过时**直接返回空串**，不再重试 —— 在 widget 测试里
  ///    path_provider 的通道永远不回复（不是抛异常，是 pending），
  ///    重试一次就能把「打开文档」整条链路挂死，解析连 isolate 都起不来。
  ///    真实设备上预热几乎不会失败，偶尔失败也只是这次不启用缓存。
  ///
  /// [basePath] 供单测 / 预热直接注入，绕开平台通道。
  static Future<String> cacheDirectory({String? basePath}) async {
    final base = basePath ?? _basePath;
    if (base == null || base.isEmpty) return '';
    final path = '$base${Platform.pathSeparator}parse_cache';
    try {
      final folder = Directory(path);
      if (!await folder.exists()) await folder.create(recursive: true);
    } catch (_) {
      return '';
    }
    return path;
  }

  /// 启动时预热缓存目录（main 里调一次）
  ///
  /// 放在 `main()` 而不是「第一次打开文档时」：那时用户正等着解析，
  /// 任何一次平台通道往返都会直接加到首屏等待上；启动阶段顺手做掉最划算。
  static Future<void> warmUpCacheDirectory() async {
    try {
      final path = await cacheDirectory(basePath: await _appDocumentsPath());
      if (path.isNotEmpty) _basePath = File(path).parent.path;
    } catch (_) {
      // 拿不到就不启用缓存（_basePath 保持 null，后续不再重试）
    }
  }

  /// 已解析出的应用文档目录（[warmUpCacheDirectory] 填）
  static String? _basePath;

  static Future<String> _appDocumentsPath() async {
    try {
      return (await getApplicationDocumentsDirectory()).path;
    } catch (_) {
      return '';
    }
  }

  /// 删除某份文档的解析缓存（删除文档时调用，避免缓存目录越攒越大）
  static void dropCache(String cacheDir, String documentId) {
    if (cacheDir.isEmpty || documentId.isEmpty) return;
    DocumentCache.remove(
      '$cacheDir${Platform.pathSeparator}${DocumentCache.fileNameFor(documentId)}',
    );
  }

  /// 错误信息尽量短，避免把整段堆栈糊到界面上
  static String _describe(Object error) {
    final text = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }
}

/// 解析进度回调（公开类型，供兜底解析方法复用）
typedef ProgressSink = void Function(double value, String stage);

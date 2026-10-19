import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/services/download_watcher.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 入库即补封面（浏览器下载 / 后台扫描进来的书）
///
/// 原来只有「文件选择器导入」会补封面，下载进来的书在文档库里是空白占位。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel pathProvider =
      MethodChannel('plugins.flutter.io/path_provider');
  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    dir = await Directory.systemTemp.createTemp('cover_attach_');
    // 测试进程里没有 path_provider 插件，自己把「应用目录」指到临时目录
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (MethodCall call) async {
      return dir.path;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('没有封面的 TXT → 生成封面并回写文档库', () async {
    final String txt = '${dir.path}/book.txt';
    File(txt).writeAsStringSync('书名：钢铁是怎样炼成的\n作者：奥斯特洛夫斯基\n\n正文。\n');
    final Document doc = Document(
      id: 'd1',
      title: 'book',
      path: txt,
      type: DocumentType.txt,
      importedAt: DateTime(2026, 1, 1),
    );
    await StorageService.instance.upsertDocument(doc);

    await attachCoverFor(doc);

    final List<Document> docs = await StorageService.instance.loadDocuments();
    final Document saved = docs.firstWhere((Document d) => d.id == 'd1');
    expect((saved.coverPath ?? ''), isNotEmpty, reason: '应该写上封面路径');
    expect(File(saved.coverPath!).existsSync(), isTrue);
  });

  test('已有封面 → 不重复生成（路径原样保留）', () async {
    final Document doc = Document(
      id: 'd2',
      title: 'book',
      path: '${dir.path}/x.txt',
      type: DocumentType.txt,
      importedAt: DateTime(2026, 1, 1),
      coverPath: '${dir.path}/already.jpg',
    );
    await StorageService.instance.upsertDocument(doc);
    await attachCoverFor(doc);

    final Document saved = (await StorageService.instance.loadDocuments())
        .firstWhere((Document d) => d.id == 'd2');
    expect(saved.coverPath, '${dir.path}/already.jpg');
  });

  test('文件不存在 → 静默失败，不抛异常', () async {
    final Document doc = Document(
      id: 'd3',
      title: '不存在',
      path: '${dir.path}/nope.txt',
      type: DocumentType.txt,
      importedAt: DateTime(2026, 1, 1),
    );
    await StorageService.instance.upsertDocument(doc);
    await attachCoverFor(doc);
    // TXT 没有内嵌图源，走的是「排版生成」那条路：即使原文件不在了，
    // 也能用标题画一张，总比文档库里一块空白强；关键是**不许抛异常**。
    final Document saved = (await StorageService.instance.loadDocuments())
        .firstWhere((Document d) => d.id == 'd3');
    expect((saved.coverPath ?? ''), isNotEmpty);
  });
}

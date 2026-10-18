import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/main.dart';
import 'package:tts_reader/pages/home_page.dart';
import 'package:tts_reader/services/document_service.dart';
import 'package:tts_reader/services/library_storage.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 导入时保留文件原名的验证。
///
/// Android 上 file_picker 会把用户选的文件**复制到缓存目录**再交给应用
/// （`cache/file_picker/<时间戳>/<名字>`），名字偶尔会退回 `unamed`。
/// 所以书名必须用选择器报的**原始文件名**，而不是缓存副本的基名。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 注意 codec：file_picker 在桌面平台用 JSONMethodCodec，移动端用 StandardMethodCodec。
  // 测试跑在桌面上，这里必须跟着用 JSONMethodCodec，否则回包会「Message corrupted」。
  final MethodChannel channel = MethodChannel(
    'miguelruivo.flutter.plugins.filepicker',
    Platform.isLinux || Platform.isWindows || Platform.isMacOS
        ? const JSONMethodCodec()
        : const StandardMethodCodec(),
  );
  late Directory dir;
  late Directory appDocs;

  /// path_provider 的平台通道（Android 实现的方法名就是这些）
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    // 跳过首次使用教程弹窗（它会盖住界面，挡住这里的「导入」按钮）；
    // 教程本身由 tutorial_dialog_test 覆盖
    SharedPreferences.setMockInitialValues(<String, Object>{
      'tutorial_done': true,
    });
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    // 测试环境不会跑 dart_plugin_registrant，FilePicker.platform 是 late 的，
    // 得自己把 IO 实现装上，否则一取就 LateInitializationError
    FilePicker.platform = FilePickerIO();
    dir = Directory.systemTemp.createTempSync('tts_import_');
    // 应用私有目录（导入时文件会被复制进来）
    appDocs = Directory.systemTemp.createTempSync('tts_appdocs_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProvider,
      (call) async =>
          call.method == 'getApplicationDocumentsDirectory' ? appDocs.path : null,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    for (final target in <Directory>[dir, appDocs]) {
      try {
        if (target.existsSync()) target.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  /// 模拟 file_picker：路径是缓存副本（名字已被改成 unamed），但报出原始文件名
  void mockPicker({required String cachedPath, required String originalName, int size = 20}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'custom') return null;
          return <Map<String, Object?>>[
            <String, Object?>{
              'path': cachedPath,
              'name': originalName,
              'size': size,
              'bytes': null,
              'identifier': null,
            },
          ];
        });
  }

  Future<void> cleanup(WidgetTester tester) async {
    unawaited(TtsManager.instance.stop());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
  }

  testWidgets('书名用选择器报的原始文件名，而不是缓存副本的基名', (tester) async {
    // 缓存副本故意起成 unamed（file_picker 在拿不到名字时就是这么写的）
    final cached = File('${dir.path}/unamed')
      ..writeAsStringSync('第一章 风起\n天还没亮他就出门了。\n第二章 雨落\n雨下了整夜。\n');
    mockPicker(cachedPath: cached.path, originalName: '红楼梦 (曹雪芹).txt', size: cached.lengthSync());

    await tester.pumpWidget(const TtsReaderApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byKey(HomePage.importButtonKey));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    }

    final documents = await tester.runAsync(() => StorageService.instance.loadDocuments());
    expect(documents, isNotNull);
    expect(documents!.length, 1);
    final document = documents.single;
    expect(document.title, '红楼梦 (曹雪芹)', reason: '书名应当是原始文件名去掉扩展名');
    // 导入时收进了应用私有目录，文件名保持原样（缓存副本叫 unamed，不能跟着它）
    final sep = Platform.pathSeparator;
    expect(document.path, '${appDocs.path}$sep${LibraryStorage.dirName}$sep红楼梦 (曹雪芹).txt');
    expect(File(document.path).existsSync(), isTrue, reason: '副本应当真的落盘');
    expect(File(document.path).readAsStringSync(), cached.readAsStringSync(), reason: '内容要一致');
    expect(document.path, isNot(cached.path), reason: '不该再指向 picker 的缓存副本');
    // 与 FileNaming 的规则一致
    expect(DocumentService.titleFromPath(cached.path), 'unamed', reason: '缓存副本的基名确实不是原名');

    await cleanup(tester);
  });

  testWidgets('选择器没报名字时退回路径基名（不至于变成未命名）', (tester) async {
    final cached = File('${dir.path}/三体 第1部.txt')..writeAsStringSync('第一章 科学边界\n内容。\n');
    mockPicker(cachedPath: cached.path, originalName: '', size: cached.lengthSync());

    await tester.pumpWidget(const TtsReaderApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(HomePage.importButtonKey));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    }

    final documents = await tester.runAsync(() => StorageService.instance.loadDocuments());
    expect(documents!.single.title, '三体 第1部', reason: '空格与中文都要保留');
    final sep = Platform.pathSeparator;
    expect(documents.single.path, '${appDocs.path}$sep${LibraryStorage.dirName}$sep三体 第1部.txt');

    await cleanup(tester);
  });
}

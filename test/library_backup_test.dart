// 书库备份 / 恢复（v1.22.68）
//
// 这一组守的是「用户的书不会因为卸载、清数据、换机而消失」。
// 之前书库没有任何出口：书在应用私有目录，记录与进度在 SharedPreferences，
// 一旦清掉就全没了（系统备份对单应用只 25MB，实际指望不上）。
//
// 覆盖：
//   · 导出 → 导入 round-trip：文档、进度、书籍字节都一致
//   · 重复导入同一个包：不产生重复文档、不重复占空间
//   · 备份进度更旧：保留本机进度（不许倒退）
//   · 同名但内容不同：另存为 `名字 (1).ext`，原文件不动
//   · 损坏包 / 版本不符：明确报错，且**不动现有书库**
//   · 阅读样式只在书库为空（全新安装）时套用
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/services/library_backup.dart';
import 'package:tts_reader/services/storage_service.dart';

const MethodChannel _pathProvider =
    MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory appDir;
  late Directory outDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    appDir = await Directory.systemTemp.createTemp('lib_backup_app_');
    outDir = await Directory.systemTemp.createTemp('lib_backup_out_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (MethodCall call) async {
      return appDir.path;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    if (appDir.existsSync()) appDir.deleteSync(recursive: true);
    if (outDir.existsSync()) outDir.deleteSync(recursive: true);
  });

  /// 往书库里放一本书，并登记到文档库
  Future<Document> addBook(
    String id,
    String title, {
    String content = '正文',
    double progress = 0,
  }) async {
    final Directory books = Directory('${appDir.path}${Platform.pathSeparator}books')
      ..createSync(recursive: true);
    final File f = File('${books.path}${Platform.pathSeparator}$title.pdf');
    f.writeAsBytesSync(Uint8List.fromList(utf8.encode(content)));
    final Document doc = Document(
      id: id,
      title: title,
      path: f.path,
      type: DocumentType.pdf,
      importedAt: DateTime(2026, 1, 1),
      progress: progress,
    );
    final List<Document> docs = await StorageService.instance.loadDocuments();
    await StorageService.instance.saveDocuments(<Document>[...docs, doc]);
    return doc;
  }

  test('导出 → 导入 round-trip：文档、进度、书籍字节都一致', () async {
    await addBook('d1', '第一本', content: 'AAAA', progress: 0.42);
    await StorageService.instance.setPdfReadingSpot(
      'd1',
      pageIndex: 12,
      sentenceIndex: 3,
    );

    final LibraryBackupResult exported =
        await LibraryBackup.exportToDirectory(outDir.path);
    expect(File(exported.path).existsSync(), isTrue);
    expect(exported.documentCount, 1);
    expect(exported.fileCount, 1);
    expect(exported.missingFiles, isEmpty);

    // 清空本机，模拟重装
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    Directory('${appDir.path}${Platform.pathSeparator}books')
        .deleteSync(recursive: true);
    expect(await StorageService.instance.loadDocuments(), isEmpty);

    final LibraryRestoreResult r =
        await LibraryBackup.importFromZip(exported.path);
    expect(r.addedDocuments, 1);
    expect(r.filesWritten, 1);

    final List<Document> docs = await StorageService.instance.loadDocuments();
    expect(docs, hasLength(1));
    expect(docs.single.title, '第一本');
    expect(docs.single.progress, closeTo(0.42, 1e-9));
    expect(File(docs.single.path).existsSync(), isTrue,
        reason: '恢复后路径必须指向真实存在的文件');
    expect(File(docs.single.path).readAsStringSync(), 'AAAA');

    final spot = StorageService.instance.pdfReadingSpot('d1');
    expect(spot, isNotNull, reason: '朗读进度也要跟着回来');
    expect(spot!.pageIndex, 12);
    expect(spot.sentenceIndex, 3);
  });

  test('重复导入同一个包：不产生重复文档，文件复用', () async {
    await addBook('d1', '第一本', content: 'AAAA');
    final LibraryBackupResult exported =
        await LibraryBackup.exportToDirectory(outDir.path);

    final LibraryRestoreResult first =
        await LibraryBackup.importFromZip(exported.path);
    expect(first.addedDocuments, 0, reason: '本机已有同 id，不应重复添加');
    expect(first.skippedDocuments, 1);
    expect(first.filesReused, 1, reason: '同名同大小应当复用，不重复占空间');

    final LibraryRestoreResult second =
        await LibraryBackup.importFromZip(exported.path);
    expect(second.addedDocuments, 0);
    expect(await StorageService.instance.loadDocuments(), hasLength(1));
  });

  test('备份进度更旧：保留本机进度，不许倒退', () async {
    await addBook('d1', '第一本', content: 'AAAA', progress: 0.10);
    final LibraryBackupResult exported =
        await LibraryBackup.exportToDirectory(outDir.path);

    // 本机读到更后面
    final List<Document> docs = await StorageService.instance.loadDocuments();
    await StorageService.instance.saveDocuments(<Document>[
      docs.single.copyWith(progress: 0.80),
    ]);

    final LibraryRestoreResult r =
        await LibraryBackup.importFromZip(exported.path);
    expect(r.skippedDocuments, 1);
    expect(r.updatedDocuments, 0);

    final List<Document> after =
        await StorageService.instance.loadDocuments();
    expect(after.single.progress, closeTo(0.80, 1e-9),
        reason: '备份更旧时不能被覆盖回去');
  });

  test('备份进度更新：采纳备份的记录与进度', () async {
    await addBook('d1', '第一本', content: 'AAAA', progress: 0.90);
    await StorageService.instance.setPdfReadingSpot(
      'd1',
      pageIndex: 50,
      sentenceIndex: 7,
    );
    final LibraryBackupResult exported =
        await LibraryBackup.exportToDirectory(outDir.path);

    final List<Document> docs = await StorageService.instance.loadDocuments();
    await StorageService.instance.saveDocuments(<Document>[
      docs.single.copyWith(progress: 0.05),
    ]);

    final LibraryRestoreResult r =
        await LibraryBackup.importFromZip(exported.path);
    expect(r.updatedDocuments, 1);

    final List<Document> after =
        await StorageService.instance.loadDocuments();
    expect(after.single.progress, closeTo(0.90, 1e-9));
    final spot = StorageService.instance.pdfReadingSpot('d1');
    expect(spot!.pageIndex, 50, reason: '采纳了备份的记录，进度也应当跟着采纳');
  });

  test('同名但内容不同：另存为「名字 (1).pdf」，原文件不动', () async {
    await addBook('d1', '第一本', content: 'AAAA');
    final LibraryBackupResult exported =
        await LibraryBackup.exportToDirectory(outDir.path);

    // 本机换成同名但不同内容的文件，且把文档记录删掉
    final Directory books = Directory('${appDir.path}${Platform.pathSeparator}books');
    File('${books.path}${Platform.pathSeparator}第一本.pdf')
        .writeAsBytesSync(Uint8List.fromList(utf8.encode('BBBBBB')));
    await StorageService.instance.saveDocuments(<Document>[]);

    final LibraryRestoreResult r =
        await LibraryBackup.importFromZip(exported.path);
    expect(r.filesWritten, 1, reason: '不同内容要另存，不能覆盖原文件');

    final List<Document> docs = await StorageService.instance.loadDocuments();
    expect(docs, hasLength(1));
    expect(docs.single.path, contains('第一本 (1).pdf'));
    expect(File(docs.single.path).readAsStringSync(), 'AAAA');
    expect(
      File('${books.path}${Platform.pathSeparator}第一本.pdf').readAsStringSync(),
      'BBBBBB',
      reason: '本机原有文件必须原封不动',
    );
  });

  test('损坏的包：明确报错，且不动现有书库', () async {
    await addBook('d1', '第一本');
    final int before =
        (await StorageService.instance.loadDocuments()).length;

    final File bad = File('${outDir.path}${Platform.pathSeparator}bad.zip')
      ..writeAsBytesSync(Uint8List.fromList(<int>[1, 2, 3, 4, 5]));

    await expectLater(
      LibraryBackup.importFromZip(bad.path),
      throwsA(isA<LibraryBackupException>()),
    );
    expect((await StorageService.instance.loadDocuments()).length, before,
        reason: '坏包不能改动现有书库');
  });

  test('版本过高的包：报错并说明原因', () async {
    final Archive a = Archive();
    final Uint8List meta = Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'schemaVersion': 999})),
    );
    a.addFile(ArchiveFile(LibraryBackup.metaEntry, meta.length, meta));
    final File f = File('${outDir.path}${Platform.pathSeparator}future.zip')
      ..writeAsBytesSync(Uint8List.fromList(ZipEncoder().encode(a)!.toList()));

    await expectLater(
      LibraryBackup.importFromZip(f.path),
      throwsA(
        isA<LibraryBackupException>()
            .having((LibraryBackupException e) => e.message, 'message',
                contains('版本')),
      ),
    );
  });

  test('不是本站的包：缺 meta.json 时明确报错', () async {
    final Archive a = Archive();
    final Uint8List junk = Uint8List.fromList(utf8.encode('hello'));
    a.addFile(ArchiveFile('books/x.pdf', junk.length, junk));
    final File f = File('${outDir.path}${Platform.pathSeparator}other.zip')
      ..writeAsBytesSync(Uint8List.fromList(ZipEncoder().encode(a)!.toList()));

    await expectLater(
      LibraryBackup.importFromZip(f.path),
      throwsA(
        isA<LibraryBackupException>().having(
          (LibraryBackupException e) => e.message,
          'message',
          contains('meta.json'),
        ),
      ),
    );
  });

  test('阅读样式：书库为空时才套用，否则保持本机', () async {
    await addBook('d1', '第一本');
    final LibraryBackupResult exported =
        await LibraryBackup.exportToDirectory(outDir.path);

    // 本机还有书 → 不套用
    final LibraryRestoreResult withBooks =
        await LibraryBackup.importFromZip(exported.path);
    expect(withBooks.styleApplied, isFalse,
        reason: '书库非空时不该覆盖用户当前的排版习惯');

    // 清空 → 套用
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    final LibraryRestoreResult empty =
        await LibraryBackup.importFromZip(exported.path);
    expect(empty.styleApplied, isTrue);
  });

  test('记录在、文件不在：照常导入但计入 missingFiles', () async {
    final Document ghost = Document(
      id: 'ghost',
      title: '丢了文件的记录',
      path: '${appDir.path}${Platform.pathSeparator}books${Platform.pathSeparator}ghost.pdf',
      type: DocumentType.pdf,
      importedAt: DateTime(2026, 1, 1),
    );
    await StorageService.instance.saveDocuments(<Document>[ghost]);

    final LibraryBackupResult exported =
        await LibraryBackup.exportToDirectory(outDir.path);
    expect(exported.missingFiles, contains('丢了文件的记录'));

    final LibraryRestoreResult r =
        await LibraryBackup.importFromZip(exported.path);
    expect(r.missingFiles, 1);
    final List<Document> docs = await StorageService.instance.loadDocuments();
    expect(docs.any((Document d) => d.id == 'ghost'), isTrue,
        reason: '记录本身有价值（进度/书名），不能因为文件丢了就丢掉记录');
  });
}

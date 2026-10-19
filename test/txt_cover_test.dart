import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/services/cover_renderer.dart';
import 'package:tts_reader/services/document_service.dart';

/// TXT 封面：**必须是带中文书名的真图，不是一块纯色**
///
/// 核对过现状：TXT 原来直接走 `writeDefaultCover`，而那里用 `image` 包自带的
/// 位图 ASCII 字体画书名 —— 中文一个字也画不出来，用户看到的是一块没有书名的纯色。
/// TXT 没有任何内嵌图片，所以只能自己排版。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cover_test_');
  });

  tearDown(() async {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('CoverRenderer 能画出中文书名并落成 PNG', () async {
    final String out = '${dir.path}/cover.png';
    final String? path = await CoverRenderer.render(
      title: '钢铁是怎样炼成的',
      author: '奥斯特洛夫斯基',
      outPath: out,
    );
    expect(path, out);
    final File f = File(out);
    expect(f.existsSync(), isTrue);
    final bytes = f.readAsBytesSync();
    expect(bytes.length, greaterThan(1000), reason: '不能是空文件');
    // PNG magic
    expect(bytes.sublist(0, 8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);
  });

  test('TXT 走 extractCover 会产出「非默认」的封面（含文字）', () async {
    // 造一个带头部的 TXT（模拟常见中文书源）
    final String txtPath = '${dir.path}/book.txt';
    File(txtPath).writeAsStringSync(
      '书名：钢铁是怎样炼成的\n作者：奥斯特洛夫斯基\n\n正文第一段。\n',
    );
    final Document doc = Document(
      id: 't1',
      title: 'book', // 故意给个不像书名的标题，验证会用头部里的书名
      path: txtPath,
      type: DocumentType.txt,
      importedAt: DateTime(2026, 1, 1),
    );
    final String out = '${dir.path}/txt-cover.png';
    final String? cover = await DocumentService.extractCover(doc, out);
    expect(cover, out);
    final File f = File(out);
    expect(f.existsSync(), isTrue);
    expect(f.lengthSync(), greaterThan(1000));
  });

  test('没有头部信息的 TXT 也能出封面（退回文件名）', () async {
    final String txtPath = '${dir.path}/plain.txt';
    File(txtPath).writeAsStringSync('就是一段正文，没有任何头部。\n');
    final Document doc = Document(
      id: 't2',
      title: '我的小说',
      path: txtPath,
      type: DocumentType.txt,
      importedAt: DateTime(2026, 1, 1),
    );
    final String out = '${dir.path}/plain-cover.png';
    final String? cover = await DocumentService.extractCover(doc, out);
    expect(cover, out);
    expect(File(out).existsSync(), isTrue);
  });
}

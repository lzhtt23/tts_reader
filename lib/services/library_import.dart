import 'dart:io';

import '../models/document.dart';
import 'document_service.dart';
import 'file_naming.dart';
import 'library_storage.dart';
import 'storage_service.dart';

/// 把一个**已经在磁盘上**的文件收进文档库（复制进 books/ 并登记）
///
/// 从 `HomePage._import()` 里抽出来的：那里原本是 file_picker 专用的一段逻辑，
/// 而局域网传书（[LanUploadServer] 落盘后）走的是同一条路 —— 复制进应用私有目录、
/// 生成 Document、写进文档库。抽成函数是为了**两处不各写一套**（书库路径规则
/// 一旦分叉，就会出现「选择器导入的书能打开、传书导入的打不开」）。
///
/// 返回登记后的文档；调用方负责刷新列表与补封面。
class LibraryImport {
  LibraryImport._();

  /// 递增序号：同一微秒内连续上传多个文件也不会撞 id
  static int _seq = 0;

  static Future<Document> importPath(String path, {String? name}) async {
    final String displayName =
        (name != null && name.trim().isNotEmpty) ? name.trim() : '';
    final Document draft = Document(
      id: '${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
      title: displayName.isEmpty
          ? DocumentService.titleFromPath(path)
          : FileNaming.titleOf(displayName),
      path: path,
      type: DocumentType.fromExtension(path),
      importedAt: DateTime.now(),
    );
    // 收进应用私有目录：临时目录会被系统清掉，不收进去就是死链接
    final AdoptResult adopted = await LibraryStorage.adopt(path, name: displayName.isEmpty ? null : displayName);
    final Document stored = adopted.path.isEmpty || adopted.path == path
        ? draft
        : draft.copyWith(
            path: adopted.path,
            type: DocumentType.fromExtension(adopted.path),
          );
    await StorageService.instance.upsertDocument(stored);
    // 临时文件已经复制进书库，删掉避免占空间（删不掉也无所谓）
    if (adopted.ok && adopted.path != path) {
      try {
        final File tmp = File(path);
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
    }
    return stored;
  }
}

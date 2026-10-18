import 'package:flutter/foundation.dart';

import '../models/source_rule.dart';
import 'crash_log.dart';
import 'source_client.dart';

/// 在线书下载状态
enum OnlineDownloadStatus { running, done, failed }

/// 一条在线书下载**记录**
///
/// ## 这不是队列
///
/// 用户明确要求：下载仍在书籍详情页里**当场做完**（不要改成后台排队）。
/// 这个类只做一件事 —— **记账**：谁在下载、下到第几章、下完没有，
/// 好让发现页的「下载列表」能把这些统一列出来。
///
/// 所以：
/// * 真正的抓取代码只有一份，在 `BookIntroPage._download()`；
/// * 这里只有 `start / progress / finish / fail` 四个记账方法；
/// * 进程被杀就当没下过（半截文件不留用）。
class OnlineDownloadRecord {
  OnlineDownloadRecord({
    required this.id,
    required this.bookName,
    required this.bookUrl,
    required this.sourceUrl,
    required this.sourceName,
    this.total = 0,
    this.done = 0,
    this.status = OnlineDownloadStatus.running,
    this.error,
    this.documentId,
  });

  final String id;
  final String bookName;
  final String bookUrl;
  final String sourceUrl;
  final String sourceName;

  int total;
  int done;
  OnlineDownloadStatus status;
  String? error;

  /// 完成后写入文档库的 id
  String? documentId;

  bool get isActive => status == OnlineDownloadStatus.running;

  double? get fraction => total <= 0 ? null : (done / total).clamp(0.0, 1.0);
}

/// 在线书下载的记录表（全局唯一，供发现页「下载列表」展示）
class OnlineDownloadRecords extends ChangeNotifier {
  OnlineDownloadRecords._();

  static final OnlineDownloadRecords instance = OnlineDownloadRecords._();

  final List<OnlineDownloadRecord> _items = <OnlineDownloadRecord>[];

  List<OnlineDownloadRecord> get items =>
      List<OnlineDownloadRecord>.unmodifiable(_items);

  /// 开始下载：登记一条并返回它（调用方拿着它更新进度）
  OnlineDownloadRecord start({
    required SourceRule source,
    required OnlineBook book,
  }) {
    // 同一本书只留最新那条：重复点下载不该出现两行
    _items.removeWhere(
      (OnlineDownloadRecord r) => r.bookUrl == book.url && r.isActive,
    );
    final OnlineDownloadRecord record = OnlineDownloadRecord(
      id: '${book.url}#${DateTime.now().millisecondsSinceEpoch}',
      bookName: book.name,
      bookUrl: book.url,
      sourceUrl: source.url,
      sourceName: source.displayName,
    );
    _items.insert(0, record);
    notifyListeners();
    CrashLog.mark('在线下载[记账·开始] ${book.name} 源=${source.displayName}');
    return record;
  }

  void progress(OnlineDownloadRecord record, {required int done, int? total}) {
    record.done = done;
    if (total != null) record.total = total;
    notifyListeners();
  }

  void finish(OnlineDownloadRecord record, String documentId, {int? failed}) {
    record.documentId = documentId;
    record.status = OnlineDownloadStatus.done;
    if (failed != null && failed > 0) record.error = '$failed 章失败';
    notifyListeners();
    CrashLog.mark('在线下载[记账·完成] ${record.bookName}');
  }

  void fail(OnlineDownloadRecord record, Object error) {
    record.status = OnlineDownloadStatus.failed;
    record.error = '$error';
    notifyListeners();
    CrashLog.mark('在线下载[记账·失败] ${record.bookName} $error');
  }

  void remove(String id) {
    _items.removeWhere((OnlineDownloadRecord r) => r.id == id);
    notifyListeners();
  }

  void clearFinished() {
    _items.removeWhere((OnlineDownloadRecord r) => !r.isActive);
    notifyListeners();
  }
}

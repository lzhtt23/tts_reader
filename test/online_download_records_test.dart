import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/source_rule.dart';
import 'package:tts_reader/services/online_download_records.dart';
import 'package:tts_reader/services/source_client.dart';

/// 在线书下载「记账」（不是队列）
///
/// 用户明确要求：**不要改成入队**，下载仍在详情页里当场做完。
/// 这个表只负责让「发现 → 下载列表」看得到进度。
void main() {
  final SourceRule source = SourceRule.fromJson(<String, dynamic>{
    'bookSourceName': '测试源',
    'bookSourceUrl': 'http://src.com',
    'bookSourceType': 0,
  });
  const OnlineBook book = OnlineBook(
    name: '钢铁是怎样炼成的',
    url: 'http://src.com/book/1',
  );

  setUp(() {
    OnlineDownloadRecords.instance.clearFinished();
  });

  test('开始下载会登记一条 running 记录', () {
    final OnlineDownloadRecord r =
        OnlineDownloadRecords.instance.start(source: source, book: book);
    expect(r.status, OnlineDownloadStatus.running);
    expect(r.bookName, '钢铁是怎样炼成的');
    expect(r.sourceName, '测试源');
    expect(OnlineDownloadRecords.instance.items, hasLength(1));
  });

  test('进度能更新，分数正确', () {
    final OnlineDownloadRecord r =
        OnlineDownloadRecords.instance.start(source: source, book: book);
    OnlineDownloadRecords.instance.progress(r, done: 3, total: 10);
    expect(r.done, 3);
    expect(r.total, 10);
    expect(r.fraction, closeTo(0.3, 1e-9));
  });

  test('完成时记下文档 id，状态变 done', () {
    final OnlineDownloadRecord r =
        OnlineDownloadRecords.instance.start(source: source, book: book);
    OnlineDownloadRecords.instance.finish(r, 'online-123', failed: 2);
    expect(r.status, OnlineDownloadStatus.done);
    expect(r.documentId, 'online-123');
    expect(r.error, '2 章失败');
  });

  test('失败也有记录（不静默）', () {
    final OnlineDownloadRecord r =
        OnlineDownloadRecords.instance.start(source: source, book: book);
    OnlineDownloadRecords.instance.fail(r, '网络断了');
    expect(r.status, OnlineDownloadStatus.failed);
    expect(r.error, contains('网络断了'));
  });

  test('同一本书重复点下载：不会出现两行', () {
    OnlineDownloadRecords.instance.start(source: source, book: book);
    OnlineDownloadRecords.instance.start(source: source, book: book);
    expect(OnlineDownloadRecords.instance.items, hasLength(1));
  });

  test('清除已完成只留进行中的', () {
    final OnlineDownloadRecord a =
        OnlineDownloadRecords.instance.start(source: source, book: book);
    OnlineDownloadRecords.instance.finish(a, 'doc-a');
    OnlineDownloadRecords.instance.start(
      source: source,
      book: const OnlineBook(name: '另一本', url: 'http://src.com/book/2'),
    );
    expect(OnlineDownloadRecords.instance.items, hasLength(2));
    OnlineDownloadRecords.instance.clearFinished();
    expect(OnlineDownloadRecords.instance.items, hasLength(1));
    expect(OnlineDownloadRecords.instance.items.single.bookName, '另一本');
  });
}

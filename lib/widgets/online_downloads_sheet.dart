import 'package:flutter/material.dart';

import '../services/online_download_records.dart';
import 'wavy_progress.dart';

/// 在线书下载列表（发现页那个「下载列表」入口）
///
/// 用户要求：**在线书架/详情页触发的下载，统一归类到这里**。
/// 注意这不是队列面板 —— 下载本身在详情页里当场完成，
/// 这里只汇总「谁下过、下到哪、下完没」。
class OnlineDownloadsSheet extends StatelessWidget {
  const OnlineDownloadsSheet({super.key, required this.onOpenDocument});

  /// 打开下载完成的文档（由外层决定怎么打开）
  final void Function(String documentId) onOpenDocument;

  static const Key emptyKey = ValueKey<String>('online-downloads-empty');

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AnimatedBuilder(
      animation: OnlineDownloadRecords.instance,
      builder: (context, _) {
        final List<OnlineDownloadRecord> items =
            OnlineDownloadRecords.instance.items;
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.6,
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '下载列表（${items.length}）',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      if (items.isNotEmpty)
                        TextButton(
                          onPressed:
                              OnlineDownloadRecords.instance.clearFinished,
                          child: const Text('清除已完成'),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: _body(context, theme, items)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    ThemeData theme,
    List<OnlineDownloadRecord> items,
  ) {
    if (items.isEmpty) {
      return Center(
        key: OnlineDownloadsSheet.emptyKey,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.download_done, size: 56, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text('还没有下载记录', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(
                '在书籍详情页点「下载」，这里就能看到进度',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final OnlineDownloadRecord r = items[index];
        return ListTile(
          title: Text(r.bookName, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SizedBox(height: 4),
              LinearWavyProgressIndicator(
                value: r.status == OnlineDownloadStatus.done ? 1 : r.fraction,
              ),
              const SizedBox(height: 4),
              Text(
                _statusText(r),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          trailing: r.status == OnlineDownloadStatus.done &&
                  r.documentId != null
              ? IconButton(
                  tooltip: '移除记录',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () =>
                      OnlineDownloadRecords.instance.remove(r.id),
                )
              : IconButton(
                  tooltip: '移除',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () =>
                      OnlineDownloadRecords.instance.remove(r.id),
                ),
          onTap: r.status == OnlineDownloadStatus.done && r.documentId != null
              ? () => onOpenDocument(r.documentId!)
              : null,
        );
      },
    );
  }

  String _statusText(OnlineDownloadRecord r) {
    switch (r.status) {
      case OnlineDownloadStatus.running:
        return r.total <= 0
            ? '正在取目录… （源：${r.sourceName}）'
            : '下载中 ${r.done}/${r.total} 章 · 源：${r.sourceName}';
      case OnlineDownloadStatus.done:
        return r.error == null
            ? '已完成 · 已加入文档库'
            : '已完成（${r.error}）· 已加入文档库';
      case OnlineDownloadStatus.failed:
        return '失败：${r.error ?? "未知错误"}';
    }
  }
}

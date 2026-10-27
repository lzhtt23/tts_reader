import 'package:flutter/material.dart';

import '../models/structured_document.dart';
import '../widgets/toc_current_item.dart';

/// 目录面板：原书自带目录（PDF 书签 / EPUB nav 与 NCX）+ 章节 / 页数跳转
///
/// 独立成文件是为了能直接写 widget 测试（`test/toc_sheet_test.dart`）。
class TocSheet extends StatefulWidget {
  const TocSheet({
    super.key,
    required this.document,
    required this.cursor,
    required this.paragraphsPerPage,
  });

  final StructuredDocument document;
  final (int, int, int) cursor;
  final int paragraphsPerPage;

  @override
  State<TocSheet> createState() => _TocSheetState();
}

class _TocSheetState extends State<TocSheet> {
  late final TextEditingController _pageInput = TextEditingController(
    text:
        '${widget.document.pageOf(widget.cursor.$1, widget.cursor.$2, widget.paragraphsPerPage)}',
  );
  final TextEditingController _search = TextEditingController();

  /// 原书自带的目录（PDF 书签 / EPUB 的 nav 与 NCX）有内容时默认显示它
  late bool _showOutline = widget.document.hasOutline;

  /// 章号过滤结果；为空表示不过滤
  late List<int> _matches = const <int>[];

  /// 目录条目过滤结果
  late List<DocumentOutlineEntry> _outlineMatches =
      const <DocumentOutlineEntry>[];

  /// 总页数只算一次：几千章的 TXT 每次 build 都重算会明显卡
  late final int _totalPages = widget.document.chapterIsPage
      ? widget.document.chapters.length
      : widget.document.totalPages(widget.paragraphsPerPage);

  /// 目录列表的滚动控制（v1.22.62：打开时把「正在读的那一章」滚到正中）
  final ScrollController _scroll = ScrollController();

  /// 挂在「当前章」那一行上；`ensureVisible` 用它精确定位
  ///
  /// 为什么用 GlobalKey 而不是「行高 × 序号」算偏移：章节行是 ExpansionTile，
  /// 展开后高度不定，估算必然偏；`ensureVisible(alignment: 0.5)` 直接按真实
  /// 布局把目标放到视口正中，对任意行高都成立。
  final GlobalKey _currentKey = GlobalKey();

  /// 只在首次打开时居中一次；用户之后自己滚动不再打扰
  bool _centeredOnCurrent = false;

  @override
  void initState() {
    super.initState();
    // 与 PDF 目录对齐的行为：打开时当前章显示在正中（用户 2026-10-27）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _centerOnCurrent());
  }

  /// 把「当前章」滚到视口正中
  ///
  /// 两步走：`ListView.builder` 只构建可见项，所以先按估算跳一次把目标拉进构建范围，
  /// 等一帧后再用 `ensureVisible(alignment: 0.5)` 精确居中。
  Future<void> _centerOnCurrent() async {
    if (_centeredOnCurrent) return;
    if (!mounted || !_scroll.hasClients) return;
    _centeredOnCurrent = true;
    final current = widget.cursor.$1;
    // 估算跳：行高按 72dp 粗算，clamp 到合法范围
    const double estimate = 72;
    final max = _scroll.position.maxScrollExtent;
    var target = current * estimate -
        _scroll.position.viewportDimension / 2 +
        estimate / 2;
    if (target < 0) target = 0;
    if (target > max) target = max;
    _scroll.jumpTo(target);
    await WidgetsBinding.instance.endOfFrame;
    final BuildContext? ctx = _currentKey.currentContext;
    // 这里的 ctx 来自 GlobalKey（不是本 State 的 build context），
    // 所以按它自己的 mounted 判断有效性，而不是本 State 的 mounted。
    if (ctx == null || !ctx.mounted) return;
    // ignore: use_build_context_synchronously
    await Scrollable.ensureVisible(ctx, alignment: 0.5);
  }

  @override
  void dispose() {
    _pageInput.dispose();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _applySearch(String value) {
    final keyword = value.trim().toLowerCase();
    if (keyword.isEmpty) {
      setState(() {
        _matches = const <int>[];
        _outlineMatches = const <DocumentOutlineEntry>[];
      });
      return;
    }
    final document = widget.document;
    final chapters = document.chapters;
    final matches = <int>[];
    for (var i = 0; i < chapters.length; i++) {
      if (chapters[i].title.toLowerCase().contains(keyword)) matches.add(i);
      // 目录搜索只在用户输入时跑一次，几千章也是毫秒级；上限避免极端情况拖住界面
      if (matches.length >= 500) break;
    }
    final outline = <DocumentOutlineEntry>[];
    for (final entry in document.outline) {
      if (entry.title.toLowerCase().contains(keyword)) outline.add(entry);
      if (outline.length >= 500) break;
    }
    setState(() {
      _matches = matches;
      _outlineMatches = outline;
    });
  }

  void _jumpToPage() {
    final page = int.tryParse(_pageInput.text.trim());
    if (page == null || page < 1) return;
    final document = widget.document;
    if (document.chapterIsPage) {
      final index = page > document.chapters.length
          ? document.chapters.length - 1
          : page - 1;
      Navigator.pop(context, (index, 0));
      return;
    }
    final perPage = widget.paragraphsPerPage;
    if (perPage < 1 || _totalPages < 1) return;
    // 页码指「整篇第几页」：先夹取到有效范围（越界跳最后一页而不是回到开头），
    // 再逐章累加定位。全程只做算术，不构造区间列表 —— 几千章的书也是微秒级。
    // 注意别用 clamp()：它返回 num，后面和下标混用会被判成 double。
    final lastPage = _totalPages - 1;
    final raw = page - 1;
    final target = raw < 0 ? 0 : (raw > lastPage ? lastPage : raw);
    var acc = 0;
    for (var c = 0; c < document.chapters.length; c++) {
      final count = document.pageCountOf(c, perPage);
      if (acc + count > target) {
        Navigator.pop(
            context, (c, document.pageStartOf(c, target - acc, perPage) ?? 0));
        return;
      }
      acc += count;
    }
    Navigator.pop(context, (document.chapters.length - 1, 0));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final document = widget.document;
    final perPage = widget.paragraphsPerPage;
    final asPages = document.chapterIsPage;
    final current = widget.cursor.$1;

    // ★v1.22.62：不再自己钉死高度 —— 由调用方决定（阅读页给的是悬浮卡片的
    // 62% 屏幕高；测试里给了别的约束）。原来写死 0.75 会和外层卡片打架。
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: <Widget>[
              Text('目录', style: theme.textTheme.titleLarge),
              const Spacer(),
              Text(
                asPages
                    ? '共 ${document.chapters.length} 页'
                    : '共 ${document.chapters.length} 章',
                style: theme.textTheme.labelMedium,
              ),
            ],
          ),
        ),
        // 原书自带目录（PDF 书签 / EPUB nav 与 NCX）与「我们自己切的章节」是两套东西，
        // 有目录时让用户自己选看哪一套
        if (document.hasOutline)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SegmentedButton<bool>(
              segments: <ButtonSegment<bool>>[
                ButtonSegment<bool>(
                  value: true,
                  icon: const Icon(Icons.list_alt, size: 18),
                  label: Text('原书目录（${document.outline.length}）'),
                ),
                ButtonSegment<bool>(
                  value: false,
                  icon: const Icon(Icons.menu_book_outlined, size: 18),
                  label: Text(asPages ? '全部页码' : '章节'),
                ),
              ],
              selected: <bool>{_showOutline},
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  setState(() => _showOutline = selection.first),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _pageInput,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.go,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: '跳转到第几页',
                    helperText: asPages
                        ? '当前第 ${current + 1} 页，共 ${document.chapters.length} 页'
                        : '当前第 ${document.pageOf(current, widget.cursor.$2, perPage)} 页 / 全篇 $_totalPages 页（每页 $perPage 段）',
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _jumpToPage(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _jumpToPage, child: const Text('跳转')),
            ],
          ),
        ),
        // 几千章的小说（或几百条的原书目录）没有搜索就只能靠翻，这里给个过滤器
        if (!asPages &&
            (document.chapters.length >= 20 || document.outline.length >= 20))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                labelText: '搜索章节名',
                helperText: _matches.isEmpty
                    ? '输入章名关键字，例如「第 3 章」「风起」'
                    : '匹配到 ${_matches.length} 章${_matches.length >= 500 ? '（只显示前 500 条）' : ''}',
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _search.clear();
                          _applySearch('');
                        },
                      ),
                border: const OutlineInputBorder(),
              ),
              onChanged: _applySearch,
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: _showOutline && document.hasOutline
              ? _outlineList(document, current, perPage, scheme, theme)
              : asPages
                  ? _pageList(document, current, scheme, theme)
                  : _chapterList(document, current, perPage, scheme, theme),
        ),
      ],
    );
  }

  /// 原书自带的目录：按层级缩进，点一下跳到对应章节 / 页码
  Widget _outlineList(
    StructuredDocument document,
    int current,
    int perPage,
    ColorScheme scheme,
    ThemeData theme,
  ) {
    final searching = _search.text.trim().isNotEmpty;
    final entries = searching ? _outlineMatches : document.outline;
    if (entries.isEmpty) {
      return Center(
          child: Text(searching ? '目录里没有匹配的条目' : '这本书没有自带目录',
              style: theme.textTheme.bodyMedium));
    }
    return ListView.builder(
      controller: _scroll,
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final active = entry.chapter == current;
        // 缩进按层级，最多 4 级，再深就都按 4 级对齐（省得标题被挤没）
        final indent = 16.0 + (entry.depth > 4 ? 4 : entry.depth) * 16.0;
        // ★当前章节标识（淡色圆角背景 + 加粗 + graphic_eq）：三处目录共用同一套装饰
        return TocCurrentItem(
          key: active ? _currentKey : null,
          active: active,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.only(left: indent, right: 16),
            title: Text(
              entry.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: active
                  ? TextStyle(
                      color: scheme.primary, fontWeight: FontWeight.w600)
                  : null,
            ),
            subtitle: Text(
              document.chapterIsPage
                  ? '第 ${entry.chapter + 1} 页'
                  : '第 ${entry.chapter + 1} 章',
              style: theme.textTheme.labelSmall,
            ),
            trailing: active
                ? Icon(TocCurrentItem.currentIcon,
                    size: 18, color: scheme.primary)
                : null,
            onTap: () =>
                Navigator.pop(context, (entry.chapter, entry.paragraph)),
          ),
        );
      },
    );
  }

  /// PDF：直接列页码，点页即跳到该页朗读
  Widget _pageList(StructuredDocument document, int current, ColorScheme scheme,
      ThemeData theme) {
    return ListView.builder(
      controller: _scroll,
      itemCount: document.chapters.length,
      itemBuilder: (context, index) {
        final chapter = document.chapters[index];
        final active = index == current;
        return TocCurrentItem(
          key: active ? _currentKey : null,
          active: active,
          child: ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 14,
              backgroundColor:
                  active ? scheme.primary : scheme.surfaceContainerHighest,
              child: Text(
                '${index + 1}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
                ),
              ),
            ),
            title: Text(
              active ? '${chapter.title}（当前）' : chapter.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: active
                  ? TextStyle(
                      color: scheme.primary, fontWeight: FontWeight.w600)
                  : null,
            ),
            subtitle: Text('${chapter.paragraphs.length} 段'),
            trailing: active
                ? Icon(TocCurrentItem.currentIcon,
                    size: 18, color: scheme.primary)
                : null,
            onTap: () => Navigator.pop(context, (index, 0)),
          ),
        );
      },
    );
  }

  Widget _chapterList(
    StructuredDocument document,
    int current,
    int perPage,
    ColorScheme scheme,
    ThemeData theme,
  ) {
    // 搜索时只列匹配到的章节；否则列全部（ListView.builder 保证只构建可见项）。
    // 注意判据是「搜索框里有没有字」，不是「匹配结果空不空」——
    // 搜不到东西时要显示「没有匹配」，而不是把全部章节又列出来。
    final searching = _search.text.trim().isNotEmpty;
    final count = searching ? _matches.length : document.chapters.length;
    if (count == 0) {
      return Center(
        child: Text('没有匹配的章节', style: theme.textTheme.bodyMedium),
      );
    }
    return ListView.builder(
      controller: _scroll,
      itemCount: count,
      itemBuilder: (context, position) {
        final chapterIndex = searching ? _matches[position] : position;
        final chapter = document.chapters[chapterIndex];
        final active = chapterIndex == current;
        final pageCount = document.pageCountOf(chapterIndex, perPage);
        return ExpansionTile(
          key: active ? _currentKey : null,
          // 搜索时默认展开当前章，避免匹配结果还要再点一次
          initiallyExpanded: active,
          // ★ 当前章节整行加淡色圆角背景（与上面两处同源，见 TocCurrentItem）
          //
          // ⚠️ 这里**不能**用 TocCurrentItem 包起来：ExpansionTile 的子项
          // （那一章的页列表）会被一起染上背景色，看起来像"整个展开块都选中"。
          // 用户明确要求"只高亮章节 header，展开后的子项页列表不一起高亮"，
          // 所以走 backgroundColor / shape 这两个自带参数。
          backgroundColor: TocCurrentItem.fillColor(context, active),
          collapsedBackgroundColor: TocCurrentItem.fillColor(context, active),
          shape: TocCurrentItem.expansionShape(active, 12),
          collapsedShape: TocCurrentItem.expansionShape(active, 12),
          leading: CircleAvatar(
            radius: 14,
            backgroundColor:
                active ? scheme.primary : scheme.surfaceContainerHighest,
            child: Text(
              '${chapterIndex + 1}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
            ),
          ),
          // ⚠️ 图标放在 title 的 Row 里而不是 trailing：trailing 一旦给了值，
          // ExpansionTile 自带的展开箭头就没了。这里要**两者都有**。
          title: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  chapter.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: active
                      ? TextStyle(
                          color: scheme.primary, fontWeight: FontWeight.w600)
                      : null,
                ),
              ),
              if (active)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    TocCurrentItem.currentIcon,
                    size: 18,
                    color: scheme.primary,
                  ),
                ),
            ],
          ),
          subtitle: Text('${chapter.paragraphs.length} 段 · $pageCount 页'),
          // 章节内容很多时，展开后一次性塞几百个 ListTile 会卡：这里只在展开时才建，
          // 且页数少于 200 才逐页列出
          children: <Widget>[
            if (pageCount <= 200)
              for (var i = 0; i < pageCount; i++)
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 64, right: 16),
                  title: Text('第 ${i + 1} 页'),
                  subtitle: Text(
                    '第 ${i * perPage + 1}-${(i * perPage + perPage) > chapter.paragraphs.length ? chapter.paragraphs.length : i * perPage + perPage} 段',
                  ),
                  // ⚠️ 子项**不带任何"当前"标识**：用户要求只高亮章节 header。
                  // （原来这里有个 play_arrow 标"当前页"，与"只标章节"冲突，
                  //   而且它是另一个图标 —— 三处目录共用一个图标这条规矩不允许。）
                  onTap: () =>
                      Navigator.pop(context, (chapterIndex, i * perPage)),
                )
            else
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(left: 64, right: 16),
                title: const Text('这一章页数很多，用上面的页码直接跳'),
                onTap: () => Navigator.pop(context, (chapterIndex, 0)),
              ),
          ],
        );
      },
    );
  }
}

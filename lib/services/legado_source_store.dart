/// 书源持久化
///
/// ## ⚠️ 为什么用新键
///
/// 工程里已有 `StorageService._kBookSources = 'book_sources'`，存的是
/// `List<WebLink>`（浏览器书签式书源）。那套有自己的「一次性清理内置条目」
/// 逻辑（`_kBookSourcesPurged`），**只能跑一次**。
///
/// 如果把 legado 书源混进同一个键：
/// - `book_sources_defaults_test.dart` 会红（它断言内置条目被清掉）
/// - 用户已有的书签式书源会被 `SourceRule.fromJson` 解析成空对象
///
/// 所以这边**完全独立**的键，互不干扰。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/source_rule.dart';

/// legado 书源的本地存储
class LegadoSourceStore {
  LegadoSourceStore._();

  static final LegadoSourceStore instance = LegadoSourceStore._();

  /// 书源列表的键（与 `_kBookSources` 完全无关）
  static const String _kSources = 'legado_sources_v1';

  /// 当前在线书籍的键（阅读进度、所选书源）
  static const String _kOnlineBooks = 'legado_online_books_v1';

  SharedPreferences? _sp;

  Future<SharedPreferences> get _prefs async =>
      _sp ??= await SharedPreferences.getInstance();

  // ---------------- 书源 ----------------

  /// 读取全部书源
  Future<List<SourceRule>> load() async {
    try {
      final SharedPreferences sp = await _prefs;
      final String? raw = sp.getString(_kSources);
      if (raw == null || raw.isEmpty) return <SourceRule>[];

      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return <SourceRule>[];

      final List<SourceRule> out = <SourceRule>[];
      for (final Object? item in decoded) {
        if (item is Map) {
          final SourceRule rule = SourceRule.fromJson(
            item.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
          );
          if (rule.url.trim().isNotEmpty) out.add(rule);
        }
      }
      return out;
    } catch (_) {
      // 存档损坏时当空处理，不影响启动
      return <SourceRule>[];
    }
  }

  /// 以 url 为键的映射（供 `mergeSourceRules` 用）
  Future<Map<String, SourceRule>> loadByUrl() async {
    final List<SourceRule> all = await load();
    return <String, SourceRule>{
      for (final SourceRule r in all) r.url: r,
    };
  }

  /// 整体覆盖保存
  Future<void> saveAll(List<SourceRule> sources) async {
    final SharedPreferences sp = await _prefs;
    final String raw = jsonEncode(
      sources.map((SourceRule r) => r.toJson()).toList(),
    );
    await sp.setString(_kSources, raw);
  }

  /// 合并写入（新增 + 更新，保留其余的）
  Future<void> upsert(List<SourceRule> incoming) async {
    final Map<String, SourceRule> map = await loadByUrl();
    for (final SourceRule rule in incoming) {
      map[rule.url] = rule;
    }
    await saveAll(map.values.toList());
  }

  /// 删除一条
  Future<void> remove(String url) async {
    final Map<String, SourceRule> map = await loadByUrl();
    map.remove(url);
    await saveAll(map.values.toList());
  }

  /// 清空
  Future<void> clear() async {
    final SharedPreferences sp = await _prefs;
    await sp.remove(_kSources);
  }

  /// 可用（`isSupported`）的那部分
  Future<List<SourceRule>> loadUsable() async {
    final List<SourceRule> all = await load();
    return all.where((SourceRule r) => r.isSupported && r.enabled).toList();
  }

  // ---------------- 在线书籍 ----------------

  /// 书架里的在线书
  Future<List<OnlineBookRecord>> loadBooks() async {
    try {
      final SharedPreferences sp = await _prefs;
      final String? raw = sp.getString(_kOnlineBooks);
      if (raw == null || raw.isEmpty) return <OnlineBookRecord>[];
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return <OnlineBookRecord>[];
      return <OnlineBookRecord>[
        for (final Object? item in decoded)
          if (item is Map)
            OnlineBookRecord.fromJson(
              item.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
            ),
      ];
    } catch (_) {
      return <OnlineBookRecord>[];
    }
  }

  Future<void> saveBooks(List<OnlineBookRecord> books) async {
    final SharedPreferences sp = await _prefs;
    await sp.setString(
      _kOnlineBooks,
      jsonEncode(books.map((OnlineBookRecord b) => b.toJson()).toList()),
    );
  }

  Future<void> upsertBook(OnlineBookRecord book) async {
    final List<OnlineBookRecord> all = await loadBooks();
    final int index = all.indexWhere((OnlineBookRecord b) => b.url == book.url);
    if (index >= 0) {
      all[index] = book;
    } else {
      all.add(book);
    }
    await saveBooks(all);
  }

  Future<void> removeBook(String url) async {
    final List<OnlineBookRecord> all = await loadBooks();
    all.removeWhere((OnlineBookRecord b) => b.url == url);
    await saveBooks(all);
  }

  /// 记下「这本书已经整本下载」对应的本地文档 id
  ///
  /// 只对**已在书架**的书生效（不在书架就什么都不做）：
  /// 下载不该顺手把人加进书架（用户要求：在线阅读 ≠ 加入书架）。
  Future<bool> attachLocalDocument({
    required String bookUrl,
    required String documentId,
  }) async {
    final List<OnlineBookRecord> books = await loadBooks();
    final int at = books.indexWhere((OnlineBookRecord b) => b.url == bookUrl);
    if (at < 0) return false;
    books[at] = books[at].copyWith(localDocumentId: documentId);
    await saveBooks(books);
    return true;
  }

  /// 本地文档被删除时，把在线书架里指向它的「已下载」标记清掉
  ///
  /// ⚠️ **只清标记，绝不把书移出书架**（用户明确要求）：
  /// 删的是本地那份文件，书架上的收藏还在 —— 之后再点开就回到在线阅读。
  ///
  /// 返回被清掉标记的条数。
  Future<int> detachLocalDocumentByDocumentId(String documentId) async {
    if (documentId.isEmpty) return 0;
    final List<OnlineBookRecord> books = await loadBooks();
    var changed = 0;
    for (var i = 0; i < books.length; i++) {
      if (books[i].localDocumentId == documentId) {
        books[i] = books[i].copyWith(localDocumentId: '');
        changed++;
      }
    }
    if (changed > 0) await saveBooks(books);
    return changed;
  }

  ///
  /// ⚠️ 关键语义：**在线阅读 ≠ 加入书架**。
  /// 打开读页就自动写记录的话，用户随便点开一本，书架就被塞满了 ——
  /// 书架应当是「我自己选的」，不是「我碰过的」。
  ///
  /// 返回是否真的更新了（false = 这本不在书架里，什么都不做）。
  Future<bool> updateBookProgress({
    required String url,
    int? chapterIndex,
    int? paragraph,
    int? sentence,
    String? chapterName,
  }) async {
    final List<OnlineBookRecord> books = await loadBooks();
    final int at = books.indexWhere((OnlineBookRecord b) => b.url == url);
    if (at < 0) return false;
    books[at] = books[at].copyWith(
      chapterIndex: chapterIndex,
      paragraph: paragraph,
      sentence: sentence,
      chapterName: chapterName,
    );
    await saveBooks(books);
    return true;
  }

  /// 测试用：清空两个键
  Future<void> clearAllForTest() async {
    final SharedPreferences sp = await _prefs;
    await sp.remove(_kSources);
    await sp.remove(_kOnlineBooks);
  }

  /// 测试用：丢弃缓存的 SharedPreferences 实例
  ///
  /// `SharedPreferences.setMockInitialValues()` 会换上新的底层存储，
  /// 但本类缓存了旧实例，不丢就会读到旧数据。
  void refreshForTest() {
    _sp = null;
  }
}

/// 书架里的一条在线书（只存元数据，正文按需抓）
class OnlineBookRecord {
  const OnlineBookRecord({
    required this.url,
    required this.name,
    required this.sourceUrl,
    this.author = '',
    this.coverUrl = '',
    this.chapterIndex = 0,
    this.paragraph = 0,
    this.sentence = 0,
    this.chapterName = '',
    this.addedAt,
    this.localDocumentId,
  });

  /// 书籍详情页地址（主键）
  final String url;
  final String name;

  /// 用哪个书源抓的
  final String sourceUrl;

  final String author;
  final String coverUrl;

  /// 阅读进度：章 / 段 / 句（对齐 `StructuredDocument` 游标）
  final int chapterIndex;
  final int paragraph;
  final int sentence;

  final String chapterName;
  final DateTime? addedAt;

  /// 整本下载后写进本地文档库的那本的 id
  ///
  /// 有值 = 已下载：列表要标「已下载」，点开直接读本地那份，不再联网解析。
  /// 文档可能被用户从文档库删掉，所以用到时要**再确认存在**。
  final String? localDocumentId;

  bool get isDownloaded => (localDocumentId ?? '').isNotEmpty;

  OnlineBookRecord copyWith({
    int? chapterIndex,
    int? paragraph,
    int? sentence,
    String? chapterName,
    String? localDocumentId,
  }) => OnlineBookRecord(
    url: url,
    name: name,
    sourceUrl: sourceUrl,
    author: author,
    coverUrl: coverUrl,
    chapterIndex: chapterIndex ?? this.chapterIndex,
    paragraph: paragraph ?? this.paragraph,
    sentence: sentence ?? this.sentence,
    chapterName: chapterName ?? this.chapterName,
    addedAt: addedAt,
    localDocumentId: localDocumentId ?? this.localDocumentId,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': url,
    'name': name,
    'sourceUrl': sourceUrl,
    'author': author,
    'coverUrl': coverUrl,
    'chapterIndex': chapterIndex,
    'paragraph': paragraph,
    'sentence': sentence,
    'chapterName': chapterName,
    'addedAt': addedAt?.toIso8601String(),
    'localDocumentId': localDocumentId,
  };

  factory OnlineBookRecord.fromJson(Map<String, dynamic> json) =>
      OnlineBookRecord(
        url: json['url'] as String? ?? '',
        name: json['name'] as String? ?? '未命名',
        sourceUrl: json['sourceUrl'] as String? ?? '',
        author: json['author'] as String? ?? '',
        coverUrl: json['coverUrl'] as String? ?? '',
        chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
        paragraph: (json['paragraph'] as num?)?.toInt() ?? 0,
        sentence: (json['sentence'] as num?)?.toInt() ?? 0,
        chapterName: json['chapterName'] as String? ?? '',
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? ''),
        localDocumentId: json['localDocumentId'] as String?,
      );

  /// 存成 `StructuredDocument` 游标
  (int, int, int) get cursor => (chapterIndex, paragraph, sentence);

  @override
  String toString() => 'OnlineBookRecord($name <$url>)';
}

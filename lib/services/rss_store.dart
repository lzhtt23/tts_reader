import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/rss_source.dart';

/// 订阅源（RSS）的持久化
///
/// 与书源完全分开的键（`rss_sources_v1`），互不影响：
/// 书源坏了不影响订阅，订阅删了不影响搜书。
class RssStore {
  RssStore._();

  static final RssStore instance = RssStore._();

  static const String _kSources = 'rss_sources_v1';

  SharedPreferences? _sp;

  Future<SharedPreferences> get _prefs async =>
      _sp ??= await SharedPreferences.getInstance();

  /// 全部订阅源（含已禁用的）
  Future<List<RssSource>> load() async {
    try {
      final SharedPreferences sp = await _prefs;
      final String? raw = sp.getString(_kSources);
      if (raw == null || raw.isEmpty) return <RssSource>[];
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return <RssSource>[];
      final List<RssSource> out = <RssSource>[];
      for (final Object? item in decoded) {
        if (item is Map) {
          final RssSource s = RssSource.fromJson(
            item.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
          );
          if (s.sourceUrl.isNotEmpty) out.add(s);
        }
      }
      return out;
    } catch (_) {
      // 存档损坏当空处理，不影响启动
      return <RssSource>[];
    }
  }

  /// 能用的那部分：字段齐全 + 已启用
  Future<List<RssSource>> loadUsable() async {
    final List<RssSource> all = await load();
    return all.where((RssSource s) => s.isUsable && s.enabled).toList();
  }

  Future<void> saveAll(List<RssSource> sources) async {
    final SharedPreferences sp = await _prefs;
    await sp.setString(
      _kSources,
      jsonEncode(sources.map((RssSource s) => s.toJson()).toList()),
    );
  }

  /// 按 `sourceUrl` 合并：已存在就覆盖（新的 `lastUpdateTime` 更大时），否则追加
  ///
  /// 返回 `(added, updated)` 计数，给导入结果对话框用。
  Future<({int added, int updated})> merge(List<RssSource> incoming) async {
    final List<RssSource> all = await load();
    final Map<String, int> indexOf = <String, int>{
      for (var i = 0; i < all.length; i++) all[i].sourceUrl: i,
    };
    var added = 0;
    var updated = 0;
    for (final RssSource s in incoming) {
      final int? at = indexOf[s.sourceUrl];
      if (at == null) {
        indexOf[s.sourceUrl] = all.length;
        all.add(s);
        added++;
      } else {
        all[at] = s;
        updated++;
      }
    }
    await saveAll(all);
    return (added: added, updated: updated);
  }

  Future<void> remove(String sourceUrl) async {
    final List<RssSource> all = await load();
    all.removeWhere((RssSource s) => s.sourceUrl == sourceUrl);
    await saveAll(all);
  }

  /// 测试用：清空
  Future<void> clear() async {
    final SharedPreferences sp = await _prefs;
    await sp.remove(_kSources);
  }
}

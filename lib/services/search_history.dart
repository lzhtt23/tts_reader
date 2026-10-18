import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 搜索历史（本地保存，最多 30 条，最近的在前）
///
/// 单独一层是为了能离线单测：去重、置顶、上限、删除都在纯逻辑里。
class SearchHistory {
  SearchHistory._();

  static final SearchHistory instance = SearchHistory._();

  static const String _key = 'search_history_v1';

  /// 最多留多少条（再多对用户就是噪音）
  static const int maxItems = 30;

  SharedPreferences? _sp;

  Future<SharedPreferences> get _prefs async =>
      _sp ??= await SharedPreferences.getInstance();

  Future<List<String>> load() async {
    try {
      final SharedPreferences sp = await _prefs;
      final String? raw = sp.getString(_key);
      if (raw == null || raw.isEmpty) return <String>[];
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return <String>[];
      return decoded
          .whereType<String>()
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toList();
    } catch (_) {
      return <String>[];
    }
  }

  /// 记一条：已存在就**移到最前**（不重复），超出上限丢最旧的
  Future<List<String>> add(String keyword) async {
    final String k = keyword.trim();
    if (k.isEmpty) return load();
    final List<String> all = await load();
    all.removeWhere((String s) => s == k);
    all.insert(0, k);
    final List<String> trimmed = all.length > maxItems
        ? all.sublist(0, maxItems)
        : all;
    await _save(trimmed);
    return trimmed;
  }

  Future<List<String>> remove(String keyword) async {
    final List<String> all = await load();
    all.removeWhere((String s) => s == keyword);
    await _save(all);
    return all;
  }

  Future<void> clear() async {
    final SharedPreferences sp = await _prefs;
    await sp.remove(_key);
  }

  Future<void> _save(List<String> items) async {
    final SharedPreferences sp = await _prefs;
    await sp.setString(_key, jsonEncode(items));
  }

  /// 测试用：丢弃缓存实例
  void refreshForTest() {
    _sp = null;
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/search_history.dart';

/// 搜索历史：去重置顶、上限、删除
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SearchHistory.instance.refreshForTest();
  });

  test('空的时候是空列表', () async {
    expect(await SearchHistory.instance.load(), isEmpty);
  });

  test('新增的排在最前', () async {
    await SearchHistory.instance.add('书一');
    await SearchHistory.instance.add('书二');
    expect(await SearchHistory.instance.load(), <String>['书二', '书一']);
  });

  test('重复搜索同一句：置顶而不是多一条', () async {
    await SearchHistory.instance.add('书一');
    await SearchHistory.instance.add('书二');
    await SearchHistory.instance.add('书一');
    expect(await SearchHistory.instance.load(), <String>['书一', '书二']);
  });

  test('空白关键词不记', () async {
    await SearchHistory.instance.add('   ');
    expect(await SearchHistory.instance.load(), isEmpty);
  });

  test('超过上限只留最近的 30 条', () async {
    for (var i = 0; i < 35; i++) {
      await SearchHistory.instance.add('书$i');
    }
    final List<String> all = await SearchHistory.instance.load();
    expect(all.length, SearchHistory.maxItems);
    expect(all.first, '书34', reason: '最新的在最前');
    expect(all.contains('书0'), isFalse, reason: '最旧的被丢掉');
  });

  test('单条删除', () async {
    await SearchHistory.instance.add('甲');
    await SearchHistory.instance.add('乙');
    final List<String> rest = await SearchHistory.instance.remove('甲');
    expect(rest, <String>['乙']);
  });

  test('全部清空', () async {
    await SearchHistory.instance.add('甲');
    await SearchHistory.instance.clear();
    expect(await SearchHistory.instance.load(), isEmpty);
  });

  test('存档损坏时当空处理，不崩', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'search_history_v1': '这不是 JSON',
    });
    SearchHistory.instance.refreshForTest();
    expect(await SearchHistory.instance.load(), isEmpty);
  });
}

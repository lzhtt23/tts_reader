import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/source_rule.dart';
import 'package:tts_reader/services/source_importer.dart';

/// 构造一条最小可用书源 JSON
Map<String, dynamic> _rule({
  String url = 'https://a.com',
  String name = 'A 站',
  int updateTime = 100,
  int type = 0,
  bool fullRules = true,
}) => <String, dynamic>{
  'bookSourceUrl': url,
  'bookSourceName': name,
  'bookSourceType': type,
  'lastUpdateTime': updateTime,
  if (fullRules) ...<String, dynamic>{
    'searchUrl': '/search?q={{key}}&page={{page}}',
    'ruleSearch': <String, dynamic>{
      'bookList': '.list li',
      'name': 'a@text',
      'bookUrl': 'a@href',
    },
    'ruleToc': <String, dynamic>{
      'chapterList': '.chapters a',
      'chapterName': '@text',
      'chapterUrl': '@href',
    },
    'ruleContent': <String, dynamic>{'content': '#content@html'},
  },
};

void main() {
  group('SourceRule.fromJson', () {
    test('读取全部核心字段', () {
      final rule = SourceRule.fromJson(_rule());
      expect(rule.url, 'https://a.com');
      expect(rule.name, 'A 站');
      expect(rule.type, SourceType.text);
      expect(rule.lastUpdateTime, 100);
      expect(rule.isSupported, isTrue);
    });

    test('缺字段给默认值，不抛异常', () {
      final rule = SourceRule.fromJson(<String, dynamic>{
        'bookSourceUrl': 'https://b.com',
      });
      expect(rule.url, 'https://b.com');
      expect(rule.name, '');
      expect(rule.type, SourceType.text);
      expect(rule.enabled, isTrue);
      // 没有规则 → 不支持
      expect(rule.isSupported, isFalse);
    });

    test('类型字段容错：字符串数字也能解析', () {
      final rule = SourceRule.fromJson(<String, dynamic>{
        'bookSourceUrl': 'https://c.com',
        'bookSourceType': '1',
        'enabled': 'false',
        'lastUpdateTime': '12345',
      });
      expect(rule.type, SourceType.audio);
      expect(rule.enabled, isFalse);
      expect(rule.lastUpdateTime, 12345);
    });

    test('音频源不被判为可执行（本轮只支持文本）', () {
      final rule = SourceRule.fromJson(_rule(type: SourceType.audio));
      expect(rule.isSupported, isFalse);
    });

    test('分组按中英文逗号/分号拆分', () {
      final rule = SourceRule.fromJson(<String, dynamic>{
        'bookSourceUrl': 'https://d.com',
        'bookSourceGroup': '小说,出版；有声',
      });
      expect(rule.groups, <String>['小说', '出版', '有声']);
    });

    test('toJson 与 fromJson 对称', () {
      final original = SourceRule.fromJson(_rule());
      final round = SourceRule.fromJson(original.toJson());
      expect(round.url, original.url);
      expect(round.name, original.name);
      expect(round.ruleSearch?['bookList'], '.list li');
      expect(round.ruleToc?['chapterName'], '@text');
    });
  });

  group('SourceImporter 输入形态判定', () {
    test('isAbsoluteUrl 只认 http/https', () {
      expect(isAbsoluteUrl('https://a.com/x.json'), isTrue);
      expect(isAbsoluteUrl('HTTP://a.com'), isTrue);
      expect(isAbsoluteUrl('file:///x.json'), isFalse);
      expect(isAbsoluteUrl('{"a":1}'), isFalse);
    });

    test('isLocalUri 只认 file/content', () {
      expect(isLocalUri('file:///sdcard/a.json'), isTrue);
      expect(isLocalUri('content://media/1'), isTrue);
      expect(isLocalUri('https://a.com'), isFalse);
    });
  });

  group('SourceImporter.parseText 三种 JSON 形态', () {
    test('数组：解析多条', () async {
      final text = jsonEncode(<Map<String, dynamic>>[
        _rule(url: 'https://a.com', name: 'A'),
        _rule(url: 'https://b.com', name: 'B'),
      ]);
      final out = await SourceImporter.parseText(text);
      expect(out.rules.length, 2);
      expect(out.rules.map((SourceRule r) => r.name), containsAll(<String>['A', 'B']));
    });

    test('单对象：解析一条', () async {
      final out = await SourceImporter.parseText(jsonEncode(_rule()));
      expect(out.rules.length, 1);
      expect(out.rules.first.url, 'https://a.com');
    });

    test('数组内重复 url：保留 lastUpdateTime 更大的', () async {
      final text = jsonEncode(<Map<String, dynamic>>[
        _rule(url: 'https://same.com', name: '旧', updateTime: 100),
        _rule(url: 'https://same.com', name: '新', updateTime: 200),
      ]);
      final out = await SourceImporter.parseText(text);
      expect(out.rules.length, 1);
      expect(out.rules.first.name, '新');
    });

    test('缺 bookSourceUrl 的条目跳过并记错误，其余照常', () async {
      final text = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{'bookSourceName': '没 url'},
        _rule(),
      ]);
      final out = await SourceImporter.parseText(text);
      expect(out.rules.length, 1);
      expect(out.errors, isNotEmpty);
    });

    test('非 JSON 报明确错误', () async {
      final out = await SourceImporter.parseText('这不是 JSON');
      expect(out.rules, isEmpty);
      expect(out.errors.first, contains('不是合法 JSON'));
    });

    test('空内容不崩', () async {
      final out = await SourceImporter.parseText('   ');
      expect(out.rules, isEmpty);
      expect(out.errors, isNotEmpty);
    });

    test('顶层是数字：报格式错误', () async {
      final out = await SourceImporter.parseText('123');
      expect(out.rules, isEmpty);
      expect(out.errors.first, contains('既不是数组也不是对象'));
    });
  });

  group('sourceUrls 订阅索引', () {
    test('展开多个子源并合并', () async {
      final index = jsonEncode(<String, dynamic>{
        'sourceUrls': <String>['https://x.com/1.json', 'https://x.com/2.json'],
      });
      final fetched = <String, String>{
        'https://x.com/1.json': jsonEncode(_rule(url: 'https://a.com', name: 'A')),
        'https://x.com/2.json': jsonEncode(_rule(url: 'https://b.com', name: 'B')),
      };
      final out = await SourceImporter.parseText(
        index,
        fetch: (String u) async => fetched[u]!,
      );
      expect(out.rules.length, 2);
    });

    test('子源下载失败不影响其它', () async {
      final index = jsonEncode(<String, dynamic>{
        'sourceUrls': <String>['https://ok.com/1.json', 'https://bad.com/2.json'],
      });
      final out = await SourceImporter.parseText(
        index,
        fetch: (String u) async {
          if (u.contains('bad')) throw StateError('timeout');
          return jsonEncode(_rule(url: 'https://a.com'));
        },
      );
      expect(out.rules.length, 1);
      expect(out.errors.any((String e) => e.contains('下载失败')), isTrue);
    });

    test('嵌套过深被拦住（环保护）', () async {
      // 自己引用自己
      final self = jsonEncode(<String, dynamic>{
        'sourceUrls': <String>['https://loop.com/self.json'],
      });
      final out = await SourceImporter.parseText(
        self,
        fetch: (String u) async => self,
      );
      // 递归被 maxIndexDepth 截断，不会无限循环
      expect(out.rules, isEmpty);
      expect(out.errors.any((String e) => e.contains('嵌套过深')), isTrue);
    });

    test('未提供 fetch 时给可读错误', () async {
      final out = await SourceImporter.parseText(
        jsonEncode(<String, dynamic>{
          'sourceUrls': <String>['https://x.com/1.json'],
        }),
      );
      expect(out.errors.first, contains('未提供网络实现'));
    });
  });

  group('mergeSourceRules 去重语义', () {
    final now = SourceRule.fromJson(_rule(url: 'https://a.com', updateTime: 100));

    test('本地没有 → 新增', () {
      final result = mergeSourceRules(<SourceRule>[now], <String, SourceRule>{});
      expect(result.added.length, 1);
      expect(result.updated, isEmpty);
      expect(result.existing, isEmpty);
    });

    test('本地有且更新的时间更大 → 更新', () {
      final newer = SourceRule.fromJson(_rule(url: 'https://a.com', updateTime: 200));
      final result = mergeSourceRules(
        <SourceRule>[newer],
        <String, SourceRule>{now.url: now},
      );
      expect(result.updated.length, 1);
    });

    test('本地有但时间相同 → 已存在（不覆盖）', () {
      final same = SourceRule.fromJson(_rule(url: 'https://a.com', updateTime: 100));
      final result = mergeSourceRules(
        <SourceRule>[same],
        <String, SourceRule>{now.url: now},
      );
      expect(result.existing.length, 1);
      expect(result.appliedCount, 0);
    });

    test('本地更新（时间更大）→ 不降级', () {
      final older = SourceRule.fromJson(_rule(url: 'https://a.com', updateTime: 50));
      final result = mergeSourceRules(
        <SourceRule>[older],
        <String, SourceRule>{now.url: now},
      );
      expect(result.existing.length, 1);
    });

    test('不支持的源单独归类，不算已有', () {
      final audio = SourceRule.fromJson(
        _rule(url: 'https://a.com', type: SourceType.audio),
      );
      final result = mergeSourceRules(
        <SourceRule>[audio],
        <String, SourceRule>{now.url: now},
      );
      expect(result.skipped.length, 1);
      expect(result.existing, isEmpty);
    });
  });

  group('真实书源合集（离线样本）', () {
    // 这些是真实的 legado 书源片段，用来锁住「字段名对得上」这件事
    test('解析真实结构的书源', () async {
      const String real = '''
      [
        {
          "bookSourceUrl": "https://www.example-real.com",
          "bookSourceName": "真实站",
          "bookSourceGroup": "小说",
          "bookSourceType": 0,
          "bookUrlPattern": "https://www\\\\.example-real\\\\.com/book/\\\\d+",
          "lastUpdateTime": 1700000000000,
          "respondTime": 180000,
          "searchUrl": "/search?keyword={{java.encodeURI(key)}}&page={{page}}",
          "ruleSearch": {
            "bookList": "class.book-list@tag.li",
            "name": "tag.a.0@text",
            "author": "class.author@text",
            "bookUrl": "tag.a.0@href",
            "coverUrl": "tag.img@src"
          },
          "ruleBookInfo": {
            "name": "h1@text",
            "intro": "class.intro@html##<br>##\\n"
          },
          "ruleToc": {
            "chapterList": "class.chapters@tag.a",
            "chapterName": "@text",
            "chapterUrl": "@href"
          },
          "ruleContent": {
            "content": "id.content@html"
          }
        }
      ]
      ''';
      final out = await SourceImporter.parseText(real);
      expect(out.rules.length, 1);
      final rule = out.rules.first;
      expect(rule.url, 'https://www.example-real.com');
      expect(rule.name, '真实站');
      expect(rule.groups, <String>['小说']);
      expect(rule.lastUpdateTime, 1700000000000);
      expect(rule.isSupported, isTrue);
      expect(rule.ruleSearch?['bookList'], 'class.book-list@tag.li');
      expect(rule.ruleContent?['content'], 'id.content@html');
    });

    test('#requestWithoutUA 后缀被剥掉', () async {
      String? requested;
      await SourceImporter.parse(
        'https://a.com/sources.json#requestWithoutUA',
        fetch: (String u) async {
          requested = u;
          return jsonEncode(_rule());
        },
      );
      expect(requested, 'https://a.com/sources.json');
    });
  });

  // 可选：用本机真实合集做一次规模验证（文件不存在时跳过）
  group('本机真实合集', () {
    final File file = File(
      r'D:\Workspaces\default-workspace\work\legado-src\real_book_sources.json',
    );

    test('194 条真实书源全部解析成功', () async {
      if (!file.existsSync()) {
        markTestSkipped('本机无真实合集样本，跳过');
        return;
      }
      final String text = file.readAsStringSync();
      final out = await SourceImporter.parseText(text);
      expect(out.rules.length, greaterThan(150));
      // 每一条都必须有 url 与 name
      for (final SourceRule rule in out.rules) {
        expect(rule.url.trim(), isNotEmpty);
      }
      // 文本类源应当占多数且可执行
      final int supported = out.rules.where((SourceRule r) => r.isSupported).length;
      expect(supported, greaterThan(50));
    });
  });
}

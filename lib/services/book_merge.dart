/// 搜索结果的「聚合」与「匹配度排序」
///
/// ## 为什么单独抽出来
///
/// 这两件事都是**纯计算**，跟 UI 无关，却最容易写错：
/// - 聚合键怎么归一（空格、全半角、大小写）
/// - 匹配度怎么排（搜《钢铁是怎样炼成的》时，《飞刀是怎样炼成的》不能压过正主）
///
/// 抽成纯函数就能拿真实书名离线跑用例，不用起界面、不用联网。
library;

/// 聚合用的键：去掉所有空白 + 统一小写
///
/// 同名书在不同源里常带不同空格/换行（「钢铁是怎样炼成的 」「钢铁是怎样炼成的」），
/// 不归一就会被当成两本。
String mergeKey(String name) =>
    name.replaceAll(RegExp(r'\s+'), '').toLowerCase().trim();

/// 名字匹配度（越大越靠前）
///
/// 分档：
/// | 情况 | 分值 |
/// | --- | --- |
/// | 完全相同 | 1000 |
/// | 前缀匹配 | 900 − 多出来的字数 |
/// | 包含 | 800 − 多出来的字数 |
/// | 只有部分字相同 | 按共有字比例（可能为负） |
///
/// 「多出来的字数」封顶 200：避免名字特别长的书被压得过低。
int nameMatchScore(String keyword, String name) {
  final String k = mergeKey(keyword);
  final String n = mergeKey(name);
  if (k.isEmpty || n.isEmpty) return 0;
  if (n == k) return 1000;
  final int extra = (n.length - k.length).clamp(0, 200);
  if (n.startsWith(k)) return 900 - extra;
  if (n.contains(k)) return 800 - extra;

  // 只数「关键词里的字在书名里出现没出现」，不重复计数
  final Set<String> chars = k.split('').toSet();
  final int hit = chars.where(n.contains).length;
  return ((hit * 700) ~/ k.length) - 300;
}

/// 排序：匹配度 → 源数 → 书名
///
/// 抽成泛型比较器，UI 层只提供三个取值函数，避免排序逻辑散在页面里。
int compareByScoreThenCountThenName({
  required int scoreA,
  required int scoreB,
  required int countA,
  required int countB,
  required String nameA,
  required String nameB,
}) {
  if (scoreA != scoreB) return scoreB.compareTo(scoreA);
  if (countA != countB) return countB.compareTo(countA);
  return nameA.compareTo(nameB);
}

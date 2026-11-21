import 'text_rule.dart';

/// 一条「预设规则」的说明书（v1.22.75）
///
/// 和 [TextRule] 的区别：预设是**目录里的候选**，用户从「预设库」里挑着加进来；
/// 加进来之后才变成一条普通的 [TextRule]（可以改、可以停用、可以删）。
///
/// 为什么不直接把它们塞进 [TextRule.defaults] 自动播种：
/// 页码/页眉这类规则**只对某些书成立** —— 一部小说的正文里本来就有
/// 「一九〇三年」这样的数字，盲目删页码会把正文一起吃掉。
/// 所以做成「清单 + 用户自己勾」，而不是默认全开。
class TextRulePreset {
  const TextRulePreset({
    required this.id,
    required this.group,
    required this.name,
    required this.pattern,
    this.replacement = '',
    this.isRegex = true,
    required this.hint,
    this.cautious = false,
  });

  /// 目录内唯一标识；落到 [TextRule] 时前缀成 `preset.<id>`
  final String id;

  /// 分组名（面板里按它分节）
  final String group;

  final String name;
  final String pattern;
  final String replacement;
  final bool isRegex;

  /// 这条规则**具体删掉什么**，写给用户看（不要写成"清理无用内容"这种空话）
  final String hint;

  /// 是否「要小心」：可能影响到正文，面板上会额外提示
  final bool cautious;

  /// 转成真正可用的规则
  TextRule toRule() => TextRule(
    id: ruleId,
    name: name,
    pattern: pattern,
    replacement: replacement,
    isRegex: isRegex,
  );

  String get ruleId => 'preset.$id';

  /// 全部分组名（按目录顺序，去重）
  static List<String> get groups {
    final List<String> out = <String>[];
    for (final TextRulePreset p in all) {
      if (!out.contains(p.group)) out.add(p.group);
    }
    return out;
  }

  static List<TextRulePreset> ofGroup(String group) =>
      all.where((TextRulePreset p) => p.group == group).toList();

  static TextRulePreset? byId(String id) {
    for (final TextRulePreset p in all) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 目录
  ///
  /// ## 写这些正则的三条纪律
  ///
  /// 1. **只认"整行只有它"**：页码规则一律用 `^...$`（TextProcessor 编译时带
  ///    `multiLine: true`，所以是按行匹配）。裸写 `\d+` 会把正文里的年份、
  ///    数量、编号全删掉 —— 那是这类规则最容易造成的破坏。
  /// 2. **不碰正文里会出现的常见写法**：`1990-1995` 这种区间不能当成页码。
  /// 3. **每条都写清楚删什么**：用户勾之前必须能判断"这条对我的书成立吗"。
  static const List<TextRulePreset> all = <TextRulePreset>[
    // ---------------- 页码 ----------------
    TextRulePreset(
      id: 'page.standalone-number',
      group: '页码',
      name: '独立成行的纯数字（页码）',
      pattern: r'^[ \t　]*\d{1,4}[ \t　]*$',
      hint: '删掉整行只有一个数字的行，例如单独一行的「42」。'
          '正文里的数字不在独立行上，不会被删。',
    ),
    TextRulePreset(
      id: 'page.dashed-number',
      group: '页码',
      name: '带横线的页码 - 42 -',
      pattern: r'^[ \t　]*[-—–―·]{1,2}[ \t　]*\d{1,4}[ \t　]*[-—–―·]{1,2}[ \t　]*$',
      hint: '删掉独立成行的「- 42 -」「—7—」「·12·」这类页码。',
    ),
    TextRulePreset(
      id: 'page.x-of-y',
      group: '页码',
      name: '页码 12/319（独立成行）',
      pattern: r'^[ \t　]*\d{1,4}[ \t　]*[/／][ \t　]*\d{1,4}[ \t　]*$',
      hint: '删掉独立成行的「12/319」。正文里的分数不在独立行上，不会误伤。',
    ),
    TextRulePreset(
      id: 'page.cn-page',
      group: '页码',
      name: '第 N 页 / 共 M 页',
      pattern: r'第[ \t　]*\d{1,4}[ \t　]*页[ \t　]*(?:[/／]|共)[ \t　]*\d{1,4}[ \t　]*页?',
      hint: '删掉「第 12 页 / 共 319 页」这类页脚。',
    ),
    TextRulePreset(
      id: 'page.of-pages',
      group: '页码',
      name: 'Page 12 of 319',
      pattern: r'\b[Pp][Aa][Gg][Ee][ \t]+\d{1,4}[ \t]+[Oo][Ff][ \t]+\d{1,4}\b',
      hint: '删掉英文页脚「Page 12 of 319」。',
    ),

    // ---------------- 注释标记 ----------------
    TextRulePreset(
      id: 'note.circled',
      group: '注释标记',
      name: '带圈数字 ①②③（脚注标记）',
      pattern: r'[\u2460-\u2473\u3251-\u325F]',
      hint: '删掉正文里的 ①-⑳ 脚注标记。这类字符很多引擎读不出来，'
          '留着还可能让朗读卡住。',
    ),
    TextRulePreset(
      id: 'note.superscript',
      group: '注释标记',
      name: '上标数字 ¹²³',
      pattern: r'[\u00B9\u00B2\u00B3\u2070-\u2079]',
      hint: '删掉上标数字（常见于脚注引用）。',
    ),
    TextRulePreset(
      id: 'note.star-mark',
      group: '注释标记',
      name: '段首星号标记 ＊ **',
      pattern: r'^[ \t　]*[*＊]{1,3}[ \t　]*',
      hint: '删掉段首的星号标记（脚注或强调符号）。',
    ),
    TextRulePreset(
      id: 'note.bracket-full-width',
      group: '注释标记',
      name: '去掉全角方括号内容【…】',
      pattern: r'【[^】]*】',
      hint: '删掉【】里的内容，常见于编者注、题注。',
    ),

    // ---------------- 断行与空白 ----------------
    TextRulePreset(
      id: 'layout.hyphen-join',
      group: '断行与空白',
      name: '英文断词连字符接回（exam-ple → example）',
      pattern: r'([A-Za-z])-[ \t]*\r?\n[ \t]*([A-Za-z])',
      replacement: r'$1$2',
      hint: 'PDF 抽取常把英文单词在行尾拆成两半，这条把它们接回去。中文不受影响。',
    ),
    TextRulePreset(
      id: 'layout.blank-lines',
      group: '断行与空白',
      name: '多个空行压成一个',
      pattern: r'(?:\r?\n[ \t　]*){3,}',
      replacement: '\n\n',
      hint: '把连续三个以上的换行压成一个空行，减少朗读时的停顿。',
    ),
    TextRulePreset(
      id: 'layout.line-break',
      group: '断行与空白',
      name: '把硬换行接成一段（PDF 抽文常用）',
      pattern: r'[ \t　]*\r?\n[ \t　]*',
      replacement: '',
      hint: '把 PDF 每一行的硬换行去掉、接成完整段落，朗读时句子不会被拦腰截断。'
          '注意：也会把头衔与正文接在一起。',
      cautious: true,
    ),

    // ---------------- OCR 噪声 ----------------
    TextRulePreset(
      id: 'ocr.dot-leader',
      group: 'OCR 噪声',
      name: '目录点线 …… 或 ....',
      pattern: r'[.·・…]{3,}',
      hint: '删掉目录里的引导点线。',
    ),
    TextRulePreset(
      id: 'ocr.rule-line',
      group: 'OCR 噪声',
      name: '分隔线 ==== 或 ----',
      pattern: r'[=＝\-—_·•※]{4,}',
      hint: '删掉文字排版里的装饰性分隔线。',
    ),
    TextRulePreset(
      id: 'ocr.replacement-char',
      group: 'OCR 噪声',
      name: '乱码替换符 �',
      pattern: r'\uFFFD',
      hint: '删掉编码错误产生的 � 字符（读出来是「问号」或杂音）。',
    ),
    TextRulePreset(
      id: 'ocr.soft-hyphen',
      group: 'OCR 噪声',
      name: '软连字符 / 零宽字符',
      pattern: r'[\u00AD\u200B-\u200D\uFEFF]',
      hint: '删掉不可见的软连字符与零宽空格（会让分词与朗读节奏变怪）。',
    ),
  ];
}

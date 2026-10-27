import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// PDF 文本层模型：把 `pdfrx` 抽出来的「逐字符包围盒」整理成
/// **可点击、可合并、可高亮**的结构。
///
/// 为什么非要这一层：PDF 里的文字是**碎片**——一行的字可能被拆成好几段
/// （换字体、换字距、加粗、上下标都会断开），一个句子更是横跨多个碎片。
/// 直接拿 `fullText` 或单看一个字都没法「读一整句」，所以要先重新组织。
///
/// 组织顺序：字符 → 行 → 句子。
/// 行的切分靠**几何**（同一基线上的字符），不靠 PDF 里那些不可靠的空格 ——
/// 中文 PDF 的文本层经常一个空格都没有，靠空格分行会得到一整页一段。
class PdfTextChar {
  PdfTextChar({
    required this.index,
    required this.char,
    required this.rect,
  });

  /// 在 `PdfPageText.fullText` 里的下标（句子回溯到原文用）
  final int index;

  /// 单个字符（可能是代理对的一个 code unit，见 [charLength]）
  final String char;

  /// 在 PDF 页面坐标系里的包围盒（原点左上，单位点 = 72dpi 的像素）
  final Rect rect;

  /// 这个「字符」占几个 code unit（emoji 等代理对占 2）
  int get charLength => char.length;
}

/// 一行：同一水平带上的一串字符
class PdfTextLine {
  PdfTextLine({required this.chars});

  final List<PdfTextChar> chars;

  /// 行内文字（按字符顺序拼接）
  String get text => chars.map((c) => c.char).join();

  /// 行的合并包围盒
  Rect get bounds => chars.isEmpty
      ? Rect.zero
      : chars
          .map((c) => c.rect)
          .reduce((a, b) => a.expandToInclude(b));

  /// 行基线的纵向中心（用于判断「点在哪一行」）
  double get centerY => bounds.center.dy;

  /// 行高（取字符盒高度的中位数，避免个别上下标把行高拉大）
  double get height {
    if (chars.isEmpty) return 0;
    final heights = chars.map((c) => c.rect.height).toList()..sort();
    return heights[heights.length ~/ 2];
  }
}

/// 一个可朗读单元：**完整的一句话**（或一整段，若这一行没有句末标点）
class PdfTextSentence {
  PdfTextSentence({
    required this.text,
    required this.chars,
    required this.lineIndex,
  });

  /// 要送去合成的文字（已做基本清理：合并碎片造成的多余空白）
  final String text;

  /// 组成这句话的字符（高亮、命中测试都用它）
  final List<PdfTextChar> chars;

  /// 所属行在原页行列表里的下标（跨页合并时用于排序）
  final int lineIndex;

  /// 合并包围盒
  Rect get bounds => chars.isEmpty
      ? Rect.zero
      : chars.map((c) => c.rect).reduce((a, b) => a.expandToInclude(b));

  /// 这句话在源页面文本里的起始下标（跨页合并时定位用）
  int get firstCharIndex => chars.isEmpty ? -1 : chars.first.index;
  int get lastCharIndex => chars.isEmpty ? -1 : chars.last.index;

  /// 句心在**本页内**的 y（PDF 坐标，页内 0 起）
  ///
  /// 模型 A（让朗读句滑到屏幕对齐位置）用它算目标滚动偏移。
  /// ⚠️ 与 [PdfTextLine.centerY] 同名但**不同类**：那个是"行心"，
  /// 这个是"整句的包围盒中心"（一句可能跨多行）。
  /// 空句返回 `null`（调用方要能区分"算出来是 0"与"算不出来"）。
  double? get centerY => chars.isEmpty ? null : bounds.center.dy;

  /// **逐行高亮矩形**（HANDOFF §4.44 / §4.100）：
  /// 每行一个独立 Rect，只覆盖该行内这句话实际占的字符区间，
  /// **绝不合并成整句 bounding box** ——
  /// 句子跨几行就返回几个 Rect，各 Rect 的 left 互不相同（行首位置不同），
  /// 这正是「不是大框」的判据。
  ///
  /// 行的归属用**几何**判断（与 [groupIntoLines] 同款判据：与当前行带
  /// 纵向重叠过半 → 同一行），不依赖 `lineIndex`（那只是句子起始行）。
  /// 每行的纵向范围钳制到字符高度中位数的 ±0.75 倍：个别上下标字符的
  /// 高盒不会把这一条底色拽成斜跨邻行的观感。
  List<Rect> get highlightRects {
    if (chars.isEmpty) return const <Rect>[];

    // 先按视觉顺序排（上→下、左→右），分行带更稳
    final sorted = List<PdfTextChar>.from(chars)
      ..sort((a, b) {
        final byY = a.rect.center.dy.compareTo(b.rect.center.dy);
        if (byY != 0) return byY;
        return a.rect.left.compareTo(b.rect.left);
      });

    final heights = sorted.map((c) => c.rect.height).toList()..sort();
    final medianH = heights[heights.length ~/ 2];

    // 按几何分行带：与当前带的纵向重叠超过「较矮者的一半」→ 同带
    final rows = <List<PdfTextChar>>[];
    for (final c in sorted) {
      if (rows.isEmpty) {
        rows.add(<PdfTextChar>[c]);
        continue;
      }
      final row = rows.last;
      var rowTop = row.first.rect.top;
      var rowBottom = row.first.rect.bottom;
      for (final p in row.skip(1)) {
        if (p.rect.top < rowTop) rowTop = p.rect.top;
        if (p.rect.bottom > rowBottom) rowBottom = p.rect.bottom;
      }
      final overlap =
          math.min(rowBottom, c.rect.bottom) - math.max(rowTop, c.rect.top);
      final refH = math.min(
        math.max(rowBottom - rowTop, 1.0),
        math.max(c.rect.height, 1.0),
      );
      if (overlap > refH * 0.5) {
        row.add(c);
      } else {
        rows.add(<PdfTextChar>[c]);
      }
    }

    final rects = <Rect>[];
    for (final row in rows) {
      // ★v1.22.27：算这一行的左右边界时**只看有墨的字符**。
      //
      // 真机（平板 TB335FC，2026-10-19）：高亮框会明显超出文字右侧、甚至铺到
      // 页面边上。原因是行里混进了**空白字符 / 占位盒**（空格、换行、引擎给的
      // 零面积或超宽假盒），而这里取的是 min/max —— 一个坏盒就把整行拉宽。
      // 空白本来就没有墨，不该参与边界；超宽盒（宽于字高中位数 3 倍）同理。
      final List<PdfTextChar> ink = row
          .where((c) =>
              c.char.trim().isNotEmpty &&
              (medianH <= 0 || c.rect.width <= medianH * 3))
          .toList();
      final List<PdfTextChar> basis = ink.isEmpty ? row : ink;
      var left = basis.first.rect.left;
      var right = basis.first.rect.right;
      var top = basis.first.rect.top;
      var bottom = basis.first.rect.bottom;
      for (final c in basis.skip(1)) {
        if (c.rect.left < left) left = c.rect.left;
        if (c.rect.right > right) right = c.rect.right;
        if (c.rect.top < top) top = c.rect.top;
        if (c.rect.bottom > bottom) bottom = c.rect.bottom;
      }
      if (medianH > 0) {
        final cy = (top + bottom) / 2;
        top = cy - medianH * 0.75;
        bottom = cy + medianH * 0.75;
      }
      rects.add(Rect.fromLTRB(left, top, right, bottom));
    }
    return rects;
  }
}

/// 按「字符下标闭区间」找到对应的**整句**。
///
/// 区间取自 [PdfTextSentence.firstCharIndex / lastCharIndex]，同一页内
/// 每句的字符互不重叠，(首, 尾) 成对唯一 —— 文本相同的重复短句也不会认错
/// （§4.44 的老坑是**按文本**匹配，这里按下标对匹配，与文本无关）。
/// 找不到（区间不对应本页任何整句）返回 null，调用方宁可不画也不
/// 要按区间去扫全页字符 —— 那正是「合并大框斜跨多行」的根源（§4.100）。
PdfTextSentence? sentenceAtRange(PdfPageTextLayer layer, (int, int) range) {
  for (final s in layer.sentences) {
    if (s.firstCharIndex == range.$1 && s.lastCharIndex == range.$2) return s;
  }
  return null;
}

/// 一页的文本层
class PdfPageTextLayer {
  PdfPageTextLayer({
    required this.pageNumber,
    required this.pageSize,
    required this.lines,
    required this.sentences,
    required this.fullText,
  });

  /// 页码（1 起，与 pdfrx 一致）
  final int pageNumber;

  /// 页面尺寸（PDF 点）
  final Size pageSize;

  final List<PdfTextLine> lines;
  final List<PdfTextSentence> sentences;

  /// 原始整页文本（`PdfPageText.fullText`，保留用于回查）
  final String fullText;

  bool get isEmpty => sentences.isEmpty;

  /// 命中测试：PDF 页面坐标 → 句子下标；没命中返回 null
  ///
  /// 容差（v1.22.61 收紧，见方法内注释）：
  /// * 先找「真命中」的字符盒；
  /// * 找不到就按**单字高度**算容差：纵向 [missToleranceFactor] 倍、横向约 1 个字宽。
  ///
  /// 为什么还要容差：用户手指点在两行之间、或点在行尾标点右侧的空白处，
  /// 严格按包围盒会「点了没反应」——那正是「PDF 点句时灵时不灵」的来源。
  /// 但容差**必须有横向上限**，否则页边距里的任意空白都会命中同一行
  /// （真机「点空白处也开始朗读」就是这个漏洞）。
  int? sentenceIndexAt(
    Offset point, {
    double missToleranceFactor = 0.55,
    double maxHorizontalMissFactor = 1.2,
  }) {
    if (sentences.isEmpty) return null;

    // 1) 精确命中：点在某个字符盒里（横向留一点余量，行首行尾好点）
    for (var i = 0; i < sentences.length; i++) {
      for (final c in sentences[i].chars) {
        final r = c.rect.inflate(math.max(1.5, c.rect.height * 0.12));
        if (r.contains(point)) return i;
      }
    }

    // 2) 就近兜底：允许「点在行间缝隙 / 行尾标点右侧一点点」
    //
    // ★★ v1.22.61 修「平板 PDF 点空白处也会读同一行」（用户 2026-10-25）
    //
    // **原实现的漏洞**：纵向有容差（`b.height * 0.9`），横向**完全没有上限**
    // —— 于是只要点的 y 落在某一行的容差带内，哪怕 x 在页面最左边的页边距、
    // 或者最右边的空白，都会命中那一行。用户在页面上点任意空白处（只要与某行同高）
    // 就会开始朗读，看起来像"点哪都读"。
    //
    // 实测形态：PDF 页有很宽的左右页边距，页边距里任意位置都能触发同一行。
    //
    // **修法**：横向也加一个**按字高算的**上限（约 1 个字宽），纵向容差收紧到
    // 半行高左右。这样"行间缝隙 / 标点右侧"仍能命中（原本的容差目的），
    // 但页边距、行间大空白、段落之间的空白都不再命中。
    //
    // ⚠️ 用**单字高度**当标尺而不是 `sentences[i].bounds.height`：
    // 一句话换行后会跨多行，bounds 是并集，高度可能是单行的好几倍 ——
    // 拿它算容差会让"多行句"周围的空白全部命中，等于没修。
    double? bestDistance;
    int? bestIndex;
    for (var i = 0; i < sentences.length; i++) {
      final b = sentences[i].bounds;
      // 单字高度（没有字符盒时退回句子高度）
      var lineH = 0.0;
      for (final c in sentences[i].chars) {
        if (c.rect.height > lineH) lineH = c.rect.height;
      }
      if (lineH <= 0) lineH = b.height;
      // 纵向距离（点到行的垂直距离，落在行内记 0）
      final dy = point.dy < b.top
          ? b.top - point.dy
          : (point.dy > b.bottom ? point.dy - b.bottom : 0.0);
      if (dy > lineH * missToleranceFactor) continue;
      // 横向距离（点到行水平区间的距离，落在区间内记 0）
      final dx = point.dx < b.left
          ? b.left - point.dx
          : (point.dx > b.right ? point.dx - b.right : 0.0);
      // ★横向上限：最多约 1 个字宽（留给"点行尾标点右侧"的手感）
      if (dx > math.max(10.0, lineH * maxHorizontalMissFactor)) continue;
      final d = dy * 2 + dx; // 纵向权重更高：优先「同一行」
      if (bestDistance == null || d < bestDistance) {
        bestDistance = d;
        bestIndex = i;
      }
    }
    return bestIndex;
  }
}

/// 把 `pdfrx` 的 `PdfPageText` 整理成 [PdfPageTextLayer]
///
/// 入参刻意用**回调**而不是直接依赖 pdfrx 的类型：这样纯逻辑可以脱离
/// PDF 引擎单测（本项目的坑大多出在合并与分行逻辑上，而不是取数据那一步）。
PdfPageTextLayer buildTextLayer({
  required int pageNumber,
  required Size pageSize,
  required String fullText,
  required List<Rect> charRects,
  required List<PdfTextSentence> Function(List<PdfTextLine>) segment,
}) {
  final chars = <PdfTextChar>[];
  // `charRects` 与 `fullText` 一一对应；长度不一致时以短的那个为准，
  // 越界访问会直接崩，宁可少几个字符。
  final n = math.min(fullText.length, charRects.length);
  for (var i = 0; i < n; i++) {
    final ch = fullText[i];
    if (ch == '\r') continue; // 归一化：CRLF 里的 CR 不参与排版
    final r = charRects[i];
    // 跳过零高度盒。⚠️ §4.100：判据必须是「高度不足半磅」（不是「宽和高都 ≤0」、
    // 也不是「≤ 0」——实测这些盒的高度是 **0.005 之类的微小正值**，
    // 打印成 0.0，`height <= 0` 根本拦不住，绕了一轮才发现）。
    // 真实 PDF 的换行符 / 行前空格占位常常是 **width>0 而 height≈0**，
    // 而且纵向落在**下一行**的位置上。这种盒本身没有字形，可一旦放进来，
    // 它作为「空白字符」会被 [groupIntoLines] 的「空白无条件跟随当前行」
    // 规则吸进上一行，把那一行的 bounds 底部撑到下一行的 y 上
    //（实测《共产主义ABC》：正文行 485.5 被同行尾的零高占位撑到 508.8）。
    // 任何可读字号（≥4pt）的字形盒都远大于 0.5 磅，这个阈值拦得住占位
    // 又不会误杀文字。后果（不拦时）：行 bounds 虚高 → 可见性误判、
    // 高亮块覆盖违例；朗读文本混进「出\n版。」这种断行碎片
    //（用户报的「读出来的文字不是视觉顺序」正是它）。
    if (r.height < 0.5) continue;
    chars.add(PdfTextChar(index: i, char: ch, rect: r));
  }

  final lines = groupIntoLines(chars);
  final sentences = segment(lines);

  return PdfPageTextLayer(
    pageNumber: pageNumber,
    pageSize: pageSize,
    lines: lines,
    sentences: sentences,
    fullText: fullText,
  );
}

/// 按**几何**把字符分组成行
///
/// 判据（从上往下扫）：
/// - 纵向重叠够多（落在同一水平带）→ 同一行；
/// - 否则若这一行的基线比当前行**低得明显** → 换行。
///
/// 中文 PDF 的文本层**常常没有空格**，纯按 `\n` / 空格分行会把整页糊成一段，
/// 所以这里以坐标为准，换行符只当作一个普通的分隔提示。
List<PdfTextLine> groupIntoLines(List<PdfTextChar> chars) {
  if (chars.isEmpty) return <PdfTextLine>[];

  // 先按「先上后下、再左到右」排序：PDF 的绘制顺序不保证是阅读顺序
  // （两栏排版、页眉页脚、脚注都会打乱），排序后才能顺序分组。
  final sorted = List<PdfTextChar>.from(chars)
    ..sort((a, b) {
      // ⚠️ v1.21.29：**同一水平带要容忍字高差异**。
      // 数字 / 字母的字形盒中心常比汉字偏上或偏下不到 1 磅；直接比 `center.dy`
      // 会把它们排到整行**之后**，随后被 `toTheRight` 判成「新的一行」——
      // 真机症状就是「数字被切到整句后面、读完整句又回头读数字、并与下一句合并」。
      // 容差取两者较小高度的一半：足以吸收基线微调，又远小于行距（不会把两行并成一行）。
      final double tol = math.min(a.rect.height, b.rect.height).abs() * 0.5;
      final double dy = a.rect.center.dy - b.rect.center.dy;
      if (dy.abs() > tol) return dy < 0 ? -1 : 1;
      return a.rect.left.compareTo(b.rect.left);
    });

  final lines = <List<PdfTextChar>>[];
  for (final c in sorted) {
    // 空白字符**不参与分行判断**：PDF 里常有「一条宽大的空白占位」
    // （字距调整、表格留白），它的盒子又宽又偏，拿它当行尾参照会把
    // 后面本来同一行的字判成「不在右边」→ 一整页被切得七零八落。
    // 空白本身还是要保留在行里（英文分词需要它）。
    final isSpace = c.char.trim().isEmpty;
    if (lines.isEmpty) {
      lines.add(<PdfTextChar>[c]);
      continue;
    }
    final current = lines.last;
    // 参照取「本行最后一个非空白字符」，没有就退回最后一个
    PdfTextChar ref = c;
    for (var i = current.length - 1; i >= 0; i--) {
      if (current[i].char.trim().isNotEmpty) {
        ref = current[i];
        break;
      }
    }
    if (isSpace) {
      // 空白跟随当前行，不做换行判断
      current.add(c);
      continue;
    }
    // 与参照字符比较，而不是行平均 —— 行内字高不一时更稳
    final overlap = math.min(ref.rect.bottom, c.rect.bottom) -
        math.max(ref.rect.top, c.rect.top);
    final refHeight = math.max(ref.rect.height, 1.0);
    var sameLine = overlap > refHeight * 0.5;

    // ⚠️ 补充判据（v1.21.29 修，用户 812 页文档实测）：
    // 数字 / 字母 / 半角标点的字形盒常比汉字**矮一截**（没有下伸部分），
    // 基线也可能有微调 —— 只按重叠比例会把它们判成「新的一行」，于是数字被切出
    // 行外、排到整句后面：整句先成句，数字块因没有句末标点被判"还会续"→ 与下一句
    // 合并。表现就是「先读整句、数字被跳过；读完又回头读数字；数字混进下一句；
    // 高亮只盖住数字前后一小段」。
    // 这种情况改用**中心距离**再判一次：中心落在同一行带内就归为同行。
    // 只对 ASCII 窄字形放宽，汉字之间、全角标点之间仍用原判据。
    if (!sameLine && _isNarrowGlyph(c.char)) {
      final refCenter = ref.rect.center.dy;
      final cCenter = c.rect.center.dy;
      final band = math.max(refHeight, math.max(c.rect.height, 1.0)) * 0.6;
      sameLine = (cCenter - refCenter).abs() < band;
    }

    // 同一行的字符横向必须递增（在右边），否则是两栏/换段
    final toTheRight = c.rect.left >= ref.rect.right - refHeight * 0.5;
    if (sameLine && toTheRight) {
      current.add(c);
    } else {
      // 换行（或同带但在左边：两栏排版的另一栏）
      lines.add(<PdfTextChar>[c]);
    }
  }

  // 行内再按 x 排序（分组时大体有序，保险）
  for (final line in lines) {
    line.sort((a, b) => a.rect.left.compareTo(b.rect.left));
  }

  // ⚠️ §4.100 线索 2 修复：同一 y 带上「正文行 + 居中/靠右的小节标题」
  // 被并成一行后，分句会把两段一起读（朗读顺序错）、高亮会画出一条
  // 斜跨两段的长框。判据：**未被任何字符盒（含空白盒）覆盖的空档**
  // 超过约 3 个中位字宽 → 切成两个独立「行块」。
  //
  // 必须算「未覆盖空档」而不是「相邻非空白字的 x 差」—— PDF 字距调整
  // 留下的宽大**空白占位盒**会盖住空档，按后者会把它当空档切开，
  // 正常行被切得七零八落（§4.44 同款坑，回归用例
  // 「又宽又偏的空白占位盒不会把一整行切断」钉着这条）。
  final blocks = <List<PdfTextChar>>[];
  for (final row in lines) {
    blocks.addAll(_splitRowByGap(row));
  }
  // 行块之间按「(top, left)」重排：切出来的第二块与下一行同带时，
  // 保证视觉顺序 = 数组顺序（朗读顺序、目录跳转都依赖它）
  blocks.sort((a, b) {
    final ta = a.first.rect.center.dy;
    final tb = b.first.rect.center.dy;
    final byY = ta.compareTo(tb);
    if (byY != 0) return byY;
    return a.first.rect.left.compareTo(b.first.rect.left);
  });
  return blocks.map((l) => PdfTextLine(chars: l)).toList();
}

/// 把一行按「未覆盖空档 > 3 个中位字宽」切成若干独立行块（保持 x 顺序）
List<List<PdfTextChar>> _splitRowByGap(List<PdfTextChar> row) {
  if (row.length < 2) return <List<PdfTextChar>>[row];
  final widths = row
      .where((c) => c.char.trim().isNotEmpty && c.rect.width > 0)
      .map((c) => c.rect.width)
      .toList();
  if (widths.isEmpty) return <List<PdfTextChar>>[row];
  widths.sort();
  final maxGap = widths[widths.length ~/ 2] * 3;

  final out = <List<PdfTextChar>>[<PdfTextChar>[row.first]];
  var coveredRight = row.first.rect.right;
  for (var i = 1; i < row.length; i++) {
    final c = row[i];
    if (c.rect.left - coveredRight > maxGap) {
      out.add(<PdfTextChar>[c]);
    } else {
      out.last.add(c);
    }
    if (c.rect.right > coveredRight) coveredRight = c.rect.right;
  }
  return out;
}

/// 句子切分器（等价于 Web 端的 `Intl.Segmenter({granularity:'sentence'})`）
///
/// 页脚 / 页码行识别（v1.21.14 任务①）—— **保守**，宁可漏判也不误伤正文
///
/// 背景：真实 PDF 的页脚「− 311 −」原本被当正文成句（HANDOFF §4.100 记过）；
/// 更糟的是它**没有句末标点**，于是 `looksUnfinished` 判「还会往下续」，
/// 与**下一页首句**合并成一次朗读 —— 用户报的「读到页末会连读下一页首句」。
///
/// 三条判据**同时**满足才算页码：
/// 1. **内容**：去掉装饰符与「第 / 页」这类字之后**只剩数字**（`− 311 −`、`第 311 页`、
///    纯 `311` 都命中；`1998 年` 不命中，因为剩下的不是纯数字）；
/// 2. **长度**：清理后 ≤ 12 字符（页码不会长）；
/// 3. **位置**：本页**第一个或最后一个非空行**，且本页至少有 3 个非空行。
///
/// 第 3 条是防误伤的关键：正文中间单独成行的数字（年份、编号、表格里的数）
/// 不会被判成页码；只有排在页首/页尾的纯数字行才按页码丢掉。
bool isPageNumberLine(List<PdfTextLine> lines, int index) {
  if (index < 0 || index >= lines.length) return false;
  final PdfTextLine line = lines[index];
  if (line.chars.isEmpty) return false;

  // 先做便宜的判据（内容 / 长度），再做需要扫全页的位置判据
  final String text = _cleanText(line.text).trim();
  if (text.isEmpty || text.length > 12) return false;
  final String stripped = text.replaceAll(_pageNumberDecoration, '');
  if (stripped.isEmpty || !_onlyDigits.hasMatch(stripped)) return false;

  int first = -1;
  int last = -1;
  int count = 0;
  for (int i = 0; i < lines.length; i++) {
    if (lines[i].chars.isEmpty) continue;
    if (first < 0) first = i;
    last = i;
    count++;
  }
  if (count < 3) return false; // 行数太少（封面 / 表格 / 图片页）不判
  return index == first || index == last;
}

/// 页码行里允许出现的装饰符与「第/页」这类字（去掉它们之后应当只剩数字）
final RegExp _pageNumberDecoration = RegExp(
    r'[\s\-−–—_·．.。、,，:：;；()（）\[\]【】{}<>《》|/\\]|第|页|頁|共|之|Page|page');

final RegExp _onlyDigits = RegExp(r'^[0-9]+$');

/// Dart 没有 `Intl.Segmenter`，这里按**中英标点规则**实现，行为对齐：
/// - 句末标点：`。！？!?` 以及中文省略号 `……`；
/// - 句末标点后面跟**收尾标点**（`」』）】"` 等）时，一并算进本句；
/// - **小数点 / 缩写不算句末**：`3.14`、`No.1`、`U.S.` 不断句；
/// - 换行（新的一行）一定断句 —— PDF 的一行结束通常就是一句话的边界。
///
/// 之所以不用「按换行切」了事：一行可能是**半句话**（排版折行），
/// 那样读出来会一顿一顿的；按标点切才读得顺。
List<PdfTextSentence> segmentIntoSentences(List<PdfTextLine> lines) {
  final result = <PdfTextSentence>[];

  // 排版右边界：本页所有非空行右边缘的最大值。硬折行的那几行都会顶到它。
  final double? fullRight = _textBlockRight(lines);
  // 非空行数：封面 / 扉页 / 插图页判据（v1.21.15）
  final int lineCount = _nonEmptyLineCount(lines);

  // 一条句子的累加器 —— **跨行存活**：硬折行时它要连着吃下一行，
  // 直到遇见句末标点、或者某一行"没排满"（= 段落结束）为止。
  final List<String> chunkTexts = <String>[];
  final List<PdfTextChar> chunkChars = <PdfTextChar>[];
  var startLine = 0;

  void flush() {
    if (chunkChars.isEmpty) return;
    final String text = _cleanText(_joinChunks(chunkTexts));
    if (text.trim().isNotEmpty) {
      result.add(PdfTextSentence(
        text: text,
        chars: List<PdfTextChar>.unmodifiable(chunkChars),
        lineIndex: startLine,
      ));
    }
    chunkTexts.clear();
    chunkChars.clear();
  }

  for (var li = 0; li < lines.length; li++) {
    final line = lines[li];
    if (line.chars.isEmpty) continue;
    // v1.21.14 任务①：页脚/页码行**既不成句、也不参与跨页合并**。
    // 不滤的话它会以「没有句末标点」的身份被 `looksUnfinished` 判成"还会续"，
    // 于是和下一页首句拼成一句朗读（用户报的「页末连读下一页首句」）。
    if (isPageNumberLine(lines, li)) continue;

    // 本行内先按标点切；切出来的每一段都并进句子累加器
    var buffer = <PdfTextChar>[];

    void appendBuffer() {
      if (buffer.isEmpty) return;
      if (chunkChars.isEmpty) startLine = li;
      chunkTexts.add(buffer.map((c) => c.char).join());
      chunkChars.addAll(buffer);
      buffer = <PdfTextChar>[];
    }

    for (var i = 0; i < line.chars.length; i++) {
      final c = line.chars[i];
      buffer.add(c);
      if (_isSentenceEnd(line.chars, i)) {
        appendBuffer();
        flush(); // 句末标点：一句到此为止（收尾引号归下一句开头）
      }
    }
    appendBuffer();

    // 行尾。v1.21.14：**硬折行不能断句** —— 这一行如果是被排版排满的，
    // 它只是"折"到了下一行，句子还没完，继续往下吃。
    if (_continuesOnNextLine(lines, li, chunkChars, fullRight, lineCount)) {
      continue;
    }
    flush(); // 行末没有句末标点：整行作为一句（宁可读长一点，也别丢字）
  }
  flush(); // 页末收尾（最后一行也可能在跨行累加中）
  return result;
}

/// 一行"排满"的判据（硬折行）：右边缘顶到本页排版右边界（留 [tolerance] 余量）
///
/// 为什么要这条：同一页里
/// - **排满**的行 = 排版排到边了才换行 → 句子还没写完（硬折行，要续）；
/// - **没排满**的行 = 段落/句子的自然结尾（要收尾）。
///
/// 右边界取"全页非空行右边缘的最大值"：硬折行的那几行必然顶着它。
/// 容差取 `max(10pt, 4%)`：标题比正文宽一点、或者末行差几个字，都还能判对。
double? _textBlockRight(List<PdfTextLine> lines) {
  double maxRight = 0;
  for (final PdfTextLine line in lines) {
    if (line.chars.isEmpty) continue;
    final double r = line.bounds.right;
    if (r > maxRight) maxRight = r;
  }
  return maxRight > 0 ? maxRight : null;
}

/// 太短的行不参与跨行合并（PDF 点）
///
/// 短行多半是标题、目录条目、图表说明 —— 合并它们没有收益，还可能把两条
/// 目录读成一句。真实正文的硬折行远长于这个值（普通书页一行 ≥ 100pt）。
const double _minWrapLineWidth = 60.0;

/// 跨行合并的字符上限（防呆：万一判据误判，也不至于把一整页读成一句）
const int _maxMergedChars = 300;

/// 少于这么多**非空行**的页才可能被判成标题页（v1.21.15）
const int _minLinesForWrapMerge = 4;

/// 标题页的"每行字数"下限：少于它才算标题页（v1.21.15）
const int _minCharsPerLineForWrap = 18;

/// 封面 / 扉页 / 插页判据（v1.21.15）
///
/// 这类页面**行数少、每行字数也少**（书名、丛书名、出版地），彼此**不是**同一句话
/// 被排版折行，而是各自独立的一行。实测副作用：《共产主义ABC》封面把
/// 「莱茵学社共产主义文库系列丛书」与「二〇一七·哈尔滨」读成了一句。
///
/// 判据 = **（非空行数 < 4）且（平均每行字数 < 18）**，两个条件同时满足才算标题页：
/// - 只看行数会误伤：小页里也有真正被折行的正文（用例「硬折行的正文」就只有 3 行、
///   每行 28~30 字）；
/// - 只看字数会误伤：窄栏排版的正文行也可能很短。
bool _isSparseTitlePage(List<PdfTextLine> lines, int lineCount) {
  if (lineCount >= _minLinesForWrapMerge) return false;
  int chars = 0;
  int nonEmpty = 0;
  for (final PdfTextLine line in lines) {
    if (line.chars.isEmpty) continue;
    chars += line.chars.length;
    nonEmpty++;
  }
  if (nonEmpty == 0) return true;
  return chars / nonEmpty < _minCharsPerLineForWrap;
}

/// 本页非空行数（封面判据用）
int _nonEmptyLineCount(List<PdfTextLine> lines) {
  int count = 0;
  for (final PdfTextLine line in lines) {
    if (line.chars.isNotEmpty) count++;
  }
  return count;
}

/// 本行结束时，句子是否应当**继续到下一行**（硬折行）
bool _continuesOnNextLine(
  List<PdfTextLine> lines,
  int index,
  List<PdfTextChar> pending,
  double? fullRight,
  int lineCount,
) {
  if (pending.isEmpty) return false; // 这一行已经以句末标点收尾了
  if (fullRight == null) return false;
  if (pending.length >= _maxMergedChars) return false;

  // v1.21.15：稀疏小页（封面 / 扉页 / 插页）不合并
  if (_isSparseTitlePage(lines, lineCount)) return false;

  final PdfTextLine line = lines[index];
  if (line.bounds.right < _minWrapLineWidth) return false;

  final double tolerance = fullRight * 0.04 > 10.0 ? fullRight * 0.04 : 10.0;
  if (line.bounds.right < fullRight - tolerance) return false; // 没排满 → 收尾

  // 目录条目 / 编号行常以数字结尾（"…… 12"）：不合并，避免把两行目录读成一句。
  //
  // ⚠️ v1.21.22：判据**不能只看"行尾是不是数字"**。
  // 正文行也经常以数字结尾 —— 最典型的就是年份被换行切开：
  // "……爆发于1917" + "年，俄国随后……"。只看尾字符会把一句话劈成两半，
  // 后半截（"年，俄国随后……"）稍后自成一句**再读一遍**，
  // 真机反馈的「含"年"的数字被拆开、读完当前句又回头读年代」就是这条。
  //
  // 只有**像目录条目**时才拦（见 [_looksLikeTocEntry]）：行尾数字前面有
  // 点引导符或多空格 —— 正文行没有这个特征。
  final String tail = line.text.trimRight();
  if (_looksLikeTocEntry(tail)) return false;

  // 下一行要存在且不是页码行（否则接上去就是读页码）
  final int nextIndex = index + 1;
  if (nextIndex >= lines.length) return false;
  final PdfTextLine next = lines[nextIndex];
  if (next.chars.isEmpty) return false;
  if (isPageNumberLine(lines, nextIndex)) return false;

  // ★ 下一行必须也"像正文"才续：
  //   · 够长（排到右边界的一半以上）→ 典型的硬折行，继续接；
  //   · 否则只有当**这一句在下一行里就结束**（下一行里有句末标点）时才接 ——
  //     这正是"段落末行很短"的常见情形（`…发生了很大` + `变化。`）。
  //   反例（用户用例）：上一行排满、下一行只有「完了」两个短字且没标点
  //   → 那是独立的一条（标题/图注/条目），**不能**粘到上一句里。
  if (_isBodyLine(next, fullRight)) return true;
  return _lineHasSentenceEnd(next);
}

/// 窄字形：ASCII 可见字符（数字 / 字母 / 半角标点）。
///
/// 这类字符在中文 PDF 里常与汉字盒高不一致（矮一截或基线偏移），
/// 单靠「纵向重叠 > 50%」会把它们切成独立行块（v1.21.29 修）。
bool _isNarrowGlyph(String ch) {
  if (ch.isEmpty) return false;
  final int code = ch.codeUnitAt(0);
  return code >= 0x20 && code < 0x7F;
}

/// 下一行是否"还算正文行"：至少排到本页排版右边界的一半，且超过最小行宽
bool _isBodyLine(PdfTextLine line, double fullRight) =>
    line.bounds.right >= fullRight * 0.5 &&
    line.bounds.right >= _minWrapLineWidth;

/// 这一行是否"像目录条目"（行尾挂着页码），v1.21.22
///
/// 目录的典型排版是 `第一章 绪论 …………… 12`（点引导）或 `绪论    12`（多空格）；
/// 单空格的 `第一章 绪论 12` 也按目录处理（行首是章节标记）。
///
/// 与之相对，**正文行只是恰好以数字结尾**（年份 / 数量 / 编号，例如两端对齐
/// 排版里被换行切开的 `……爆发于1917` + `年，……`）——它没有任何引导符，
/// 必须照常合并，否则一句话会被劈成两半、后半截再被单独读一遍。
bool _looksLikeTocEntry(String tail) {
  final int end = tail.length;
  if (end == 0 || !_isDigit(tail[end - 1])) return false;
  var i = end;
  while (i > 0 && _isDigit(tail[i - 1])) {
    i--; // 跳过尾部那串数字（页码）
  }
  if (i == 0) return false; // 整行都是数字：交给页码行判据，不在这里管
  var spaces = 0;
  while (i > 0 && (tail[i - 1] == ' ' || tail[i - 1] == '\u3000')) {
    i--;
    spaces++;
  }
  var dots = 0;
  while (i > 0 && _isDotLeader(tail[i - 1])) {
    i--;
    dots++;
  }
  if (dots >= 2) return true; // `……12`
  if (spaces >= 2) return true; // `绪论   12`
  if (spaces >= 1 && _startsWithChapterMarker(tail)) return true; // `第一章 绪论 12`
  return false;
}

/// 点引导符（目录里连接标题与页码的那些点）
bool _isDotLeader(String c) =>
    c == '.' || c == '·' || c == '…' || c == '•' || c == '‧' || c == '・';

/// 行首是不是章节标记（`第…章 / 节 / 卷 / 篇 / 部 / 讲`）
bool _startsWithChapterMarker(String text) {
  if (!text.startsWith('第')) return false;
  final int limit = text.length < 8 ? text.length : 8;
  for (var i = 1; i < limit; i++) {
    if ('章节卷篇部讲'.contains(text[i])) return true;
  }
  return false;
}

/// 这一行里有没有句末标点（决定"句子是否在下一行内结束"）
bool _lineHasSentenceEnd(PdfTextLine line) {
  for (var i = 0; i < line.chars.length; i++) {
    if (_isSentenceEnd(line.chars, i)) return true;
  }
  return false;
}

/// 把逐行的文本拼成一句：中文直接接，英文/数字之间补空格
String _joinChunks(List<String> chunks) {
  final StringBuffer out = StringBuffer();
  for (final String chunk in chunks) {
    if (chunk.isEmpty) continue;
    if (out.isNotEmpty && _needsSpaceBetween(out.toString(), chunk)) {
      out.write(' ');
    }
    out.write(chunk);
  }
  return out.toString();
}

/// 判断 `chars[i]` 是不是「一句话的结束」
///
/// ⚠️ 关键细节：**行尾**（`i + 1 == chars.length`）必须直接判为结束。
/// 早期版本在这里继续看「下一个字符」，而下一个字符在行尾是**空字符串** ——
/// `''.contains(...)` 之类判断会把「没有下一个字符」误当成「下一个是收尾标点」，
/// 于是整行**永远不断句**（实测：「走吧。」然后…… 整段被当成一句）。
bool _isSentenceEnd(List<PdfTextChar> chars, int i) {
  final ch = chars[i].char;
  final atLineEnd = i + 1 >= chars.length;
  final next = atLineEnd ? '' : chars[i + 1].char;
  const enders = '。！？!?';
  if (enders.contains(ch)) {
    // 句末标点**永远断句**，后面跟的收尾引号/括号归到下一句开头。
    //
    // 一开始想「把收尾引号算进本句」，但那需要「再等一个字符才断」，
    // 判断复杂度陡增，收益只是让下一句开头少一个「」」——
    // 而合成引擎读「」然后离开了」和读「走吧。」「然后离开了」没区别。
    // 简单规则更不容易错（这里踩过：等待收尾标点的写法会让整行不断句）。
    return true;
  }
  // 中文省略号「……」占两个字符，第二个「…」才算结束
  if (ch == '…') {
    if (!atLineEnd && next == '…') return false;
    return true;
  }
  // 半角句点：只在「不是小数点 / 缩写」时算句末
  if (ch == '.') {
    if (atLineEnd) return true;
    final prev = i > 0 ? chars[i - 1].char : '';
    // 前一个是数字且后一个也是数字 → 小数点，不断
    if (_isDigit(prev) && _isDigit(next)) return false;
    // 单个大写字母后跟点（缩写）→ 不断
    if (_isAsciiUpper(prev) && _isAsciiUpper(next)) return false;
    // 后面还有内容却紧跟着小写字母 → 缩写或网址，不断
    if (_isAsciiLower(next)) return false;
    return true;
  }
  return false;
}

bool _isDigit(String ch) => ch.isNotEmpty && '0123456789'.contains(ch);
bool _isAsciiUpper(String ch) =>
    ch.isNotEmpty && ch.codeUnitAt(0) >= 0x41 && ch.codeUnitAt(0) <= 0x5A;
bool _isAsciiLower(String ch) =>
    ch.isNotEmpty && ch.codeUnitAt(0) >= 0x61 && ch.codeUnitAt(0) <= 0x7A;

/// 清理送进合成引擎的文字
///
/// 碎片合并后常出现「字 与 字 之间莫名多出空格」的情况（PDF 用空格占位
/// 来做字距），中文里这些空格会让朗读出现奇怪停顿，所以：
/// - 中文之间的空格去掉；
/// - 连续空白压成一个；
/// - 首尾空白去掉。
///
/// ⚠️ §4.100：空白折叠必须**含 `\n`**。pdfrx 给行内换行符的字形盒有时
/// 落在**两个正文汉字中间**（实测《共产主义ABC》：「出\n版。」——换行符的
/// x 恰好在「出」「版」之间），按 x 排序后就夹进句子文本里。原来只折叠
/// `[ \t\u00a0]`，`\n` 会原样送进合成引擎，读出来就是断开的「出 版」。
/// 折叠成普通空格后，中文对之间的空格又被下一条规则删掉 → 「出版。」。
String _cleanText(String raw) {
  var s = raw.replaceAll(RegExp(r'[ \t\u00a0\n\r\u000b\u000c]+'), ' ');
  // 中文（含中文标点）之间的空格删掉
  s = s.replaceAllMapped(
    RegExp(r'([\u3000-\u9fff\uff00-\uffef]) ([^\x00-\x7f])'),
    (m) => '${m[1]}${m[2]}',
  );
  s = s.replaceAllMapped(
    RegExp(r'([^\x00-\x7f]) ([\u3000-\u9fff\uff00-\uffef])'),
    (m) => '${m[1]}${m[2]}',
  );
  return s.trim();
}

/// 对外暴露给测试用的清理函数
String cleanSentenceText(String raw) => _cleanText(raw);

/// 跨页句子的合并结果
class CrossPageSentence {
  const CrossPageSentence({
    required this.text,
    required this.startPage,
    required this.startSentence,
    required this.endPage,
    required this.endSentence,
  });

  /// 合并后的完整文字（送合成用）
  final String text;

  /// 起始页（1 起）与该页里的句子下标
  final int startPage;
  final int startSentence;

  /// 结束页（1 起）与该页里的句子下标；与起始相同表示没跨页
  final int endPage;
  final int endSentence;

  bool get spansPages => startPage != endPage;
}

/// 判断一句话是不是「跨页断开了」——即它明显还会往下续
///
/// 只看**结尾**：
/// - 以 `，、；：,;:` 结尾 → 肯定还有下半句；
/// - 完全没有句末标点（`。！？!?…`）→ 排版折行或断页，也当作会续；
/// - 其它（正常句末）→ 不续。
///
/// 注意：**不能**只看「有没有句末标点」就一路往下拼，所以调用方只允许
/// 拼**一页**（见 [buildCrossPageSentence]），否则整本书会被接成一句。
bool looksUnfinished(String text) {
  final t = text.trimRight();
  if (t.isEmpty) return false;
  const continuers = '，、；：,;:';
  const enders = '。！？!?…';
  final last = t[t.length - 1];
  if (continuers.contains(last)) return true;
  return !enders.contains(last);
}

/// 把「本页第 [sentenceIndex] 句」与需要的下一页开头拼成完整一句
///
/// 需求里的边界情况：上一页末尾到下一页开头本来是同一句话。
/// - [current] 是这句话所在的页；
/// - [next] 是下一页的文本层（没有就传 null，此时不合并）；
/// - 返回的 [CrossPageSentence] 里 `text` 是合并后的完整句子，
///   起止坐标用于高亮与「回到朗读位置」（高亮仍然只画起始页那部分）。
CrossPageSentence buildCrossPageSentence(
  PdfPageTextLayer current,
  int sentenceIndex,
  PdfPageTextLayer? next,
) {
  final sentence = current.sentences[sentenceIndex];
  final single = CrossPageSentence(
    text: sentence.text,
    startPage: current.pageNumber,
    startSentence: sentenceIndex,
    endPage: current.pageNumber,
    endSentence: sentenceIndex,
  );

  // 只处理「本页最后一句」——中间那句断页是不可能的
  if (sentenceIndex != current.sentences.length - 1) return single;
  if (next == null || next.sentences.isEmpty) return single;
  if (!looksUnfinished(sentence.text)) return single;

  final head = next.sentences.first;
  // 拼的时候不要多加空格：中文直接接；英文才需要空格（看首尾字符判断）
  final needsSpace = _needsSpaceBetween(sentence.text, head.text);
  return CrossPageSentence(
    text: '${sentence.text}${needsSpace ? ' ' : ''}${head.text}',
    startPage: current.pageNumber,
    startSentence: sentenceIndex,
    endPage: next.pageNumber,
    endSentence: 0,
  );
}

bool _needsSpaceBetween(String a, String b) {
  if (a.isEmpty || b.isEmpty) return false;
  final x = a[a.length - 1];
  final y = b[0];
  // 两边都是 ASCII 字母/数字才补空格（英文单词之间）
  bool ascii(String c) => c.codeUnitAt(0) < 0x80 && c.trim().isNotEmpty;
  return ascii(x) && ascii(y);
}

// ---------------------------------------------------------------- 推进导航

/// 「读到哪一句」的轻量引用。
///
/// 刻意**不带 layer 引用**：会话（`PdfReadSession`）只持有这一个值就能知道
/// 位置，读文字时再用 [PdfPageTextLayer] 查。这样位置可以安全地跨页面存活
/// （阅读页 dispose 了、layer 缓存没了，位置本身还在）。
///
/// ⚠️ `pageIndex` 是 **0 起**的下标（内部统一用 0 起），
/// 而 `PdfPageTextLayer.pageNumber` 是 **1 起**（跟着 pdfrx 走）。
/// 两者差一，换算时容易错，所以这里写明。
class PdfSentenceRef {
  const PdfSentenceRef({
    required this.pageIndex,
    required this.sentenceIndex,
    required this.text,
  });

  /// 页下标（**0 起**）
  final int pageIndex;

  /// 该页里的句子下标（0 起）
  final int sentenceIndex;

  /// 这句话的文字（送合成用；不含跨页合并的后半句）
  final String text;

  @override
  bool operator ==(Object other) =>
      other is PdfSentenceRef &&
      other.pageIndex == pageIndex &&
      other.sentenceIndex == sentenceIndex;

  @override
  int get hashCode => Object.hash(pageIndex, sentenceIndex);

  @override
  String toString() => 'PdfSentenceRef($pageIndex, $sentenceIndex, "$text")';
}

/// 一次跨页查找最多跳过多少页没文字的页
///
/// 用来兜住「整本都是扫描件」这种情况：不然会从第 1 页一路扫到第 319 页。
/// 12 页足够跨过正文之间的空白页 / 插图页，又不会把整本书扫一遍。
const int maxBlankPagesToSkip = 12;

/// 取 [ref] 的**下一句**；到文档末尾返回 null。
///
/// 跨页规则（HANDOFF §4.28：PDF 一章即一页）：本页读完就跳到**下一页的第 0 句**。
/// 页面之间的「半句话衔接」不在这里做 —— 那是 [buildCrossPageSentence] 的职责，
/// 推进循环只管「下一页第一句」。
///
/// [layerOf] 用来按页下标取文本层。
///
/// ## ⚠️ 下一页「没有文字层」**不等于**读到头了（v1.21.4 修）
///
/// 原来这里写的是「取不到就返回 null = 读到头」，结果在真实书上踩了大坑：
/// 《共产主义ABC》第 7 页之后有**空白页**，于是朗读在第 8 页就认定「整本读完」
/// （实测 `isFinished=true`、319 页只读到第 8 页）。
///
/// 现在分两种情况：
///
/// | 情况 | 判据 | 处置 |
/// | --- | --- | --- |
/// | **空白页 / 插图页** | [isEmptyPage] 为真（真的抽过、确实没文字） | **跳过，继续往后找** |
/// | **还没抽出来 / 抽失败** | `layer == null` 且 [isEmptyPage] 为假 | 返回 null（不是读到头，是暂时没法推进） |
///
/// 第二种返回 null 时**不能**当成「读到头」往外报 —— 调用方要自己分清，
/// 否则用户看到的就是「书读到一半突然说读完了」。
PdfSentenceRef? nextPdfSentence(
  PdfSentenceRef ref,
  PdfPageTextLayer? Function(int pageIndex) layerOf, {
  bool Function(int pageIndex)? isEmptyPage,
  int pageCount = 1 << 30,
}) {
  final current = layerOf(ref.pageIndex);
  if (current != null && ref.sentenceIndex + 1 < current.sentences.length) {
    final s = current.sentences[ref.sentenceIndex + 1];
    return PdfSentenceRef(
      pageIndex: ref.pageIndex,
      sentenceIndex: ref.sentenceIndex + 1,
      text: s.text,
    );
  }
  // 本页读完了 → 往后找第一句有文字的页（跳过空白页）
  var skipped = 0;
  for (var page = ref.pageIndex + 1;
      page < pageCount && skipped <= maxBlankPagesToSkip;
      page++, skipped++) {
    final layer = layerOf(page);
    if (layer != null && layer.sentences.isNotEmpty) {
      final head = layer.sentences.first;
      return PdfSentenceRef(
        pageIndex: page,
        sentenceIndex: 0,
        text: head.text,
      );
    }
    final blank = isEmptyPage?.call(page) ?? false;
    if (!blank) {
      // 还没抽出来 / 抽失败：不是「读到头」，交给调用方重试
      return null;
    }
    // 确实是空白页：继续往后找
  }
  return null;
}

/// 某页的**第一句**（目录跳转 / 通知栏滚动都用它）。
///
/// 页越界、或那一页没有文字（扫描件）时返回 null。
PdfSentenceRef? firstSentenceOnPage(
  int pageIndex,
  PdfPageTextLayer? layer,
) {
  if (layer == null || layer.sentences.isEmpty) return null;
  final head = layer.sentences.first;
  return PdfSentenceRef(
    pageIndex: pageIndex,
    sentenceIndex: 0,
    text: head.text,
  );
}

/// 按页下标 + 句下标取引用；越界返回 null（供恢复位置时校验用）
PdfSentenceRef? sentenceRefAt(
  int pageIndex,
  int sentenceIndex,
  PdfPageTextLayer? layer,
) {
  if (layer == null) return null;
  if (sentenceIndex < 0 || sentenceIndex >= layer.sentences.length) return null;
  return PdfSentenceRef(
    pageIndex: pageIndex,
    sentenceIndex: sentenceIndex,
    text: layer.sentences[sentenceIndex].text,
  );
}

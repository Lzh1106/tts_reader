import 'dart:ui' show Rect;

import '../models/structured_document.dart';
import 'txt_chapters.dart' show DocumentTextSplitter;

/// PDF「自动排版」：把逐行抽出来的文本按语义合并回自然段落
///
/// 为什么需要它：PDF 里没有「段落」这种东西，只有一行行定位好的文字。
/// 抽取出来的文本因此是**每行一段**（阅读时一句话被拆成好几段，朗读也会平白
/// 多出停顿），而正文段落是页面上真实存在的结构，只是需要按语义猜回来。
///
/// 判定「这一行是不是上一行的续行」用两条线索：
/// 1. **行尾标点**：以 `。！？` 或收尾引号结束的行是完整段落；以 `，、；：` 或
///    连字符结束的行明显还没说完，必须接上；
/// 2. **行尾宽度**：文字排到接近右边界说明被排版硬折了，下一行是续行。
///    （拿不到右边界时退化成「行尾没有句末标点且不是明显的新段起始」）
///
/// 另外顺手处理三件 PDF 常见噪声：软连字符断词（`inter-` + `national`）、
/// 每页重复的页眉页脚、以及项目符号 / 编号开头的新段落。
///
/// 全程纯函数、无 IO，便于单测；供阅读页的「自动排版」按钮调用。
class ParagraphReflow {
  ParagraphReflow._();

  /// 行尾明显的「话没说完」标点：逗号 / 顿号 / 分号 / 冒号 / 破折号 / 连字符 /
  /// 开引号。命中了就一定还要接下一行。
  static final RegExp trailingOpen = RegExp(r'[，,、；;：:—–\-（(「『“"【《]$');

  /// 行尾的「话说完了」标点（含收尾引号与省略号）
  static final RegExp trailingClosed =
      RegExp(r'[。．.！!？?…]["”"』」》\)）\]］】]\s*$|[。．！!？?…]["”"』」》\)）\]］】]*$');

  /// 下一行以这些字符开头 → 它是上一行的续行（几乎不可能是一个新段落的第一句）
  static final RegExp _continuationStart =
      RegExp(r'^[，,、。．！!？?；;：:—–\-\)）\]］】』」》…]');

  /// 英文小写字母开头：上一行没写完才会这样换行
  static bool _startsLowerAscii(String text) {
    if (text.isEmpty) return false;
    final code = text.codeUnitAt(0);
    return code >= 0x61 && code <= 0x7A;
  }

  /// 行**中间**出现了「句末标点 + 后续句子的开头」
  ///
  /// 典型来源：PDF 里的软换行被抽取器接回同一行（`…sentence here.filler word…`）。
  /// 这种换行是排版折行，作者其实在这里分了段 —— 只看着行尾标点会把它漏掉，
  /// 于是整页被并成一段。
  ///
  /// 点号后面允许**零个或多个**空格：抽取出来的文本常常把折行处的空格也吃掉，
  /// 变成 `here.filler`（没有空格）与 `here. filler`（有空格）两种都要认。
  ///
  /// 三条分支各管一种写法（`.` 放进字符类里只是字面的点，所以要单独写）：
  /// - 中文句末标点 + 汉字（中文里句号后面直接接字，没有空格问题）；
  /// - `.`/`!`/`?` + 空格 + **大写**字母（英文的句子几乎总以大写开头）；
  /// - `.`/`!`/`?` + 直接跟着的单词（折行处的空格被吃掉时。这条会误伤
  ///   `No.1` 这类写法，但误判代价只是多分一段，比整页粘成一段轻得多）。
  ///
  /// **不认「`.` + 空格 + 小写字母」**：那是软换行把句子接回同一行的样子
  /// （`…here. filler word…` 里的 `filler` 其实是上一行的续词），
  /// 认了会把一整段从中间劈开。
  static final RegExp _midSentenceBreak = RegExp(
    r'[。．！？…]\s*[A-Z\u4e00-\u9fff]'
    r'|[.!?]\s+[A-Z]'
    r'|[.!?][A-Za-z][a-z]',
  );

  /// 行尾的标点（判断「行中间」时要排除行尾本身）
  static bool breaksMidLine(String text) {
    if (text.length < 8) return false;
    // 去掉行尾标点再找：行尾的句号属于第 1 条判据，不算「行中间」
    final body = text.replaceAll(RegExp(r'[。．.!！?？…\s]+$'), '');
    return _midSentenceBreak.hasMatch(body);
  }

  /// 明显的「新段落开头」：项目符号、编号列表、序号
  ///
  /// 注意**不能把 `.` 也算成编号分隔符**：英文句子就以 `.` 结尾，
  /// `…margin.` 这种行会被误判成「1. 标题」那一类，整页被切得七零八落。
  /// 所以窄化成「数字 + `、`」（中文排版用的编号形式）。
  /// `[一二三四五六七八九十]+[、.]` 里的 `.` 保留：它要求中文数字在前，
  /// `三.` 这种写法只有编号会用，不会与英文句子撞车。
  static final RegExp newBlockStart = RegExp(
    r'^\s*([•·▪◦※*\-–—]\s|\(?\d{1,3}[)）]\s|\d{1,3}\s*[、]\s|'
    r'[一二三四五六七八九十]+[、.]\s|第\s*\d+\s*[章节節条條])',
  );

  /// 明显是标题的行（很短、不含句末标点、常见于页首）
  static final RegExp headingLike = RegExp(
    r'^(第\s*[0-9一二三四五六七八九十百千]+\s*[章节節回卷篇部集话話]|'
    r'chapter\s|part\s|附录|附錄|目录|目錄|前言|序言|后记|後記|参考文献|參考文獻)',
    caseSensitive: false,
  );

  /// 页脚常见的纯页码行（`12`、`- 12 -`、`第 12 页`、`12 / 340`）
  static final RegExp pageNumberLike = RegExp(
    r'^\s*[-—–\[]*\s*(第\s*)?\d{1,4}\s*(页|頁|/\s*\d{1,4})?\s*[-—–\]]*\s*$',
  );

  /// 硬折行的判定阈值：行右边界达到「该行最宽处」的这个比例就算排满了
  static const double wrappedRatio = 0.88;

  /// 行太短时（不足这么多个字符）不靠宽度判断，只看标点
  static const int shortLineChars = 12;

  /// 诊断钩子：非空时每次「另起一段」的判定都会回调一次
  ///
  /// 这套判据全是启发式的，遇到「这本 PDF 排得不对」时只能靠它看清楚
  /// 到底是哪一条规则命中了。正式代码不设置它，零开销（一次 null 判断）。
  static void Function(String message)? debugSink;

  static void _debug(String message) => debugSink?.call(message);

  /// 把一页（或一段连续抽取的文本行）合并成自然段落
  ///
  /// [lines] 按页面上的先后顺序给出；[rightEdge] 是正文右边界（PDF 页面坐标，
  /// 拿不到就传 0，此时只按标点判断）。
  static List<Paragraph> reflowPage(List<ReflowLine> lines,
      {double rightEdge = 0}) {
    final paragraphs = <Paragraph>[];
    if (lines.isEmpty) return paragraphs;

    final rows = _filterChrome(lines);
    if (rows.isEmpty) return paragraphs;

    final edge = rightEdge > 0 ? rightEdge : _widestRight(rows);
    _debug('reflowPage: lines=${lines.length} rows=${rows.length} edge=$edge');
    final buffer = StringBuffer();
    // 「上一行」的文字与外框都要留着：宽度判断只有拿到上一行的右边界才有意义
    var previous = '';
    ReflowLine? previousRow;

    void flush() {
      final text = buffer.toString().trim();
      buffer.clear();
      previous = '';
      previousRow = null;
      if (text.isEmpty) return;
      final sentences = DocumentTextSplitter.splitSentences(text);
      if (sentences.isNotEmpty) paragraphs.add(Paragraph(sentences: sentences));
    }

    for (final row in rows) {
      final text = row.text.trim();
      if (text.isEmpty) {
        flush(); // 空行 = 作者真的分段了
        continue;
      }
      if (buffer.isEmpty) {
        buffer.write(text);
        previous = text;
        previousRow = row;
        continue;
      }
      // 这一行要另起一段的三种情况：
      // 1. 当前行本身是明显的段首标记（项目符号 / 编号）；
      // 2. 当前行是标题行（很短、以「第 X 章」这类词开头）；
      // 3. 上一行已经把话说完了（句末标点，或没排满右边界 = 段落末行）。
      // 注意 2 / 3 判的是**上一行**：续行与否取决于上一行停在哪里。
      final lastRow = previousRow;
      final ends = lastRow != null && _rowEndsParagraph(lastRow, previous, text, edge);
      final block = _startsNewBlock(text);
      final heading = _isHeadingRow(text);
      if (block || heading || ends) {
        _debug('break block=$block heading=$heading ends=$ends '
            'prevRight=${lastRow?.bounds.right} edge=$edge text="$text"');
        flush();
        buffer.write(text);
        previous = text;
        previousRow = row;
        continue;
      }
      // 续行：先按需补空格 / 去掉断词连字符，再拼上去
      final dehyphenate = _needsDehyphenate(previous, text);
      if (dehyphenate) {
        // 把上一行末尾的连字符去掉（buffer 最后写入的就是它）
        final soFar = buffer.toString();
        buffer.clear();
        buffer.write(soFar.substring(0, soFar.length - 1));
      } else {
        final separator = lineSeparator(previous, text);
        if (separator.isNotEmpty) buffer.write(separator);
      }
      buffer.write(text);
      previous = text;
      previousRow = row;
    }
    flush();
    return paragraphs;
  }

  /// 把整份文档（PDF 一页一章）重新排版，返回新的章节列表
  ///
  /// 只需要「页面文字行」的文档（也就是 PDF 文本模式）才有意义：
  /// 其它格式自带段落标记，重排反而会破坏原结构，因此返回 null 让调用方放弃。
  ///
  /// 返回 null 有两种情况：没有行信息，或者**重排后内容与原来完全一样**。
  /// 界面要区分这两种情况（提示文案不同），用 [analyze] 拿诊断信息。
  static List<Chapter>? reflowDocument(
    List<Chapter> chapters,
    Map<int, List<ReflowLine>> linesByPage,
  ) =>
      analyze(chapters, linesByPage).chapters;

  /// 与 [reflowDocument] 同逻辑，但把「为什么没重排」的原因一起带回来
  ///
  /// 界面用它写诊断日志：用户反馈「点了自动排版没反应」时，
  /// 一条日志就能看出是没行信息、还是判据认为本就排好了。
  static ReflowReport analyze(
    List<Chapter> chapters,
    Map<int, List<ReflowLine>> linesByPage,
  ) {
    var beforeParagraphs = 0;
    var afterParagraphs = 0;
    var pagesWithLines = 0;
    var firstPageDiagnostic = '';
    final reflowed = <Chapter>[];
    var changed = false;
    for (var i = 0; i < chapters.length; i++) {
      final chapter = chapters[i];
      beforeParagraphs += chapter.paragraphs.length;
      final lines = linesByPage[i];
      if (lines == null || lines.isEmpty) {
        afterParagraphs += chapter.paragraphs.length;
        reflowed.add(chapter);
        continue;
      }
      pagesWithLines++;
      final captured = <String>[];
      debugSink = captured.add;
      final paragraphs = reflowPage(lines);
      debugSink = null;
      if (paragraphs.isEmpty) {
        if (firstPageDiagnostic.isEmpty) {
          firstPageDiagnostic = '第 1 页重排没有产出段落（原文 ${chapter.paragraphs.length} 段）';
        }
        afterParagraphs += chapter.paragraphs.length;
        reflowed.add(chapter);
        continue;
      }
      afterParagraphs += paragraphs.length;
      // 判「有没有变」要**比内容**，不能只比段数：PDF 一页一章时原文常常
      // 本来就只有一段（多行挤在一段里），重排后段数一样、但正文已经被合并了。
      if (!changed && !_sameParagraphs(chapter.paragraphs, paragraphs)) {
        changed = true;
      }
      if (firstPageDiagnostic.isEmpty) {
        // 「解析出来的原文」与「重排结果」各取开头一段，便于对照排查
        final original = chapter.paragraphs.isEmpty ? '' : chapter.paragraphs.first.text;
        firstPageDiagnostic = '${captured.join(' | ')} ｜原文${chapter.paragraphs.length}段'
            '「${_head(original)}」→排版后${paragraphs.length}段'
            '「${_head(paragraphs.first.text)}」';
      }
      reflowed.add(Chapter(title: chapter.title, paragraphs: paragraphs));
    }
    return ReflowReport(
      chapters: changed ? reflowed : null,
      pagesWithLines: pagesWithLines,
      beforeParagraphs: beforeParagraphs,
      afterParagraphs: afterParagraphs,
      diagnostic: firstPageDiagnostic,
    );
  }

  /// 段落列表的内容是否完全一致（段数 + 每段文本 + **每段的分句**）
  ///
  /// ⚠️ 为什么必须连**分句**一起比（v1.21.47 踩到）：
  /// 原来只比段落文本，于是「段落没变、但句子的切分变了」会被判成"无变化" →
  /// `ReflowReport.chapters == null` → **用户点了「自动排版」什么都不会发生**。
  /// 真机回归用例：`test/reader_auto_format_test.dart` 的"点一次排版应当开启并落盘"，
  /// 在 v1.21.47 改分句规则（不再把英文缩写 `H.` / 小数点切成句）之后**变红** ——
  /// 因为那一页重排后的段落文本与原文一字不差，可句子已经不同了。
  ///
  /// 「排版」这件事本来就要重算分句（朗读的停顿位置跟着变），所以分句变也算变。
  static bool _sameParagraphs(List<Paragraph> a, List<Paragraph> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].text != b[i].text) return false;
      final sa = a[i].sentences;
      final sb = b[i].sentences;
      if (sa.length != sb.length) return false;
      for (var s = 0; s < sa.length; s++) {
        if (sa[s].text != sb[s].text) return false;
      }
    }
    return true;
  }

  /// 诊断日志里截断长文本（只留开头，够定位就行）
  static String _head(String text) =>
      text.length <= 60 ? text : '${text.substring(0, 60)}…';

  /// 丢掉每页重复出现的页眉 / 页脚与纯页码行
  ///
  /// 判据保守：同一段文字在至少 2 页的**首两行或末两行**出现过，且整行不超过
  /// [chromeMaxChars] 个字，才算页眉页脚。正文里正常重复的句子不会被误删。
  static const int chromeMaxChars = 40;

  static List<ReflowLine> _filterChrome(List<ReflowLine> lines) {
    if (lines.length < 8) return lines; // 行太少（一页都没排满）不做去噪，避免误删
    final counts = <String, int>{};
    final zones = <String, Set<int>>{};
    for (final row in lines) {
      final text = row.text.trim();
      if (text.isEmpty || text.length > chromeMaxChars) continue;
      final zone = _zoneOf(row, lines);
      if (zone == 0) continue;
      counts[text] = (counts[text] ?? 0) + 1;
      zones.putIfAbsent(text, () => <int>{}).add(zone);
    }
    if (counts.isEmpty) return lines;
    final trimmed = lines
        .where((row) => !_isChrome(row, lines, counts, zones))
        .toList(growable: false);
    // 全被删掉说明判据不适用（整页都是小字块），退回原样
    return trimmed.isEmpty ? lines : trimmed;
  }

  /// 位置分区：1 = 页首两行，2 = 页尾两行，0 = 中间
  static int _zoneOf(ReflowLine row, List<ReflowLine> lines) {
    final index = lines.indexOf(row);
    if (index < 0) return 0;
    if (index <= 1) return 1;
    if (index >= lines.length - 2) return 2;
    return 0;
  }

  static bool _isChrome(
    ReflowLine row,
    List<ReflowLine> lines,
    Map<String, int> counts,
    Map<String, Set<int>> zones,
  ) {
    final text = row.text.trim();
    if (text.isEmpty) return false;
    final zone = _zoneOf(row, lines);
    if (zone == 0) return false;
    // 纯页码行：只要在页首/页尾就直接丢，不必重复出现
    if (pageNumberLike.hasMatch(text)) return true;
    if (text.length > chromeMaxChars) return false;
    return (counts[text] ?? 0) >= 2 && (zones[text]?.length ?? 0) >= 1;
  }

  /// 这一行是不是「完整段落」的结尾（结合文字、外框、以及下一行的开头）
  ///
  /// 判据按可靠性排序，宁可多分段也不要把两段粘成一段：
  /// 1. 行尾句末标点 → 说完了（最可靠）；
  /// 2. 行尾是逗号 / 开引号等 → 一定没说完；
  /// 3. **下一行以标点或小写字母开头** → 它只能是续行（新段落不会这么开头）；
  /// 4. 行排到了接近右边界 → 被排版硬折了，下一行是续行；
  /// 5. 其余（行短、无标点、下一行像新句子）→ 当成段落末行，保守断开。
  ///
  /// 第 4 条单独用时不够：PDF 抽取出来的行**参差不齐**（一段的最后一行本来就短），
  /// 而且文字行外框常常只是字身、右边界估计偏保守，只靠宽度会把该合的段落拆开。
  static bool _rowEndsParagraph(
    ReflowLine row,
    String text,
    String next,
    double edge,
  ) {
    if (text.isEmpty) return true;
    // 1. 说完了
    if (trailingClosed.hasMatch(text)) return true;
    // 2. 行中间就有句末标点 + 新句子开头：软换行被接回来了，作者在这里分段
    if (breaksMidLine(text)) return true;
    // 3. 明显没说完
    if (trailingOpen.hasMatch(text)) return false;
    // 4. 下一行只能接在上一行后面
    if (next.isNotEmpty &&
        (_continuationStart.hasMatch(next) || _startsLowerAscii(next))) {
      return false;
    }
    if (edge <= 0) return false; // 没有宽度信息时，只能靠标点
    // 太短的一行不像是被折出来的（多是被强制换行的短句 / 标题）
    if (text.length < shortLineChars) return true;
    // 5. 排到接近右边界 → 被排版硬折了，这一段还没完（注意这里是取反）
    return row.bounds.right < edge * wrappedRatio;
  }

  /// 当前行是不是「新段落的开头」（项目符号 / 编号列表）
  static bool _startsNewBlock(String text) => newBlockStart.hasMatch(text);

  /// 拼接时上一行末尾要不要去掉连字符（英文断词：`inter-` + `national`）
  static bool _needsDehyphenate(String previous, String next) {
    if (previous.length < 2 || next.isEmpty) return false;
    if (previous.codeUnitAt(previous.length - 1) != 0x2D) return false;
    final before = previous.codeUnitAt(previous.length - 2);
    final first = next.codeUnitAt(0);
    // 只有「字母-小写字母」才算断词；后面是大写时更像是 `well-Known`
    // 这类保留连字符的写法，就不动它
    return _isAsciiLetter(before) && first >= 0x61 && first <= 0x7A;
  }

  /// 续行拼接前要补的分隔符（纯函数，便于单测）
  ///
  /// - 两侧都是 ASCII 词字符 → 空格（英文换行本来就在词间断开，空格要补回来）；
  /// - 其余（中文之间、或一侧是标点）→ 空串，中文拼接不该插空格。
  ///
  /// 注意上一行以连字符结尾时**不该**补空格：`well-` + `Known` 里那个连字符
  /// 已经占住了词间位置，再补一个空格会变成 `well- Known`。
  static String lineSeparator(String previous, String next) {
    if (previous.isEmpty || next.isEmpty) return '';
    final last = previous.codeUnitAt(previous.length - 1);
    final first = next.codeUnitAt(0);
    return _isAsciiWord(last) && _isAsciiWord(first) ? ' ' : '';
  }

  static bool _isHeadingRow(String text) =>
      headingLike.hasMatch(text) && text.length <= 40;

  static bool _isAsciiLetter(int code) =>
      (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);

  static bool _isAsciiWord(int code) =>
      _isAsciiLetter(code) || (code >= 0x30 && code <= 0x39);

  static double _widestRight(List<ReflowLine> rows) {
    var widest = 0.0;
    for (final row in rows) {
      if (row.text.trim().isEmpty) continue;
      if (row.bounds.right > widest) widest = row.bounds.right;
    }
    return widest;
  }
}

/// 自动排版的结论与诊断信息（见 [ParagraphReflow.analyze]）
class ReflowReport {
  const ReflowReport({
    required this.chapters,
    required this.pagesWithLines,
    required this.beforeParagraphs,
    required this.afterParagraphs,
    required this.diagnostic,
  });

  /// 重排后的章节；**没有变化时为 null**（界面据此提示「无需重排」）
  final List<Chapter>? chapters;

  /// 有多少页拿到了文字行信息
  final int pagesWithLines;

  /// 重排前后的段落总数（用来看效果）
  final int beforeParagraphs;
  final int afterParagraphs;

  /// 第一页的判定诊断（每一条「另起一段」的原因）
  final String diagnostic;

  bool get changed => chapters != null;

  /// 诊断日志用的一行摘要
  String get summary =>
      '有行信息的页=$pagesWithLines 段数 $beforeParagraphs→$afterParagraphs '
      '有变化=$changed';
}

/// 页面上一行文字（文字 + 外框），与 `PdfLineBox` 同构
/// 单独定义是为了让排版逻辑不依赖 `dart:ui` 之外的模型细节，单测更好写。
class ReflowLine {
  const ReflowLine({
    required this.text,
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
  });

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;

  /// 外框（PDF 页面坐标）
  Rect get bounds => Rect.fromLTRB(left, top, right, bottom);

  double get width => right - left;

  double get height => bottom - top;

  @override
  String toString() => 'ReflowLine(${width.toStringAsFixed(0)}x'
      '${height.toStringAsFixed(0)} @${right.toStringAsFixed(0)} "$text")';
}

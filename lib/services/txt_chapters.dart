import '../models/structured_document.dart';

/// 一行文本被识别成章节标题时的结果
class TxtHeading {
  const TxtHeading({required this.title, required this.line, this.number, this.kind = ''});

  /// 目录里显示的标题（就是原行，去掉首尾空白）
  final String title;

  /// 原文行号（从 0 开始），便于排查
  final int line;

  /// 章节号（能解析出来时），用于「卷 / 章」层级与单调性校验
  final int? number;

  /// 命中的类型：chapter / volume / special / english / numbered
  final String kind;

  @override
  String toString() => 'TxtHeading($title, line=$line, kind=$kind, number=$number)';
}

/// TXT 章节切分
///
/// 纯函数、无 IO，便于单测。识别的顺序与取舍：
/// 1. 中文章节标题（`第X章` / `第X节` / `第X回` …）——最常见，优先；
/// 2. 卷 / 部 / 篇（`第三卷 风起`）——作为标题保留，让目录里能看到分层；
/// 3. 特殊章节名（`楔子` / `序章` / `番外` / `尾声` / `后记` …）；
/// 4. 英文 `Chapter 12`；
/// 5. 纯数字编号（`12. 标题`）——**只有在前面几种都识别不到时**才启用，
///    否则会把正文里的编号列表误当成章节。
///
/// 判据不只看正则，还要求这一行「像标题」：够短、独占一行、不含句末标点。
/// 识别不到（或只识别出一两处）时返回单章「全文」，与旧行为一致。
class TxtChapterSplitter {
  TxtChapterSplitter._();

  /// 标题行的最大长度：超过这个长度的行按正文处理
  static const int maxHeadingLength = 48;

  /// 至少识别出这么多处才认为「这本书有章节」，否则回退成单章
  static const int minHeadings = 2;

  /// 纯数字编号策略的门槛（比主策略高，见 [split]）
  static const int minNumberedHeadings = 3;

  /// 纯数字编号策略下，平均每章至少要有这么多字
  static const int minNumberedChapterChars = 120;

  /// 中文章节：第 12 章 / 第一百二十三章 / 第 3 节 / 第十二回 / 第一话
  static final RegExp _cnNumbered = RegExp(
    r'^第\s*([0-9０-９零〇一二三四五六七八九十百千两]+)\s*([章节節回卷篇部集话話幕])',
  );

  /// 特殊章节名（可带后缀标题）
  ///
  /// 后面只允许「行尾 / 空白 / 标点 / 数字」，避免把「序章写得很潦草」这种正文当成标题；
  /// 不能用 `\b`：中文之间没有词边界，`番外一` 会被判成不匹配。
  static final RegExp _special = RegExp(
    r'^(序章|序言|序曲|序幕|楔子|引子|前言|引语|后记|後記|尾声|尾聲|终章|終章|结局|番外|外传|外傳|'
    r'附录|附錄|作品相关|作品相關|作者的话|作者的話|开篇|開篇|正文)'
    r'(?=$|[\s、，,：:·\-—－_【（(\[0-9０-９一二三四五六七八九十]|第)',
  );

  /// 英文：Chapter 12 / CHAPTER XII / Chapter One（拼写数字也常见）
  static final RegExp _english = RegExp(
    r'^(chapter|part|book|section)\s+([0-9]+|[IVXLCDM]+|[A-Za-z]+)\b',
    caseSensitive: false,
  );

  /// 纯数字编号：12. 标题 / 12、标题（次要策略）
  static final RegExp _numbered = RegExp(r'^([0-9]{1,4})\s*[、.．，,:：]\s*\S');

  /// 句末标点：标题里不该出现（出现就说明这是正文）
  static final RegExp _sentenceEnd = RegExp(r'[。！？!?；;]');

  /// 目录里「开篇」（第一个标题之前的内容）的标题
  static const String prologueTitle = '开篇';

  /// 没有章节时的单章标题
  static const String wholeTitle = '全文';

  /// 判断一行是不是标题；不是则返回 null
  ///
  /// [allowNumbered] 为真时才使用「纯数字编号」这条次要策略。
  static TxtHeading? headingOf(String rawLine, {required int line, bool allowNumbered = false}) {
    final title = rawLine.trim();
    if (title.isEmpty) return null;
    if (title.length > maxHeadingLength) return null;
    if (_sentenceEnd.hasMatch(title)) return null;
    // 目录行、网址行这类明显不是标题
    if (title.startsWith('http://') || title.startsWith('https://')) return null;

    final numbered = _cnNumbered.firstMatch(title);
    if (numbered != null) {
      final kind = switch (numbered.group(2)) {
        '卷' || '篇' || '部' => 'volume',
        _ => 'chapter',
      };
      return TxtHeading(
        title: title,
        line: line,
        number: parseChineseNumber(numbered.group(1)!),
        kind: kind,
      );
    }

    final special = _special.firstMatch(title);
    if (special != null) {
      return TxtHeading(title: title, line: line, kind: 'special');
    }

    final english = _english.firstMatch(title);
    if (english != null) {
      return TxtHeading(
        title: title,
        line: line,
        number: parseChineseNumber(english.group(2)!),
        kind: 'english',
      );
    }

    if (allowNumbered) {
      final plain = _numbered.firstMatch(title);
      if (plain != null) {
        return TxtHeading(
          title: title,
          line: line,
          number: int.tryParse(plain.group(1)!),
          kind: 'numbered',
        );
      }
    }
    return null;
  }

  /// 把整篇文本切成章节
  ///
  /// 识别不到章节（或只有一两处）时返回单章「全文」——与旧行为保持一致，
  /// 免得把普通文本切成乱七八糟的碎片。
  ///
  /// 性能注意（v1.16 改）：正文**不做 **`lines.sublist(...).join()`。
  /// 一本 300 万字、上千章的小说这么切，每章都要把该章的行数组复制一遍并重新
  /// 拼成字符串，累计是「章数 × 行数」级别的分配，几 MB 的书要几十秒。
  /// 现在改成先记下每行的起始下标（纯整数数组），正文按「行号区间 + 原字符串
  /// 区间」惰性截取，只复制真正要用的那一段。
  static List<Chapter> split(String text, {ParagraphSplitter? paragraphSplitter}) {
    final splitParagraphs = paragraphSplitter ?? _defaultParagraphs;
    final index = _LineIndex.of(text);
    final lineCount = index.length;

    // 第一遍：只用主策略
    var candidates = _collect(index, allowNumbered: false);
    if (candidates.length < minHeadings) {
      // 第二遍：放开纯数字编号（网络小说里「1、标题」也常见）。
      // 门槛比主策略高得多 —— 正文里的编号列表（购物清单、待办事项）不能被当成章节，
      // 所以要同时满足：条目够多、编号大体递增、每条后面是有句子的成段文字。
      final numbered = _collect(index, allowNumbered: true);
      if (_numberedLooksLikeChapters(index, numbered)) candidates = numbered;
    }
    if (candidates.length < minHeadings) {
      return <Chapter>[Chapter(title: wholeTitle, paragraphs: splitParagraphs(text))];
    }

    final chapters = <Chapter>[];
    // 第一个标题之前的内容（书名、作者、简介…）
    final leadParagraphs = splitParagraphs(index.range(0, candidates.first.line).trim());
    if (leadParagraphs.isNotEmpty) {
      chapters.add(Chapter(title: prologueTitle, paragraphs: leadParagraphs));
    }

    for (var i = 0; i < candidates.length; i++) {
      final heading = candidates[i];
      final end = i + 1 < candidates.length ? candidates[i + 1].line : lineCount;
      final paragraphs = splitParagraphs(index.range(heading.line + 1, end).trim());
      // 空章节（标题下面没内容）不进目录，避免目录里一堆点不开的条目
      if (paragraphs.isEmpty) continue;
      chapters.add(Chapter(title: heading.title, paragraphs: paragraphs));
    }

    if (chapters.isEmpty) {
      return <Chapter>[Chapter(title: wholeTitle, paragraphs: splitParagraphs(text))];
    }
    if (chapters.length == 1 && chapters.first.title == prologueTitle) {
      // 只有「开篇」说明候选标题下面的内容都空：当成无章节处理
      return <Chapter>[Chapter(title: wholeTitle, paragraphs: splitParagraphs(text))];
    }
    return chapters;
  }

  static List<TxtHeading> _collect(_LineIndex index, {required bool allowNumbered}) {
    final headings = <TxtHeading>[];
    for (var i = 0; i < index.length; i++) {
      final heading = headingOf(index.line(i), line: i, allowNumbered: allowNumbered);
      if (heading == null) continue;
      // 同一标题重复两行（有些 TXT 会「第1章」写两遍）只留一条
      if (headings.isNotEmpty &&
          headings.last.title == heading.title &&
          heading.line - headings.last.line <= 2) {
        continue;
      }
      headings.add(heading);
    }
    return headings;
  }

  /// 编号大体递增（允许少量回退，容忍分卷重排）
  static bool _mostlyIncreasing(List<TxtHeading> headings) {
    final numbers = headings.map((h) => h.number).whereType<int>().toList();
    if (numbers.length < minHeadings) return false;
    var increases = 0;
    for (var i = 1; i < numbers.length; i++) {
      if (numbers[i] > numbers[i - 1]) increases++;
    }
    return increases * 10 >= (numbers.length - 1) * 6; // 至少 60% 是递增的
  }

  /// 纯数字编号看起来像不像章节（见 [split] 的第二遍策略）
  ///
  /// 这一步只需要「每章多长」与「章里有没有成句的文字」，所以用
  /// [_LineIndex.rangeLength] 与 [_LineIndex.rangeHasMatch] 逐行判定，
  /// 不把每章正文拼成字符串 —— 否则这一步又变成「章数 × 全书」的复制。
  static bool _numberedLooksLikeChapters(_LineIndex index, List<TxtHeading> headings) {
    if (headings.length < minNumberedHeadings) return false;
    if (!_mostlyIncreasing(headings)) return false;
    var withProse = 0;
    var chars = 0;
    for (var i = 0; i < headings.length; i++) {
      final end = i + 1 < headings.length ? headings[i + 1].line : index.length;
      chars += index.rangeLength(headings[i].line + 1, end);
      if (index.rangeHasMatch(headings[i].line + 1, end, _prosePattern)) withProse++;
    }
    // 至少 60% 的条目后面有成句的文字，且平均每条不少于 [minNumberedChapterChars] 字
    if (withProse * 10 < headings.length * 6) return false;
    return chars / headings.length >= minNumberedChapterChars;
  }

  static final RegExp _prosePattern = RegExp(r'[。！？!?]');

  /// 中文数字 → 整数；纯阿拉伯数字直接解析
  ///
  /// 支持「一百二十三」「两千零一」「十二」这类写法，解析不出来返回 null。
  static int? parseChineseNumber(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final ascii = text.replaceAllMapped(
      RegExp(r'[０-９]'),
      (m) => String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0xFEE0),
    );
    final plain = int.tryParse(ascii);
    if (plain != null) return plain;
    // 罗马数字（英文标题用）
    final roman = _romanToInt(ascii.toUpperCase());
    if (roman != null) return roman;

    const digits = <String, int>{
      '零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5,
      '六': 6, '七': 7, '八': 8, '九': 9,
    };
    const units = <String, int>{'十': 10, '百': 100, '千': 1000};
    var total = 0;
    var section = 0;
    var current = 0;
    var touched = false;
    for (final char in ascii.split('')) {
      if (char == '万') {
        section = (section + current) == 0 ? 1 : (section + current);
        total += section * 10000;
        section = 0;
        current = 0;
        touched = true;
        continue;
      }
      final digit = digits[char];
      if (digit != null) {
        current = digit;
        touched = true;
        continue;
      }
      final unit = units[char];
      if (unit != null) {
        section += (current == 0 ? 1 : current) * unit;
        current = 0;
        touched = true;
        continue;
      }
      return null; // 出现不认识的字符：按解析失败处理
    }
    if (!touched) return null;
    final value = total + section + current;
    return value == 0 ? null : value;
  }

  static int? _romanToInt(String text) {
    if (text.isEmpty || !RegExp(r'^[IVXLCDM]+$').hasMatch(text)) return null;
    const values = <String, int>{'I': 1, 'V': 5, 'X': 10, 'L': 50, 'C': 100, 'D': 500, 'M': 1000};
    var total = 0;
    for (var i = 0; i < text.length; i++) {
      final value = values[text[i]]!;
      final next = i + 1 < text.length ? values[text[i + 1]]! : 0;
      total += value < next ? -value : value;
    }
    return total == 0 ? null : total;
  }

  static List<Paragraph> _defaultParagraphs(String raw) => DocumentTextSplitter.splitParagraphs(raw);
}

/// 行下标表：把整篇文本按 `\n` 切一次，只记「每行起始下标」的整数数组
///
/// 与 `text.split('\n')` 的区别：`split` 会为每一行分配一个新的 String 对象，
/// 几百万行的文本光是这一步就要几百 MB 峰值内存；这里只留一个 Int32 级别的数组
/// （100 万行约 4 MB），行文本按需要时才 [line] 出来。
///
/// 兼容 `\r\n`：只在行尾裁掉 `\r`，与 `split('\n')` 后再 `trim()` 的效果一致
/// （正文取区间时本来也会 trim）。
class _LineIndex {
  _LineIndex._(this._text, this._starts);

  final String _text;
  final List<int> _starts;

  static _LineIndex of(String text) {
    // 行数未知，先按平均 24 字符一行预估，避免反复扩容
    final starts = <int>[];
    starts.add(0);
    var from = 0;
    while (true) {
      final at = text.indexOf('\n', from);
      if (at < 0) break;
      starts.add(at + 1);
      from = at + 1;
    }
    return _LineIndex._(text, starts);
  }

  int get length => _starts.length;

  String line(int index) {
    if (index < 0 || index >= _starts.length) return '';
    final start = _starts[index];
    final end = index + 1 < _starts.length ? _starts[index + 1] - 1 : _text.length;
    var text = start >= end ? '' : _text.substring(start, end);
    if (text.endsWith('\r')) text = text.substring(0, text.length - 1);
    return text;
  }

  /// 第 [start] 行（含）到第 [end] 行（不含）的原文，行间补 `\n`
  ///
  /// 只做一次 substring —— 这正是旧实现 `lines.sublist(a, b).join('\n')` 最贵的地方。
  String range(int start, int end) {
    if (start < 0) start = 0;
    if (end > _starts.length) end = _starts.length;
    if (start >= end) return '';
    final from = _starts[start];
    final to = end < _starts.length ? _starts[end] - 1 : _text.length;
    if (from >= to) return '';
    return _text.substring(from, to);
  }

  /// 与 [range] 等价的字符数，但不分配字符串
  ///
  /// 用于「纯数字编号像不像章节」的判定：那一步只需要知道每章多长。
  int rangeLength(int start, int end) {
    if (start < 0) start = 0;
    if (end > _starts.length) end = _starts.length;
    if (start >= end) return 0;
    final from = _starts[start];
    final to = end < _starts.length ? _starts[end] - 1 : _text.length;
    return to > from ? to - from : 0;
  }

  /// 在 [start, end) 区间里找第一个匹配 [pattern] 的行；找不到返回 null
  ///
  /// 只遍历行文本、不保留，用于正文特征探测。
  bool rangeHasMatch(int start, int end, RegExp pattern) {
    if (start < 0) start = 0;
    if (end > _starts.length) end = _starts.length;
    for (var i = start; i < end; i++) {
      if (pattern.hasMatch(line(i))) return true;
    }
    return false;
  }
}

/// 段落切分（与 [DocumentService] 的内部实现保持一致，抽出来便于单测注入）
typedef ParagraphSplitter = List<Paragraph> Function(String raw);

/// 默认段落切分：按空行分段、按句末标点分句
class DocumentTextSplitter {
  DocumentTextSplitter._();

  static final RegExp blankLinePattern = RegExp(r'\n\s*\n');

  /// 句末标点（不含半角句点与省略号 —— 那两个要单独判，见 [splitSentences]）
  ///
  /// ⚠️ 省略号不在这里：`…` 在中文里多数出现在句中，当句末会切出大量碎片。
  static const String sentenceEnders = '。！？!?';

  /// 句末标点之后的「收尾标记」：跟在句末标点后面时归**本句**，
  /// 不该被切成下一句的开头（否则 `”` 会变成 1 字符的独立句）
  ///
  /// 含：中文右双引号 / 英文双引号 / 日式引号 / 直角引号 / 书名号 / 括号 / 单引号。
  /// 注意反斜杠在这里是**多余转义**（`)` 不需要转义），analyze 会报出来，所以不写。
  static const String trailingMarks = '”"』」》()）\'’';

  /// 句末标点（含常见收尾引号）：用来判断「这一行是不是一个完整段落」
  static final RegExp lineEnd = RegExp(r'[。！？…!?.”"』」》\)）]$');

  /// 续行标点：以这些收尾的行明显还没说完，硬折行的正文常这样断行
  static final RegExp lineContinues = RegExp(r'[，,、；;：:—…\-－]$');

  /// 通用段落切分：先按空行拆块；块超过 400 字且含换行时再按行拆。
  ///
  /// PDF / EPUB / 网页都自带段落标记，用这套就够。
  static List<Paragraph> splitParagraphs(String raw) {
    final blocks = <String>[];
    for (final block in raw.split(blankLinePattern)) {
      final trimmed = block.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.length > 400 && trimmed.contains('\n')) {
        for (final line in trimmed.split('\n')) {
          final one = line.trim();
          if (one.isNotEmpty) blocks.add(one);
        }
      } else {
        blocks.add(trimmed);
      }
    }
    final paragraphs = <Paragraph>[];
    for (final block in blocks) {
      final sentences = splitSentences(block);
      if (sentences.isNotEmpty) paragraphs.add(Paragraph(sentences: sentences));
    }
    return paragraphs;
  }

  /// 分句：保留标点，丢弃空白
  ///
  /// ## ⚠️ 改这里**必须同时**把 `DocumentService.parseRevision` +1
  ///
  /// 分句结果会被写进解析缓存；老缓存配新代码会导致
  /// 「句子总数对不上 → 朗读游标来回跳、反复重启、最后卡住」（2026-10-14 真机事故）。
  ///
  /// ## ⚠️ 这里是"一个字母当一句话"的根源（v1.21.47 重写）
  ///
  /// 原来只有一条正则：`[^。！？!?\.\n]+[。！？!?\.]*` —— 它把**每个点号**都当句末。
  /// 于是真机上（《一八七一年巴黎公社史》epub，用户报"把一个字母当一句话"）：
  ///
  /// * 外国人名缩写被切成独立句：`H.` / `A.` / `J.` / `N.` / `Ф.` / `Β.` …
  ///   全本 **741 条**这种 ≤2 字符的"句子"；
  /// * 小数点也被切：`3.14` → `3.` + `14`；
  /// * **收尾引号被切到下一句开头**：`…好转。»«”»` —— 那个 `”` 成了 1 字符的独立句。
  ///
  /// 后两条 **PDF 那边早就修过**（`pdf_text_layer.dart` 的 `_isSentenceEnd`：
  /// 小数点 / 缩写 / 句后收尾引号都有保护），而 EPUB / TXT 走的是本方法，
  /// 一直没有那套保护 —— 用户的原话是「epub 犯了之前在 pdf 上修好的 bug」。
  ///
  /// 现在改成和 PDF **同一套判据**（逐字符扫描）：
  /// * 半角句点：前数字后数字 → 小数点，不断；前大写字母后大写字母 → 缩写，不断；
  ///   后面紧跟小写字母 → 缩写 / 网址，不断；
  /// * 句末标点之后的**收尾引号 / 括号 / 引号式书名号**不被切成新句，
  ///   而是把标记交出去、留给下一句开头（与 PDF 的取舍一致：简单规则不容易错）。
  static List<Sentence> splitSentences(String block) {
    final sentences = <Sentence>[];
    final buffer = StringBuffer();

    /// 当前 buffer 收尾是不是"句末标点 + 可选收尾标记" —— 是就可以收一句了
    bool isBreakPoint() {
      final t = buffer.toString();
      if (t.isEmpty) return false;
      var end = t.length - 1;
      while (end >= 0 && trailingMarks.contains(t[end])) {
        end--;
      }
      if (end < 0) return false;
      return sentenceEnders.contains(t[end]);
    }

    void flush() {
      final text = buffer.toString().trim();
      buffer.clear();
      if (text.isNotEmpty) sentences.add(Sentence(text));
    }

    for (var i = 0; i < block.length; i++) {
      final ch = block[i];
      // 换行只当空白：`splitParagraphs` 已经把段落拆开了，这里不再按行断句
      if (ch == '\n' || ch == '\r') {
        if (buffer.isNotEmpty && !buffer.toString().endsWith(' ')) buffer.write(' ');
        continue;
      }
      buffer.write(ch);
      if (ch == '.') {
        if (_isDecimalPoint(block, i) || _isAbbreviationDot(block, i)) continue;
      } else if (ch == '…') {
        // 省略号**不当句末**（v1.21.47）：中文里 `…` 绝大多数出现在**句子中间**
        // （「他犹豫了一下……然后走了」），当句末会切出一堆 1~2 字符的碎片
        // （真机那本书里 512 条 `…` / `…”` 独立成句，读起来一頓一頓）。
        // 真正的停顿由后面的 `。！？` 给出。
        continue;
      } else if (!sentenceEnders.contains(ch)) {
        continue;
      }
      // 走到这里 ch 是句末标点（或一个真正的句点）：
      // 把紧随其后的收尾引号 / 括号一并算进**本句**，避免它们变成独立句。
      var j = i + 1;
      while (j < block.length && trailingMarks.contains(block[j])) {
        buffer.write(block[j]);
        j++;
      }
      if (isBreakPoint()) flush();
      i = j - 1;
    }
    flush();
    return sentences;
  }

  /// 半角句点是不是小数点（`3.14`）：前后都是数字
  static bool _isDecimalPoint(String s, int i) {
    if (i <= 0 || i + 1 >= s.length) return false;
    return _isDigit(s[i - 1]) && _isDigit(s[i + 1]);
  }

  /// 半角句点是不是缩写点（`A.` / `U.S.` / `No.1` / `e.g.`）
  ///
  /// 判据（与 PDF 那份一致）：
  /// * 单个字母 + 点 + 空格/收尾 → 缩写（`H.` `A.`）—— 这是"一个字母当一句"的正主；
  /// * 点后面紧跟另一个大写字母 → 缩写内部（`U.S.`）；
  /// * 点后面紧跟小写字母 → 缩写 / 网址（`No.1` `e.g.`）。
  static bool _isAbbreviationDot(String s, int i) {
    final prev = i > 0 ? s[i - 1] : '';
    final next = i + 1 < s.length ? s[i + 1] : '';
    // 前一个字符是字母（含西里尔 / 希腊字母），且点在词中间或后接空格 → 缩写
    if (_isLetter(prev) && (next.isEmpty || next == ' ')) return true;
    if (_isUpper(next)) return true;
    if (_isLower(next)) return true;
    return false;
  }

  static bool _isDigit(String ch) =>
      ch.isNotEmpty && '0123456789'.contains(ch);

  /// 字母：ASCII + 拉丁扩展 + 西里尔 + 希腊（这本书里的人名缩写有 `Ф.` `Β.`）
  static bool _isLetter(String ch) {
    if (ch.isEmpty) return false;
    final c = ch.codeUnitAt(0);
    return (c >= 0x41 && c <= 0x5A) || // A-Z
        (c >= 0x61 && c <= 0x7A) || // a-z
        (c >= 0x00C0 && c <= 0x024F) || // 拉丁扩展
        (c >= 0x0370 && c <= 0x03FF) || // 希腊
        (c >= 0x0400 && c <= 0x04FF); // 西里尔
  }

  static bool _isUpper(String ch) {
    if (ch.isEmpty) return false;
    final c = ch.codeUnitAt(0);
    return (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x0391 && c <= 0x03A9) || // Α-Ω
        (c >= 0x0410 && c <= 0x042F); // А-Я
  }

  static bool _isLower(String ch) {
    if (ch.isEmpty) return false;
    final c = ch.codeUnitAt(0);
    return (c >= 0x61 && c <= 0x7A) ||
        (c >= 0x03B1 && c <= 0x03C9) || // α-ω
        (c >= 0x0430 && c <= 0x044F); // а-я
  }

  /// TXT 专用段落切分：默认「一行一段」，硬折行的正文会被合并回去
  ///
  /// 小说 TXT 有两种常见排法：
  /// - 一段一行（起点、番茄这类导出常见）——直接一行一段最准；
  /// - 按 80 列硬折行——按行切会把一句话劈成两段，朗读时平白多出停顿。
  ///
  /// 判据：这一行以句末标点（或收尾引号）结束 → 认为是一个完整段落；
  /// 否则与下一行合并。空行一律断段；超长（>1000 字）也会强制断开，避免一段过大。
  static List<Paragraph> splitTextParagraphs(String raw) {
    final paragraphs = <Paragraph>[];
    final buffer = StringBuffer();
    var lastChar = '';

    void write(String text) {
      if (text.isEmpty) return;
      buffer.write(text);
      lastChar = text[text.length - 1]; // 只关心末字符，别为了它整段 toString()
    }

    void flush() {
      final text = buffer.toString().trim();
      buffer.clear();
      lastChar = '';
      if (text.isEmpty) return;
      final sentences = splitSentences(text);
      if (sentences.isNotEmpty) paragraphs.add(Paragraph(sentences: sentences));
    }

    for (final rawLine in raw.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        flush(); // 空行 = 明确的分段
        continue;
      }
      if (buffer.isNotEmpty && _isAsciiWord(lastChar) && _isAsciiWord(line[0])) {
        // 中英混排：两侧都是 ASCII 字母数字时补一个空格，其余直接拼接
        write(' ');
      }
      write(line);
      final complete = lineEnd.hasMatch(line);
      // 短行（像「他点点头」这种没标点的动作句）也按独立段落处理，
      // 但以逗号 / 顿号 / 冒号收尾的行明显还要接着说，不能断（硬折行的正文就是这样）。
      final continues = lineContinues.hasMatch(line);
      if (complete || buffer.length > 1000 || (line.length <= 20 && !continues)) flush();
    }
    flush();
    return paragraphs;
  }

  static bool _isAsciiWord(String char) {
    if (char.isEmpty) return false;
    final code = char.codeUnitAt(0);
    return (code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);
  }
}

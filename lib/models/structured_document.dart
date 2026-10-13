/// 朗读粒度：句 / 章 / 页（默认按句）
enum ReadGranularity {
  sentence('按句'),
  chapter('按章'),
  page('按页');

  const ReadGranularity(this.label);

  final String label;
}

/// 最小朗读单元：一句话（保留句末标点）
class Sentence {
  const Sentence(this.text);

  final String text;

  @override
  String toString() => text;
}

/// 段落：由若干句子组成
class Paragraph {
  const Paragraph({required this.sentences});

  final List<Sentence> sentences;

  /// 段落纯文本（句间不加空格，避免中文朗读出现停顿）
  String get text => sentences.map((s) => s.text).join();
}

/// 章节：由若干段落组成
class Chapter {
  const Chapter({required this.title, required this.paragraphs});

  final String title;
  final List<Paragraph> paragraphs;

  /// 整章纯文本
  String get text => paragraphs.map((p) => p.text).join('\n');
}

/// 文档自带的目录条目（PDF 书签 / EPUB 的 nav 与 NCX）
///
/// 与「章节」分开存：章节结构是我们自己切的（PDF 一页一章、EPUB 一个正文文件一章），
/// 而目录是原书作者写的，可能更细（多层、指向同一章的不同位置），也可能更粗或干脆没有。
class DocumentOutlineEntry {
  const DocumentOutlineEntry({
    required this.title,
    required this.chapter,
    this.paragraph = 0,
    this.depth = 0,
  });

  final String title;

  /// 落在第几章（PDF 就是第几页，从 0 开始）
  final int chapter;

  /// 章内第几段（能定位到段时才有意义）
  final int paragraph;

  /// 层级：0 是顶层，越大越深，用于目录缩进
  final int depth;

  @override
  String toString() => '${'  ' * depth}$title → 第 ${chapter + 1} 章';
}

/// 结构化文档：解析结果，供朗读游标定位
///
/// 统计量与游标索引都用 `late final` 惰性缓存：PDF 会拆成上千章，
/// 如果每朗读一句都重新折叠统计一遍，会明显拖慢（通知栏进度也会跟着卡）。
class StructuredDocument {
  StructuredDocument({
    required this.chapters,
    this.chapterIsPage = false,
    this.outline = const <DocumentOutlineEntry>[],
  });

  StructuredDocument.empty()
    : chapters = const <Chapter>[],
      chapterIsPage = false,
      outline = const <DocumentOutlineEntry>[];

  final List<Chapter> chapters;

  /// 原书自带的目录（可能为空）
  final List<DocumentOutlineEntry> outline;

  /// 目录条目够不够撑起一个目录面板（只有一两条就没必要单独给一栏）
  bool get hasOutline => outline.length >= 2;

  /// 目录标题的最大层级（用于缩进上限）
  int get maxOutlineDepth =>
      outline.isEmpty ? 0 : outline.map((entry) => entry.depth).reduce((a, b) => a > b ? a : b);


  /// true 表示「一章 == 一页」（PDF 按真实页拆分），此时页号与章号等价
  final bool chapterIsPage;

  bool get isEmpty => chapters.isEmpty;

  /// 段落总数
  late final int paragraphCount =
      chapters.fold(0, (sum, c) => sum + c.paragraphs.length);

  /// 句子总数
  late final int sentenceCount = chapters.fold(
    0,
    (sum, c) => sum + c.paragraphs.fold(0, (inner, p) => inner + p.sentences.length),
  );

  /// 每章起始句序号（前缀和），把「游标 → 全局句序号」从 O(全篇) 降到 O(单章)
  late final List<int> _chapterSentenceStart = _buildChapterStarts();

  List<int> _buildChapterStarts() {
    final starts = List<int>.filled(chapters.length + 1, 0);
    var index = 0;
    for (var c = 0; c < chapters.length; c++) {
      starts[c] = index;
      for (final paragraph in chapters[c].paragraphs) {
        index += paragraph.sentences.length;
      }
    }
    starts[chapters.length] = index;
    return starts;
  }

  /// 整篇纯文本
  String get plainText => chapters.map((c) => c.text).join('\n');

  /// 游标对应的全局句序号（从 0 开始），用于进度与通知栏时间轴
  int indexOfCursor((int, int, int) cursor) {
    final chapter = cursor.$1;
    if (chapter < 0 || chapter >= chapters.length) return sentenceCount;
    var index = _chapterSentenceStart[chapter];
    final paragraphs = chapters[chapter].paragraphs;
    final limit = cursor.$2 < paragraphs.length ? cursor.$2 : paragraphs.length;
    for (var p = 0; p < limit; p++) {
      index += paragraphs[p].sentences.length;
    }
    return index + (cursor.$3 < 0 ? 0 : cursor.$3);
  }

  /// 游标 (章, 段, 句) 对应的整体阅读进度 0.0 ~ 1.0
  double progressOf((int, int, int) cursor) {
    final total = sentenceCount;
    if (total == 0) return 0;
    final value = indexOfCursor(cursor) / total;
    return value < 0 ? 0 : (value > 1 ? 1 : value);
  }

  /// 按进度（0~1）反查游标，用于通知栏拖动进度
  ///
  /// ⚠️ **v1.21.19 修：这里必须吃一个小 epsilon，不能直接 `floor`。**
  ///
  /// 进度是 `double`：`progressOf()` 写出去的 `index / total`，乘回 `total` 时
  /// 可能落到 `index - 1e-14`（例如 59/3450 = 0.017101449275362317，
  /// 再 ×3450 = 58.99999999999999），`floor()` 一取就**退一句** ——
  /// 跨段落时表现为"回到上一段开头"，也就是用户报的
  /// 「退出前读到哪句，重进读不到那」。
  ///
  /// 实测（`test/progress_roundtrip_test.dart` 逐句回环）：修前
  /// 句数 1585 → 掉 83 句、3450 → 掉 121 句、5000 → 掉 286 句（约 2%~9%）；
  /// 加上epsilon 后全部为 0。
  ///
  /// epsilon 取 1e-9 句：远大于浮点误差（~1e-14 量级），又远小于一句，
  /// 不会把"拖到两句之间"的结果推过界。
  (int, int, int) cursorAt(double progress) {
    final total = sentenceCount;
    if (total == 0) return (0, 0, 0);
    final ratio = progress < 0 ? 0.0 : (progress > 1 ? 1.0 : progress);
    return cursorAtIndex((ratio * total + _progressEpsilon).floor());
  }

  /// 进度反查时抵消浮点误差（见 [cursorAt]）
  static const double _progressEpsilon = 1e-9;

  /// 全篇句序号 → 游标（章, 段, 句），越界一律夹取
  ///
  /// 「上一句 / 下一句」就是在句序号上 ±1，跨段跨章由这里统一处理。
  (int, int, int) cursorAtIndex(int index) {
    final total = sentenceCount;
    if (total == 0) return (0, 0, 0);
    var target = index < 0 ? 0 : (index >= total ? total - 1 : index);

    // 先在前缀和上二分找到章，再在章内线性定位段与句
    var low = 0;
    var high = chapters.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (_chapterSentenceStart[mid] <= target) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    var index0 = _chapterSentenceStart[low];
    final paragraphs = chapters[low].paragraphs;
    for (var p = 0; p < paragraphs.length; p++) {
      final count = paragraphs[p].sentences.length;
      if (index0 + count > target) return (low, p, target - index0);
      index0 += count;
    }
    return (low, paragraphs.isEmpty ? 0 : paragraphs.length - 1, 0);
  }

  /// 去掉所有空白（含全角空格），用于把「页面上点到的那一行」与正文对齐
  static String squeeze(String text) => text.replaceAll(RegExp(r'[\s\u3000]+'), '');

  /// 在一章里定位一段文字，返回 (段下标, 句下标)；找不到返回 null  ///
  /// 用途：PDF 原版式里点页面上的某一行 → 从那一句开始读。
  /// 比较时忽略所有空白，因为页面上的文字与结构化后的正文在换行、空格上
  /// 经常对不齐（提取文本按行分段，页面上一行可能只是半句）。
  /// 整段匹配不上时退一步用前 8 个字找（PDF 里常混入连字符、页码等）。
  (int, int)? locateText(int chapterIndex, String needle) {
    if (chapterIndex < 0 || chapterIndex >= chapters.length) return null;
    final target = squeeze(needle);
    if (target.isEmpty) return null;
    final chapter = chapters[chapterIndex];

    final buffer = StringBuffer();
    final starts = <(int, int, int)>[]; // (句在无空白文本中的起始下标, 段, 句)
    for (var p = 0; p < chapter.paragraphs.length; p++) {
      final sentences = chapter.paragraphs[p].sentences;
      for (var s = 0; s < sentences.length; s++) {
        starts.add((buffer.length, p, s));
        buffer.write(squeeze(sentences[s].text));
      }
    }
    final flat = buffer.toString();
    if (flat.isEmpty) return null;

    var index = flat.indexOf(target);
    if (index < 0 && target.length > 8) {
      final head = target.substring(0, 8);
      index = flat.indexOf(head);
    }
    if (index < 0) return null;

    // 命中位置所在的句子：最后一个起始下标不超过它的句子
    for (var i = starts.length - 1; i >= 0; i--) {
      if (starts[i].$1 <= index) return (starts[i].$2, starts[i].$3);
    }
    return (0, 0);
  }

  /// 全篇范围内按文字定位，返回游标 (章, 段, 句)；找不到返回 null
  ///
  /// **换排版时用它保位置**（见 `ReaderPage._remapSpot`）。
  /// 为什么不用「全局句序号」：自动排版会把跨页断开的行并成一段，
  /// 有的页段数变少、有的页变多，句序号整体会漂 —— 实测在《共产主义ABC》
  /// （319 页）上，按句序号映射 5 个抽查位置有 4 个落到别的句子上。
  /// 按**文字**定位则不受段数变化影响。
  ///
  /// [hintChapter] 非空时先试这一章（排版前后章号通常相近），失败再全篇找。
  (int, int, int)? locateTextAnywhere(String needle, {int? hintChapter}) {
    final target = squeeze(needle);
    if (target.isEmpty) return null;
    // 太长反而容易因为空白 / 连字符差异匹配不上，取前 24 个字足够唯一
    final probe = target.length > 24 ? target.substring(0, 24) : target;

    if (hintChapter != null) {
      final hit = locateText(hintChapter, probe);
      if (hit != null) return (hintChapter, hit.$1, hit.$2);
    }
    for (var c = 0; c < chapters.length; c++) {
      if (c == hintChapter) continue;
      final hit = locateText(c, probe);
      if (hit != null) return (c, hit.$1, hit.$2);
    }
    return null;
  }

  /// 章节内的「页」划分：每页 [paragraphsPerPage] 段，返回段落下标区间（左闭右开）
  ///
  /// [chapterIsPage] 为真时（PDF）一章就是一页，直接返回整章范围。
  List<(int, int)> pageRanges(int chapterIndex, int paragraphsPerPage) {
    if (chapterIndex < 0 || chapterIndex >= chapters.length) return const <(int, int)>[];
    final count = chapters[chapterIndex].paragraphs.length;
    if (chapterIsPage) return <(int, int)>[(0, count)];
    if (paragraphsPerPage < 1) return const <(int, int)>[];
    final ranges = <(int, int)>[];
    for (var start = 0; start < count; start += paragraphsPerPage) {
      final end = start + paragraphsPerPage < count ? start + paragraphsPerPage : count;
      ranges.add((start, end));
    }
    return ranges;
  }

  /// 段落所在页序号（从 1 开始）
  int pageOf(int chapterIndex, int paragraphIndex, int paragraphsPerPage) {
    if (chapterIsPage) return chapterIndex + 1;
    if (paragraphsPerPage < 1) return 1;
    final safe = paragraphIndex < 0 ? 0 : paragraphIndex;
    return safe ~/ paragraphsPerPage + 1;
  }

  /// 当前章共多少页
  ///
  /// 纯算术，不构造区间列表：目录里每章都要显示页数，
  /// 一本几千章的小说若每条都分配一次 List，滑动时会明显掉帧。
  int pageCountOf(int chapterIndex, int paragraphsPerPage) {
    if (chapterIndex < 0 || chapterIndex >= chapters.length) return 0;
    if (chapterIsPage) return 1;
    if (paragraphsPerPage < 1) return 0;
    final count = chapters[chapterIndex].paragraphs.length;
    return (count + paragraphsPerPage - 1) ~/ paragraphsPerPage;
  }

  /// 章内第 [pageIndex]（从 0 开始）页的起始段落下标；越界返回 null
  int? pageStartOf(int chapterIndex, int pageIndex, int paragraphsPerPage) {
    if (pageIndex < 0 || chapterIsPage) return pageIndex == 0 ? 0 : null;
    if (paragraphsPerPage < 1) return null;
    final count = chapterIndex >= 0 && chapterIndex < chapters.length
        ? chapters[chapterIndex].paragraphs.length
        : 0;
    if (pageIndex >= pageCountOf(chapterIndex, paragraphsPerPage)) return null;
    final start = pageIndex * paragraphsPerPage;
    return start >= count ? null : start;
  }

  /// 整篇共多少页
  int totalPages(int paragraphsPerPage) {
    if (chapterIsPage) return chapters.length;
    if (paragraphsPerPage < 1) return 0;
    var total = 0;
    for (var c = 0; c < chapters.length; c++) {
      total += pageCountOf(c, paragraphsPerPage);
    }
    return total;
  }
}

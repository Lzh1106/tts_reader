import 'structured_document.dart';

/// 阅读区的一页（章节内分页）
///
/// 「按章节分页」：每章内部按「每页 N 段」切开，页不会跨章；
/// 章节标题只出现在**本章第一页**的开头（翻页时不会每页都重复标题）。
class ReaderPageSlice {
  const ReaderPageSlice({
    required this.chapter,
    required this.pageInChapter,
    required this.paragraphStart,
    required this.paragraphEnd,
    required this.blockStart,
    required this.blockCount,
  });

  /// 章序号
  final int chapter;

  /// 本章内第几页（从 0 开始）
  final int pageInChapter;

  /// 本页覆盖的段落区间（左闭右开）
  final int paragraphStart;
  final int paragraphEnd;

  /// 本页在「章节标题 + 段落」块列表里的起始块下标与块数
  final int blockStart;
  final int blockCount;

  int get paragraphCount => paragraphEnd - paragraphStart;

  /// 是否本章第一页（这一页要显示章节标题）
  bool get isChapterFirstPage => pageInChapter == 0;

  @override
  String toString() => '第${chapter + 1}章第${pageInChapter + 1}页 '
      '(段 $paragraphStart..$paragraphEnd, 块 $blockStart+$blockCount)';
}

/// 把一份文档切成「章节内分页」的页列表
///
/// 与 `StructuredDocument.pageRanges/pageOf` 同一口径（每页 [paragraphsPerPage] 段），
/// 所以目录里显示的页码、底部控制条的「第 X/Y 页」与阅读区真正翻到的页**永远一致**。
///
/// 块列表口径与旧的滚动列表相同：每章一个「章标题块」+ 每段一个「段落块」，
/// 于是 [ReaderPageSlice.blockStart]/[blockCount] 可以直接用来切片渲染。
class ReaderPaging {
  ReaderPaging._(this.pages, Map<int, int> chapterFirstPage)
      : _chapterFirstPage = chapterFirstPage;

  /// 全部页（按章节顺序、章内按页序）
  final List<ReaderPageSlice> pages;

  /// 章序号 → 该章第一页在 [pages] 里的下标
  ///
  /// 用 Map 而不是 List：空章不产生页，章序号与「第几个有内容的章」不再一一对应，
  /// 用列表下标会把所有后续章节的定位全错开。
  final Map<int, int> _chapterFirstPage;

  int get pageCount => pages.length;

  bool get isEmpty => pages.isEmpty;

  /// 空文档
  static final ReaderPaging empty = ReaderPaging._(
    const <ReaderPageSlice>[],
    const <int, int>{},
  );

  /// 按文档与「每页段数」切页
  static ReaderPaging build(StructuredDocument document, int paragraphsPerPage) {
    final pages = <ReaderPageSlice>[];
    final chapterFirstPage = <int, int>{};
    // PDF 一章就是一页：整章一页，不再按段数切
    final perPage = document.chapterIsPage ? 0 : paragraphsPerPage;
    var blockCursor = 0;

    for (var c = 0; c < document.chapters.length; c++) {
      final count = document.chapters[c].paragraphs.length;
      final chapterBlockStart = blockCursor;
      // 空章不产生任何页（否则会翻到一页空白）；它的标题块也不占位，
      // 所以这里 `continue` 时**不能**推进 blockCursor —— 否则块下标会出现空洞，
      // 与「每章 1 个标题块 + 段落数」的总数对不上。
      if (count == 0) continue;
      chapterFirstPage[c] = pages.length;
      // 章标题块占 1 个位置
      var pageBlockCursor = chapterBlockStart + 1;
      final ranges = perPage > 0
          ? <(int, int)>[
              for (var start = 0; start < count; start += perPage)
                (start, start + perPage < count ? start + perPage : count),
            ]
          : <(int, int)>[(0, count)];
      for (var p = 0; p < ranges.length; p++) {
        final (start, end) = ranges[p];
        pages.add(
          ReaderPageSlice(
            chapter: c,
            pageInChapter: p,
            paragraphStart: start,
            paragraphEnd: end,
            // 第一页从「章标题块」开始，后面的页只含段落块
            blockStart: p == 0 ? chapterBlockStart : pageBlockCursor,
            blockCount: p == 0 ? 1 + (end - start) : (end - start),
          ),
        );
        pageBlockCursor += end - start;
      }
      blockCursor = chapterBlockStart + 1 + count;
    }
    return ReaderPaging._(pages, chapterFirstPage);
  }

  /// 某个段落落在哪一页（页下标，从 0 开始）
  ///
  /// 该章没有页（空章）时，落到「下一个有内容的章的第一页」；
  /// 后面都没有内容就落到最后一页。这样任何游标都能定位到一页真实存在的页。
  int pageIndexForParagraph(int chapter, int paragraph) {
    if (pages.isEmpty) return 0;
    final safeParagraph = paragraph < 0 ? 0 : paragraph;
    final start = _firstPageOf(chapter);
    final targetChapter = pages[start].chapter;
    // 从这一章的第一页往后找：段落下标落在哪一页的范围内
    var last = start;
    for (var i = start; i < pages.length; i++) {
      if (pages[i].chapter != targetChapter) break;
      last = i;
      if (safeParagraph < pages[i].paragraphEnd) return i;
    }
    // 段落下标超出本章范围：夹到**本章最后一页**（不是第一页）
    return last;
  }

  /// 章序号 → 该章第一页下标；空章 / 越界时往后找最近的章，找不到就用最后一页
  int _firstPageOf(int chapter) {
    if (pages.isEmpty) return 0;
    final direct = _chapterFirstPage[chapter];
    if (direct != null) return direct;
    // 空章 / 越界：往后找第一个有内容的章
    for (var c = chapter + 1; c < pages.length; c++) {
      final next = _chapterFirstPage[c];
      if (next != null) return next;
    }
    // 后面也没有：退回「章号不超过自己的最后一个有内容的章」。
    // 注意这里必须取**最大的**那个 key（Map 的迭代顺序不保证升序），
    // 随手取第一个匹配会把越界定位错误地拉回第一章。
    int? bestKey;
    var fallback = 0;
    for (final entry in _chapterFirstPage.entries) {
      if (entry.key > chapter) continue;
      if (bestKey == null || entry.key > bestKey) {
        bestKey = entry.key;
        fallback = entry.value;
      }
    }
    return fallback;
  }

  /// 页下标对应的页；越界夹取
  ReaderPageSlice pageAt(int index) {
    if (pages.isEmpty) {
      return const ReaderPageSlice(
        chapter: 0,
        pageInChapter: 0,
        paragraphStart: 0,
        paragraphEnd: 0,
        blockStart: 0,
        blockCount: 0,
      );
    }
    final safe = index < 0 ? 0 : (index >= pages.length ? pages.length - 1 : index);
    return pages[safe];
  }

  /// 全篇页下标 → 章/页坐标（用于目录与进度显示）
  (int, int) locationOf(int index) {
    final page = pageAt(index);
    return (page.chapter, page.pageInChapter);
  }
}

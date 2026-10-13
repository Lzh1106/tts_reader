import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/reader_paging.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 分页模型验证：**章节内分页**、每页 N 段、章节标题只在本章首页。
///
/// 这是「真·分页版面」的地基：目录页码、底部「第 X/Y 页」、阅读区翻页
/// 三处都从这份切分读，口径必须完全一致（都走 `paragraphsPerPage`）。
void main() {
  /// 造一份文档：3 章，段落数分别为 5 / 0 / 7
  StructuredDocument makeDoc({bool chapterIsPage = false}) {
    Chapter chapter(int index, int paragraphs, {String? title}) => Chapter(
          title: title ?? '第 ${index + 1} 章',
          paragraphs: <Paragraph>[
            for (var p = 0; p < paragraphs; p++)
              Paragraph(
                sentences: <Sentence>[Sentence('第 $index 章第 $p 段正文。')],
              ),
          ],
        );
    return StructuredDocument(
      chapters: <Chapter>[
        chapter(0, 5),
        chapter(1, 0), // 空章：不该产生任何页
        chapter(2, 7),
      ],
      chapterIsPage: chapterIsPage,
    );
  }

  test('每页 2 段：章内切页，页不跨章', () {
    final paging = ReaderPaging.build(makeDoc(), 2);
    // 第 1 章 5 段 → 3 页（2/2/1）；第 2 章 0 段 → 0 页；第 3 章 7 段 → 4 页
    expect(paging.pageCount, 3 + 0 + 4);

    final first = paging.pages.first;
    expect(first.chapter, 0);
    expect(first.pageInChapter, 0);
    expect((first.paragraphStart, first.paragraphEnd), (0, 2));
    expect(first.isChapterFirstPage, isTrue);

    // 第 1 章第 2 页：段落 2..4，不是本章首页
    final second = paging.pages[1];
    expect(second.chapter, 0);
    expect(second.pageInChapter, 1);
    expect((second.paragraphStart, second.paragraphEnd), (2, 4));
    expect(second.isChapterFirstPage, isFalse);

    // 最后一页只剩 1 段
    final third = paging.pages[2];
    expect((third.paragraphStart, third.paragraphEnd), (4, 5));
    expect(third.paragraphCount, 1);

    // 空章不产生页：第 3 章直接接在第 1 章后面
    expect(paging.pages[3].chapter, 2);
    expect(paging.pages[3].pageInChapter, 0);
    expect(paging.pages[3].isChapterFirstPage, isTrue);

    // 每页最多 2 段
    for (final page in paging.pages) {
      expect(page.paragraphCount, lessThanOrEqualTo(2), reason: '$page');
      expect(page.paragraphCount, greaterThan(0), reason: '$page 不该有空页');
    }
  });

  test('章节标题只挂在本章第一页（翻页不会重复标题）', () {
    final paging = ReaderPaging.build(makeDoc(), 2);
    for (final page in paging.pages) {
      // 第一页 = 1 个标题块 + 段落数；其它页 = 只有段落块
      final expected = page.isChapterFirstPage
          ? 1 + page.paragraphCount
          : page.paragraphCount;
      expect(page.blockCount, expected, reason: '$page');
    }
  });

  test('块下标连续：按章顺序累加，可以直接切片渲染', () {
    final document = makeDoc();
    final paging = ReaderPaging.build(document, 2);
    // 整篇块数 = Σ(1 + 该章段落数)，**空章不占位**（它也没有页）
    var expectedBlocks = 0;
    for (final chapter in document.chapters) {
      if (chapter.paragraphs.isEmpty) continue;
      expectedBlocks += 1 + chapter.paragraphs.length;
    }
    var cursor = 0;
    for (final page in paging.pages) {
      expect(page.blockStart, cursor, reason: '$page 的块起点应当是连续的');
      cursor += page.blockCount;
    }
    expect(cursor, expectedBlocks, reason: '所有页的块数之和 = 整篇块数（不含空章）');
  });

  test('段落 → 页：章内定位正确', () {
    final paging = ReaderPaging.build(makeDoc(), 2);
    // 第 1 章：段 0,1 → 页 0；段 2,3 → 页 1；段 4 → 页 2
    expect(paging.pageIndexForParagraph(0, 0), 0);
    expect(paging.pageIndexForParagraph(0, 1), 0);
    expect(paging.pageIndexForParagraph(0, 2), 1);
    expect(paging.pageIndexForParagraph(0, 3), 1);
    expect(paging.pageIndexForParagraph(0, 4), 2);
    // 越界的段落下标夹到本章最后一页
    expect(paging.pageIndexForParagraph(0, 99), 2);
    // 第 3 章从页 3 开始
    expect(paging.pageIndexForParagraph(2, 0), 3);
    expect(paging.pageIndexForParagraph(2, 2), 4);
    // 章越界夹到最后一章
    expect(paging.pageIndexForParagraph(99, 0), greaterThanOrEqualTo(3));
  });

  test('页码换算与 StructuredDocument 的口径一致', () {
    final document = makeDoc();
    const perPage = 3;
    final paging = ReaderPaging.build(document, perPage);
    // 逐段核对：分页模型算出的页 == 文档模型算出的页（章内序号）
    for (var c = 0; c < document.chapters.length; c++) {
      final count = document.chapters[c].paragraphs.length;
      for (var p = 0; p < count; p++) {
        final index = paging.pageIndexForParagraph(c, p);
        final page = paging.pages[index];
        expect(page.chapter, c);
        // 文档模型是 1 起，分页模型章内是 0 起
        expect(page.pageInChapter + 1, document.pageOf(c, p, perPage),
            reason: '第 $c 章第 $p 段的页码两边必须一致');
      }
      expect(
        document.pageCountOf(c, perPage),
        paging.pages.where((page) => page.chapter == c).length,
        reason: '第 $c 章的页数两边必须一致',
      );
    }
    expect(paging.pageCount, document.totalPages(perPage));
  });

  test('PDF（一章即一页）：整章一页，不按段数切', () {
    final paging = ReaderPaging.build(makeDoc(chapterIsPage: true), 2);
    // 只有第 1、3 章有段落 → 2 页
    expect(paging.pageCount, 2);
    expect(paging.pages[0].chapter, 0);
    expect(paging.pages[0].paragraphCount, 5, reason: '整章在一页里');
    expect(paging.pages[1].chapter, 2);
    expect(paging.pages[1].paragraphCount, 7);
  });

  test('单段文档 / 每页段数大于总段数：只有一页', () {
    final paging = ReaderPaging.build(makeDoc(), 1000);
    // 第 1 章 1 页 + 第 3 章 1 页
    expect(paging.pageCount, 2);
    expect(paging.pages[0].paragraphCount, 5);
    for (final page in paging.pages) {
      expect(page.isChapterFirstPage, isTrue);
    }
  });

  test('空文档：没有页，取页也不越界', () {
    final paging = ReaderPaging.build(StructuredDocument.empty(), 40);
    expect(paging.isEmpty, isTrue);
    expect(paging.pageCount, 0);
    // 越界访问要被夹住而不是抛异常
    expect(paging.pageAt(0).chapter, 0);
    expect(paging.pageIndexForParagraph(0, 0), 0);
    expect(paging.locationOf(5), (0, 0));
  });

  test('locationOf 把页下标换算成章/页坐标', () {
    final paging = ReaderPaging.build(makeDoc(), 2);
    expect(paging.locationOf(0), (0, 0));
    expect(paging.locationOf(1), (0, 1));
    expect(paging.locationOf(2), (0, 2));
    expect(paging.locationOf(3), (2, 0));
    expect(paging.locationOf(6), (2, 3));
  });

  group('自动排版开关的固化', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      StorageService.instance.resetForTest();
    });

    test('默认关闭；打开后落盘，重开仍是打开', () async {
      await StorageService.instance.init();
      expect(StorageService.instance.isAutoFormat('book1'), isFalse,
          reason: '没点过排版按钮就不该生效（不再次点击不更改当前排版）');

      await StorageService.instance.setAutoFormat('book1', true);
      expect(StorageService.instance.isAutoFormat('book1'), isTrue);

      // 模拟重启：丢掉缓存后重新 init
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      expect(StorageService.instance.isAutoFormat('book1'), isTrue,
          reason: '退出重进要保持排版选择');
    });

    test('再点一次关掉后也落盘，重开仍是关闭', () async {
      await StorageService.instance.init();
      // 先把共享偏好设成「开着」，模拟上次的选择
      SharedPreferences.setMockInitialValues(<String, Object>{
        'reader_auto_format_docs': <String>['book1'],
      });
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      expect(StorageService.instance.isAutoFormat('book1'), isTrue);

      await StorageService.instance.setAutoFormat('book1', false);
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      expect(StorageService.instance.isAutoFormat('book1'), isFalse,
          reason: '恢复原排版的选择同样要被记住');
    });

    test('按文档分别记：改一本不影响另一本', () async {
      await StorageService.instance.init();
      await StorageService.instance.setAutoFormat('a', true);
      expect(StorageService.instance.isAutoFormat('a'), isTrue);
      expect(StorageService.instance.isAutoFormat('b'), isFalse,
          reason: '排版选择是按文档记的，不能串到别的书');
    });
  });
}

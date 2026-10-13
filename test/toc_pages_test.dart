import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/structured_document.dart';

/// 目录页数计算验证。
///
/// 目录面板要显示「每章多少页 / 全篇多少页」，而一本几千章的小说如果每章都
/// 构造一次区间列表，滑动就会掉帧。所以 [StructuredDocument.pageCountOf] /
/// [pageStartOf] 改成纯算术 —— 这组测试保证它们与 [StructuredDocument.pageRanges]
/// 的结果逐一对齐，别在提速的同时把页码算错。
void main() {
  StructuredDocument build(List<int> paragraphsPerChapter) {
    return StructuredDocument(
      chapters: <Chapter>[
        for (var c = 0; c < paragraphsPerChapter.length; c++)
          Chapter(
            title: '第 ${c + 1} 章',
            paragraphs: <Paragraph>[
              for (var p = 0; p < paragraphsPerChapter[c]; p++)
                Paragraph(sentences: <Sentence>[Sentence('第 $p 段。')]),
            ],
          ),
      ],
    );
  }

  group('页数与区间列表一致', () {
    test('各种段数 × 各种每页段数都对得上', () {
      final document = build(<int>[0, 1, 2, 7, 39, 40, 41, 80, 123]);
      for (final perPage in <int>[1, 2, 5, 10, 40, 50]) {
        for (var c = 0; c < document.chapters.length; c++) {
          final ranges = document.pageRanges(c, perPage);
          expect(
            document.pageCountOf(c, perPage),
            ranges.length,
            reason: '第 $c 章 每页 $perPage 段：页数要与区间数一致',
          );
          for (var i = 0; i < ranges.length; i++) {
            expect(
              document.pageStartOf(c, i, perPage),
              ranges[i].$1,
              reason: '第 $c 章第 ${i + 1} 页起始段不一致',
            );
          }
          // 越界页返回 null，不能抛
          expect(document.pageStartOf(c, ranges.length, perPage), isNull);
          expect(document.pageStartOf(c, -1, perPage), isNull);
        }
      }
    });

    test('全篇页数等于逐章页数之和', () {
      final document = build(<int>[3, 44, 0, 12, 99]);
      for (final perPage in <int>[1, 4, 40]) {
        var sum = 0;
        for (var c = 0; c < document.chapters.length; c++) {
          sum += document.pageCountOf(c, perPage);
        }
        expect(document.totalPages(perPage), sum);
      }
    });

    test('PDF：一章即一页', () {
      final document = StructuredDocument(
        chapters: <Chapter>[
          for (var i = 0; i < 12; i++)
            Chapter(
              title: '第 ${i + 1} 页',
              paragraphs: const <Paragraph>[
                Paragraph(sentences: <Sentence>[Sentence('内容。')]),
              ],
            ),
        ],
        chapterIsPage: true,
      );
      expect(document.totalPages(40), 12);
      expect(document.pageCountOf(0, 40), 1);
      expect(document.pageCountOf(11, 40), 1);
      expect(document.pageStartOf(3, 0, 40), 0);
      expect(document.pageStartOf(3, 1, 40), isNull);
      expect(document.pageOf(3, 0, 40), 4);
    });

    test('越界 / 非法参数不抛异常', () {
      final document = build(<int>[10]);
      expect(document.pageCountOf(-1, 40), 0);
      expect(document.pageCountOf(9, 40), 0);
      expect(document.pageCountOf(0, 0), 0);
      expect(document.totalPages(0), 0);
      expect(document.pageStartOf(0, 0, 0), isNull);
      expect(document.pageOf(-3, -5, 40), 1);
    });

    test('几千章的目录计算是毫秒级（不做区间分配）', () {
      final document = build(List<int>.filled(4000, 30));
      final watch = Stopwatch()..start();
      var pages = 0;
      for (var c = 0; c < document.chapters.length; c++) {
        pages += document.pageCountOf(c, 40);
      }
      watch.stop();
      expect(pages, 4000, reason: '每章 30 段、每页 40 段 → 每章 1 页');
      expect(
        watch.elapsedMilliseconds,
        lessThan(200),
        reason: '4000 章只做算术，不该慢（实测 ${watch.elapsedMilliseconds}ms）',
      );
    });
  });
}

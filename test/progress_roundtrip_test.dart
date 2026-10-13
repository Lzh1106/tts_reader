import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/structured_document.dart';

/// 位置记忆的**浮点回环**（v1.21.19 诊断）
///
/// 进度 ↔ 游标的换算是按**句**做的：
///   `progressOf(c) = indexOfCursor(c) / sentenceCount`
///   `cursorAt(p)   = cursorAtIndex((p * sentenceCount).floor())`
/// 而进度是 `double`：`index/total` 再乘回 `total` 可能落到 `index - 1e-15`，
/// `.floor()` 一取就**退一句**（跨段落时表现为"回到上一段开头"）。
/// 用户报的「退出前读到哪句，重进读不到那」如果出在这一环，就是这条。
///
/// 所以这里**遍历所有句序号**做回环断言，而不是只测几个好数。
void main() {
  StructuredDocument docWith(int total, {int sentencesPerParagraph = 1}) {
    final List<Chapter> chapters = <Chapter>[];
    var left = total;
    var chapterNo = 0;
    while (left > 0) {
      final int inChapter = left > 60 ? 60 : left;
      final List<Paragraph> paragraphs = <Paragraph>[];
      var inParagraphLeft = inChapter;
      while (inParagraphLeft > 0) {
        final int n = inParagraphLeft > sentencesPerParagraph
            ? sentencesPerParagraph
            : inParagraphLeft;
        paragraphs.add(Paragraph(
          sentences: List<Sentence>.generate(n, (int i) => Sentence('第$i句。')),
        ));
        inParagraphLeft -= n;
      }
      chapters.add(Chapter(title: '第$chapterNo章', paragraphs: paragraphs));
      left -= inChapter;
      chapterNo++;
    }
    return StructuredDocument(chapters: chapters);
  }

  /// 逐句回环：cursorAtIndex(i) → progressOf → cursorAt 必须回到 i
  List<String> roundTripMisses(StructuredDocument doc) {
    final List<String> misses = <String>[];
    final int total = doc.sentenceCount;
    for (var i = 0; i < total; i++) {
      final (int, int, int) cursor = doc.cursorAtIndex(i);
      final (int, int, int) back = doc.cursorAt(doc.progressOf(cursor));
      if (back != cursor) {
        misses.add('#$i $cursor → ${doc.progressOf(cursor)} → $back');
      }
    }
    return misses;
  }

  test('进度回环：每一句都要能原样还原（多种句数规模）', () {
    final Map<int, List<String>> bad = <int, List<String>>{};
    // 真实《国家与革命》83521 字 / 55 章 —— 句数落在几千量级；再扫几个不同规模
    for (final int total in <int>[137, 999, 1585, 3450, 5000, 8352, 12000]) {
      final List<String> misses = roundTripMisses(docWith(total));
      if (misses.isNotEmpty) bad[total] = misses;
      // ignore: avoid_print
      print('PROBE[回环] 句数=$total 掉句=${misses.length}'
          '${misses.isEmpty ? "" : " 例：${misses.first}"}');
    }
    expect(
      bad,
      isEmpty,
      reason: '进度 → 游标回环掉句（floor 吃到浮点误差）：'
          '${bad.map((k, v) => MapEntry(k, v.take(3).toList()))}',
    );
  });

  test('进度回环：段落里多句（真实排版，每段 3~6 句）', () {
    final List<String> misses = roundTripMisses(docWith(3000, sentencesPerParagraph: 4));
    // ignore: avoid_print
    print('PROBE[回环-多句段] 掉句=${misses.length}'
        '${misses.isEmpty ? "" : " 例：${misses.take(3).join(" | ")}"}');
    expect(misses, isEmpty,
        reason: '每段多句时同样必须逐句还原（掉一句就是"重进读不到那句"）');
  });
}

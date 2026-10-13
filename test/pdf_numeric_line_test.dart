import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';

/// PDF 里「数字年份被切开」的回归（v1.21.29 修）。
///
/// 真机症状（用户文档，812 页）：含阿拉伯数字年份的句子朗读异常 ——
/// ① 先读整句、数字被跳过；② 读完整句又回头读数字；③ 数字混进下一句；
/// ④ 高亮只盖住数字前后一小段。
///
/// 根因：`groupIntoLines()` 判「同一行」只看纵向重叠比例，而**数字/字母/半角标点
/// 的字形盒常比汉字矮一截**（没有下伸部分、基线有微调）→ 重叠不到 50% →
/// 数字被切成独立行块 → 排到整句之后 → 整句先成句、数字块因没有句末标点被判
/// "还会续"→ 与下一句合并。
void main() {
  /// 造一串字盒：[text] 从 [x] 起排，字宽 [w]、字高 [h]、顶边 [y]
  List<PdfTextChar> makeChars(
    String text, {
    required double x,
    required double y,
    double w = 10,
    double h = 12,
    int indexBase = 0,
  }) {
    return <PdfTextChar>[
      for (var i = 0; i < text.length; i++)
        PdfTextChar(
          index: indexBase + i,
          char: text[i],
          rect: Rect.fromLTWH(x + i * w, y, w, h),
        ),
    ];
  }

  test('数字盒比汉字盒矮 / 基线偏下时，仍归为同一行', () {
    final chars = <PdfTextChar>[
      ...makeChars('这部巨著从', x: 0, y: 100, h: 12),
      // 盒矮（8 高 vs 汉字 12）、基线偏下（y=103）—— 真机上的数字盒就是这样
      ...makeChars('1943', x: 50, y: 103, w: 5, h: 8, indexBase: 5),
      ...makeChars('年开始，', x: 70, y: 100, h: 12, indexBase: 9),
    ];
    final lines = groupIntoLines(chars);
    // ignore: avoid_print
    print('PROBE[单测-分行] ${lines.map((l) => l.text).toList()}');
    expect(lines.length, 1, reason: '数字必须与汉字同一行');
    expect(lines.first.text, '这部巨著从1943年开始，');
  });

  test('数字不会被切到整句之后（分句只切标点）', () {
    final chars = <PdfTextChar>[
      // ⚠️ 坐标必须**不重叠**（任务书给的 x=70 与「年开始，到」的末字撞在一起，
//     那会让 toTheRight 判失败 —— 那是夹具问题，不是产品问题）
      ...makeChars('从', x: 0, y: 100, h: 12),
      ...makeChars('1943', x: 10, y: 103, w: 5, h: 8, indexBase: 1),
      ...makeChars('年开始，到', x: 30, y: 100, h: 12, indexBase: 5),
      ...makeChars('1960', x: 80, y: 103, w: 5, h: 8, indexBase: 10),
      ...makeChars('年编写完成。', x: 100, y: 100, h: 12, indexBase: 14),
    ];
    final sentences = segmentIntoSentences(groupIntoLines(chars));
    // ignore: avoid_print
    print('PROBE[单测-分句] ${sentences.map((s) => s.text).toList()}');
    expect(sentences.length, 1);
    expect(sentences.first.text, '从1943年开始，到1960年编写完成。');
  });
}

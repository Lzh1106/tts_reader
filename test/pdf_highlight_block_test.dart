import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:tts_reader/models/pdf_line_box.dart';
import 'package:tts_reader/services/paragraph_reflow.dart';

/// 「整句一块连续底色」的几何验证。
///
/// 阅读页把「这一句覆盖到的行」合并成一个包围盒（`_pdfHighlightOverlay` 里的
/// `expandToInclude`）。这里用**真实 PDF 抽出来的行框**验证：
/// 一句话跨多行时，合并结果是一块（而不是每行一块），且高度就是那几行的总高。
void main() {
  test('跨行的一句话：行框合并后是一整块，不是多个小块', () {
    // 造一页：一句话被排版折成 3 行（行尾没有句末标点）
    final pdf = PdfDocument();
    final font = PdfStandardFont(PdfFontFamily.helvetica, 11);
    final page = pdf.pages.add();
    const lines = <String>[
      'Reflow verification page one, the first wrapped line of a',
      'sentence that the typesetter broke here, and the second',
      'wrapped line continues until the paragraph finally ends.',
    ];
    for (var i = 0; i < lines.length; i++) {
      page.graphics.drawString(lines[i], font,
          bounds: Rect.fromLTWH(40, 40 + i * 18, 520, 18));
    }
    final bytes = pdf.saveSync();
    pdf.dispose();

    // 抽取行（与解析器走同一条 API）
    final doc = PdfDocument(inputBytes: bytes);
    final extracted =
        PdfTextExtractor(doc).extractTextLines(startPageIndex: 0, endPageIndex: 0);
    expect(extracted.length, 3, reason: '这一页应当抽出 3 行');
    final boxes = <PdfLineBox>[
      for (final line in extracted)
        PdfLineBox(text: line.text, bounds: line.bounds),
    ];

    // 走解析器的 PDF 分支：一页一行一段 → 自动排版后并成一句
    final plain = boxes.map((b) => b.text).join('\n');
    final paragraphs = ParagraphReflow.reflowPage(<ReflowLine>[
      for (final box in boxes)
        ReflowLine(
          text: box.text,
          left: box.bounds.left,
          top: box.bounds.top,
          right: box.bounds.right,
          bottom: box.bounds.bottom,
        ),
    ]);
    expect(paragraphs.length, 1, reason: '三行折行文字应当并成一段');
    expect(paragraphs.first.sentences.length, 1, reason: '并成一句');
    expect(paragraphs.first.text.length, greaterThan(plain.length - 10));

    // 该句覆盖到的行 = 全部 3 行；合并成一个包围盒
    final union = boxes
        .map((b) => b.bounds)
        .reduce((a, b) => a.expandToInclude(b));
    expect(union.top, closeTo(boxes.first.bounds.top, 0.01));
    expect(union.bottom, closeTo(boxes.last.bounds.bottom, 0.01));
    // 一整块的高度 = 3 行的总跨度（约 2 个行距 + 一行高），明显高于单行
    expect(
      union.height,
      greaterThan(boxes.first.bounds.height * 2),
      reason: '跨 3 行的整句块应当明显高于单行',
    );
    expect(
      union.height,
      lessThan(boxes.first.bounds.height * 5),
      reason: '也不该高得离谱（那说明圈进了更后面的行）',
    );
    doc.dispose();
  });
}

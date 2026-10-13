import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:tts_reader/features/pdf_reading/pdf_page_layer.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';

/// 真实 PDF 上的**页码行过滤**验证（v1.21.14 任务①）。
///
/// 修前：《共产主义ABC》的页脚（形如「− 311 −」）会被当正文成句，而且因为它
/// 没有句末标点，还会与**下一页首句**合并成一次朗读。
///
/// 本用例用 lib 自己的判据 `isPageNumberLine` 找原始行里的页码行，再断言
/// **它们一句都没进 sentences**（也就是不会被读出来）。
/// 顺带报告全书里页码行的分布 —— 这能说明这条规则到底在哪些页生效。
///
/// 需要 `/data/local/tmp/abc.pdf`（319 页，与其它 PDF 设备用例同源）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('页脚页码不成句：抽查两端共 80 页，页码行泄漏到句子的数量必须为 0',
      (tester) async {
    final File src = File('/data/local/tmp/abc.pdf');
    expect(src.existsSync(), isTrue, reason: '需要 /data/local/tmp/abc.pdf');
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory books = Directory('${base.path}/books');
    if (!books.existsSync()) await books.create(recursive: true);
    final File pdf = File('${books.path}/abc.pdf');
    await src.copy(pdf.path);

    final PdfDocument doc = await PdfDocument.openFile(pdf.path);
    final List<int> scan = <int>[
      for (int p = 1; p <= 60; p++) p,
      for (int p = 300; p <= 319; p++) p,
    ];
    int pageNumberLines = 0;
    int leaked = 0;
    int sentencesTotal = 0;
    final List<String> samples = <String>[];
    try {
      for (final int pageNumber in scan) {
        if (pageNumber > doc.pages.length) break;
        final PdfPageTextLayer? layer =
            await loadTextLayer(doc.pages[pageNumber - 1]);
        if (layer == null) continue;
        sentencesTotal += layer.sentences.length;

        for (int i = 0; i < layer.lines.length; i++) {
          if (!isPageNumberLine(layer.lines, i)) continue;
          pageNumberLines++;
          final String t = layer.lines[i].text.trim();
          if (samples.length < 6) samples.add('p$pageNumber「$t」');
          // 它不该出现在任何句子里
          final bool hit = layer.sentences.any((PdfTextSentence s) {
            final String st = s.text.trim();
            return st == t || (t.length >= 3 && st.contains(t));
          });
          if (hit) leaked++;
        }
      }
    } finally {
      await doc.dispose();
    }

    // ignore: avoid_print
    print('DEVICE_VERIFY[pagenum] 抽查 ${scan.length} 页：句子总数=$sentencesTotal '
        '页码行=$pageNumberLines 泄漏到句子=$leaked 样例=$samples');
    expect(sentencesTotal, greaterThan(0), reason: '抽查的页必须有正文');
    expect(leaked, 0, reason: '页码行必须一句都不进 sentences（实际 $leaked）');
  });
}

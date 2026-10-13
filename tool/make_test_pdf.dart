import 'dart:io';

/// 造一份「真实的被折行 PDF」用于设备验证（纯 Dart，不依赖 Flutter）。
///
/// 为什么不用 Syncfusion 生成：`syncfusion_flutter_pdf` 依赖 `dart:ui`，
/// `dart run` 里跑不起来。这里直接写最小 PDF（Helvetica + 几行文本），
/// 只为造出「每行都是排版硬折的一截」这种结构。
///
/// 用法：dart run tool/make_test_pdf.dart <输出路径>
void main(List<String> args) {
  final out = args.isNotEmpty ? args.first : 'wrapped.pdf';

  // 第 1 页：一句话被折成三行（行尾是逗号 / 小写续词 → 该并回一段）
  // 第 2 页：三句各自完整（本来就排好 → 自动排版应当提示无需重排）
  final pages = <List<String>>[
    <String>[
      'Reflow verification page one, the first wrapped line of a',
      'sentence that the typesetter broke here, and the second',
      'wrapped line continues until the paragraph finally ends.',
    ],
    <String>[
      'This is the first independent sentence.',
      'This is the second independent sentence.',
      'This is the third independent sentence.',
    ],
    <String>[
      'Third page verifies plain English narration again.',
      'A second complete sentence sits right below it.',
    ],
  ];

  final objects = <String>[];
  // 1: Catalog, 2: Pages, 3: Font, 4..: Page / Contents pairs
  final pageRefs = <int>[];
  var nextId = 4;
  for (var i = 0; i < pages.length; i++) {
    final pageId = nextId++;
    final contentId = nextId++;
    pageRefs.add(pageId);
    objects.add('$pageId 0 obj\n<< /Type /Page /Parent 2 0 R '
        '/MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> '
        '/Contents $contentId 0 R >>\nendobj\n');

    final buffer = StringBuffer();
    var y = 740;
    for (final line in pages[i]) {
      buffer.writeln('BT /F1 11 Tf 40 $y Td (${_escape(line)}) Tj ET');
      y -= 18;
    }
    final stream = buffer.toString();
    objects.add('$contentId 0 obj\n<< /Length ${stream.length} >>\nstream\n'
        '$stream\nendstream\nendobj\n');
  }

  final pagesObj = '2 0 obj\n<< /Type /Pages /Count ${pages.length} /Kids '
      '[${pageRefs.map((id) => '$id 0 R').join(' ')}] >>\nendobj\n';
  const fontObj = '3 0 obj\n<< /Type /Font /Subtype /Type1 '
      '/BaseFont /Helvetica >>\nendobj\n';
  const catalogObj = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n';

  final all = <String>[catalogObj, pagesObj, fontObj, ...objects];
  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  for (final obj in all) {
    offsets.add(buffer.length);
    buffer.write(obj);
  }
  final xrefAt = buffer.length;
  buffer.writeln('xref');
  buffer.writeln('0 ${all.length + 1}');
  buffer.writeln('0000000000 65535 f ');
  for (var i = 1; i <= all.length; i++) {
    buffer.writeln('${offsets[i].toString().padLeft(10, '0')} 00000 n ');
  }
  buffer.writeln('trailer\n<< /Size ${all.length + 1} /Root 1 0 R >>');
  buffer.writeln('startxref\n$xrefAt\n%%EOF');

  final file = File(out);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(buffer.toString(), encoding: const SystemEncoding());
  stdout.writeln('wrote $out (${file.lengthSync()} bytes, ${pages.length} pages)');
}

String _escape(String text) =>
    text.replaceAll('\\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');

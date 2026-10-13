import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/services/document_service.dart';

/// 诊断：真实 PDF 能否被 Syncfusion 打开、页数是多少、
/// 以及「第一页有没有整页图」（决定封面能不能抽）。
void main() {
  test('abc.pdf 能否被 PdfDocument 打开', () async {
    final path = File('test_assets/abc.pdf').absolute.path;
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-open] path=$path exists=${File(path).existsSync()} '
        'bytes=${File(path).lengthSync()}');

    final bytes = await File(path).readAsBytes();
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-open] 读到 ${bytes.length} 字节，'
        '头部=${String.fromCharCodes(bytes.take(8))}');

    try {
      final pdf = PdfDocument(inputBytes: bytes);
      // ignore: avoid_print
      print('DEVICE_VERIFY[pdf-open] pages=${pdf.pages.count}');
      final page = pdf.pages[0];
      // ignore: avoid_print
      print('DEVICE_VERIFY[pdf-open] page0 size=${page.size}');
      final text = PdfTextExtractor(pdf).extractText(startPageIndex: 0, endPageIndex: 0);
      // ignore: avoid_print
      print('DEVICE_VERIFY[pdf-open] page0 文本前 80 字='
          '${text.trim().substring(0, text.trim().length.clamp(0, 80))}');
      pdf.dispose();
    } catch (e, stack) {
      // ignore: avoid_print
      print('DEVICE_VERIFY[pdf-open] 打开失败：$e\n$stack');
    }

    // 顺带确认解析链路自己也读过这个文件
    final result = await DocumentService.parse(
      Document(
        id: 'diag',
        title: 'diag',
        path: path,
        type: DocumentType.pdf,
        importedAt: DateTime(2024),
      ),
    );
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-open] parse 成功：章=${result.document.chapters.length} '
        '段=${result.document.paragraphCount} 行页=${result.pdfLines?.length} '
        'pageCount=${result.pageCount} fileSize=${result.fileSize}');
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/services/document_service.dart';

/// PDF 封面用 pdfrx 渲染第 1 页（v1.21.17 第 4 件）
///
/// 改前 `_extractPdfCover` 直接 `return null`（注释里写着 Syncfusion 26.2
/// 没有读图 API），于是 PDF 永远落到「默认样式封面」。
/// 现在改成 pdfrx 渲染整页 —— 但 pdfrx 走平台通道，**只能在设备上验**。
///
/// 需要 `/data/local/tmp/abc.pdf`（与其它 PDF 设备用例同源）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('PDF 封面：走 pdfrx 渲染，而不是默认样式', (tester) async {
    final File src = File('/data/local/tmp/abc.pdf');
    expect(src.existsSync(), isTrue, reason: '需要 /data/local/tmp/abc.pdf');
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory books = Directory('${base.path}/books');
    if (!books.existsSync()) await books.create(recursive: true);
    final File pdf = File('${books.path}/abc.pdf');
    await src.copy(pdf.path);

    final Directory covers = Directory('${base.path}/covers');
    if (!covers.existsSync()) await covers.create(recursive: true);
    final String outPath = '${covers.path}/probe-pdf-cover.jpg';

    DocumentService.debugPdfCoverSource = null;
    final Document doc = Document(
      id: 'pdf-cover-probe',
      title: '共产主义ABC',
      path: pdf.path,
      type: DocumentType.pdf,
      importedAt: DateTime.now(),
    );
    final String? result = await DocumentService.extractCover(doc, outPath);
    final int size = result == null ? -1 : await File(result).length();

    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-cover] 来源=${DocumentService.debugPdfCoverSource} '
        '路径=$result 大小=$size 字节');

    expect(DocumentService.debugPdfCoverSource, 'render',
        reason: 'PDF 封面必须由 pdfrx 渲染首页产生（改前这里是 null → 默认样式封面）');
    expect(result, isNotNull);
    expect(size, greaterThan(1000), reason: '渲染出来的封面不该是空文件');
  });
}

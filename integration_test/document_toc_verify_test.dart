import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset, Rect;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/services/document_service.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 设备层验证：**PDF 书签 / EPUB nav 的目录能被解析出来并跨 isolate 带回**
///
/// 单元测试里已经覆盖了解析逻辑；这里在真机上验证整条链路：
/// 真文件 → isolate 解析 → 目录条目与章名都对（目录对象要能被复制回主 isolate）。
///
/// 跑法：flutter test integration_test/document_toc_verify_test.dart -d emulator-5554
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('PDF：书签目录被读出并用作章名', (tester) async {
    await StorageService.instance.init();
    final dir = await Directory.systemTemp.createTemp('tts_toc_pdf');
    final file = File('${dir.path}/bookmarked.pdf');

    final pdf = PdfDocument();
    final font = PdfStandardFont(PdfFontFamily.helvetica, 14);
    final pages = <PdfPage>[];
    for (var i = 0; i < 4; i++) {
      final page = pdf.pages.add();
      pages.add(page);
      page.graphics.drawString('Page ${i + 1}.', font, bounds: const Rect.fromLTWH(20, 20, 400, 80));
    }
    const at = Offset(0, 0);
    // Syncfusion 的 add(destination:) 命名参数无效，必须赋值 destination
    final chapterOne = pdf.bookmarks.add('Chapter One');
    chapterOne.destination = PdfDestination(pages[0], at);
    final section = chapterOne.add('Section 1.1');
    section.destination = PdfDestination(pages[1], at);
    final chapterTwo = pdf.bookmarks.add('Chapter Two');
    chapterTwo.destination = PdfDestination(pages[3], at);
    file.writeAsBytesSync(pdf.saveSync());
    pdf.dispose();

    final task = DocumentService.parseAsync(
      Document(
        id: 'toc_pdf',
        title: 'bookmarked',
        path: file.path,
        type: DocumentType.pdf,
        importedAt: DateTime.now(),
      ),
    );
    final result = await task.result;
    final outline = result.document.outline;
    // ignore: avoid_print
    print('DEVICE_VERIFY[toc-pdf] 目录=${outline.map((e) => '${e.depth}:${e.title}→p${e.chapter + 1}').join(' | ')}');
    // ignore: avoid_print
    print('DEVICE_VERIFY[toc-pdf] 章名=${result.document.chapters.map((c) => c.title).join(' / ')}');

    expect(outline.length, 3, reason: '目录要跨 isolate 回来');
    expect(outline.map((e) => e.title).toList(), <String>['Chapter One', 'Section 1.1', 'Chapter Two']);
    expect(outline.map((e) => e.depth).toList(), <int>[0, 1, 0]);
    expect(outline.map((e) => e.chapter).toList(), <int>[0, 1, 3]);
    expect(result.document.chapters.first.title, 'Chapter One');
    expect(result.document.chapters.length, 4, reason: '仍然一页一章，翻页与朗读不受影响');
    expect(result.document.hasOutline, isTrue);

    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  testWidgets('EPUB：nav 文档被用来起章名并保留层级', (tester) async {
    await StorageService.instance.init();
    final dir = await Directory.systemTemp.createTemp('tts_toc_epub');
    final file = File('${dir.path}/nav.epub');

    const container = '<?xml version="1.0" encoding="UTF-8"?>'
        '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="OEBPS/content.opf" '
        'media-type="application/oebps-package+xml"/></rootfiles></container>';
    const opf = '<?xml version="1.0" encoding="UTF-8"?>'
        '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>设备测试书</dc:title><dc:identifier id="bookid">urn:uuid:dev-toc</dc:identifier>'
        '</metadata><manifest>'
        '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
        '<item id="ch1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>'
        '<item id="ch2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>'
        '</manifest><spine><itemref idref="ch1"/><itemref idref="ch2"/></spine></package>';
    const nav = '<?xml version="1.0" encoding="utf-8"?>'
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
        '<head><title>目录</title></head><body><nav epub:type="toc"><ol>'
        '<li><a href="Text/ch1.xhtml">第一章 出发</a></li>'
        '<li><a href="Text/ch2.xhtml">第二章 路上</a>'
        '<ol><li><a href="Text/ch2.xhtml#s1">第一节 雨</a></li></ol></li>'
        '</ol></nav></body></html>';
    // 每个正文文件的 <title> 都是书名 —— 用 <title> 起名会出现重复章名
    String body(String text) => '<?xml version="1.0" encoding="UTF-8"?>'
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>设备测试书</title></head>'
        '<body><p>$text</p></body></html>';

    final archive = Archive();
    void add(String name, String data, {bool store = false}) {
      final bytes = utf8.encode(data);
      archive.addFile(ArchiveFile(name, bytes.length, bytes)..compress = !store);
    }

    add('mimetype', 'application/epub+zip', store: true);
    add('META-INF/container.xml', container);
    add('OEBPS/content.opf', opf);
    add('OEBPS/nav.xhtml', nav);
    add('OEBPS/Text/ch1.xhtml', body('第一章的正文。'));
    add('OEBPS/Text/ch2.xhtml', body('第二章的正文。'));
    file.writeAsBytesSync(ZipEncoder().encode(archive)!);

    final task = DocumentService.parseAsync(
      Document(
        id: 'toc_epub',
        title: 'nav',
        path: file.path,
        type: DocumentType.epub,
        importedAt: DateTime.now(),
      ),
    );
    final result = await task.result;
    final outline = result.document.outline;
    // ignore: avoid_print
    print('DEVICE_VERIFY[toc-epub] 章名=${result.document.chapters.map((c) => c.title).join(' / ')}');
    // ignore: avoid_print
    print('DEVICE_VERIFY[toc-epub] 目录=${outline.map((e) => '${e.depth}:${e.title}→c${e.chapter + 1}').join(' | ')}');

    expect(result.document.chapters.map((c) => c.title).toList(), <String>['第一章 出发', '第二章 路上']);
    expect(outline.map((e) => e.title).toList(), <String>['第一章 出发', '第二章 路上', '第一节 雨']);
    expect(outline[2].depth, 1);
    expect(outline[2].chapter, 1, reason: '锚点条目挂在同一章');
    expect(result.document.hasOutline, isTrue);

    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });
}

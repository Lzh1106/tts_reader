import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset, Rect;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/document_service.dart';
import 'package:tts_reader/services/pdf_outline.dart';

/// PDF / EPUB 目录解析的端到端验证（真文件 → 解析 → 目录结构）。
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tts_toc_');
  });

  tearDown(() async {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {
      // Windows 句柄占用时忽略
    }
  });

  group('PDF 书签当目录', () {
    /// 造一份带书签树的 PDF：3 页正文 + 顶层书签 + 一个子书签
    List<int> buildPdfWithOutline() {
      final pdf = PdfDocument();
      final font = PdfStandardFont(PdfFontFamily.helvetica, 14);
      final pages = <PdfPage>[];
      for (var i = 0; i < 3; i++) {
        final page = pdf.pages.add();
        pages.add(page);
        page.graphics.drawString(
          'Page ${i + 1} body text.',
          font,
          bounds: const Rect.fromLTWH(20, 20, 400, 100),
        );
      }
      // 注意：Syncfusion 的 `add(title, destination: ...)` 命名参数实际上没被使用
      // （内部固定传 null），必须**赋值** `destination` 才能真的写进目标页
      const at = Offset(0, 0);
      final first = pdf.bookmarks.add('Chapter One');
      first.destination = PdfDestination(pages[0], at);
      final section = first.add('Section 1.1');
      section.destination = PdfDestination(pages[1], at);
      final second = pdf.bookmarks.add('Chapter Two');
      second.destination = PdfDestination(pages[2], at);
      final bytes = pdf.saveSync();
      pdf.dispose();
      return bytes;
    }

    test('读出书签的标题、层级与页号，并用作章名', () async {
      final file = File('${dir.path}/outline.pdf')..writeAsBytesSync(buildPdfWithOutline());
      final document = Document(
        id: 'pdf_outline',
        title: 'outline',
        path: file.path,
        type: DocumentType.pdf,
        importedAt: DateTime(2024),
      );
      final result = await DocumentService.parse(document);

      final outline = result.document.outline;
      expect(outline.map((e) => e.title).toList(), <String>[
        'Chapter One',
        'Section 1.1',
        'Chapter Two',
      ]);
      expect(outline.map((e) => e.chapter).toList(), <int>[0, 1, 2]);
      expect(outline.map((e) => e.depth).toList(), <int>[0, 1, 0]);
      expect(result.document.hasOutline, isTrue);
      expect(result.document.maxOutlineDepth, 1);

      // 章名用书签标题（页号仍然一页一章，翻页与朗读不受影响）
      expect(result.document.chapterIsPage, isTrue);
      expect(result.document.chapters.length, 3);
      expect(result.document.chapters.map((c) => c.title).toList(), <String>[
        'Chapter One',
        'Section 1.1',
        'Chapter Two',
      ]);
      expect(result.document.chapters.first.paragraphs.first.text, contains('Page 1'));
    });

    test('没有书签的 PDF：目录为空，章名回到「第 N 页」', () async {
      final pdf = PdfDocument();
      for (var i = 0; i < 2; i++) {
        pdf.pages.add().graphics.drawString(
          'Page ${i + 1}.',
          PdfStandardFont(PdfFontFamily.helvetica, 12),
          bounds: const Rect.fromLTWH(20, 20, 300, 60),
        );
      }
      final file = File('${dir.path}/plain.pdf')..writeAsBytesSync(pdf.saveSync());
      pdf.dispose();

      final result = await DocumentService.parse(
        Document(
          id: 'plain',
          title: 'plain',
          path: file.path,
          type: DocumentType.pdf,
          importedAt: DateTime(2024),
        ),
      );
      expect(result.document.outline, isEmpty);
      expect(result.document.hasOutline, isFalse);
      expect(result.document.chapters.map((c) => c.title).toList(), <String>['第 1 页', '第 2 页']);
    });

    test('标题清洗：压缩空白并截断过长标题', () {
      expect(PdfOutlineReader.cleanTitle('  第一章\n\t 出发  '), '第一章 出发');
      expect(PdfOutlineReader.cleanTitle('书' * 300).length, 121);
      expect(PdfOutlineReader.cleanTitle('\u0000\u0007'), '');
    });

    test('isolate 解析路径（parseAsync）也能把目录带回来', () async {
      // 真实使用时解析跑在 isolate 里，目录对象要跨 isolate 复制回来 —— 这条专门盯这个
      final file = File('${dir.path}/async.pdf')..writeAsBytesSync(buildPdfWithOutline());
      final task = DocumentService.parseAsync(
        Document(
          id: 'pdf_async',
          title: 'async',
          path: file.path,
          type: DocumentType.pdf,
          importedAt: DateTime(2024),
        ),
      );
      final result = await task.result;

      expect(result.document.outline.length, 3, reason: '目录要跟着解析结果一起回来');
      expect(result.document.outline.first.title, 'Chapter One');
      expect(result.document.chapters.first.title, 'Chapter One');
    });

    test('titlesByPage：同一页多条时取第一条', () {
      const entries = <DocumentOutlineEntry>[
        DocumentOutlineEntry(title: '第一章', chapter: 0),
        DocumentOutlineEntry(title: '1.1 小节', chapter: 0, depth: 1),
        DocumentOutlineEntry(title: '第二章', chapter: 1),
      ];
      final map = PdfOutlineReader.titlesByPage(entries);
      expect(map[0], '第一章');
      expect(map[1], '第二章');
    });
  });

  group('EPUB 目录', () {
    /// 造一本 EPUB3：正文文件的 <title> 一律是书名（模拟真实世界的坑），
    /// 真正的章名只写在 nav 文档里。
    List<int> buildEpub3({bool withNav = true}) {
      const container = '<?xml version="1.0" encoding="UTF-8"?>'
          '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
          '<rootfiles><rootfile full-path="OEBPS/content.opf" '
          'media-type="application/oebps-package+xml"/></rootfiles></container>';

      final manifest = StringBuffer('<manifest>')
        ..write('<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>')
        ..write('<item id="ch1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>')
        ..write('<item id="ch2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>')
        ..write('<item id="ch3" href="Text/ch3.xhtml" media-type="application/xhtml+xml"/>')
        ..write('</manifest>');
      final opf = '<?xml version="1.0" encoding="UTF-8"?>'
          '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0">'
          '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:title>测试书</dc:title><dc:identifier id="bookid">urn:uuid:toc-test</dc:identifier>'
          '</metadata>$manifest'
          '<spine><itemref idref="ch1"/><itemref idref="ch2"/><itemref idref="ch3"/></spine>'
          '</package>';

      const nav = '<?xml version="1.0" encoding="utf-8"?>'
          '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
          '<head><title>目录</title></head><body>'
          '<nav epub:type="toc"><ol>'
          '<li><a href="Text/ch1.xhtml">第一章 出发</a></li>'
          '<li><a href="Text/ch2.xhtml">第二章 路上</a>'
          '<ol><li><a href="Text/ch2.xhtml#s1">第一节 雨</a></li></ol></li>'
          '<li><a href="Text/ch3.xhtml">第三章 归来</a></li>'
          '</ol></nav></body></html>';

      // 每个文件的 <title> 都是书名 —— 用 <title> 起章名就会出现三个「测试书」
      String body(String text) => '<?xml version="1.0" encoding="UTF-8"?>'
          '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>测试书</title></head>'
          '<body><p>$text</p></body></html>';

      final archive = Archive();
      void add(String name, String data, {bool store = false}) {
        final bytes = utf8.encode(data);
        archive.addFile(ArchiveFile(name, bytes.length, bytes)..compress = !store);
      }

      add('mimetype', 'application/epub+zip', store: true);
      add('META-INF/container.xml', container);
      add('OEBPS/content.opf', opf);
      if (withNav) add('OEBPS/nav.xhtml', nav);
      add('OEBPS/Text/ch1.xhtml', body('第一章的正文。'));
      add('OEBPS/Text/ch2.xhtml', body('第二章的正文。'));
      add('OEBPS/Text/ch3.xhtml', body('第三章的正文。'));
      return ZipEncoder().encode(archive)!;
    }

    test('EPUB3 用 nav 起章名并保留层级', () async {
      final file = File('${dir.path}/nav.epub')..writeAsBytesSync(buildEpub3());
      final result = await DocumentService.parseEpubManually(file.path);

      expect(result.document.chapters.length, 3);
      expect(result.document.chapters.map((c) => c.title).toList(), <String>[
        '第一章 出发',
        '第二章 路上',
        '第三章 归来',
      ]);
      expect(result.document.chapters.first.paragraphs.first.text, '第一章的正文。');

      final outline = result.document.outline;
      expect(outline.map((e) => e.title).toList(), <String>[
        '第一章 出发',
        '第二章 路上',
        '第一节 雨',
        '第三章 归来',
      ]);
      // 指向同一文件内锚点的条目也列出来，挂在同一章
      expect(outline.map((e) => e.chapter).toList(), <int>[0, 1, 1, 2]);
      expect(outline[2].depth, 1);
      expect(result.document.hasOutline, isTrue);
    });

    test('没有 nav 时退回「正文里的标题标签」，再退回「第 N 章」', () async {
      final file = File('${dir.path}/nonav.epub')..writeAsBytesSync(buildEpub3(withNav: false));
      final result = await DocumentService.parseEpubManually(file.path);

      expect(result.document.chapters.length, 3);
      expect(result.document.outline, isEmpty);
      // 正文里没有 h1，<title> 又是书名：只能按序号命名，且三个标题都一样也不该崩
      expect(result.document.chapters.first.title, '测试书');
    });

    test('主解析路径（DocumentService.parse）同样用上 nav', () async {
      final file = File('${dir.path}/main.epub')..writeAsBytesSync(buildEpub3());
      final result = await DocumentService.parse(
        Document(
          id: 'epub_nav',
          title: 'main',
          path: file.path,
          type: DocumentType.epub,
          importedAt: DateTime(2024),
        ),
      );
      expect(result.document.chapters.map((c) => c.title).first, '第一章 出发');
      expect(result.document.outline.length, 4);
    });
  });
}

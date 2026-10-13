import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/models/web_link.dart';
import 'package:tts_reader/services/document_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 1×1 的合法 JPEG，用作 EPUB 封面的测试数据
const String tinyJpegBase64 =
    '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a'
    'HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA'
    'AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==';

/// 现场构造一个合法的 EPUB（EPUB2：container.xml + OPF + NCX + 两个 XHTML 章节 + 封面）
List<int> buildTestEpub({bool corruptCover = false}) {
  const container = '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
      '<rootfiles><rootfile full-path="OEBPS/content.opf" '
      'media-type="application/oebps-package+xml"/></rootfiles></container>';

  const opf = '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="2.0">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">'
      '<dc:title>测试书</dc:title><dc:language>zh</dc:language>'
      '<dc:identifier id="bookid">urn:uuid:test-epub-0001</dc:identifier>'
      '<meta name="cover" content="cover-image"/></metadata>'
      '<manifest>'
      '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
      '<item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="cover-image" href="images/cover.jpg" media-type="image/jpeg"/>'
      '</manifest>'
      '<spine toc="ncx"><itemref idref="ch1"/><itemref idref="ch2"/></spine></package>';

  const ncx = '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
      '<head><meta name="dtb:uid" content="urn:uuid:test-epub-0001"/></head>'
      '<docTitle><text>测试书</text></docTitle><navMap>'
      '<navPoint id="np1" playOrder="1"><navLabel><text>第一章</text></navLabel>'
      '<content src="ch1.xhtml"/></navPoint>'
      '<navPoint id="np2" playOrder="2"><navLabel><text>第二章</text></navLabel>'
      '<content src="ch2.xhtml"/></navPoint></navMap></ncx>';

  const ch1 = '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title></head><body>'
      '<h1>第一章</h1><p>第一章第一句。第一章第二句！</p><p>第一章第二段。</p></body></html>';

  const ch2 = '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第二章</title></head><body>'
      '<h1>第二章</h1><p>第二章只有一段。</p></body></html>';

  final cover = corruptCover
      ? <int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
      : base64Decode(tinyJpegBase64);

  final archive = Archive();
  void add(String name, List<int> data, {bool store = false}) {
    archive.addFile(ArchiveFile(name, data.length, data)..compress = !store);
  }

  // mimetype 必须是第一个条目且不压缩
  add('mimetype', utf8Bytes('application/epub+zip'), store: true);
  add('META-INF/container.xml', utf8Bytes(container));
  add('OEBPS/content.opf', utf8Bytes(opf));
  add('OEBPS/toc.ncx', utf8Bytes(ncx));
  add('OEBPS/ch1.xhtml', utf8Bytes(ch1));
  add('OEBPS/ch2.xhtml', utf8Bytes(ch2));
  add('OEBPS/images/cover.jpg', cover);
  return ZipEncoder().encode(archive)!;
}

List<int> utf8Bytes(String text) => const Utf8Encoder().convert(text);

void main() {
  group('WebLink', () {
    test('toJson / fromJson 往返一致，空标题回退域名', () {
      final link = WebLink(title: '', url: 'https://example.com/a/b', createdAt: DateTime(2024, 6, 1, 8, 30));
      final restored = WebLink.fromJson(link.toJson());
      expect(restored.url, link.url);
      expect(restored.createdAt, link.createdAt);
      expect(restored.displayTitle, 'example.com');
      expect(
        WebLink(title: '标题', url: 'https://a.com', createdAt: DateTime(2024)).displayTitle,
        '标题',
      );
    });
  });

  group('目录分页', () {
    final document = StructuredDocument(
      chapters: <Chapter>[
        Chapter(
          title: '全文',
          paragraphs: <Paragraph>[
            for (var i = 0; i < 95; i++) Paragraph(sentences: <Sentence>[Sentence('第 $i 段。')]),
          ],
        ),
        const Chapter(title: '第二章', paragraphs: <Paragraph>[]),
      ],
    );

    test('pageRanges 按每页段数切分，最后一页取余数', () {
      final ranges = document.pageRanges(0, 40);
      expect(ranges.length, 3);
      expect(ranges.first, (0, 40));
      expect(ranges.last, (80, 95));
      expect(document.pageRanges(1, 40), isEmpty);
      expect(document.pageRanges(9, 40), isEmpty);
      expect(document.pageRanges(0, 0), isEmpty);
    });

    test('pageOf 定位段落下标所在页', () {
      expect(document.pageOf(0, 0, 40), 1);
      expect(document.pageOf(0, 39, 40), 1);
      expect(document.pageOf(0, 40, 40), 2);
      expect(document.pageOf(0, 94, 40), 3);
    });

    test('粒度只剩 句 / 章 / 页', () {
      expect(ReadGranularity.values, <ReadGranularity>[
        ReadGranularity.sentence,
        ReadGranularity.chapter,
        ReadGranularity.page,
      ]);
    });

    test('PDF 模式（chapterIsPage）：一章即一页，不再二次分页', () {
      final pdfLike = StructuredDocument(
        chapters: <Chapter>[
          Chapter(title: '第 1 页', paragraphs: <Paragraph>[
            for (var i = 0; i < 95; i++) Paragraph(sentences: <Sentence>[Sentence('第 $i 段。')]),
          ]),
          const Chapter(title: '第 2 页', paragraphs: <Paragraph>[]),
        ],
        chapterIsPage: true,
      );
      expect(pdfLike.pageRanges(0, 40), <(int, int)>[(0, 95)]);
      expect(pdfLike.pageOf(0, 80, 40), 1);
      expect(pdfLike.pageOf(1, 0, 40), 2);
      expect(pdfLike.totalPages(40), 2);
    });

    test('indexOfCursor / cursorAt 互为逆运算', () {
      final doc = StructuredDocument(
        chapters: const <Chapter>[
          Chapter(title: 'A', paragraphs: <Paragraph>[
            Paragraph(sentences: <Sentence>[Sentence('a1。'), Sentence('a2。')]),
            Paragraph(sentences: <Sentence>[Sentence('a3。')]),
          ]),
          Chapter(title: 'B', paragraphs: <Paragraph>[
            Paragraph(sentences: <Sentence>[Sentence('b1。'), Sentence('b2。')]),
          ]),
        ],
      );
      expect(doc.sentenceCount, 5);
      expect(doc.indexOfCursor((0, 0, 0)), 0);
      expect(doc.indexOfCursor((0, 1, 0)), 2);
      expect(doc.indexOfCursor((1, 0, 1)), 4);
      // 反查
      expect(doc.cursorAt(0), (0, 0, 0));
      expect(doc.cursorAt(0.4), (0, 1, 0));
      expect(doc.cursorAt(0.9), (1, 0, 1));
      expect(doc.cursorAt(1), (1, 0, 1));
      expect(doc.progressOf((1, 0, 1)), 0.8);
    });
  });

  group('网页正文分片', () {
    test('按段落 / 句子切分且不超过上限', () {
      final chunks = DocumentService.readChunks('第一句。第二句！\n\n第二段内容。', maxLength: 12);
      expect(chunks, isNotEmpty);
      for (final chunk in chunks) {
        expect(chunk.length, lessThanOrEqualTo(12));
      }
      expect(chunks.join(), contains('第二段内容。'));
    });

    test('超长单句会被硬切而不是丢字', () {
      final long = '啊' * 50;
      final chunks = DocumentService.readChunks(long, maxLength: 20);
      expect(chunks.length, greaterThanOrEqualTo(3));
      expect(chunks.join().length, 50);
    });

    test('空白文本得到空列表', () {
      expect(DocumentService.readChunks('   \n\n  '), isEmpty);
    });
  });

  group('后台 isolate 解析', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('tts_reader_test');
    });

    tearDown(() async {
      try {
        if (dir.existsSync()) await dir.delete(recursive: true);
      } catch (_) {
        // Windows 上被强制终止的 isolate 可能仍短暂持有文件句柄，忽略清理失败
      }
    });

    test('解析 TXT：结构正确且回报进度', () async {
      final file = File('${dir.path}/demo.txt')
        ..writeAsStringSync('第一段第一句。第一段第二句！\n\n第二段只有一句。');
      final document = Document(
        id: 'txt1',
        title: 'demo',
        path: file.path,
        type: DocumentType.txt,
        importedAt: DateTime(2024),
      );

      final progress = <double>[];
      final task = DocumentService.parseAsync(document, onProgress: (p) => progress.add(p.value));
      final result = await task.result;

      expect(result.document.chapters.length, 1);
      expect(result.document.chapters.first.title, '全文');
      final paragraphs = result.document.chapters.first.paragraphs;
      expect(paragraphs.length, 2);
      expect(paragraphs.first.sentences.length, 2);
      expect(paragraphs.first.sentences.first.text, '第一段第一句。');
      expect(paragraphs.last.sentences.single.text, '第二段只有一句。');
      expect(progress, isNotEmpty);
      expect(progress.last, 1.0);
    });

    test('取消解析：等待方收到取消异常而不是挂起', () async {
      final file = File('${dir.path}/big.txt')
        ..writeAsStringSync(List<String>.filled(2000, '一段文字。').join('\n\n'));
      final document = Document(
        id: 'txt2',
        title: 'big',
        path: file.path,
        type: DocumentType.txt,
        importedAt: DateTime(2024),
      );
      final task = DocumentService.parseAsync(document);
      task.cancel();
      await expectLater(task.result, throwsA(isA<ParseCancelledException>()));
    });

    test('文件不存在时抛出可读错误', () async {
      final document = Document(
        id: 'missing',
        title: 'missing',
        path: '${dir.path}/nope.txt',
        type: DocumentType.txt,
        importedAt: DateTime(2024),
      );
      await expectLater(DocumentService.parse(document), throwsA(anything));
    });

    test('PDF 按页拆章：章号与页号一一对应，空白页也保留', () async {
      final file = File('${dir.path}/demo.pdf');
      final pdf = PdfDocument();
      for (var i = 0; i < 3; i++) {
        final page = pdf.pages.add();
        // 第 2 页留空，模拟扫描页 / 图片页
        if (i != 1) {
          page.graphics.drawString(
            'Page ${i + 1} text.',
            PdfStandardFont(PdfFontFamily.helvetica, 14),
            bounds: const Rect.fromLTWH(20, 20, 400, 100),
          );
        }
      }
      file.writeAsBytesSync(pdf.saveSync());
      pdf.dispose();

      final document = Document(
        id: 'pdf1',
        title: 'demo',
        path: file.path,
        type: DocumentType.pdf,
        importedAt: DateTime(2024),
      );
      final result = await DocumentService.parse(document);

      expect(result.document.chapterIsPage, isTrue);
      expect(result.document.chapters.length, 3);
      expect(result.document.chapters[0].title, '第 1 页');
      expect(result.document.chapters[2].title, '第 3 页');
      expect(result.document.chapters[0].paragraphs.first.text, contains('Page 1'));
      expect(result.document.chapters[2].paragraphs.first.text, contains('Page 3'));
      // 空白页保留为空章，避免页号错位
      expect(result.document.chapters[1].paragraphs, isEmpty);
      expect(result.document.totalPages(40), 3);

      // 3 页里 2 页有文字 → 判定为有文本层
      expect(result.hasTextLayer, isTrue);
      expect(result.pageCount, 3);
      expect(result.textCharCount, greaterThan(0));
    });

    test('PDF 文本层检测：纯图片（扫描件）判为无文本层', () async {
      final file = File('${dir.path}/scan.pdf');
      final pdf = PdfDocument();
      for (var i = 0; i < 4; i++) {
        pdf.pages.add();
      }
      file.writeAsBytesSync(pdf.saveSync());
      pdf.dispose();

      final document = Document(
        id: 'scan1',
        title: 'scan',
        path: file.path,
        type: DocumentType.pdf,
        importedAt: DateTime(2024),
      );
      final result = await DocumentService.parse(document);

      expect(result.hasTextLayer, isFalse);
      expect(result.pageCount, 4);
      expect(result.textCharCount, 0);
      // 页仍然一页一章，方便原版式翻页
      expect(result.document.chapters.length, 4);
    });

    test('EPUB：主路径解析出章节、正文与文本层', () async {
      final file = File('${dir.path}/book.epub')..writeAsBytesSync(buildTestEpub());
      final document = Document(
        id: 'epub1',
        title: 'book',
        path: file.path,
        type: DocumentType.epub,
        importedAt: DateTime(2024),
      );
      final result = await DocumentService.parse(document);

      expect(result.hasTextLayer, isTrue);
      expect(result.document.chapters.length, 2);
      expect(result.document.chapters.first.paragraphs.first.text, contains('第一章第一句。'));
      expect(result.document.chapters.last.paragraphs.first.text, contains('第二章只有一段。'));

      // 封面能被抽出来（走 epubx 或兜底路径都应成功）
      final coverPath = '${dir.path}/cover.jpg';
      final cover = await DocumentService.extractCover(document, coverPath);
      expect(cover, coverPath);
      expect(File(coverPath).existsSync(), isTrue);
      expect(File(coverPath).lengthSync(), greaterThan(0));
    });

    test('EPUB 兜底解析：直接读 container.xml / OPF / spine', () async {
      final file = File('${dir.path}/manual.epub')..writeAsBytesSync(buildTestEpub());
      final result = await DocumentService.parseEpubManually(file.path);

      expect(result.hasTextLayer, isTrue);
      expect(result.document.chapters.length, 2);
      // 标题取自 <title>
      expect(result.document.chapters.first.title, '第一章');
      expect(result.document.chapters.last.title, '第二章');
      expect(result.document.chapters.first.paragraphs.length, 2);
      expect(result.document.chapters.first.paragraphs.first.text, '第一章第一句。第一章第二句！');
    });

    test('EPUB 兜底解析：顺带复制封面原图', () async {
      final file = File('${dir.path}/manual2.epub')..writeAsBytesSync(buildTestEpub());
      final coverPath = '${dir.path}/fallback-cover.jpg';
      await DocumentService.parseEpubManually(file.path, coverOutPath: coverPath);
      expect(File(coverPath).existsSync(), isTrue);
      expect(File(coverPath).lengthSync(), greaterThan(0));
    });

    test('EPUB：封面损坏时仍能解析出正文（不会整本失败）', () async {
      final file = File('${dir.path}/bad-cover.epub')..writeAsBytesSync(buildTestEpub(corruptCover: true));
      final document = Document(
        id: 'epub2',
        title: 'bad',
        path: file.path,
        type: DocumentType.epub,
        importedAt: DateTime(2024),
      );
      final result = await DocumentService.parse(document);
      // 无论走哪条路径，用户看到的结果都必须是「解析成功」
      expect(result.document.sentenceCount, greaterThan(0));
      expect(result.document.chapters.length, 2);
      expect(result.hasTextLayer, isTrue);
    });

    test('EPUB：不是 zip 时给出可读错误', () async {
      final file = File('${dir.path}/broken.epub')..writeAsStringSync('这不是一个 epub 文件');
      final document = Document(
        id: 'epub3',
        title: 'broken',
        path: file.path,
        type: DocumentType.epub,
        importedAt: DateTime(2024),
      );
      await expectLater(DocumentService.parse(document), throwsA(anything));
    });
  });

  group('大文档游标索引', () {
    StructuredDocument buildBig(int chapters) {
      return StructuredDocument(
        chapters: <Chapter>[
          for (var c = 0; c < chapters; c++)
            Chapter(
              title: '第 ${c + 1} 页',
              paragraphs: <Paragraph>[
                for (var p = 0; p < 3; p++)
                  Paragraph(sentences: <Sentence>[
                    for (var s = 0; s < 4; s++) Sentence('第 $c-$p-$s 句。'),
                  ]),
              ],
            ),
        ],
        chapterIsPage: true,
      );
    }

    test('统计量只算一次且游标换算正确', () {
      final document = buildBig(1500);
      expect(document.chapters.length, 1500);
      expect(document.paragraphCount, 4500);
      expect(document.sentenceCount, 18000);

      // 第 1000 章第 2 段第 3 句 = 1000*12 + 2*4 + 3
      expect(document.indexOfCursor((1000, 2, 3)), 1000 * 12 + 11);
      expect(document.progressOf((0, 0, 0)), 0);
      expect(document.progressOf((1499, 2, 3)), closeTo((1499 * 12 + 11) / 18000, 1e-9));

      // 反复调用不应改变结果（惰性缓存）
      for (var i = 0; i < 5; i++) {
        expect(document.sentenceCount, 18000);
        expect(document.indexOfCursor((500, 1, 2)), 500 * 12 + 6);
      }
    });

    test('cursorAt 与 indexOfCursor 在整篇范围内互逆', () {
      final document = buildBig(200);
      for (final cursor in <(int, int, int)>[(0, 0, 0), (7, 2, 3), (199, 2, 3), (123, 1, 2)]) {
        final progress = document.progressOf(cursor);
        expect(document.cursorAt(progress), cursor);
      }
      expect(document.cursorAt(1), (199, 2, 3));
      expect(document.cursorAt(0), (0, 0, 0));
    });
  });

  group('快进 / 快退一页（底部控制栏）', () {
    // TtsManager 会初始化 flutter_tts（MethodChannel），本文件原本是纯 Dart 测试，
    // 没有初始化 binding；不初始化会直接断言失败。
    setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

    /// TtsManager 的游标是在 _run 里「先 await 停掉上一段声音、再落游标」，
    /// 所以断言前必须让真实事件循环跑一会儿。
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

    /// 等「真实游标」落到位。
    ///
    /// ⚠️ §4.102 之后**不能**再轮询 `tts.cursor` 来等落位：那个 getter 现在优先
    /// 返回「意图游标」（`speakFrom` / `skip*` 一进来就同步写入），于是它一调用
    /// 就已经等于预期值、`until` 会立刻返回，**根本等不到异步落位**，
    /// 下一步动作就会在真实游标还没落地时发出（本组用例曾因此变红）。
    /// 轮询目标是「真实游标」`settledCursor` —— 这才是「落位完成了没」的信号。
    Future<void> until(TtsManager tts, (int, int, int) expected) async {
      for (var i = 0; i < 60; i++) {
        if (tts.settledCursor == expected) return;
        await settle();
      }
      expect(tts.settledCursor, expected,
          reason: '真实游标未按页步进到 $expected（意图游标=${tts.cursor}）');
    }

    /// 单章 90 段的 TXT（每页 40 段 → 3 页：0-39 / 40-79 / 80-89）
    StructuredDocument buildTxt() => StructuredDocument(
      chapters: <Chapter>[
        Chapter(
          title: '全文',
          paragraphs: <Paragraph>[
            for (var p = 0; p < 90; p++)
              Paragraph(sentences: <Sentence>[Sentence('第 $p 段。')]),
          ],
        ),
      ],
    );

    test('按页边界步进：40 段一页，末页再快进落到末段而不越界', () async {
      final tts = TtsManager.instance;
      tts.loadDocument(buildTxt());
      expect(tts.cursor, (0, 0, 0));

      tts.skipPageForward();
      await until(tts, (0, 40, 0));

      tts.skipPageForward();
      await until(tts, (0, 80, 0));

      // 末页只剩 80~89：再快进落到末段，不越界也不停住不动
      tts.skipPageForward();
      await until(tts, (0, 89, 0));
      expect(tts.cursor.$2, lessThan(90));
    });

    test('从半页位置快退先归位到本页起点，再整页后退', () async {
      final tts = TtsManager.instance;
      tts.loadDocument(buildTxt());
      tts.speakFrom(0, 89, 0);
      await until(tts, (0, 89, 0));

      // 归位到本页起点 80 → 再退一页 40
      tts.skipPageBackward();
      await until(tts, (0, 40, 0));

      tts.skipPageBackward();
      await until(tts, (0, 0, 0));

      // 首页再快退不越界
      tts.skipPageBackward();
      await settle();
      expect(tts.cursor, (0, 0, 0));
    });

    test('PDF 一章即一页：快进 / 快退按章走', () async {
      final tts = TtsManager.instance;
      final pdf = StructuredDocument(
        chapters: <Chapter>[
          for (var c = 0; c < 5; c++)
            Chapter(
              title: '第 ${c + 1} 页',
              paragraphs: <Paragraph>[
                Paragraph(sentences: <Sentence>[Sentence('第 ${c + 1} 页正文。')]),
              ],
            ),
        ],
        chapterIsPage: true,
      );
      tts.loadDocument(pdf);
      await tts.setGranularity(ReadGranularity.chapter);
      expect(tts.cursor, (0, 0, 0));

      tts.skipPageForward();
      await until(tts, (1, 0, 0));

      tts.skipPageForward();
      await until(tts, (2, 0, 0));

      tts.skipPageBackward();
      await until(tts, (1, 0, 0));

      // 末页再快进停在末页
      tts.speakFrom(4, 0, 0);
      await until(tts, (4, 0, 0));
      tts.skipPageForward();
      await settle();
      expect(tts.cursor, (4, 0, 0));

      await tts.setGranularity(ReadGranularity.sentence);
      await tts.stop();
    });
  });
}

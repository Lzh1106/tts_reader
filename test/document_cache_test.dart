import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/pdf_line_box.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/document_cache.dart';
import 'package:tts_reader/services/document_service.dart';

/// 解析结果磁盘缓存验证。
///
/// 这一层的价值全在「大文件第二次打开」上，所以用例盯的是三件事：
/// 1. 写进去的东西能一模一样读回来（含 PDF 行表、目录、空章节）；
/// 2. 文件变了 / 缓存被写坏时**必须**读不出来（宁可重解析，不能解出半本书）；
/// 3. 走 DocumentService 的真实入口时，命中缓存不再起 isolate。
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tts_cache_test');
    // 块读缓存是**静态**的（跨用例会串味：命中缓存会让"读盘次数"断言失真）
    DocumentCache.resetBlockCacheForTest();
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String cachePath([String name = 'doc']) => '${dir.path}/$name.ttsc';

  /// 造一份有代表性的文档：两章、多段多句、带目录与 PDF 行表
  ParsedSnapshot sample() {
    final boxes = <PdfLineBox>[
      const PdfLineBox(
        text: 'Page 1 first sentence.',
        bounds: Rect.fromLTRB(20, 20, 320, 40),
      ),
      const PdfLineBox(
        text: '第二行，带中文与标点。',
        bounds: Rect.fromLTRB(20.5, 44.25, 300.75, 64),
      ),
    ];
    return ParsedSnapshot(
      document: StructuredDocument(
        chapterIsPage: true,
        chapters: <Chapter>[
          const Chapter(
            title: '第 1 页',
            paragraphs: <Paragraph>[
              Paragraph(
                sentences: <Sentence>[
                  Sentence('Page 1 first sentence.'),
                  Sentence('第二句。'),
                ],
              ),
              Paragraph(sentences: <Sentence>[Sentence('另一段只有一句')]),
            ],
          ),
          const Chapter(title: '空页也占一章', paragraphs: <Paragraph>[]),
        ],
        outline: const <DocumentOutlineEntry>[
          DocumentOutlineEntry(title: '封面', chapter: 0, depth: 0),
          DocumentOutlineEntry(title: '第一章', chapter: 1, paragraph: 0, depth: 1),
        ],
      ),
      hasTextLayer: true,
      pageCount: 2,
      textCharCount: 42,
      fileSize: 123456,
      encoding: 'GBK',
      pdfLines: <int, List<PdfLineBox>>{0: boxes},
      textRevision: DocumentService.parseRevision,
    );
  }

  group('缓存往返', () {
    test('写进去的结构原样读回来（章 / 段 / 句 / 目录 / 编码 / 分块索引）', () {
      final identity = DocumentCache.identityOfFile('/books/a.pdf', 123456, 777);
      DocumentCache.write(cachePath(), identity, sample());

      final read = DocumentCache.read(cachePath(), identity);
      expect(read, isNotNull);
      final document = read!.document;
      expect(document.chapters.length, 2);
      expect(document.chapterIsPage, isTrue);
      expect(document.chapters[0].title, '第 1 页');
      expect(document.chapters[0].paragraphs.length, 2);
      expect(document.chapters[0].paragraphs[0].sentences.length, 2);
      expect(document.chapters[0].paragraphs[0].sentences[1].text, '第二句。');
      expect(document.chapters[1].paragraphs, isEmpty, reason: '空章节要保住占位');
      expect(document.outline.length, 2);
      expect(document.outline[1].title, '第一章');
      expect(document.outline[1].depth, 1);
      expect(read.encoding, 'GBK');
      expect(read.hasTextLayer, isTrue);
      expect(read.pageCount, 2);
      expect(read.textCharCount, 42);
      expect(read.fileSize, 123456);
      expect(read.textRevision, DocumentService.parseRevision);
    });

    test('行表不再进主缓存：改由「分块索引 + 块文件」读回（L2b-2 语义）', () {
      final Map<int, List<PdfLineBox>> lines = <int, List<PdfLineBox>>{
        for (var page = 0; page < 60; page++)
          page: <PdfLineBox>[
            PdfLineBox(
              text: '第 $page 页第一行',
              bounds: Rect.fromLTWH(0.0, page * 14.0, 200, 12),
            ),
          ],
      };
      final identity = DocumentCache.identityOfFile('/books/big.pdf', 999, 888);
      DocumentCache.write(
        cachePath('big'),
        identity,
        ParsedSnapshot(
          document: StructuredDocument(
            chapters: <Chapter>[
              const Chapter(title: '第 1 页', paragraphs: <Paragraph>[]),
            ],
          ),
          hasTextLayer: true,
          pageCount: 60,
          textCharCount: 60,
          pdfLines: lines,
          linesChunks: DocumentCache.chunksOf(lines),
        ),
      );
      // 块文件的生产者仍是写入侧（`DocumentService.writeCache` 里那句
      // `writeLineChunks` 必须保留 —— 它是行表唯一的落盘处）
      expect(DocumentCache.writeLineChunks(dir.path, 'big', lines), 2);

      final read = DocumentCache.read(cachePath('big'), identity);
      expect(read, isNotNull);
      // ① 主缓存里**没有**整份行表 —— 这是本轮改动的核心
      expect(read!.pdfLines, isNull,
          reason: '命中缓存时行表一律为 null，消费方必须走按块读');

      // ② 读取地图在：块号 + 覆盖页区间（与 writeLineChunks 的分块口径一致）
      final List<LinesChunkRef>? chunks = read.linesChunks;
      expect(chunks, isNotNull, reason: '没有地图就不知道有哪些块，行表等于丢了');
      expect(chunks!.length, 2, reason: '60 页 / 50 页一块 = 2 块');
      expect(chunks.first.chunk, 0);
      expect(chunks.first.startPage, 0);
      expect(chunks.first.endPage, 49);
      expect(chunks.last.chunk, 1);
      expect(chunks.last.startPage, 50);
      expect(chunks.last.endPage, 59);

      // ③ 照地图去块文件读回：页号与内容都要对得上（这才是"行表真的还在"）
      var totalPages = 0;
      for (final LinesChunkRef ref in chunks) {
        final Map<int, List<PdfLineBox>>? back = DocumentCache.readLineChunkByName(
          dir.path,
          'big',
          ref.chunk,
        );
        expect(back, isNotNull, reason: '第 ${ref.chunk} 块必须读得回来');
        for (final int page in back!.keys) {
          expect(page ~/ DocumentCache.linesChunkPages, ref.chunk);
          expect(page, inInclusiveRange(ref.startPage, ref.endPage),
              reason: '读回来的页必须落在地图声明的区间里');
          expect(back[page]!.first.text, lines[page]!.first.text,
              reason: '文本要原样读回');
          expect(back[page]!.first.bounds, lines[page]!.first.bounds,
              reason: '包围盒要原样读回');
        }
        totalPages += back.length;
      }
      expect(totalPages, 60, reason: '两块合起来正好覆盖 60 页');
    });

    test('编码为 null 与空串能区分', () {
      DocumentCache.write(
        cachePath('a'),
        'id',
        ParsedSnapshot(
          document: StructuredDocument(
            chapters: <Chapter>[
              const Chapter(
                title: 't',
                paragraphs: <Paragraph>[
                  Paragraph(sentences: <Sentence>[Sentence('x')]),
                ],
              ),
            ],
          ),
          hasTextLayer: false,
          pageCount: 1,
          textCharCount: 1,
        ),
      );
      expect(DocumentCache.read(cachePath('a'), 'id')!.encoding, isNull);
    });

    test('没有行表时读回来也是 null（不是空 Map）', () {
      final snapshot = ParsedSnapshot(
        document: StructuredDocument(
          chapters: <Chapter>[
            const Chapter(
              title: '全文',
              paragraphs: <Paragraph>[
                Paragraph(sentences: <Sentence>[Sentence('只有一段')]),
              ],
            ),
          ],
        ),
        hasTextLayer: true,
        pageCount: 1,
        textCharCount: 4,
      );
      DocumentCache.write(cachePath('b'), 'id', snapshot);
      expect(DocumentCache.read(cachePath('b'), 'id')!.pdfLines, isNull);
    });
  });

  group('失效判据', () {
    test('文件指纹变了（大小 / 时间 / 路径）就读不到', () {
      final identity = DocumentCache.identityOfFile('/books/a.pdf', 100, 1000);
      DocumentCache.write(cachePath(), identity, sample());

      expect(DocumentCache.read(cachePath(), identity), isNotNull);
      expect(
        DocumentCache.read(cachePath(), DocumentCache.identityOfFile('/books/a.pdf', 101, 1000)),
        isNull,
        reason: '大小变了',
      );
      expect(
        DocumentCache.read(cachePath(), DocumentCache.identityOfFile('/books/a.pdf', 100, 1001)),
        isNull,
        reason: '修改时间变了',
      );
      expect(
        DocumentCache.read(cachePath(), DocumentCache.identityOfFile('/books/b.pdf', 100, 1000)),
        isNull,
        reason: '换文件了',
      );
    });

    test('缓存被写坏（改一个字节）读不到，而不是解出半本书', () {
      final identity = DocumentCache.identityOfFile('/books/a.pdf', 100, 1000);
      DocumentCache.write(cachePath(), identity, sample());

      final file = File(cachePath());
      final bytes = Uint8List.fromList(file.readAsBytesSync());
      // 改载荷区最后一个字节：CRC 应当立刻发现
      bytes[bytes.length - 1] = bytes[bytes.length - 1] ^ 0xFF;
      file.writeAsBytesSync(bytes);

      expect(DocumentCache.read(cachePath(), identity), isNull);
    });

    test('文件被截断读不到', () {
      final identity = DocumentCache.identityOfFile('/books/a.pdf', 100, 1000);
      DocumentCache.write(cachePath(), identity, sample());

      final file = File(cachePath());
      final bytes = file.readAsBytesSync();
      file.writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
      expect(DocumentCache.read(cachePath(), identity), isNull);
    });

    test('不是缓存文件（magic 不符）读不到', () {
      File(cachePath()).writeAsBytesSync(List<int>.filled(64, 0x41));
      expect(DocumentCache.read(cachePath(), 'any'), isNull);
    });

    test('文件不存在读不到', () {
      expect(DocumentCache.read('${dir.path}/missing.ttsc', 'any'), isNull);
    });

    test('缓存格式版本变化后被丢弃', () {
      final identity = DocumentCache.identityOfFile('/books/a.pdf', 100, 1000);
      DocumentCache.write(cachePath(), identity, sample());

      final file = File(cachePath());
      final bytes = Uint8List.fromList(file.readAsBytesSync());
      // 版本字段在头部偏移 4（小端 2 字节）
      bytes[4] = 0xFF;
      bytes[5] = 0xFF;
      file.writeAsBytesSync(bytes);
      expect(DocumentCache.read(cachePath(), identity), isNull);
    });
  });

  group('DocumentService 入口', () {
    test('cacheDirectory 会建出目录，dropCache 会把缓存清掉', () async {
      final cacheDir = DocumentService.cacheDirectory(basePath: dir.path);
      final dir2 = await cacheDir;
      expect(dir2.isNotEmpty, isTrue);
      expect(Directory(dir2).existsSync(), isTrue);

      DocumentCache.write(
        '$dir2${Platform.pathSeparator}${DocumentCache.fileNameFor('doc1')}',
        'whatever',
        sample(),
      );
      final target =
          '$dir2${Platform.pathSeparator}${DocumentCache.fileNameFor('doc1')}';
      expect(File(target).existsSync(), isTrue);
      DocumentService.dropCache(dir2, 'doc1');
      expect(File(target).existsSync(), isFalse);
    });

    test('文件名清洗：文档 id 里的怪字符不会跑出目录', () {
      final name = DocumentCache.fileNameFor('a/b\\c:d*e?f');
      expect(name.contains('/'), isFalse);
      expect(name.contains('\\'), isFalse);
      expect(name.endsWith(DocumentCache.extension), isTrue);
    });

    test('TXT 命中缓存时不再起 isolate（第二次打开是「读取缓存」）', () async {
      final file = File('${dir.path}/book.txt');
      final content = StringBuffer();
      for (var c = 1; c <= 6; c++) {
        content.writeln('第 $c 章 测试章节');
        for (var p = 0; p < 8; p++) {
          content.writeln('第 $c 章第 $p 段的内容。这里还有第二句！');
        }
        content.writeln();
      }
      file.writeAsStringSync(content.toString());

      final cacheDir = await DocumentService.cacheDirectory(basePath: dir.path);
      final document = Document(
        id: 'cache_hit_txt',
        title: '缓存命中',
        path: file.path,
        type: DocumentType.txt,
        importedAt: DateTime.now(),
      );

      // 第一次：真解析（isolate）并落盘
      final first = await DocumentService.parse(document, cacheDir: cacheDir);
      expect(first.fromCache, isFalse);
      expect(first.document.chapters.length, greaterThanOrEqualTo(6));
      final cacheFile =
          '$cacheDir${Platform.pathSeparator}${DocumentCache.fileNameFor(document.id)}';
      expect(File(cacheFile).existsSync(), isTrue, reason: '真解析后应当写出缓存');
      expect(File('$cacheFile.tmp').existsSync(), isFalse, reason: '临时文件要被改名掉');

      // 第二次：命中缓存
      final stages = <String>[];
      final second = await DocumentService.parse(
        document,
        cacheDir: cacheDir,
        onProgress: (progress) => stages.add(progress.stage),
      );
      expect(second.fromCache, isTrue);
      expect(stages, contains('读取缓存'));
      expect(second.document.chapters.length, first.document.chapters.length);
      expect(second.document.sentenceCount, first.document.sentenceCount);
      expect(
        second.document.chapters[1].paragraphs.first.sentences.first.text,
        first.document.chapters[1].paragraphs.first.sentences.first.text,
      );
    });

    test('文件内容变了（同一路径）缓存失效，重新解析', () async {
      final file = File('${dir.path}/change.txt');
      file.writeAsStringSync('第 1 章 甲\n正文一。\n\n第 2 章 乙\n正文二。\n');
      final cacheDir = await DocumentService.cacheDirectory(basePath: dir.path);
      final document = Document(
        id: 'cache_change',
        title: '变更',
        path: file.path,
        type: DocumentType.txt,
        importedAt: DateTime.now(),
      );

      final first = await DocumentService.parse(document, cacheDir: cacheDir);
      expect(first.fromCache, isFalse);
      expect(first.document.chapters.length, 2);

      // 改内容并让修改时间往前走（文件系统时间精度可能是秒）
      file.writeAsStringSync('第 1 章 甲\n改过的正文。\n');
      file.setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));

      final second = await DocumentService.parse(document, cacheDir: cacheDir);
      expect(second.fromCache, isFalse, reason: '文件变了就不能再用旧缓存');
      expect(second.document.chapters.length, 1);
    });

    test('不传 cacheDir 时行为与从前一致（不写缓存）', () async {
      final file = File('${dir.path}/nocache.txt');
      file.writeAsStringSync('第 1 章 甲\n正文一。\n\n第 2 章 乙\n正文二。\n');
      final document = Document(
        id: 'no_cache',
        title: '无缓存',
        path: file.path,
        type: DocumentType.txt,
        importedAt: DateTime.now(),
      );
      final result = await DocumentService.parse(document);
      expect(result.fromCache, isFalse);
      expect(
        File('${dir.path}/${DocumentCache.fileNameFor(document.id)}').existsSync(),
        isFalse,
      );
    });
  });
}

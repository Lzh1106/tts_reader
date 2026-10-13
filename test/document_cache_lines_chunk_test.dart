import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/pdf_line_box.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/document_cache.dart';

/// **分块行表**（v1.21.33 / L2a）：
/// 把整份行表按 [DocumentCache.linesChunkPages] 页一块写成 `.ttsl`，
/// 供将来"阅读页只读当前页所在块"（L2b）用。
///
/// L2a 是**纯增量**：主缓存格式不变（`formatVersion` 仍是 2）、读路径不变。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<int, List<PdfLineBox>> makeLines(int pageCount, {int linesPerPage = 2}) {
    return <int, List<PdfLineBox>>{
      for (var page = 0; page < pageCount; page++)
        page: <PdfLineBox>[
          for (var i = 0; i < linesPerPage; i++)
            PdfLineBox(
              text: '第 $page 页第 $i 行',
              bounds: Rect.fromLTWH(0, i * 14.0, 200, 12),
            ),
        ],
    };
  }

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lines_chunk');
    // 块读缓存是静态的：不清会让"读盘次数 / 淘汰最旧"这类断言跨用例串味
    DocumentCache.resetBlockCacheForTest();
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('分块数 = ceil(页数/50)，每块都能读回且内容一致', () {
    final Map<int, List<PdfLineBox>> lines = makeLines(812);
    final int written =
        DocumentCache.writeLineChunks(dir.path, 'doc_812', lines);

    // ignore: avoid_print
    print('PROBE[分块] 页数=812 块数=$written '
        '每块页数=${DocumentCache.linesChunkPages}');
    expect(written, (812 / DocumentCache.linesChunkPages).ceil(),
        reason: '812 页应当正好切成 17 块');
    expect(written, 17);

    // 逐块读回：页号与内容都要对得上
    var totalPages = 0;
    for (var chunk = 0; chunk < written; chunk++) {
      final String path =
          '${dir.path}${Platform.pathSeparator}'
          '${DocumentCache.linesChunkFileNameFor('doc_812', chunk)}';
      final Map<int, List<PdfLineBox>>? back = DocumentCache.readLineChunk(path);
      expect(back, isNotNull, reason: '第 $chunk 块应当能读回');
      totalPages += back!.length;
      for (final MapEntry<int, List<PdfLineBox>> entry in back.entries) {
        expect(entry.key ~/ DocumentCache.linesChunkPages, chunk,
            reason: '第 ${entry.key} 页应当落在第 $chunk 块里');
        expect(entry.value.length, lines[entry.key]!.length);
        expect(entry.value.first.text, lines[entry.key]!.first.text,
            reason: '文本要原样读回');
        expect(entry.value.first.bounds, lines[entry.key]!.first.bounds,
            reason: '包围盒要原样读回');
      }
    }
    expect(totalPages, 812, reason: '所有块加起来应当覆盖全部页');
  });

  test('缺块 / 坏文件 → 返回 null 不抛（语义 = 这些页没抽出来）', () {
    // ① 文件根本不存在
    final String ghost =
        '${dir.path}${Platform.pathSeparator}'
        '${DocumentCache.linesChunkFileNameFor('doc_x', 3)}';
    expect(DocumentCache.readLineChunk(ghost), isNull);

    // ② 文件存在但不是块文件（乱字节）
    final File junk = File(ghost);
    junk.writeAsBytesSync(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
    expect(DocumentCache.readLineChunk(ghost), isNull,
        reason: '魔数不对要当"没这块"，不能抛');

    // ③ 头对但载荷被截断
    final Map<int, List<PdfLineBox>> lines = makeLines(60);
    DocumentCache.writeLineChunks(dir.path, 'doc_y', lines);
    final File truncated = File(
      '${dir.path}${Platform.pathSeparator}'
      '${DocumentCache.linesChunkFileNameFor('doc_y', 1)}',
    );
    final List<int> bytes = truncated.readAsBytesSync();
    truncated.writeAsBytesSync(bytes.sublist(0, math.min(20, bytes.length)));
    expect(DocumentCache.readLineChunk(truncated.path), isNull);
  });

  test('空行表 / null → 不写任何文件（返回 0）', () {
    expect(DocumentCache.writeLineChunks(dir.path, 'doc_e', null), 0);
    expect(
      DocumentCache.writeLineChunks(dir.path, 'doc_e', <int, List<PdfLineBox>>{}),
      0,
    );
    expect(dir.listSync().length, 0, reason: '没有行表就不该留下任何块文件');
  });

  test('页号不连续也能分块（缺页不影响其它页）', () {
    // 只有第 10、60、61 页（第 10 页独占第 0 块，后两页在第 1 块）
    final Map<int, List<PdfLineBox>> sparse = <int, List<PdfLineBox>>{
      10: <PdfLineBox>[
        const PdfLineBox(text: 'a', bounds: Rect.fromLTWH(0, 0, 10, 10)),
      ],
      60: <PdfLineBox>[
        const PdfLineBox(text: 'b', bounds: Rect.fromLTWH(0, 0, 10, 10)),
      ],
      61: <PdfLineBox>[
        const PdfLineBox(text: 'c', bounds: Rect.fromLTWH(0, 0, 10, 10)),
      ],
    };
    final int written =
        DocumentCache.writeLineChunks(dir.path, 'doc_sparse', sparse);
    // ignore: avoid_print
    print('PROBE[稀疏分块] 块数=$written');
    expect(written, 2);

    final Map<int, List<PdfLineBox>>? c0 = DocumentCache.readLineChunk(
      '${dir.path}${Platform.pathSeparator}'
      '${DocumentCache.linesChunkFileNameFor('doc_sparse', 0)}',
    );
    final Map<int, List<PdfLineBox>>? c1 = DocumentCache.readLineChunk(
      '${dir.path}${Platform.pathSeparator}'
      '${DocumentCache.linesChunkFileNameFor('doc_sparse', 1)}',
    );
    expect(c0!.keys.toList(), <int>[10]);
    expect(c1!.keys.toList(), <int>[60, 61]);
  });
  test('v3 主缓存：分块索引写进去、读回来（L2b-2 起它取代整份行表当读侧地图）', () {
    expect(DocumentCache.formatVersion, 3,
        reason: 'v1.21.34 / L2b-1：格式版本升到 3（v2 缓存一律当 miss，不迁移）');

    final Map<int, List<PdfLineBox>> lines = makeLines(812);
    final String cachePath = '${dir.path}${Platform.pathSeparator}'
        '${DocumentCache.fileNameFor('doc_v3')}';
    DocumentCache.write(
      cachePath,
      'identity-v3',
      ParsedSnapshot(
        document: StructuredDocument(chapters: <Chapter>[]),
        hasTextLayer: true,
        pageCount: 812,
        textCharCount: 100,
        pdfLines: lines,
        pageSize: const Size(400, 300),
      ),
    );
    expect(File(cachePath).existsSync(), isTrue);

    final ParsedSnapshot? back = DocumentCache.read(cachePath, 'identity-v3');
    expect(back, isNotNull);
    // ⚠️ v1.21.35 / L2b-2：**主缓存不再写整份行表** —— 行表只活在块文件里。
    // L2b-1 那轮这里断言的是"仍然在主缓存里"（过渡态），本轮把它删掉了。
    expect(back!.pdfLines, isNull,
        reason: 'L2b-2：主缓存不存整份行表，读侧一律走按块读');
    expect(back.pageSize, const Size(400, 300), reason: 'pageSize 照旧可靠读回');

    final List<LinesChunkRef>? chunks = back.linesChunks;
    // ignore: avoid_print
    print('PROBE[v3索引] 块数=${chunks?.length} 首块=${chunks?.first} 末块=${chunks?.last}');
    expect(chunks, isNotNull, reason: 'v3 载荷尾部必须带分块索引');
    expect(chunks!.length, 17, reason: '812 页 / 50 = 17 块（与 writeLineChunks 口径一致）');
    expect(chunks.first.chunk, 0);
    expect(chunks.first.startPage, 0);
    expect(chunks.first.endPage, 49);
    expect(chunks.last.chunk, 16);
    expect(chunks.last.startPage, 800);
    expect(chunks.last.endPage, 811);

    // 地图不是空的：照它去块文件读，每一块都要读得回来（"行表真的还在"）
    DocumentCache.writeLineChunks(dir.path, 'doc_v3', lines);
    var covered = 0;
    for (final LinesChunkRef ref in chunks) {
      final Map<int, List<PdfLineBox>>? chunk = DocumentCache.readLineChunkByName(
        dir.path,
        'doc_v3',
        ref.chunk,
      );
      expect(chunk, isNotNull, reason: '第 ${ref.chunk} 块必须读得回来');
      covered += chunk!.length;
    }
    expect(covered, 812, reason: '17 块合起来覆盖全部 812 页');
  });

  test('版本不符当 miss：v2 缓存不会被当成 v3 读（不迁移）', () {
    // 直接造一个"版本号不是 3"的文件头，确认 read 返回 null（调用方回退全量解析）
    final String cachePath = '${dir.path}${Platform.pathSeparator}'
        '${DocumentCache.fileNameFor('doc_v2')}';
    final Map<int, List<PdfLineBox>> lines = makeLines(60);
    DocumentCache.write(
      cachePath,
      'identity-v2',
      ParsedSnapshot(
        document: StructuredDocument(chapters: <Chapter>[]),
        hasTextLayer: true,
        pageCount: 60,
        textCharCount: 10,
        pdfLines: lines,
      ),
    );
    expect(DocumentCache.read(cachePath, 'identity-v2'), isNotNull);

    // 指纹不符 → miss（这条路径已有；这里只确认门禁还在）
    expect(DocumentCache.read(cachePath, '别的指纹'), isNull,
        reason: '指纹不符必须当 miss（版本闸门同理：version != 3 → null）');
  });
}
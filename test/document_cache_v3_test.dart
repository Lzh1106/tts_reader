import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/pdf_line_box.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/document_cache.dart';
import 'package:tts_reader/services/storage_service.dart';

/// **L2b-2 探针**（v1.21.35）：主缓存不再写整份行表，读路径改走「按块读」。
///
/// 这一份用例是**先写后接**的：步骤 1 它必须红（红的理由是"读路径还没接上"），
/// 步骤 2~4 把块读缓存 / 读路径 / 阅读页接好之后它才绿。
///
/// 守三条不变量：
/// 1. **主缓存里没有整份行表**（`pdfLines` 读回 null），但 `pageSize` 与
///    「分块索引」必须在 —— 否则命中缓存时页面尺寸拿不到，点句 / 跳页全废；
/// 2. **块读是"读盘才记账"**：同一块连读两次只碰一次盘，读盘字节数可被断言；
///    块读缓存**按字节数**设上限（约 2MB），溢出淘汰最旧的那块；
/// 3. **切文本模式 = 读满全部块**（不再重跑 `_parse()`），且内存增量不超预算。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<int, List<PdfLineBox>> makeLines(int pageCount) {
    return <int, List<PdfLineBox>>{
      for (var page = 0; page < pageCount; page++)
        page: <PdfLineBox>[
          PdfLineBox(
            text: '第 $page 页第一行',
            bounds: Rect.fromLTWH(0, page * 20.0, 200, 14),
          ),
        ],
    };
  }

  group('主缓存 v3：不再写整份行表', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('cache_v3');
      DocumentCache.resetBlockCacheForTest();
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('v3 载荷里没有整份行表：pdfLines=null，但 pageSize 与分块索引都在', () {
      final String cachePath = '${dir.path}${Platform.pathSeparator}'
          '${DocumentCache.fileNameFor('doc_v3b2')}';
      final Map<int, List<PdfLineBox>> lines = makeLines(812);
      DocumentCache.write(
        cachePath,
        'identity-v3b2',
        ParsedSnapshot(
          document: StructuredDocument(chapters: <Chapter>[]),
          hasTextLayer: true,
          pageCount: 812,
          textCharCount: 100,
          pdfLines: lines,
          pageSize: const Size(400, 300),
        ),
      );

      final ParsedSnapshot? back = DocumentCache.read(cachePath, 'identity-v3b2');
      expect(back, isNotNull);
      // ignore: avoid_print
      print('PROBE[v3-b2] pdfLines=${back!.pdfLines?.length} '
          'pageSize=${back.pageSize} 块数=${back.linesChunks?.length}');

      expect(back.pdfLines, isNull,
          reason: 'L2b-2：主缓存**不再**存整份行表（这是本轮的核心改动）');
      expect(back.pageSize, const Size(400, 300),
          reason: 'pageSize 是缓存的"必需元数据"，绝不能跟着行表一起丢');
      expect(back.linesChunks?.length, 17, reason: '分块索引必须留着当读取地图');
    });
  });

  group('块读缓存：按字节兜底 + 记账', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('cache_blk');
      DocumentCache.resetBlockCacheForTest();
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('同一块连读两次只碰一次盘；读盘次数 / 字节数可断言', () {
      DocumentCache.writeLineChunks(dir.path, 'doc_blk', makeLines(60));

      final Map<int, List<PdfLineBox>>? c0 = DocumentCache.readLineChunkByName(
          dir.path, 'doc_blk', 0);
      expect(c0, isNotNull);
      expect(c0!.length, 50, reason: '第 0 块覆盖 0..49 共 50 页');
      final int readsAfterFirst = DocumentCache.blockReadCount;
      final int bytesAfterFirst = DocumentCache.blockReadBytes;
      expect(readsAfterFirst, 1, reason: '第一次读块必然碰盘');
      expect(bytesAfterFirst, greaterThan(0), reason: '要记下读了多少字节');

      final Map<int, List<PdfLineBox>>? again = DocumentCache.readLineChunkByName(
          dir.path, 'doc_blk', 0);
      expect(again, isNotNull);
      // ignore: avoid_print
      print('PROBE[块读账] 读盘次数=$readsAfterFirst 字节=$bytesAfterFirst '
          '二次读后次数=${DocumentCache.blockReadCount}');
      expect(DocumentCache.blockReadCount, readsAfterFirst,
          reason: '同一块第二次读必须命中块读缓存，不再读盘（翻页手感靠它）');
      expect(DocumentCache.blockReadBytes, bytesAfterFirst);
    });

    test('上限按字节：预算内留住、超预算淘汰最旧（不是按块数）', () {
      expect(DocumentCache.maxChunkCacheBytes, 2 * 1024 * 1024,
          reason: '按字节兜底 ≈2MB，不按块数 —— 注释密集的块可能翻倍');

      // 每块 50 页 × 每页 40 行，单块约 60KB 量级：连读多块必然越过 2MB
      final Map<int, List<PdfLineBox>> fat = <int, List<PdfLineBox>>{
        for (var page = 0; page < 50 * 40; page++)
          page: <PdfLineBox>[
            for (var i = 0; i < 40; i++)
              PdfLineBox(
                text: '注释密集的一行文字 $page-$i',
                bounds: Rect.fromLTWH(0, i * 14.0, 200, 12),
              ),
          ],
      };
      DocumentCache.writeLineChunks(dir.path, 'doc_big', fat);

      var guard = 0;
      for (var chunk = 0; chunk < 40; chunk++) {
        DocumentCache.readLineChunkByName(dir.path, 'doc_big', chunk);
        guard++;
      }
      final int cachedBytes = DocumentCache.blockCacheBytesForTest;
      // ignore: avoid_print
      print('PROBE[块读预算] 读了 $guard 块 缓存占用=$cachedBytes 字节 '
          '上限=${DocumentCache.maxChunkCacheBytes}');
      expect(cachedBytes, lessThanOrEqualTo(DocumentCache.maxChunkCacheBytes),
          reason: '块读缓存占用的字节数不得超过上限');
      // 超预算后必须真的淘汰过（否则上限形同虚设）
      final Map<int, List<PdfLineBox>>? oldest =
          DocumentCache.readLineChunkByName(dir.path, 'doc_big', 0);
      expect(oldest, isNotNull);
      expect(DocumentCache.blockReadCount, greaterThan(guard),
          reason: '最早的块应当已被淘汰 → 再读它必须重新碰盘');
    });

    test('缺块 / 坏块 → null（语义不变）', () {
      expect(DocumentCache.readLineChunkByName(dir.path, 'doc_none', 3), isNull);
      final File junk = File(
        '${dir.path}${Platform.pathSeparator}'
        '${DocumentCache.linesChunkFileNameFor('doc_none', 3)}',
      );
      junk.writeAsBytesSync(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
      expect(DocumentCache.readLineChunkByName(dir.path, 'doc_none', 3), isNull);
    });
  });

  group('阅读页：按块读 + 文本模式读满全部块', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      StorageService.instance.resetForTest();
      DocumentCache.resetBlockCacheForTest();
    });

    /// 造一份 100 页的合成行表 + 一个"真的按 50 页一块"返回的注入读取器
    ///
    /// 返回的块**必须完整**（按块契约：一块就是那 50 页）——
    /// 缺页会被阅读页当成"这些页没抽出来"，那不是本轮要验的东西。
    /// ⚠️ 调用顺序：**先** `debugSeedPdfLines`（它会把读取器复位），**再** [install]。
    ({Map<int, List<PdfLineBox>> table, int Function() reads}) install(
      dynamic state,
    ) {
      final Map<int, List<PdfLineBox>> table = makeLines(100);
      var reads = 0;
      state.debugSetCacheDirForTest('injected_cache_dir');
      state.debugSetChunkReaderForTest(
        (String cacheDir, String docId, int chunk) {
          reads++;
          if (cacheDir.isEmpty) return null;
          return <int, List<PdfLineBox>>{
            for (int page = chunk * 50; page < (chunk + 1) * 50; page++)
              page: table[page]!,
          };
        },
      );
      return (table: table, reads: () => reads);
    }

    List<LinesChunkRef> twoChunks() => <LinesChunkRef>[
          const LinesChunkRef(chunk: 0, startPage: 0, endPage: 49),
          const LinesChunkRef(chunk: 1, startPage: 50, endPage: 99),
        ];

    testWidgets('原版式只装当前页所在块；翻到下一块才读第二次盘', (tester) async {
      final Document document = Document(
        id: 'l2b2_chunk_read',
        title: 'L2b-2 按块读',
        path: 'test_assets/abc.pdf',
        type: DocumentType.pdf,
        importedAt: DateTime(2024),
      );
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.pump();
      final dynamic state = tester.state(find.byType(ReaderPage));

      // ⚠️ 顺序要紧：`debugSeedPdfLines` 会把块读取器复位（合成数据只在内存里），
      // 所以"先塞当前页 → 再注入读取器 → 最后给读取地图"。
      final Map<int, List<PdfLineBox>> table = makeLines(100);
      state.debugSeedPdfLines(<int, List<PdfLineBox>>{0: table[0]!});
      final ({Map<int, List<PdfLineBox>> table, int Function() reads}) fake =
          install(state);
      state.debugSetLinesChunksForTest(twoChunks());
      await tester.pump();

      // ① 翻到第 30 页：同在第 0 块 → 读一次盘（整块装进来）
      state.debugTrimPdfLinesForTest(30);
      await tester.pump();
      final int readsAfterSameChunk = fake.reads();
      final int pagesSameChunk = state.debugPdfLinesPageCount as int;
      // ② 翻到第 70 页：跨到第 1 块 → 必须再读一次盘
      state.debugTrimPdfLinesForTest(70);
      await tester.pump();
      final int readsAfterCrossChunk = fake.reads();

      // ignore: avoid_print
      print('PROBE[翻页读盘账] 同块后读盘=$readsAfterSameChunk 窗口页数=$pagesSameChunk '
          '峰值装页=${state.debugPdfLinesLoadedPeak} '
          '跨块后读盘=$readsAfterCrossChunk '
          '第70页有行表=${(state.debugPdfLinesAt(69) as List<dynamic>?)?.isNotEmpty}');

      expect(readsAfterSameChunk, 1,
          reason: '翻到同在第 0 块的页只需读一次盘（块读缓存不重复读）');
      expect(state.debugPdfLinesLoadedPeak as int, greaterThanOrEqualTo(50),
          reason: '一次读盘装进整块 50 页 —— 之后同块内翻页不再读盘');
      expect(state.debugPdfLinesLoadedPeak as int, lessThan(100),
          reason: '峰值不许是整份 100 页：装完就按窗口裁，内存只留这一小把');
      expect(pagesSameChunk, lessThanOrEqualTo(16),
          reason: '装完按窗口裁（当前页 ±3 ∪ 朗读页 ±3），内存只留这一小把');
      expect(pagesSameChunk, greaterThanOrEqualTo(8),
          reason: '窗口保底 ≥8 页（低于它点句会频繁重抽，与 v1.21.31 同一条纪律）');
      expect(readsAfterCrossChunk, 2,
          reason: '跨块翻页才是新成本来源：第 1 块必须读第二次盘');
      expect(state.debugPdfLinesAt(69), isNotNull,
          reason: '跨块后那一页的行表要真的能用（点句即读的前提）');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('切文本模式不再重跑 _parse：改为读满全部块 + 内存增量有账', (tester) async {
      final Document document = Document(
        id: 'l2b2_text_mode',
        title: 'L2b-2 文本模式',
        path: 'test_assets/abc.pdf',
        type: DocumentType.pdf,
        importedAt: DateTime(2024),
      );
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.pump();
      final dynamic state = tester.state(find.byType(ReaderPage));

      // 等价于"解析结果只塞进当前页"（顺序同上一个用例：先塞页、再注入）
      final Map<int, List<PdfLineBox>> table = makeLines(100);
      state.debugSeedPdfLines(<int, List<PdfLineBox>>{0: table[0]!});
      final ({Map<int, List<PdfLineBox>> table, int Function() reads}) fake =
          install(state);
      state.debugSetLinesChunksForTest(twoChunks());
      await tester.pump();

      expect(state.debugPdfLinesPageCount as int, 1,
          reason: '原版式只装"当前页所在块"，注入后手上只有第 0 页');

      final int rssBefore = ProcessInfo.currentRss;
      final int readsBefore = fake.reads();
      final int parseBefore = state.debugParseForTestCount as int;
      state.debugSwitchToTextModeForTest();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final int rssAfter = ProcessInfo.currentRss;
      final int reads = fake.reads() - readsBefore;
      final double deltaMb = (rssAfter - rssBefore) / (1024 * 1024);

      // ignore: avoid_print
      print('PROBE[文本模式-块读] 覆盖页数=${state.debugPdfLinesPageCount} '
          '读块次数=$reads '
          'RSS ${(rssBefore / 1048576).toStringAsFixed(1)}MB → '
          '${(rssAfter / 1048576).toStringAsFixed(1)}MB '
          '（Δ${deltaMb.toStringAsFixed(1)}MB）');

      expect(state.debugPdfLinesPageCount as int, 100,
          reason: '100 页 / 50 页一块 = 2 块，文本模式必须把整份读满（排版遍历全部页）');
      expect(reads, 2, reason: '100 页 = 2 块，正好读 2 块');
      expect(state.debugParseForTestCount as int, parseBefore,
          reason: 'L2b-2 起不再靠重跑 _parse 补表，改为顺序读全部块');
      expect(deltaMb, lessThan(60),
          reason: '内存增量超过 60MB 是硬停条件（改流式排版，不是放宽判据）');

      // ③ 退出文本模式要释放回窗口（否则切一次就永久多背一整份行表）
      state.debugTogglePdfModeForTest();
      await tester.pump();
      final int afterExit = state.debugPdfLinesPageCount as int;
      // ignore: avoid_print
      print('PROBE[退出释放] 切回原版式后覆盖页数=$afterExit');
      expect(afterExit, lessThan(100),
          reason: '退出文本模式必须把整份行表释放回窗口（内存闭环）');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
    });
  });
}

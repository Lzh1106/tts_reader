import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/pdf_line_box.dart';
import 'package:tts_reader/services/document_cache.dart';
import 'package:tts_reader/services/document_service.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 剖析：真实 318 页 PDF 的解析各阶段耗时 + 缓存读回耗时 + L2b-2 的翻页读盘账；
/// 另含大 PDF（812 页）打开速度与文本模式整份行表的内存估算。
/// 用来定位「PDF 加载慢」到底慢在哪一段，并守住 L2b-2 的三笔账。
void main() {
  const pdfPath = 'test_assets/abc.pdf';

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
  });

  test('首次解析：分段耗时', () async {
    final dir = Directory.systemTemp.createTempSync('pdf_perf');
    final document = Document(
      id: 'perf_pdf',
      title: 'perf',
      path: File(pdfPath).absolute.path,
      type: DocumentType.pdf,
      importedAt: DateTime(2024),
    );
    // 第一次：无缓存
    final t0 = DateTime.now();
    final first = await DocumentService.parse(document, cacheDir: dir.path);
    final cold = DateTime.now().difference(t0).inMilliseconds;
    // ⚠️ v1.21.35 / L2b-2：冷启动之后主缓存里**不再有整份行表**，
    // 只有"读取地图"（分块索引）—— 所以行页数要在这一步先记下来。
    final int coldLinePages = first.pdfLines?.length ?? 0;
    final int chunks = first.linesChunks?.length ?? 0;

    // 第二次：命中缓存
    final t1 = DateTime.now();
    final second = await DocumentService.parse(document, cacheDir: dir.path);
    final warm = DateTime.now().difference(t1).inMilliseconds;

    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-perf] 冷=${cold}ms 热=${warm}ms '
        'fromCache=${second.fromCache} '
        '段=${first.document.paragraphCount} 行=$coldLinePages 块=$chunks '
        '命中缓存行=${second.pdfLines?.length ?? 0}');
    expect(first.document.chapters, isNotEmpty);
    // 防退化：并行抽取若失效会掉回 4.5s 量级。阈值放到 8 秒是因为整套用例
    // 一起跑时 CPU 被别的用例占着，会明显更慢（单跑约 2.9 秒）。
    expect(cold, lessThan(8000), reason: '冷启动解析不该慢于 8 秒（单跑实测约 2.9 秒）');
    expect(warm, lessThan(1000), reason: '命中缓存应当是毫秒级');
    expect(second.fromCache, isTrue, reason: '第二次应当命中缓存');

    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// **翻页读盘账**（v1.21.35 / L2b-2 的新成本来源）
  ///
  /// L2a 那轮没有这笔账：整份行表在主缓存里，翻页不读盘。
  /// L2b-2 把行表挪到块文件后，**跨块翻页才读盘** ——
  /// 这份用例把"模拟翻 300 页"的读盘次数与字节数记下来。
  test('翻页读盘账：块读缓存命中不读盘，跨块才读（真实 319 页 PDF）', () async {
    final dir = Directory.systemTemp.createTempSync('pdf_turn');
    final document = Document(
      id: 'perf_turn',
      title: 'perf-turn',
      path: File(pdfPath).absolute.path,
      type: DocumentType.pdf,
      importedAt: DateTime(2024),
    );
    final first = await DocumentService.parse(document, cacheDir: dir.path);
    final int totalPages = first.pdfLines?.length ?? 0;
    final int chunkCount = first.linesChunks?.length ?? 0;
    expect(totalPages, greaterThan(0), reason: '真解析应当带出整份行表');

    // 第二次：命中缓存 → 主缓存里**没有**行表了，只剩读取地图
    final second = await DocumentService.parse(document, cacheDir: dir.path);
    expect(second.fromCache, isTrue);
    expect(second.pdfLines, isNull, reason: 'L2b-2：命中缓存时主缓存不提供行表');
    expect(second.linesChunks?.length, chunkCount,
        reason: '读取地图要在（它是读取侧唯一的路标）');

    final List<File> files = dir
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith(DocumentCache.linesExtension))
        .toList();
    // ignore: avoid_print
    print('DEVICE_VERIFY[翻页账] 行页数=$totalPages 块数=$chunkCount '
        '块文件数=${files.length} '
        '首块=${files.isEmpty ? 0 : (files.first.lengthSync() / 1024).round()}KB');

    DocumentCache.resetBlockCacheForTest();
    // 模拟逐页往下翻：同块内翻页不该读盘，跨块才读（阅读页走的就是这条路径）
    var cacheHitPageTurns = 0;
    var diskReadPageTurns = 0;
    for (var page = 0; page < 300 && page < totalPages; page++) {
      final int chunk = page ~/ DocumentCache.linesChunkPages;
      final int before = DocumentCache.blockReadCount;
      final Map<int, List<PdfLineBox>>? loaded =
          DocumentCache.readLineChunkByName(dir.path, document.id, chunk);
      expect(loaded, isNotNull, reason: '块文件应当读得回来（第 $chunk 块）');
      if (DocumentCache.blockReadCount - before == 0) {
        cacheHitPageTurns++;
      } else {
        diskReadPageTurns++;
      }
    }
    // ignore: avoid_print
    print('DEVICE_VERIFY[翻页账] 模拟翻 300 页：命中缓存=$cacheHitPageTurns 次 '
        '读盘=$diskReadPageTurns 次 读盘字节=${DocumentCache.blockReadBytes} '
        '块读缓存占用=${DocumentCache.blockCacheBytesForTest}B '
        '上限=${DocumentCache.maxChunkCacheBytes}B');

    expect(files.length, chunkCount,
        reason: '有多少块就该有多少个 .ttsl（生产者是 writeLineChunks）');
    expect(cacheHitPageTurns, greaterThan(250),
        reason: '绝大多数翻页应当命中块读缓存（同块内不重复读同一个文件）');
    expect(diskReadPageTurns, lessThanOrEqualTo(6),
        reason: '300 页 / 50 页一块 = 6 次跨块，读盘次数不该更多');
    expect(DocumentCache.blockCacheBytesForTest,
        lessThanOrEqualTo(DocumentCache.maxChunkCacheBytes),
        reason: '块读缓存不得越过字节上限');

    // ---------------- 文本模式：整份行表读回来的**内存占用** ----------------
    //
    // 文本模式要把整份行表读回内存（排版要遍历全部页），这是本轮唯一"内存会涨"的时刻。
    //
    // ⚠️ **不要用 `ProcessInfo.currentRss` 量这个**（实测过，白费功夫）：
    //   同一份 809 页数据读回来，前后差 **-0.4MB**、`maxRss` 全程不动 ——
    //   测试宿主堆基线 200MB+，这点分配抬不动水位，抖动（±10MB）比信号大。
    // 改成**按真实数据逐项估算对象占用**（可复现、不依赖 GC 时机）：
    //   PdfLineBox 32B + Rect 48B + String 头 32B + 文本（中文 2B/字符）+ List 引用 8B
    DocumentCache.resetBlockCacheForTest();
    final Map<int, List<PdfLineBox>> all = <int, List<PdfLineBox>>{};
    for (final LinesChunkRef ref in second.linesChunks!) {
      final Map<int, List<PdfLineBox>>? chunk =
          DocumentCache.readLineChunkByName(dir.path, document.id, ref.chunk);
      if (chunk != null) all.addAll(chunk);
    }
    var lines = 0;
    var textBytes = 0;
    for (final List<PdfLineBox> page in all.values) {
      for (final PdfLineBox box in page) {
        lines++;
        final bool wide = box.text.runes.any((int r) => r > 0xFF);
        textBytes += wide ? box.text.length * 2 : box.text.length;
      }
    }
    final int estimateBytes = lines * (32 + 48 + 32 + 8) + textBytes + all.length * 80;
    final double estimateMb = estimateBytes / 1048576;
    // ignore: avoid_print
    print('DEVICE_VERIFY[文本模式内存] 读回页=${all.length} 行=$lines '
        '文本字节=$textBytes 估算对象占用=${estimateMb.toStringAsFixed(1)}MB '
        '（阈值 60MB）');

    expect(all.length, totalPages, reason: '文本模式必须把整份行表读满（排版遍历全部页）');
    expect(estimateMb, lessThan(60),
        reason: '整份行表的对象占用超过 60MB 是硬停条件（改流式排版，不是放宽判据）');

    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 大 PDF：打开速度（L2b-2 的验收项之一）
  ///
  /// 用工作区里那份 17.5MB / 812 页的书 —— 正是"主缓存不再背整份行表"要改善的场景。
  /// 没有那份文件就跳过（别人的机器上不一定有）。
  test('大 PDF（17.5MB / 812 页）：冷启动 vs 命中缓存', () async {
    final Directory media = Directory(Platform.environment['PDF_PERF_SAMPLE'] ?? 'test_assets');
    if (!media.existsSync()) {
      // ignore: avoid_print
      print('DEVICE_VERIFY[大PDF] 没有那份大 PDF，跳过');
      return;
    }
    final List<File> candidates = media
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.toLowerCase().endsWith('.pdf'))
        .toList()
      ..sort((File a, File b) => b.lengthSync().compareTo(a.lengthSync()));
    if (candidates.isEmpty) {
      // ignore: avoid_print
      print('DEVICE_VERIFY[大PDF] 没有那份大 PDF，跳过');
      return;
    }
    final File pdf = candidates.first;

    final Directory dir = Directory.systemTemp.createTempSync('big_pdf');
    final Document document = Document(
      id: 'big_pdf_perf',
      title: 'big',
      path: pdf.path,
      type: DocumentType.pdf,
      importedAt: DateTime(2024),
    );

    final DateTime t0 = DateTime.now();
    final ParseResult cold = await DocumentService.parse(document, cacheDir: dir.path);
    final int coldMs = DateTime.now().difference(t0).inMilliseconds;

    final DateTime t1 = DateTime.now();
    final ParseResult warm = await DocumentService.parse(document, cacheDir: dir.path);
    final int warmMs = DateTime.now().difference(t1).inMilliseconds;

    final File mainCache = File(
      '${dir.path}${Platform.pathSeparator}${DocumentCache.fileNameFor(document.id)}',
    );
    final List<File> chunkFiles = dir
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith(DocumentCache.linesExtension))
        .toList();
    // ignore: avoid_print
    print('DEVICE_VERIFY[大PDF-速度] 体积=${(pdf.lengthSync() / 1048576).toStringAsFixed(1)}MB '
        '冷=${coldMs}ms 热=${warmMs}ms 页=${cold.document.chapters.length} '
        '块=${cold.linesChunks?.length} 主缓存='
        '${(mainCache.lengthSync() / 1048576).toStringAsFixed(2)}MB');

    expect(cold.document.chapters, isNotEmpty);
    expect(warm.fromCache, isTrue, reason: '第二次必须命中缓存');
    expect(warmMs, lessThan(coldMs), reason: '热启动应当明显快于冷启动');
    expect(warm.pdfLines, isNull, reason: 'L2b-2：命中缓存时不给整份行表');
    expect(warm.pageSize, isNotNull, reason: 'pageSize 必须能读回（点句 / 跳页要用）');
    expect(chunkFiles.length, cold.linesChunks?.length,
        reason: '每块一个 .ttsl 文件');

    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }, timeout: const Timeout(Duration(minutes: 10)));
}

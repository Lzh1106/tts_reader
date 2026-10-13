import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/pdf_line_box.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/document_cache.dart';
import 'package:tts_reader/services/storage_service.dart';

/// **原版式只装一小把行表 → 切文本模式必须把整份补回来**。
///
/// v1.21.32 起守的是这条不变量；**v1.21.35 / L2b-2 换了补法**：
/// - 旧：发现"裁过"就重跑 `_parse()`，借 `DocumentCache` 里那份整份行表读回；
/// - 新：数据源是分块文件 `<docId>.lines.<n>.ttsl` —— 按**读取地图**顺序读完全部块。
///
/// 所以断言也换了语义：从"`_parse()` 计数 +1"改成"**读满地图里声明的每一块**"，
/// 并且**不再允许**靠重跑解析来补（`_parse()` 计数必须原地不动）。
/// 与此同时 `_pdfLinesTrimmed` / `debugPdfLinesTrimmed` 这对粘性标记被删除 ——
/// 分块读入的模型下"表完整吗"要用**派生判据**（装了多少页）而不是粘性布尔。
///
/// ⚠️ 单测环境拿不到 path_provider 的缓存目录，真块文件读不出来 ——
/// 所以用**注入块读取器**的方式验"读了几块"这条不变量。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    DocumentCache.resetBlockCacheForTest();
  });

  /// 40 页合成行表 + 注入读取器（40 页都落在第 0 块）+ 读取地图
  ({Map<int, List<PdfLineBox>> table, int Function() reads}) install(dynamic state) {
    final Map<int, List<PdfLineBox>> table = <int, List<PdfLineBox>>{
      for (var page = 0; page < 40; page++)
        page: <PdfLineBox>[
          PdfLineBox(
            text: '第 $page 页第一行',
            bounds: Rect.fromLTWH(0, page * 20.0, 200, 14),
          ),
        ],
    };
    var reads = 0;
    state.debugSetCacheDirForTest('injected_cache_dir');
    state.debugSetChunkReaderForTest((String dir, String docId, int chunk) {
      reads++;
      if (dir.isEmpty) return null;
      if (chunk != 0) return null;
      return table;
    });
    return (table: table, reads: () => reads);
  }

  testWidgets('原版式翻页后切文本模式：读满全部块补回整份（不再重跑 _parse）', (tester) async {
    final Document document = Document(
      id: 'trim_restore_pdf',
      title: '裁剪补回用例',
      path: 'test_assets/abc.pdf',
      type: DocumentType.pdf,
      importedAt: DateTime(2024),
    );
    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
    await tester.pump();

    // ⚠️ 阅读页的 State 是私有的（`_ReaderPageState`）→ 用 dynamic 走测试钩子
    final dynamic state = tester.state(find.byType(ReaderPage));

    // 等价于"解析结果只塞进第 0 页"（解析后不会再留整份行表）
    final Map<int, List<PdfLineBox>> seed = <int, List<PdfLineBox>>{
      0: <PdfLineBox>[
        const PdfLineBox(text: '第 0 页第一行', bounds: Rect.fromLTWH(0, 0, 200, 14)),
      ],
    };
    state.debugSeedPdfLines(seed);
    final ({Map<int, List<PdfLineBox>> table, int Function() reads}) fake =
        install(state);
    state.debugSetLinesChunksForTest(<LinesChunkRef>[
      const LinesChunkRef(chunk: 0, startPage: 0, endPage: 39),
    ]);
    await tester.pump();

    final int readsBefore = fake.reads();
    final int parseBefore = state.debugParseForTestCount as int;
    // 切文本模式 → 必须读满地图里声明的块，把整份行表补回来
    state.debugSwitchToTextModeForTest();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final int pages = state.debugPdfLinesPageCount as int;
    final int reads = fake.reads() - readsBefore;
    // ignore: avoid_print
    print('PROBE[裁补-新] 切文本模式：读块次数=$reads 覆盖页数=$pages '
        '峰值装页=${state.debugPdfLinesLoadedPeak} '
        '_parse 计数 $parseBefore → ${state.debugParseForTestCount}');

    expect(reads, 1, reason: '读取地图声明了 1 块 → 必须读它（真机上是 17 块）');
    expect(pages, 40,
        reason: '补回来的必须是**整份** 40 页 —— 否则自动排版只排得出那一小块，'
            '用户看到残缺排版');
    expect(state.debugParseForTestCount as int, parseBefore,
        reason: 'L2b-2 起不再靠重跑 _parse 补表；真重跑了说明读路径没接上');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('没缺少行表时切文本模式：仍然只读地图里的块，不做多余动作', (tester) async {
    final Document document = Document(
      id: 'trim_restore_pdf2',
      title: '不裁不重解',
      path: 'test_assets/abc.pdf',
      type: DocumentType.pdf,
      importedAt: DateTime(2024),
    );
    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
    await tester.pump();
    final dynamic state = tester.state(find.byType(ReaderPage));

    // 第 0 页在手上 + 地图只有第 0 块：切文本模式应当**一次都不读盘**
    state.debugSeedPdfLines(<int, List<PdfLineBox>>{
      0: <PdfLineBox>[
        const PdfLineBox(text: '第 0 页第一行', bounds: Rect.fromLTWH(0, 0, 200, 14)),
      ],
    });
    final ({Map<int, List<PdfLineBox>> table, int Function() reads}) fake =
        install(state);
    state.debugSetLinesChunksForTest(<LinesChunkRef>[
      const LinesChunkRef(chunk: 0, startPage: 0, endPage: 39),
    ]);
    await tester.pump();

    final int readsBefore = fake.reads();
    final int parseBefore = state.debugParseForTestCount as int;
    state.debugSwitchToTextModeForTest();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // ignore: avoid_print
    print('PROBE[裁补-对照] 读块次数=${fake.reads() - readsBefore} '
        '覆盖页数=${state.debugPdfLinesPageCount} '
        '_parse 计数保持 $parseBefore');
    expect(state.debugParseForTestCount as int, parseBefore,
        reason: '切模式不该为了补表白跑一次解析');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  });
}

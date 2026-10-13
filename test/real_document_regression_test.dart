import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/pdf_line_box.dart';
import 'package:tts_reader/models/reader_style.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/document_cache.dart';
import 'package:tts_reader/services/document_service.dart';
import 'package:tts_reader/services/paragraph_reflow.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 假引擎：`speak` **挂着不返回**（保持「正在朗读」），推进由测试自己控制。
///
/// 为什么不用「会自动读完」的引擎：那样朗读循环会一路把整本书读完，
/// 测「连点快进」时根本来不及观察（实测 55 章在几百毫秒内就读完了）。
/// 保持「正在读一句」的状态，再由测试调用 `skipSentenceForward` 制造推进，
/// 才是可复现的连点场景。
class _HoldEngine with SyntheticTtsEngine implements TtsEngine {
  final Completer<void> _pending = Completer<void>();

  @override
  String get id => 'real-doc-hold';

  @override
  String get displayName => '假引擎（保持朗读中）';

  @override
  bool get isAvailable => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<TtsVoice>> getVoices() async => const <TtsVoice>[];

  @override
  Future<void> setVoice(String voiceId) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  Future<void> speak(String text) => _pending.future;

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async {}
}

/// 用**真实文档**跑的高频 bug 回归：
/// - `test_assets/abc.pdf`：《共产主义ABC》3.2 MB 中文 PDF（密集注释、多页）
/// - `test_assets/state.epub`：《国家与革命》EPUB
///
/// 重点盯三件事（用户反馈的高频故障）：
/// 1. 朗读推进 / 连点快进时，**高亮框不乱跳、页面不快速向后翻**；
/// 2. 「返回朗读页」能准确回到朗读位置；
/// 3. 封面：EPUB 抽自带封面，PDF / TXT 落到默认样式封面。
void main() {
  const pdfPath = 'test_assets/abc.pdf';
  const epubPath = 'test_assets/state.epub';

  /// 测试资产是否可用（相对路径依赖 cwd，跑不到就跳过相关用例）
  final assetsReady = File(pdfPath).existsSync() && File(epubPath).existsSync();
  // ignore: avoid_print
  print('DEVICE_VERIFY[assets] ready=$assetsReady '
      'pdf=${File(pdfPath).existsSync()} epub=${File(epubPath).existsSync()} '
      'cwd=${Directory.current.path}');

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    TtsManager.instance.resetSessionForTest();
  });

  tearDown(() {
    TtsManager.instance.resetSessionForTest();
  });

  group('真实 PDF（《共产主义ABC》）', () {
    test('解析出正文与文字行信息，且页面尺寸可用', () async {
      final file = File(pdfPath);
      expect(file.existsSync(), isTrue, reason: '测试资产应当存在：$pdfPath');
      final result = await DocumentService.parse(
        Document(
          id: 'abc_parse',
          title: 'abc',
          path: File(pdfPath).absolute.path,
          type: DocumentType.pdf,
          importedAt: DateTime(2024),
        ),
      );
      // ignore: avoid_print
      print('DEVICE_VERIFY[abc-parse] chapters=${result.document.chapters.length} '
          'paras=${result.document.paragraphCount} '
          'chars=${result.textCharCount} '
          'lines=${result.pdfLines?.length ?? 0} '
          'pageSize=${result.pageSize} '
          'hasTextLayer=${result.hasTextLayer}');
      expect(result.document.chapters, isNotEmpty, reason: '应当解析出章节');
      expect(result.textCharCount, greaterThan(1000), reason: '正文应当有实际内容');
      expect(result.hasTextLayer, isTrue, reason: '这是带文本层的 PDF');
    });

    test('自动排版在真实 PDF 上有确定结果（要么重排、要么判定无需重排）', () async {
      final result = await DocumentService.parse(
        Document(
          id: 'abc_parse',
          title: 'abc',
          path: File(pdfPath).absolute.path,
          type: DocumentType.pdf,
          importedAt: DateTime(2024),
        ),
      );
      // ignore: avoid_print
      print('DEVICE_VERIFY[abc-reflow] 段数=${result.document.paragraphCount} '
          '行页数=${result.pdfLines?.length ?? 0}');
      // 只要求「有明确结论」，不强制一定重排 —— 真实书的排版情况各异
      expect(result.document.paragraphCount, greaterThan(0));
    });

    test('自动排版前后：同一条位置能映射到同一句话（返回朗读位置的前提）', () async {
      final result = await DocumentService.parse(
        Document(
          id: 'abc_parse',
          title: 'abc',
          path: File(pdfPath).absolute.path,
          type: DocumentType.pdf,
          importedAt: DateTime(2024),
        ),
      );
      final original = result.document;
      final lines = result.pdfLines ?? const <int, List<PdfLineBox>>{};
      expect(lines, isNotEmpty, reason: '这份 PDF 应当有文字行信息');

      // 与阅读页同一套重排输入
      final linesByPage = <int, List<ReflowLine>>{};
      lines.forEach((page, boxes) {
        linesByPage[page] = <ReflowLine>[
          for (final box in boxes)
            ReflowLine(
              text: box.text,
              left: box.bounds.left,
              top: box.bounds.top,
              right: box.bounds.right,
              bottom: box.bounds.bottom,
            ),
        ];
      });
      final report = ParagraphReflow.analyze(original.chapters, linesByPage);
      // ignore: avoid_print
      print('DEVICE_VERIFY[abc-map] 有行信息的页=${report.pagesWithLines} '
          '重排后段数='
          '${report.chapters?.fold<int>(0, (a, c) => a + c.paragraphs.length) ?? -1} '
          '原文段数=${original.paragraphCount}');

      if (report.chapters == null) {
        // 判据认为本来就排好了：那「排版后定位」等同于不排版，映射必然一致
        return;
      }
      final reflowed = StructuredDocument(
        chapters: report.chapters!,
        chapterIsPage: original.chapterIsPage,
        outline: original.outline,
      );

      // 抽查若干位置：换成排版后必须还能定位到**同一句话**
      //
      // 断言方式与阅读页的实现对齐（`ReaderPage._remapSpot`）：
      // 优先按文字全篇定位；只有文字找不到时才退回句序号近似。
      var checked = 0;
      var mismatched = 0;
      var byText = 0;
      var byIndex = 0;
      for (final chapter in <int>[0, 5, 50, 150, 300]) {
        if (chapter >= original.chapters.length) continue;
        final paragraphs = original.chapters[chapter].paragraphs;
        if (paragraphs.isEmpty) continue;
        final p = paragraphs.length ~/ 2;
        if (paragraphs[p].sentences.isEmpty) continue;
        final before = paragraphs[p].sentences[0].text;

        final hit = reflowed.locateTextAnywhere(before, hintChapter: chapter);
        checked++;
        if (hit == null) {
          byIndex++;
          // 文字找不到（重排改写了这一句）：退回句序号近似，不算错
          continue;
        }
        byText++;
        final mappedParagraphs = reflowed.chapters[hit.$1].paragraphs;
        if (hit.$2 >= mappedParagraphs.length ||
            hit.$3 >= mappedParagraphs[hit.$2].sentences.length) {
          mismatched++;
          continue;
        }
        // 判定「落对地方」的正确标准**不是文本完全相同**：
        // 自动排版本就是把断行并回整段，重排后的一句话常常**包含**原文那句
        // （例：原文「…数字等」→ 重排后「…数字等等也用同号铅字…」）。
        // 用户要的是「重进还在同一处内容」，所以判据取：
        // 定位到的句子与原文那句**互相包含**（去空白后比较）。
        final a = StructuredDocument.squeeze(before);
        final b = StructuredDocument.squeeze(mappedParagraphs[hit.$2].sentences[hit.$3].text);
        final ok = a == b || b.contains(a) || a.contains(b);
        if (!ok) {
          mismatched++;
          if (mismatched <= 3) {
            final got = mappedParagraphs[hit.$2].sentences[hit.$3].text;
            // ignore: avoid_print
            print('DEVICE_VERIFY[abc-map-diff] ch=$chapter p=$p hit=$hit\n'
                '  原文(${before.length})「${before.length > 60 ? before.substring(0, 60) : before}」\n'
                '  定位(${got.length})「${got.length > 60 ? got.substring(0, 60) : got}」');
          }
        }
      }
      // ignore: avoid_print
      print('DEVICE_VERIFY[abc-map] checked=$checked 按文字=$byText '
          '退回句序号=$byIndex mismatched=$mismatched');
      expect(checked, greaterThan(0), reason: '至少要抽查到几个位置');
      expect(byText, greaterThan(0), reason: '大部分位置应当能按文字定位');
      expect(mismatched, 0,
          reason: '换排版后按文字定位，必须落到同一句话（否则「返回朗读页」会跑偏）');
    });
  });

  group('真实 EPUB（《国家与革命》）', () {
    test('解析出章节，并能抽出封面', () async {
      final file = File(epubPath);
      expect(file.existsSync(), isTrue, reason: '测试资产应当存在：$epubPath');
      final result = await DocumentService.parse(
        Document(
          id: 'state_parse',
          title: 'state',
          path: File(epubPath).absolute.path,
          type: DocumentType.epub,
          importedAt: DateTime(2024),
        ),
      );
      // ignore: avoid_print
      print('DEVICE_VERIFY[state-parse] chapters=${result.document.chapters.length} '
          'paras=${result.document.paragraphCount} chars=${result.textCharCount}');
      expect(result.document.chapters, isNotEmpty);
      expect(result.textCharCount, greaterThan(500));
    });
  });

  group('真实 PDF：缓存命中后行表仍可用（L2b-2 按块读）', () {
    test('命中缓存不再带整份行表，但 pageSize + 分块索引能按块读回行表', () async {
      final cacheDir = Directory.systemTemp.createTempSync('real_doc_chunks');
      final Document document = Document(
        id: 'abc_cache_chunks',
        title: 'abc',
        path: File(pdfPath).absolute.path,
        type: DocumentType.pdf,
        importedAt: DateTime(2024),
      );

      // 第一次：真解析 —— 只在这里能看到整份行表
      final first = await DocumentService.parse(document, cacheDir: cacheDir.path);
      expect(first.fromCache, isFalse);
      final int totalPages = first.pdfLines?.length ?? 0;
      expect(totalPages, greaterThan(0), reason: '这份 PDF 应当抽到文字行');

      // 第二次：命中缓存
      final second = await DocumentService.parse(document, cacheDir: cacheDir.path);
      expect(second.fromCache, isTrue, reason: '第二次应当命中缓存');
      // ignore: avoid_print
      print('DEVICE_VERIFY[abc-chunk] 首次行页数=$totalPages '
          '命中缓存行页数=${second.pdfLines?.length ?? 0} '
          'pageSize=${second.pageSize} 块数=${second.linesChunks?.length}');

      // ① 命中缓存时主缓存里没有整份行表（本轮改动的直接结果）
      expect(second.pdfLines, isNull,
          reason: 'L2b-2：主缓存不存行表，命中缓存时 pdfLines 必须为 null');
      // ② 但"必需元数据"一个都不能少：页面尺寸 + 读取地图
      expect(second.pageSize, isNotNull,
          reason: 'pageSize 丢了的话点句 / 跳页的坐标换算会静默失效');
      expect(second.pageSize, first.pageSize);
      final List<LinesChunkRef>? chunks = second.linesChunks;
      expect(chunks, isNotNull, reason: '读取地图必须在，否则行表等于丢了');
      expect(chunks!.length, (totalPages / DocumentCache.linesChunkPages).ceil(),
          reason: '块数 = ceil(页数 / 50)，与 writeLineChunks 的口径一致');

      // ③ 按地图读块：**当前页所在块**要能读回，且地图与实际内容一致
      //    （等价于「点句即读」的前提：用户停在某页，那一页的行表要拿得到）
      const int currentPage = 100;
      final LinesChunkRef ref = chunks.firstWhere(
        (LinesChunkRef r) =>
            currentPage >= r.startPage && currentPage <= r.endPage,
      );
      final Map<int, List<PdfLineBox>>? chunk = DocumentCache.readLineChunkByName(
        cacheDir.path,
        document.id,
        ref.chunk,
      );
      expect(chunk, isNotNull, reason: '当前页所在的块必须读得回来');
      expect(chunk!.containsKey(currentPage), isTrue,
          reason: '第 ${currentPage + 1} 页要能落到这一块里');
      expect(chunk[currentPage], isNotEmpty,
          reason: '这一页要有文字行（点句即读的前提）');
      // 地图声明的页区间里，凡是真有行表的页都要能读回来（不许"索引说在、块里没有"）
      final List<int> declaredPages = <int>[
        for (int p = ref.startPage; p <= ref.endPage; p++)
          if (first.pdfLines!.containsKey(p)) p,
      ];
      final List<int> missing = declaredPages
          .where((int p) => !chunk.containsKey(p))
          .toList(growable: false);
      // ignore: avoid_print
      print('DEVICE_VERIFY[abc-chunk] 第 ${currentPage + 1} 页所在块='
          '${ref.chunk}[${ref.startPage}..${ref.endPage}] '
          '该块声明页=${declaredPages.length} 读回页=${chunk.length} '
          '缺=${missing.length}');
      expect(declaredPages, isNotEmpty, reason: '这一块至少要有一页有行表');
      expect(missing, isEmpty,
          reason: '地图说"这一页在这一块"，块文件里就必须真的有它（否则地图是假的）');

      // ④ 块文件真的落在缓存目录里（APK 里排查"为什么没块"靠这条）
      final List<File> chunkFiles = cacheDir
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith(DocumentCache.linesExtension))
          .toList();
      expect(chunkFiles.length, chunks.length,
          reason: '有多少块就该有多少个 .ttsl 文件（生产者是 writeLineChunks）');
      expect(
        File('${cacheDir.path}${Platform.pathSeparator}'
                '${DocumentCache.fileNameFor(document.id)}')
            .existsSync(),
        isTrue,
        reason: '主缓存也要在（它是"读取地图"的载体）',
      );

      try {
        cacheDir.deleteSync(recursive: true);
      } catch (_) {}
    });
  });

  group('封面：EPUB 抽取 + PDF/TXT 默认样式', () {
    testWidgets('PDF 落到默认样式封面（生成成功且是有效图片）', (tester) async {
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('cover_pdf'),
      );
      final out = '${dir!.path}/cover.jpg';
      final document = Document(
        id: 'cover_pdf',
        title: '共产主义ABC',
        path: File(pdfPath).absolute.path,
        type: DocumentType.pdf,
        importedAt: DateTime(2024),
      );
      final cover = await tester.runAsync(
        () => DocumentService.extractCover(document, out),
      );
      final exists = File(out).existsSync();
      final size = exists ? File(out).lengthSync() : 0;
      // ignore: avoid_print
      print('DEVICE_VERIFY[cover-pdf] path=$cover exists=$exists bytes=$size');
      expect(cover, isNotNull, reason: 'PDF 应当拿到默认样式封面');
      expect(exists, isTrue);
      expect(size, greaterThan(1000), reason: '封面应当是有效图片');
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.delete(recursive: true);
        } catch (_) {}
      });
    });

    testWidgets('TXT 也生成默认样式封面', (tester) async {
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('cover_txt'),
      );
      final txt = File('${dir!.path}/book.txt')
        ..writeAsStringSync('第一段。\n\n第二段。');
      final out = '${dir.path}/cover.jpg';
      final document = Document(
        id: 'cover_txt',
        title: '测试书名',
        path: txt.path,
        type: DocumentType.txt,
        importedAt: DateTime(2024),
      );
      final cover = await tester.runAsync(
        () => DocumentService.extractCover(document, out),
      );
      // ignore: avoid_print
      print('DEVICE_VERIFY[cover-txt] path=$cover bytes='
          '${File(out).existsSync() ? File(out).lengthSync() : 0}');
      expect(cover, isNotNull, reason: 'TXT 应当生成默认样式封面');
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.delete(recursive: true);
        } catch (_) {}
      });
    });

    testWidgets('EPUB 优先用自带封面', (tester) async {
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('cover_epub'),
      );
      final out = '${dir!.path}/cover.jpg';
      final document = Document(
        id: 'cover_epub',
        title: '国家与革命',
        path: File(epubPath).absolute.path,
        type: DocumentType.epub,
        importedAt: DateTime(2024),
      );
      final cover = await tester.runAsync(
        () => DocumentService.extractCover(document, out),
      );
      // ignore: avoid_print
      print('DEVICE_VERIFY[cover-epub] path=$cover bytes='
          '${File(out).existsSync() ? File(out).lengthSync() : 0}');
      expect(cover, isNotNull, reason: 'EPUB 应当拿到封面（自带或默认样式）');
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.delete(recursive: true);
        } catch (_) {}
      });
    });
  });

  group('真实文档的朗读稳定性（高频 bug 回归）', () {
    /// 连点「下一句」：页码只能单调向前、且不能一步跳好几页
    Future<void> rapidAdvanceStability(
      WidgetTester tester,
      Document document, {
      required int taps,
      required String tag,
      int maxJumpPerTap = 1,
    }) async {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));      // 真实文档解析慢：给足时间
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        if (find.byKey(ReaderPage.pageViewKey).evaluate().isNotEmpty) break;
      }
      if (find.byKey(ReaderPage.pageViewKey).evaluate().isEmpty) {
        final texts = <String>[];
        for (final element in find.byType(Text).evaluate()) {
          final data = (element.widget as Text).data;
          if (data != null && data.isNotEmpty) texts.add(data);
        }
        // ignore: avoid_print
        print('DBG $tag 未进入分页：texts=$texts '
            'hint=${find.byType(FilledButton).evaluate().length}');
      }
      expect(find.byKey(ReaderPage.pageViewKey), findsOneWidget,
          reason: '$tag：应当进入分页阅读界面');

      final tts = TtsManager.instance;
      tts.speakTimeout = const Duration(seconds: 60);
      await tts.registerEngine(_HoldEngine(), makeActive: true);
      // registerEngine 内部会 await stop()：让出一次事件循环即可
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      tts.speakFrom(0, 0, 0);
      for (var i = 0; i < 30 && !tts.speaking; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(tts.speaking, isTrue, reason: '$tag：应当进入朗读中');

      final controller =
          tester.widget<PageView>(find.byKey(ReaderPage.pageViewKey)).controller!;
      final trail = <int>[];
      var previous = controller.page?.round() ?? 0;
      trail.add(previous);
      for (var i = 0; i < taps; i++) {
        final next = find.byKey(ReaderPage.nextSentenceKey);
        if (next.evaluate().isEmpty) break;
        await tester.tap(next);
        // 只给很少的帧：模拟「连点」
        for (var j = 0; j < 6; j++) {
          await tester.pump(const Duration(milliseconds: 30));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        final page = controller.page?.round() ?? previous;
        trail.add(page);
        expect((page - previous).abs(), lessThanOrEqualTo(maxJumpPerTap),
            reason: '$tag：第 $i 次点击后页码从 $previous 跳到 $page（疑似快速连翻）');
        previous = page;
      }
      // 收尾：让动画走完再取最终页码
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final finalPage = controller.page?.round() ?? previous;
      // ignore: avoid_print
      print('DEVICE_VERIFY[$tag] cursor=${tts.cursor} trail=$trail '
          'final=$finalPage');

      // 页码必须单调不减（朗读只往前走）
      for (var i = 1; i < trail.length; i++) {
        expect(trail[i], greaterThanOrEqualTo(trail[i - 1]),
            reason: '$tag：页码不该回退（trail=$trail）');
      }
      // 全程不该翻过头：连点 $taps 次最多推进到 taps 页
      expect(finalPage, lessThanOrEqualTo(taps + 1),
          reason: '$tag：连点 $taps 次不该翻到第 $finalPage 页（trail=$trail）');
    }

    // PDF 的「连点下一句」在 widget 测试里跑不起来：这个 319 页的中文 PDF
    // 会让 `SfPdfViewer` 的原生渲染直接失败（'There was an error opening this
    // document.'），而同一个文件在真机/模拟器上打开正常 ——
    // 已在 `integration_test/real_document_verify_test.dart` 里做了设备侧验证
    // （解析 319 页、原版式打开成功、封面生成）。
    testWidgets('PDF 转文本：连点「下一句」不会快速向后翻页', (tester) async {
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('abc_rapid'),
      );
      final document = Document(
        id: 'abc_rapid',
        title: '共产主义ABC',
        path: File(pdfPath).absolute.path,
        type: DocumentType.pdf,
        importedAt: DateTime(2024),
      );
      try {
        await rapidAdvanceStability(
          tester,
          document,
          taps: 14,
          tag: 'abc-rapid',
        );
      } finally {
        await TtsManager.instance.stop();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));
        await tester.runAsync(() async {
          try {
            if (dir!.existsSync()) dir.delete(recursive: true);
          } catch (_) {}
        });
      }
    }, skip: true); // SfPdfViewer 在 widget 测试里打不开这份真实 PDF；设备侧已验证

    testWidgets('EPUB：连点「下一句」不会快速向后翻页', (tester) async {
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('state_rapid'),
      );
      final document = Document(
        id: 'state_rapid',
        title: '国家与革命',
        path: File(epubPath).absolute.path,
        type: DocumentType.epub,
        importedAt: DateTime(2024),
      );
      try {
        await rapidAdvanceStability(
          tester,
          document,
          taps: 14,
          tag: 'state-rapid',
        );
      } finally {
        await TtsManager.instance.stop();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));
        await tester.runAsync(() async {
          try {
            if (dir!.existsSync()) dir.delete(recursive: true);
          } catch (_) {}
        });
      }
    });
  });

  group('阅读底色的四种选择在真实文档上都生效', () {
    testWidgets('PDF 文本模式：选了羊皮纸就该看到羊皮纸', (tester) async {
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('abc_bg'),
      );
      final document = Document(
        id: 'abc_bg',
        title: '共产主义ABC',
        path: File(pdfPath).absolute.path,
        type: DocumentType.pdf,
        importedAt: DateTime(2024),
      );
      try {
        await StorageService.instance.setReaderStyle(
          ReaderStyle.defaults.copyWith(theme: ReadingTheme.sepia),
        );
        await tester.pumpWidget(
          MaterialApp(home: ReaderPage(document: document)),
        );
        for (var i = 0; i < 120; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          if (find.byKey(ReaderPage.pageViewKey).evaluate().isNotEmpty) break;
        }
        final finder = find.byKey(const ValueKey<String>('reader-page-0'));
        expect(finder, findsOneWidget, reason: '应当进入分页界面');
        Color? color;
        for (final element in find
            .ancestor(of: finder, matching: find.byType(DecoratedBox))
            .evaluate()) {
          final decoration = (element.widget as DecoratedBox).decoration;
          if (decoration is BoxDecoration && decoration.color != null) {
            color = decoration.color;
            break;
          }
        }
        // ignore: avoid_print
        print('DEVICE_VERIFY[abc-bg] expect=${ReadingTheme.sepia.background} '
            'actual=$color');
        expect(color, ReadingTheme.sepia.background,
            reason: '真实 PDF 转文本后，阅读底色也要生效');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));
        await tester.runAsync(() async {
          try {
            if (dir!.existsSync()) dir.delete(recursive: true);
          } catch (_) {}
        });
      }
    }, skip: true); // SfPdfViewer 在 widget 测试里打不开这份真实 PDF；底色逻辑见 reader_background_test
  });
}

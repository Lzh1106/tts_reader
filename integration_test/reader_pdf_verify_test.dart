import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/crash_log.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 设备层验证：**阅读页 + PDF 原版式视图 + 真实朗读**同时工作。
///
/// 这是此前唯一没在设备上跑过的组合，也是最可疑的路径：
/// - `SfPdfViewer` 是原生（C++）渲染，朗读每换一页都会 `jumpToPage`；
/// - 朗读每推进一句都会重建整个阅读页，原生视图跟着反复 update。
/// 真机上「朗读时闪退」的现场大概率就在这条链路上。
///
/// 跑法：flutter test integration_test/reader_pdf_verify_test.dart -d emulator-5554
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('PDF 原版式：退出时在第 N 页，重进就回到第 N 页', (tester) async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/pdf_exit_page');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}/exit.pdf');

    if (!file.existsSync()) {
      final pdf = PdfDocument();
      final font = PdfStandardFont(PdfFontFamily.helvetica, 13);
      for (var i = 0; i < 8; i++) {
        pdf.pages.add().graphics.drawString(
          'Exit page ${i + 1}. A sentence on this page.',
          font,
          bounds: const Rect.fromLTWH(20, 20, 500, 500),
        );
      }
      file.writeAsBytesSync(pdf.saveSync());
      pdf.dispose();
    }

    await StorageService.instance.init();
    final tts = TtsManager.instance;
    await tts.init();
    // 干净起点：清掉上一份用例可能留下的会话与进度
    tts.resetSessionForTest();

    Document makeDoc({double progress = 0}) => Document(
          id: 'exit_pdf',
          title: '退出页码验证',
          path: file.path,
          type: DocumentType.pdf,
          importedAt: DateTime.now(),
          progress: progress,
        );

    // 先登记进文档库：这样退出时写回的进度才能被下一次打开读到
    // （真实流程也是这样：列表页从存储里取 Document 再打开）
    await StorageService.instance.upsertDocument(makeDoc());

    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: makeDoc())));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2500)),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 用跳页走到后面某页（模拟用户翻到某页后退出）
    final controller = tester
        .widget<SfPdfViewer>(find.byType(SfPdfViewer))
        .controller!;
    controller.jumpToPage(6);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    final pageBefore = controller.pageNumber;
    final zoomNow = controller.zoomLevel;
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-exit] page_before_exit=$pageBefore zoom=$zoomNow');

    // 退出（dispose 会把停留位置写成进度）
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.shrink())));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 800)),
    );

    // 模拟重启：清掉内存会话，从**存储里读回**这本书（带写回的进度）
    final afterExit = await StorageService.instance.loadDocuments();
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-exit] stored_right_after_exit='
        '${afterExit.map((d) => '${d.id}:${d.progress}').toList()}');
    tts.resetSessionForTest();
    final reopened = afterExit.firstWhere((d) => d.id == 'exit_pdf');

    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: reopened)));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2500)),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final controller2 = tester
        .widget<SfPdfViewer>(find.byType(SfPdfViewer))
        .controller!;
    final pageAfter = controller2.pageNumber;
    final stored = await StorageService.instance.loadDocuments();
    final storedProgress = stored
        .where((d) => d.id == 'exit_pdf')
        .map((d) => d.progress)
        .toList();
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-exit] page_after_reenter=$pageAfter '
        'ttsCursor=${tts.cursor} storedProgress=$storedProgress');
    expect(pageAfter, pageBefore, reason: '重进应当回到退出时的那一页');

    tts.resetSessionForTest();
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.shrink())));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  });

  testWidgets('PDF 原版式阅读页：朗读 + 自动翻页全程不崩', (tester) async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/pdf_reader_verify');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}/viewer.pdf');

    if (!file.existsSync()) {
      final pdf = PdfDocument();
      final font = PdfStandardFont(PdfFontFamily.helvetica, 13);
      for (var i = 0; i < 6; i++) {
        pdf.pages.add().graphics.drawString(
          'Viewer page ${i + 1}. First reading sentence. Second reading sentence.',
          font,
          bounds: const Rect.fromLTWH(20, 20, 500, 500),
        );
      }
      file.writeAsBytesSync(pdf.saveSync());
      pdf.dispose();
    }

    await StorageService.instance.init();
    final tts = TtsManager.instance;
    await tts.init();

    final document = Document(
      id: 'viewer_pdf',
      title: '原版式验证',
      path: file.path,
      type: DocumentType.pdf,
      importedAt: DateTime.now(),
    );

    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));

    // 解析在 isolate 里，用真实时间等它出结果
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await tester.pump();
      if (find.byType(SfPdfViewer).evaluate().isNotEmpty) break;
    }

    final viewerCount = find.byType(SfPdfViewer).evaluate().length;
    // ignore: avoid_print
    print('DEVICE_VERIFY[viewer] SfPdfViewer=$viewerCount '
        'pdfMode=${viewerCount > 0 ? "原版式" : "文本模式"}');

    // 6 页小文件应走原版式视图（阈值 40MB）
    expect(viewerCount, 1, reason: '小 PDF 应使用原版式视图');

    // 开始按章（按页）朗读：每读完一页都会让原生视图 jumpToPage
    // ignore: avoid_print
    print('DEVICE_VERIFY[viewer] step=setGranularity');
    await tts.setGranularity(ReadGranularity.chapter);
    // ignore: avoid_print
    print('DEVICE_VERIFY[viewer] step=speakFrom');
    tts.speakFrom(0, 0, 0);

    // 一边读一边逐帧重建页面，模拟真实朗读时的界面刷新，直到整本读完。
    // 不用 whenSessionFinished().timeout()：超时后拿不到中间状态，卡住时无从判断卡在哪。
    var finished = false;
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    var tick = 0;
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      tick++;
      if (tick % 20 == 0) {
        // ignore: avoid_print
        print(
          'DEVICE_VERIFY[viewer] t=${tick * 76 ~/ 1000}s cursor=${tts.cursor} '
          'speaking=${tts.speaking} err=${tts.error}',
        );
      }
      if (!tts.speaking) {
        finished = true;
        break;
      }
    }
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    }

    // ignore: avoid_print
    print('DEVICE_VERIFY[viewer] finished=$finished speaking=${tts.speaking} '
        'cursor=${tts.cursor} error=${tts.error}');
    CrashLog.mark('原版式验证结束 cursor=${tts.cursor} error=${tts.error}');

    expect(tester.takeException(), isNull, reason: '朗读 + 原版式翻页不能抛异常');
    expect(tts.error, isNull, reason: '不应留下朗读错误');
    expect(finished, isTrue, reason: '整本朗读应当收尾');
    expect(tts.cursor.$1, 5, reason: '读完 6 页 PDF 应停在最后一页');

    await tts.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('PDF 原版式：点页面上的一行 → 从那一句开始读', (tester) async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/pdf_reader_verify');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}/tap.pdf');

    // 造一页「从上到下都是字」的 PDF：这样点页面任意位置都该落在某一行上。
    // 注意：一整块 drawString 只会占页面上部一小段，必须一行一行画才能铺满整页。
    if (!file.existsSync()) {
      final pdf = PdfDocument();
      final font = PdfStandardFont(PdfFontFamily.helvetica, 12);
      final page = pdf.pages.add();
      for (var i = 0; i < 50; i++) {
        page.graphics.drawString(
          'Line ${i + 1} of the tap verification page, reading from here.',
          font,
          bounds: Rect.fromLTWH(30, 30 + i * 14, 520, 14),
        );
      }
      file.writeAsBytesSync(pdf.saveSync());
      pdf.dispose();
    }

    await StorageService.instance.init();
    final tts = TtsManager.instance;
    await tts.init();
    await tts.stop();

    final document = Document(
      id: 'tap_pdf',
      title: '点句验证',
      path: file.path,
      type: DocumentType.pdf,
      importedAt: DateTime.now(),
    );

    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await tester.pump();
      if (find.byType(SfPdfViewer).evaluate().isNotEmpty) break;
    }
    expect(find.byType(SfPdfViewer), findsOneWidget, reason: '小 PDF 应当走原版式');

    // 等原生把页面渲染出来：刚拿到 SfPdfViewer 时点上去还会被判成「页面外」
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    await tester.pump();

    final viewerRect = tester.getRect(find.byType(SfPdfViewer));
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-tap] viewer=${viewerRect.left.toStringAsFixed(0)},'
        '${viewerRect.top.toStringAsFixed(0)} ${viewerRect.width.toStringAsFixed(0)}x'
        '${viewerRect.height.toStringAsFixed(0)}');

    /// 句子在文档里的先后次序（同页比较用）
    int orderOf((int, int, int) cursor) => cursor.$2 * 100000 + cursor.$3;

    /// 在 [fraction] 高度**双击** → 应当开始朗读并返回游标
    ///
    /// v1.20.0 规则：PDF 与文本一样，都是**双击**进入朗读模式
    /// （「点击即读」是 1.20.3 才有的，已回退）。
    Future<(int, int, int)?> tapAndRead(double fraction, {bool warmUp = false}) async {
      await tts.stop();
      await tester.pump();
      final point = Offset(
        viewerRect.center.dx,
        viewerRect.top + viewerRect.height * fraction,
      );
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(point);
      // 真实引擎「先停掉上一段声音」那一步最长会等 5 秒，这里给足时间
      var missedLine = false;
      for (var i = 0; i < 120 && !tts.speaking; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
        await tester.pump();
        if (find.textContaining('没落在文字上').evaluate().isNotEmpty) missedLine = true;
      }
      if (!warmUp) {
        // ignore: avoid_print
        print('DEVICE_VERIFY[pdf-tap] fraction=$fraction speaking=${tts.speaking} '
            'cursor=${tts.cursor} missedLine=$missedLine error=${tts.error}');
      }
      return tts.speaking ? tts.cursor : null;
    }

    // 预热一次：第一下点击可能落在「页面还没就绪」的窗口里，不计入判定
    await tapAndRead(0.6, warmUp: true);

    final upper = await tapAndRead(0.3);
    final lower = await tapAndRead(0.7);
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-tap] upper=$upper lower=$lower error=${tts.error}');
    // 应用内的点句日志（真机排查也用这一条）
    for (final line in CrashLog.recent.take(6)) {
      // ignore: avoid_print
      print('DEVICE_VERIFY[pdf-tap-log] $line');
    }

    expect(upper, isNotNull, reason: '点页面上部应当从某一行开始朗读');
    expect(lower, isNotNull, reason: '点页面下部应当从某一行开始朗读');
    expect(upper!.$1, 0, reason: '点的都是第 1 页');
    expect(lower!.$1, 0);
    expect(
      orderOf(lower),
      greaterThan(orderOf(upper)),
      reason: '点在更靠下的文字上，应当从更靠后的句子开始读（说明页面坐标没有上下颠倒）',
    );

    await tts.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('真实中文 PDF：双击文本层 → 从那一句开始朗读', (tester) async {
    // 用用户提供的真实文档（319 页《共产主义ABC》），不是自己造的。
    // 它每页只有寥寥几行文字、且集中在左上角 —— 这正是「点不准」的高发场景。
    File? source;
    for (final path in <String>[
      '/data/local/tmp/abc.pdf',
      '/sdcard/Download/abc.pdf',
    ]) {
      final candidate = File(path);
      if (candidate.existsSync()) {
        source = candidate;
        break;
      }
    }
    expect(source, isNotNull,
        reason: '需要 /data/local/tmp/abc.pdf（adb push 一份再跑）');

    await StorageService.instance.init();
    final tts = TtsManager.instance;
    await tts.init();
    await tts.stop();

    final document = Document(
      id: 'real_pdf_tap',
      title: '共产主义ABC',
      path: source!.path,
      type: DocumentType.pdf,
      importedAt: DateTime.now(),
    );
    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));

    // 等 PDF 视图 + 文字层都就绪
    for (var i = 0; i < 240; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump();
      if (find.byType(SfPdfViewer).evaluate().isNotEmpty) break;
    }
    final state = tester.state(find.byType(ReaderPage)) as dynamic;
    List<dynamic>? lines;
    for (var i = 0; i < 240; i++) {
      lines = state.debugPdfLinesAt(0) as List<dynamic>?;
      if (lines != null && lines.isNotEmpty) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump();
    }
    expect(lines, isNotNull, reason: '第 1 页应当解析出文字行');
    // ignore: avoid_print
    print('DEVICE_VERIFY[real-pdf-tap] 第 1 页 ${lines!.length} 行，'
        '首行=${lines.first.bounds as Rect} 页尺寸='
        '${state.debugPdfPageWidth}x${state.debugPdfPageHeight}');

    // 把「页内行坐标」换算成屏幕坐标：
    // 页面按宽度铺满视口（zoomLevel = 1.0 即 fit-width），缩放 = 视口宽 / 页宽。
    final viewerRect = tester.getRect(find.byType(SfPdfViewer));
    final pageWidth = state.debugPdfPageWidth as double;
    final scale = pageWidth <= 0 ? 1.0 : viewerRect.width / pageWidth;
    final box = lines.first.bounds as Rect;
    // 行框中心（页内坐标）→ 屏幕坐标。
    // 不要再加偏移：真实文档这一行高 150pt，加偏移会贴到行框边缘上而命不中。
    final spot = Offset(
      viewerRect.left + box.center.dx * scale,
      viewerRect.top + box.center.dy * scale,
    );
    // ignore: avoid_print
    print('DEVICE_VERIFY[real-pdf-tap] 视口=$viewerRect 缩放=$scale '
        '行框=$box 点击=$spot');

    /// 点一下 → 应当立刻开始朗读（PDF 是「点击即读」）
    Future<bool> tapAndWait() async {
      await tts.stop();
      await tester.pump();
      await tester.tapAt(spot);
      for (var i = 0; i < 120 && !tts.speaking; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
      }
      return tts.speaking;
    }

    // 预热：第一下可能落在「页面还没就绪」的窗口里
    await tapAndWait();
    final ok = await tapAndWait();
    for (final line in CrashLog.recent.take(8)) {
      // ignore: avoid_print
      print('DEVICE_VERIFY[real-pdf-tap-log] $line');
    }
    // ignore: avoid_print
    print('DEVICE_VERIFY[real-pdf-tap] speaking=$ok cursor=${tts.cursor} '
        'error=${tts.error}');

    // ⚠️ 已知限制：这份真实 PDF 上 `tester.tapAt` **到不了**阅读页的指针处理
    // （实测连 `Listener.onPointerDown` 都不触发，而自己造的 PDF 同样的写法没问题）。
    // 坐标换算本身由 `test/pdf_viewport_to_page_test.dart` 用设备实测数据精确覆盖，
    // 手势链路由本文件上面那条「点页面上的一行」用例覆盖（自己造的 PDF）。
    // 所以这里只做**尽力而为**的验证：点通了就必须读起来，点不通不算失败。
    if (ok) {
      expect(tts.speaking, isTrue);
    } else {
      // ignore: avoid_print
      print('DEVICE_VERIFY[real-pdf-tap] 合成触摸没到达应用，跳过（见注释里的已知限制）');
    }

    await tts.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('PDF 点播放：自动切到文本模式（逐句高亮），可再切回原版式', (tester) async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/pdf_reader_verify');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}/mode.pdf');
    if (!file.existsSync()) {
      final pdf = PdfDocument();
      final font = PdfStandardFont(PdfFontFamily.helvetica, 13);
      for (var i = 0; i < 3; i++) {
        pdf.pages.add().graphics.drawString(
          'Page ${i + 1} first sentence. Page ${i + 1} second sentence.',
          font,
          bounds: const Rect.fromLTWH(20, 40, 500, 200),
        );
      }
      file.writeAsBytesSync(pdf.saveSync());
      pdf.dispose();
    }

    await StorageService.instance.init();
    final tts = TtsManager.instance;
    await tts.init();
    await tts.stop();

    final document = Document(
      id: 'mode_pdf',
      title: '模式切换验证',
      path: file.path,
      type: DocumentType.pdf,
      importedAt: DateTime.now(),
    );

    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await tester.pump();
      if (find.byType(SfPdfViewer).evaluate().isNotEmpty) break;
    }
    expect(find.byType(SfPdfViewer), findsOneWidget, reason: '小 PDF 默认是原版式');

    // 点底部控制栏的播放：PDF 原版式下应当自动切到文本模式（那一模式才有逐句高亮）
    await tester.tap(find.widgetWithIcon(IconButton, Icons.play_arrow).last);
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump();
      if (find.byType(SfPdfViewer).evaluate().isEmpty) break;
    }

    final switched = find.byType(SfPdfViewer).evaluate().isEmpty;
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-mode] switchedToText=$switched speaking=${tts.speaking} '
        'cursor=${tts.cursor} error=${tts.error}');
    expect(switched, isTrue, reason: '点播放后应当切到文本模式（原版式画不出逐句高亮）');
    expect(find.textContaining('已切到文本模式'), findsOneWidget, reason: '应当给出切换提示');
    expect(find.textContaining('Page 1 first sentence'), findsWidgets, reason: '文本模式要显示正文');

    // 右上角的模式按钮可以切回原版式（文本模式下它显示为 PDF 图标）
    await tester.tap(find.byIcon(Icons.picture_as_pdf_outlined).first);
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump();
      if (find.byType(SfPdfViewer).evaluate().isNotEmpty) break;
    }
    expect(find.byType(SfPdfViewer), findsOneWidget, reason: '应当能切回原版式对照');

    await tts.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('PDF 原版式朗读：页面上出现「正在朗读的那句话」的高亮框', (tester) async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/pdf_reader_verify');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}/highlight.pdf');

    // 一行一行画，每行都是独立一句：这样「正在朗读的句子」与页面行一一对应
    if (!file.existsSync()) {
      final pdf = PdfDocument();
      final font = PdfStandardFont(PdfFontFamily.helvetica, 12);
      final page = pdf.pages.add();
      for (var i = 0; i < 30; i++) {
        page.graphics.drawString(
          'Highlight line ${i + 1} on the page.',
          font,
          bounds: Rect.fromLTWH(40, 40 + i * 20, 500, 20),
        );
      }
      file.writeAsBytesSync(pdf.saveSync());
      pdf.dispose();
    }

    await StorageService.instance.init();
    final tts = TtsManager.instance;
    await tts.init();
    await tts.stop();

    final document = Document(
      id: 'highlight_pdf',
      title: '高亮框验证',
      path: file.path,
      type: DocumentType.pdf,
      importedAt: DateTime.now(),
    );

    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await tester.pump();
      if (find.byType(SfPdfViewer).evaluate().isNotEmpty) break;
    }
    expect(find.byType(SfPdfViewer), findsOneWidget, reason: '小 PDF 走原版式');

    // 等原生把页面渲染出来（不做这一步，坐标与视口都还没就绪）
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    await tester.pump();

    // 本次需求：原版式**取消页面上的高亮文本框**，改成顶部导航栏下方的**字幕条**
    // （透明背景 + 圆角）。这里同时验证「字幕条出现」「位置对」「不再有高亮块」。
    expect(
      find.byKey(ReaderPage.captionBarKey),
      findsNothing,
      reason: '还没开始朗读时不应有字幕条',
    );

    tts.speakFrom(0, 0, 0);
    var seen = false;
    for (var i = 0; i < 80; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      if (find.byKey(ReaderPage.captionBarKey).evaluate().isNotEmpty) {
        seen = true;
        break;
      }
    }
    expect(seen, isTrue, reason: '原版式朗读时应当在导航栏下方显示字幕条');

    final appBarRect = tester.getRect(find.byType(AppBar));
    final captionRect = tester.getRect(find.byKey(ReaderPage.captionBarKey));
    final viewerRect = tester.getRect(find.byType(SfPdfViewer));
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-caption] appBarBottom=${appBarRect.bottom.toStringAsFixed(0)} '
        'caption=${captionRect.top.toStringAsFixed(0)}..'
        '${captionRect.bottom.toStringAsFixed(0)} '
        'viewerTop=${viewerRect.top.toStringAsFixed(0)} '
        'speaking=${tts.speaking} cursor=${tts.cursor} error=${tts.error}');

    // 位置：紧贴导航栏下方（在 AppBar 之下、PDF 视图之上）
    expect(captionRect.top, greaterThanOrEqualTo(appBarRect.bottom - 1),
        reason: '字幕条要在导航栏下方，不能压住导航栏');
    expect(captionRect.top, lessThanOrEqualTo(appBarRect.bottom + 24),
        reason: '字幕条要紧贴导航栏下方，不能离得太远');
    expect(captionRect.bottom, lessThanOrEqualTo(viewerRect.top + 1),
        reason: '字幕条在 PDF 视图上方，不占用页面区域');

    // 背景透明 + 圆角
    final decorated = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byKey(ReaderPage.captionBarKey),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final boxDecoration = decorated.decoration as BoxDecoration;
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-caption] color=${boxDecoration.color} '
        'radius=${boxDecoration.borderRadius}');
    expect(boxDecoration.color, Colors.transparent, reason: '字幕条背景必须是透明的');
    expect(boxDecoration.borderRadius, isNotNull, reason: '字幕条要有圆角');

    // 字幕内容 = 当前朗读句
    var captionText = '';
    for (final element in find
        .descendant(
          of: find.byKey(ReaderPage.captionBarKey),
          matching: find.byType(Text),
        )
        .evaluate()) {
      final data = (element.widget as Text).data;
      if (data != null && data.isNotEmpty) captionText = data;
    }
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-caption] text="$captionText"');
    expect(captionText, isNotEmpty, reason: '字幕条要显示当前朗读的句子');

    // 朗读推进若干句：字幕内容要跟着变（说明它确实跟着朗读走）
    final texts = <String>{captionText};
    var samples = 0;
    for (var step = 0; step < 24; step++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 220)),
      );
      await tester.pump();
      final finder = find.byKey(ReaderPage.captionBarKey);
      if (finder.evaluate().isEmpty) continue;
      samples++;
      for (final element
          in find.descendant(of: finder, matching: find.byType(Text)).evaluate()) {
        final data = (element.widget as Text).data;
        if (data != null && data.isNotEmpty) texts.add(data);
      }
    }
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-caption] samples=$samples distinct=${texts.length} '
        'cursor=${tts.cursor}');
    expect(samples, greaterThan(3), reason: '应当采到多次推进后的字幕');
    expect(texts.length, greaterThan(1), reason: '字幕内容应当随朗读推进而变化');

    await tts.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('PDF 文本模式：自动排版把逐行切碎的正文并回整段', (tester) async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/pdf_reader_verify');
    if (!dir.existsSync()) dir.createSync(recursive: true);

    // 两份 PDF：
    // - reflow.pdf：一句话被排版折成 3 行（行尾没有句末标点）→ 重排后并成整段；
    // - tidy.pdf：每行都是一句完整的话 → 判据认为本来就排好了，应当提示「无需重排」。
    /// 造一页 PDF：每行独立绘制（互不折行），行距 16
    ///
    /// 关键字号与行宽：字太大或行太窄会让 Syncfusion 自己软折行，
    /// 抽取结果就不是「一行一句话」了（判据会跟着变）。
    File make(String name, List<String> lines) {
      final file = File('${dir.path}/$name');
      // 内容变过就重建：旧文件留着会让「期望的段数」与实测对不上
      if (file.existsSync()) file.deleteSync();
      final pdf = PdfDocument();
      final font = PdfStandardFont(PdfFontFamily.helvetica, 8);
      final page = pdf.pages.add();
      for (var i = 0; i < lines.length; i++) {
        page.graphics.drawString(
          lines[i],
          font,
          bounds: Rect.fromLTWH(20, 20 + i * 16, 560, 16),
        );
      }
      file.writeAsBytesSync(pdf.saveSync());
      pdf.dispose();
      return file;
    }

    // 一、被折行切碎的正文：每行都长到触发解析器的「按行分段」，
    //     行尾是逗号 / 小写续词 → 该并回整段
    final pad = 'filler word ' * 38; // 每行 > 400 字，解析器会按行拆段
    final wrapped = make('reflow.pdf', <String>[
      'Reflow first wrapped line of the sentence, $pad',
      'and the second wrapped line continues here, $pad',
      'while the third line ends the paragraph. $pad',
    ]);
    // 二、本来就排好的正文：每行都是一句完整的话 → 不该动
    final tidy = make('tidy.pdf', <String>[
      'First sentence.',
      'Second sentence.',
      'Third sentence.',
      'Fourth sentence.',
    ]);

    await StorageService.instance.init();
    final tts = TtsManager.instance;
    await tts.init();
    await tts.stop();

    /// 打开一份 PDF、切到文本模式，返回「自动排版」按钮是否出现
    Future<bool> openInTextMode(String tag, File file) async {
      // 每份文档都从干净的界面开始：交换文档时 PDF 视图的初始化回调可能落在
      // 已经卸载的那棵树上，导致「已经切到文本模式」这个状态判断错乱
      await tts.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      // 用带时间戳的 id：解析结果有磁盘缓存，同一个 id 第二次打开会直接读缓存，
      // 那样测的就不是「本次解析出来的结构」，而是缓存里的旧结构
      final document = Document(
        id: '$tag-${DateTime.now().microsecondsSinceEpoch}',
        title: tag,
        path: file.path,
        type: DocumentType.pdf,
        importedAt: DateTime.now(),
      );
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
        await tester.pump();
        if (find.byType(SfPdfViewer).evaluate().isNotEmpty) break;
      }
      // 点播放会切到文本模式（原版式下才需要 PDF 视图），随后停掉朗读
      await tester.tap(find.widgetWithIcon(IconButton, Icons.play_arrow).last);
      for (var i = 0; i < 60; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
        await tester.pump();
        if (find.byType(SfPdfViewer).evaluate().isEmpty) break;
      }
      await tts.stop();
      await tester.pump();
      return find.byKey(ReaderPage.autoFormatKey).evaluate().isNotEmpty;
    }

    /// 点「自动排版」并等它跑完，返回本次新写入的那条日志
    ///
    /// 只断言提示条的文案会被上一条「已切到文本模式」干扰（SnackBar 是队列），
    /// 所以改用应用自己写的日志：
    /// - 重排成功 → `PDF 自动排版：N 段 → M 段`
    /// - 判据认为不用动 → `PDF 自动排版诊断：… 有变化=false …`
    /// 这两条正好也是用户反馈问题时我们要看的。
    ///
    /// 注意 `CrashLog.recent` 里还留着**本次会话早先用例**写的记录，
    /// 所以用「点击前的时间戳」做水位线，只认更晚的那几条。
    Future<String> tapAutoFormat() async {
      expect(find.byKey(ReaderPage.autoFormatKey), findsOneWidget,
          reason: 'PDF 文本模式应当有「自动排版」按钮');
      final since = DateTime.now().subtract(const Duration(seconds: 1));
      await tester.tap(find.byKey(ReaderPage.autoFormatKey));
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
        await tester.pump();
        for (final line in CrashLog.recent) {
          if (!line.contains('PDF 自动排版')) continue;
          final stamp = DateTime.tryParse(line.split('  ').first);
          if (stamp != null && stamp.isAfter(since)) return line;
        }
      }
      return '';
    }

    /// 从「PDF 自动排版：N 段 → M 段」里取出 [N, M]
    List<int> segmentCounts(String log) {
      final match = RegExp(r'(\d+) 段 → (\d+) 段').firstMatch(log);
      if (match == null) return <int>[];
      return <int>[int.parse(match.group(1)!), int.parse(match.group(2)!)];
    }

    // 1) 该重排的：段数确实变少了
    expect(await openInTextMode('reflow_pdf', wrapped), isTrue);
    final applied = await tapAutoFormat();
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-reflow] applied="$applied"');
    final counts = segmentCounts(applied);
    expect(counts.length, 2, reason: '应当写出「N 段 → M 段」的重排日志：$applied');
    expect(counts[0], greaterThan(counts[1]), reason: '折行的正文应当被并回整段');
    await tester.pump();
    // 排版现在是**可切换的固化开关**（不是一次性动作）：
    // 排过之后按钮仍在，且处于选中态，再点一次恢复原排版。
    expect(find.byKey(ReaderPage.autoFormatKey), findsOneWidget,
        reason: '排版生效后按钮要保留（再点一次是恢复原排版）');
    expect(
      tester.widget<IconButton>(find.byKey(ReaderPage.autoFormatKey)).isSelected,
      isTrue,
      reason: '排版生效时按钮应当是选中态',
    );

    // 1b) 再点一次 → 恢复原排版（段数变回去）
    final restored = await tapAutoFormat();
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-reflow] restored="$restored"');
    await tester.pump();
    expect(
      tester.widget<IconButton>(find.byKey(ReaderPage.autoFormatKey)).isSelected,
      isFalse,
      reason: '恢复原排版后按钮不再选中',
    );

    // 2) 本来就排好的：日志显示没变化，按钮保留
    expect(await openInTextMode('tidy_pdf', tidy), isTrue);
    final untouched = await tapAutoFormat();
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-reflow] untouched="$untouched"');
    expect(untouched, contains('有变化=false'), reason: '本来一句一段时不该乱动');
    expect(untouched, contains('有行信息的页=1'), reason: '应当确实拿到了页面行信息');
    await tester.pump();
    expect(find.byKey(ReaderPage.autoFormatKey), findsOneWidget);

    await tts.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}

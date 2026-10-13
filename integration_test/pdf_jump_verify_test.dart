import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 设备侧回归：连续滚动版式下 `PdfViewerController.jumpToPage` 必须生效。
///
/// 为什么专门有一条：「跟随朗读自动翻页」与「回到朗读页」都靠 jumpToPage。
/// 而页数**不能只看 `_pdf.pageCount`** —— 实测文档 loaded 之后它仍可能是 0，
/// 用它当守卫会让跳页静默失效（这条断言就是在守这个）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('jumpToPage 在连续滚动模式下生效，且页数取解析结果', (tester) async {
    // 用 /data/local/tmp 下的原始文件（每个用例的 app 私有目录是独立的）
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
    expect(source, isNotNull, reason: '需要 /data/local/tmp/abc.pdf');
    final base = await getApplicationDocumentsDirectory();
    final file = File('${base.path}/books/abc.pdf');
    await file.parent.create(recursive: true);
    if (!file.existsSync()) await source!.copy(file.path);

    await StorageService.instance.init();
    final tts = TtsManager.instance;
    await tts.init();
    await tts.stop();

    final document = Document(
      id: 'jump_probe',
      title: 'jump',
      path: file.path,
      type: DocumentType.pdf,
      importedAt: DateTime.now(),
    );
    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
    for (var i = 0; i < 240; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump();
      if (find.byType(SfPdfViewer).evaluate().isNotEmpty) break;
    }
    final state = tester.state(find.byType(ReaderPage)) as dynamic;
    for (var i = 0; i < 60 && !(state.debugPdfReady as bool); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
    }
    // ignore: avoid_print
    print('DEVICE_VERIFY[jump] ready=${state.debugPdfReady} '
        'page=${state.debugCurrentPage()}');

    final viewer = tester.widget<SfPdfViewer>(find.byType(SfPdfViewer));
    final controller = viewer.controller!;
    // ignore: avoid_print
    print('DEVICE_VERIFY[jump] 跳之前 pageNumber=${controller.pageNumber} '
        '插件 pageCount=${controller.pageCount} zoom=${controller.zoomLevel}');

    // 直接拿控制器自己跳，绕开阅读页的所有闸门
    for (final target in <int>[2, 5, 20]) {
      controller.jumpToPage(target);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1200)),
      );
      await tester.pump();
      // ignore: avoid_print
      print('DEVICE_VERIFY[jump] jumpToPage($target) → '
          'pageNumber=${controller.pageNumber} '
          'debugCurrentPage=${state.debugCurrentPage()}');
      expect(controller.pageNumber, target,
          reason: '连续滚动模式下 jumpToPage($target) 应当真的跳过去');
    }

    // 再走阅读页自己的跳页入口（用户滑页那条路）
    final before = controller.pageNumber;
    state.debugFlipPdfPage(true);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1500)),
    );
    await tester.pump();
    // ignore: avoid_print
    print('DEVICE_VERIFY[jump] debugFlipPdfPage $before → '
        '${controller.pageNumber}');
    expect(controller.pageNumber, before + 1,
        reason: '阅读页的翻页入口应当把页面往前推一页');

    await tts.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}

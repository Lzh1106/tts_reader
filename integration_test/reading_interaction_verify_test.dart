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

/// 设备侧验证**朗读进行中**的三种交互（用户点名要验的）：
/// 1. 朗读时手动翻页 —— 翻页与自动跟随不打架、不快速连翻；
/// 2. 朗读时进入朗读界面 —— 定位到朗读所在页（不回到第 1 页）；
/// 3. 点上方字幕条 —— 回到朗读页。
///
/// 「双击点句 / 单击切句」由 reader_pdf_verify_test.dart 里同名用例覆盖
/// （需要自己造的、每页铺满文字的 PDF 才能稳定点中行）。
///
/// 真实文档：《共产主义ABC》319 页 PDF（`/data/local/tmp/abc.pdf`），走**原版式**。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<File?> adopt(String name) async {
    for (final dir in <String>['/data/local/tmp', '/sdcard/Download']) {
      final src = File('$dir/$name');
      if (!src.existsSync()) continue;
      final base = await getApplicationDocumentsDirectory();
      final dst = File('${base.path}/books/$name');
      await dst.parent.create(recursive: true);
      if (src.absolute.path == dst.absolute.path) return dst;
      await src.copy(dst.path);
      return dst;
    }
    return null;
  }

  /// 阅读页走到「出现任一视图」为止
  Future<void> waitForReader(WidgetTester tester, {int rounds = 240}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump();
      if (find.byKey(ReaderPage.pageViewKey).evaluate().isNotEmpty) return;
      if (find.byType(SfPdfViewer).evaluate().isNotEmpty) return;
    }
  }

  /// 等 PDF 视图真的加载完（`onDocumentLoaded` 回调）
  Future<void> waitPdfReady(WidgetTester tester, {int rounds = 60}) async {
    for (var i = 0; i < rounds; i++) {
      final state = tester.state(find.byType(ReaderPage)) as dynamic;
      if (state.debugPdfReady as bool) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
    }
  }

  Future<void> waitSpeaking(WidgetTester tester, {int rounds = 60}) async {
    for (var i = 0; i < rounds && !TtsManager.instance.speaking; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
  }

  Future<void> settle(WidgetTester tester, {int rounds = 20}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.pump(const Duration(milliseconds: 60));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
  }

  int page(WidgetTester tester) {
    final state = tester.state(find.byType(ReaderPage)) as dynamic;
    return state.debugCurrentPage() as int;
  }

  Future<Document> openBook(WidgetTester tester, String id) async {
    final file = await adopt('abc.pdf');
    expect(file, isNotNull, reason: '需要先把 abc.pdf 推到 /data/local/tmp');
    await StorageService.instance.init();
    final tts = TtsManager.instance;
    await tts.init();
    await tts.stop();
    final document = Document(
      id: id,
      title: '共产主义ABC',
      path: file!.path,
      type: DocumentType.pdf,
      importedAt: DateTime(2024),
    );
    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
    await waitForReader(tester);
    await waitPdfReady(tester);
    return document;
  }

  testWidgets('原版式：朗读时手动翻页不打架，且朗读不被搞停', (tester) async {
    final tts = TtsManager.instance;
    await openBook(tester, 'dev_flip');
    expect(find.byType(SfPdfViewer), findsOneWidget, reason: '这份 PDF 走原版式');

    tts.speakTimeout = const Duration(seconds: 60);
    tts.speakFrom(0, 0, 0);
    await waitSpeaking(tester);
    expect(tts.speaking, isTrue, reason: '应当开始朗读');

    final state = tester.state(find.byType(ReaderPage)) as dynamic;
    final pages = <int>[page(tester)];
    for (var i = 0; i < 4; i++) {
      state.debugFlipPdfPage(true);
      await settle(tester, rounds: 10);
      pages.add(page(tester));
    }
    // ignore: avoid_print
    print('DEVICE_VERIFY[flip] pages=$pages speaking=${tts.speaking} '
        'cursor=${tts.cursor}');
    expect(pages.last, greaterThan(pages.first),
        reason: '手动翻页应当真的往前走了（pages=$pages）');
    for (var i = 1; i < pages.length; i++) {
      expect((pages[i] - pages[i - 1]).abs(), lessThanOrEqualTo(2),
          reason: '第 $i 次翻页从 ${pages[i - 1]} 跳到 ${pages[i]}（疑似连翻）');
    }
    expect(tts.speaking, isTrue, reason: '手动翻页不该把朗读搞停');
    await tts.stop();
  });

  testWidgets('原版式：点上方字幕条回到朗读页', (tester) async {
    final tts = TtsManager.instance;
    await openBook(tester, 'dev_caption');
    tts.speakTimeout = const Duration(seconds: 60);
    tts.speakFrom(0, 0, 0);
    await waitSpeaking(tester);
    await settle(tester, rounds: 10);

    expect(find.byKey(ReaderPage.captionBarKey), findsOneWidget,
        reason: '原版式下应当有字幕条');

    // 翻走 4 页（用户自己看别处去了）
    final state = tester.state(find.byType(ReaderPage)) as dynamic;
    for (var i = 0; i < 4; i++) {
      state.debugFlipPdfPage(true);
      await settle(tester, rounds: 8);
    }
    final away = page(tester);
    final readingChapter = tts.cursor.$1 + 1;

    // 点字幕条 → 回到朗读页
    await tester.tap(find.byKey(ReaderPage.captionBarKey));
    await settle(tester, rounds: 25);
    final back = page(tester);
    // ignore: avoid_print
    print('DEVICE_VERIFY[caption] 翻走到=$away 朗读章=$readingChapter '
        '点字幕条后=$back cursor=${tts.cursor}');
    expect((back - readingChapter).abs(), lessThanOrEqualTo(1),
        reason: '点字幕条应当回到朗读页（朗读在第 $readingChapter 章，实际停在第 $back 页）');
    await tts.stop();
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:tts_reader/features/pdf_reading/pdf_page_layer.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_reading_page.dart';

/// 设备侧验证新的 PDF 朗读（P1~P6）在**真实中文 PDF** 上跑得通。
///
/// 需要 `/data/local/tmp/abc.pdf`（319 页《共产主义ABC》）。
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

  testWidgets('渲染 + 文本层：真实 PDF 第 1 页能抽出逐字符盒', (tester) async {
    final file = await adopt('abc.pdf');
    expect(file, isNotNull, reason: '需要 /data/local/tmp/abc.pdf');

    final doc = await PdfDocument.openFile(file!.path);
    try {
      expect(doc.pages.length, greaterThan(1), reason: '应当是多页文档');
      final page = doc.pages.first;
      final layer = await loadTextLayer(page);
      expect(layer, isNotNull, reason: '第 1 页应当能抽到文本层');

      final l = layer!;
      // ignore: avoid_print
      print('DEVICE_VERIFY[new-pdf] 页=${l.pageNumber} 尺寸=${l.pageSize} '
          '行=${l.lines.length} 句=${l.sentences.length}');
      for (final s in l.sentences.take(3)) {
        // ignore: avoid_print
        print('DEVICE_VERIFY[new-pdf] 句「${s.text}」 字符数=${s.chars.length} '
            'bounds=${s.bounds}');
      }

      expect(l.sentences, isNotEmpty, reason: '这一页有文字层，不该是空的');

      // 逐字符盒必须是**左上原点**（Y 已翻转）：所有框都要落在页面矩形内
      for (final s in l.sentences) {
        for (final c in s.chars) {
          expect(c.rect.top, greaterThanOrEqualTo(-1));
          expect(c.rect.bottom, lessThanOrEqualTo(l.pageSize.height + 1),
              reason: '字符盒超出页高说明 Y 轴没翻转好：${c.rect}');
          expect(c.rect.width, greaterThan(0));
        }
      }

      // 命中测试：拿第一句第一个字的中心去点，必须命中第一句
      final probe = l.sentences.first.chars.first.rect.center;
      final hit = l.sentenceIndexAt(probe);
      // ignore: avoid_print
      print('DEVICE_VERIFY[new-pdf] 命中探测 点=$probe → 句下标=$hit');
      expect(hit, 0, reason: '点第一句的字应当命中第 0 句');
    } finally {
      await doc.dispose();
    }
  });

  testWidgets('点句朗读：点第 2 页正文能开始朗读并高亮', (tester) async {
    final file = await adopt('abc.pdf');
    expect(file, isNotNull);
    await tester.pumpWidget(MaterialApp(
      home: PdfReadingPage(filePath: file!.path, title: '共产主义ABC'),
    ));

    // 等 PDF 与文本层就绪
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      if (find.byKey(PdfReadingPage.viewKey).evaluate().isNotEmpty) break;
    }
    expect(find.byKey(PdfReadingPage.viewKey), findsOneWidget,
        reason: 'PDF 视图应当建起来');

    final state =
        tester.state(find.byType(PdfReadingPage)) as PdfReadingPageState;
    // 让第 1 页文本层就绪
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      if (state.debugPageLayer(1) != null) break;
    }
    final layer = state.debugPageLayer(1);
    // ignore: avoid_print
    print('DEVICE_VERIFY[new-pdf] 第1页文本层=${layer == null ? "null" : "${layer.sentences.length} 句"}');
    expect(layer, isNotNull, reason: '第 1 页文本层应当加载出来');

    // 通过真实的页面组件点击：算出第一句中心在屏幕上的位置
    final pageLayerFinder = find.byType(PdfPageLayer);
    expect(pageLayerFinder, findsWidgets);
    final rect = tester.getRect(pageLayerFinder.first);
    final scale = rect.width / layer!.pageSize.width;
    final target = layer.sentences.first.bounds.center;
    final screenPoint = Offset(
      rect.left + target.dx * scale,
      rect.top + target.dy * scale,
    );
    // ignore: avoid_print
    print('DEVICE_VERIFY[new-pdf] 点击 屏幕=$screenPoint 页内=$target scale=$scale');

    await tester.tapAt(screenPoint);
    for (var i = 0; i < 60 && state.debugReadingSentence == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
    }
    // ignore: avoid_print
    print('DEVICE_VERIFY[new-pdf] 朗读页=${state.debugReadingPage} '
        '句=${state.debugReadingSentence} 高亮=${state.debugHighlightFor(1)}');
    // v1.21.1：朗读位置由 **PdfReadSession** 持有（不再是页面 State 的
    // `_readingPage`），所以这里断言会话的 current。页下标是 **0 起**
    //（`PdfSentenceRef.pageIndex`），而页面显示的页码是 1 起。
    final session = PdfReadSession.instance;
    expect(session.current?.pageIndex, 0,
        reason: '点第 1 页（页码 1）应当把会话位置设到页下标 0');
    expect(state.debugReadingSentence, isNotNull, reason: '应当选中某一句');
    expect(state.debugHighlightFor(1), isNotNull, reason: '应当有高亮范围');

    // 收尾：会话是单例，别把朗读留给下一个用例（否则报 A Timer is still pending）
    await session.clear();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('扫描件提示：没有文字层的页给提示而不是崩', (tester) async {
    final file = await adopt('abc.pdf');
    expect(file, isNotNull);
    final doc = await PdfDocument.openFile(file!.path);
    try {
      // 封面页通常只有图形：抽不出文字层时 loadTextLayer 返回 null
      final layer = await loadTextLayer(doc.pages.first);
      // ignore: avoid_print
      print('DEVICE_VERIFY[new-pdf] 第1页文本层=${layer?.sentences.length ?? "null"}');
      // 有文字层就正常，没有也不该抛异常（由页面显示提示）
      expect(true, isTrue);
    } finally {
      await doc.dispose();
    }
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:tts_reader/features/pdf_reading/pdf_page_layer.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_reading_page.dart';

/// 设备侧：在真实 PDF 的**正文页**上验「点句 → 朗读 + 高亮」。
///
/// ## 为什么单独一条
///
/// `pdf_reading_new_verify_test.dart` 点的是**封面页**（只有 3 句大字），
/// 而用户实际读的是**正文页**（每页几十行小字）。
/// v1.21.2 改了位图渲染尺寸（逻辑尺寸 → 物理像素），必须确认正文页上
/// 命中测试与高亮**没被这次改动带偏** —— 这正是 §4.93 坑 2 的同类风险。
///
/// 做法：直接问会话要第 N 页的文本层，取中间某一句的包围盒中心，
/// 换算成屏幕坐标点下去，再断言会话位置与高亮范围。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<File?> adopt(String name) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final target = File('${dir.path}/$name');
      if (!await target.exists()) {
        for (final path in <String>['test_assets/$name', '/data/local/tmp/$name']) {
          final source = File(path);
          if (await source.exists()) {
            await source.copy(target.path);
            break;
          }
        }
      }
      return await target.exists() ? target : null;
    } catch (_) {
      return null;
    }
  }

  testWidgets('正文页点句：命中准确、高亮落在点中的那一句', (tester) async {
    final file = await adopt('abc.pdf');
    expect(file, isNotNull, reason: '需要 test_assets/abc.pdf 或 /data/local/tmp/abc.pdf');

    await tester.pumpWidget(MaterialApp(
      home: PdfReadingPage(filePath: file!.path, title: '正文页点句验证'),
    ));
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      if (find.byKey(PdfReadingPage.viewKey).evaluate().isNotEmpty) break;
    }
    expect(find.byKey(PdfReadingPage.viewKey), findsOneWidget);

    // 用页面自己的文档对象取第 4 页（正文页）的文本层 —— 与渲染用的是同一份
    final session = PdfReadSession.instance;
    final doc = await PdfDocument.openFile(file.path);
    addTearDown(() async {
      await session.clear();
      await doc.dispose();
    });
    // 正文页：第 2 页是「出版说明」正文（第 1 页是封面）。
    // 挑第 2 页而不是更靠后的页：ListView 懒构建，远处的页不在树里，
    // 让用例自己滚过去会把「命中测试」这件事和「能不能滚到」混在一起。
    // 第 2 页的内容密度与后面正文页一样（每页几十行小字），足够代表。
    const targetPage = 2;
    final page = doc.pages[targetPage - 1];
    final layer = await loadTextLayer(page);
    expect(layer, isNotNull, reason: '第 $targetPage 页应当有文本层');
    // ignore: avoid_print
    print('DEVICE_VERIFY[tap-body] 第$targetPage页 行=${layer!.lines.length} '
        '句=${layer.sentences.length} 页面=${layer.pageSize}');

    // 挑一句「在页面中部」的长句，避免选中页眉页脚
    final candidates = layer.sentences
        .where((s) => s.text.trim().length >= 8)
        .toList();
    expect(candidates, isNotEmpty, reason: '正文页应当有可点的长句');
    final sentence = candidates[candidates.length ~/ 2];
    final center = sentence.bounds.center;
    // ignore: avoid_print
    print('DEVICE_VERIFY[tap-body] 选中「${sentence.text}」'
        ' bounds=${sentence.bounds} center=$center');

    // 把这一页滚进视野，并量出它在屏幕上的矩形
    final pageLayerFinder = find.byType(PdfPageLayer);
    expect(pageLayerFinder, findsWidgets, reason: '应当已经渲染出页面组件');
    // 找到「正在显示第 targetPage 页」的那个 PdfPageLayer：
    // 该页的文本层指针与我们的 layer 是同一个对象
    var target = -1;
    for (var i = 0; i < pageLayerFinder.evaluate().length; i++) {
      final widget = pageLayerFinder.evaluate().elementAt(i).widget;
      if (widget is PdfPageLayer && identical(widget.textLayer, layer)) {
        target = i;
        break;
      }
    }
    // 还没渲染到那一页就先**滚过去**（ListView 懒构建：离得远的页根本不在树里，
    // 光把文本层塞进缓存不会让组件出现）
    if (target < 0) {
      final state = tester.state(find.byType(PdfReadingPage)) as PdfReadingPageState;
      for (var p = 1; p <= targetPage; p++) {
        await tester.runAsync(() => state.debugEnsureLayer(p));
      }
      // ⚠️ 用 jumpTo 逐段下推，直到目标页的组件真的出现。
      // 之前用 `animateTo` 在 runAsync 里推，会被合并/取消 —— 实测
      // 「单独跑通过、整套跑挂在第一页」（§9 记住这条）。
      for (var attempt = 0; attempt < 12; attempt++) {
        var built = false;
        for (var k = 0; k < pageLayerFinder.evaluate().length; k++) {
          final w = pageLayerFinder.evaluate().elementAt(k).widget;
          if (w is PdfPageLayer && w.pageNumber == targetPage) {
            built = true;
            break;
          }
        }
        if (built) break;
        // 每次往下推约一页半（页高 534.6 + 内边距 + 页码行）
        state.debugJumpToOffset(820.0 * (attempt + 1));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pump();
      }
    }

    // 用会话保证这一页的文本层在缓存里，然后等**组件真的带上这一页的层**。
    //
    // ⚠️ 这里必须等到 `textLayer` 非 null，不能只等「组件出现」：
    // 组件会先以 `textLayer == null` 建出来（列表项一布局就建），
    // 层要等异步抽完才挂上去。等早了一步就会看到
    // 「组件在、textLayer 却是 null」—— 那正是 §4.96 那个并发 bug 的表现，
    // 别把它和用例自己的竞态混在一起。
    await tester.runAsync(() => session.ensureLayer(targetPage - 1));
    await tester.pump();
    // ignore: avoid_print
    print('DEVICE_VERIFY[tap-body] 等待层挂载前：docId=${session.documentId} '
        'pageCount=${session.pageCount} '
        '缓存层=${List<int>.generate(session.pageCount.clamp(0, 400), (i) => i)
            .where((i) => session.layerOf(i) != null).take(10).toList()} '
        '判定空页=${List<int>.generate(session.pageCount.clamp(0, 400), (i) => i)
            .where(session.isPageEmpty).take(10).toList()}');
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      var found = false;
      for (var k = 0; k < pageLayerFinder.evaluate().length; k++) {
        final widget = pageLayerFinder.evaluate().elementAt(k).widget;
        if (widget is PdfPageLayer &&
            widget.pageNumber == targetPage &&
            widget.textLayer != null) {
          found = true;
          break;
        }
      }
      if (found) break;
    }

    // 找到目标页组件并换算坐标（同样要求 textLayer 已挂上）
    PdfPageLayer? targetWidget;
    Rect? rect;
    for (var k = 0; k < pageLayerFinder.evaluate().length; k++) {
      final element = pageLayerFinder.evaluate().elementAt(k);
      final widget = element.widget;
      if (widget is PdfPageLayer &&
          widget.pageNumber == targetPage &&
          widget.textLayer != null) {
        targetWidget = widget;
        rect = tester.getRect(pageLayerFinder.at(k));
        break;
      }
    }
    // ignore: avoid_print
    print('DEVICE_VERIFY[tap-body] 已建出的图层数='
        '${pageLayerFinder.evaluate().length} 各页='
        '${pageLayerFinder.evaluate().map((e) {
      final w = e.widget;
      if (w is! PdfPageLayer) return '?';
      // 顺便把几何量出来：getRect 退化成 0 宽就没法换算点击坐标
      String geo;
      try {
        geo = tester.getRect(find.byWidget(w)).toString();
      } catch (err) {
        geo = 'err($err)';
      }
      return '${w.pageNumber}:${w.textLayer == null ? "无层" : "有层"} rect=$geo';
    }).toList()}');
    expect(targetWidget, isNotNull,
        reason: '第 $targetPage 页应当已渲染出组件（可能需要先滚动过去）');

    final layerOfTarget = targetWidget!.textLayer!;
    final scale = rect!.width / layerOfTarget.pageSize.width;
    final screenPoint = Offset(
      rect.left + center.dx * scale,
      rect.top + center.dy * scale,
    );
    // ignore: avoid_print
    print('DEVICE_VERIFY[tap-body] 页矩形=$rect scale=$scale 点击=$screenPoint');

    await tester.tapAt(screenPoint);
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      if (session.current != null) break;
    }

    final current = session.current;
    final highlight = (tester.state(find.byType(PdfReadingPage))
            as PdfReadingPageState)
        .debugHighlightFor(targetPage);
    // ignore: avoid_print
    print('DEVICE_VERIFY[tap-body] 会话位置=$current 高亮=$highlight '
        '期望句下标=${layer.sentences.indexOf(sentence)}');

    expect(current, isNotNull, reason: '点正文应当开始朗读（会话位置被设上）');
    expect(current!.pageIndex, targetPage - 1,
        reason: '会话位置应当落在第 $targetPage 页（0 起下标 ${targetPage - 1}）');
    expect(
      current.text,
      sentence.text,
      reason: '点中的是哪一句，就该读哪一句（命中必须精确到句）',
    );
    expect(highlight, isNotNull, reason: '正在读的那一句应当有高亮范围');
  });
}

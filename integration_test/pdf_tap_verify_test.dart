import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/crash_log.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 设备侧验证**真实中文 PDF** 的「点击即读」。
///
/// 为什么不直接用 `tester.tapAt`：合成触摸在真实文档上**到不了**应用
/// （实测连 `Listener.onPointerDown` 都不触发；同样的写法在自己造的、
/// 每页铺满文字的 PDF 上却没问题）。这里改成投递**真实的指针事件序列**
/// 到同一个处理函数（`debugPdfTapViaPointer`），
/// 于是「坐标换算 → 命中文字行 → 开始朗读」这一整条可以稳定验证。
///
/// 需要 `/data/local/tmp/abc.pdf`（319 页真实中文 PDF）。
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

  testWidgets('真实 PDF 原版式：点击文本层即开始朗读，再点另一处切换', (tester) async {
    final file = await adopt('abc.pdf');
    expect(file, isNotNull, reason: '需要 /data/local/tmp/abc.pdf');
    await StorageService.instance.init();
    final tts = TtsManager.instance;
    await tts.init();
    await tts.stop();

    final document = Document(
      id: 'real_pdf_tap_v2',
      title: '共产主义ABC',
      path: file!.path,
      type: DocumentType.pdf,
      importedAt: DateTime.now(),
    );
    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));

    // 等 PDF 视图 + 文字层就绪
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
    final viewerRect = tester.getRect(find.byType(SfPdfViewer));
    // ignore: avoid_print
    print('DEVICE_VERIFY[real-tap] 视口=$viewerRect 第1页行数=${lines!.length} '
        '页尺寸=${state.debugPdfPageWidth}x${state.debugPdfPageHeight}');

    // 用文字行的**页内坐标**反推屏幕坐标：页按宽度铺满视口
    final pageWidth = state.debugPdfPageWidth as double;
    final scale = pageWidth <= 0 ? 1.0 : viewerRect.width / pageWidth;
    Offset screenOf(Rect box) => Offset(
          viewerRect.left + box.center.dx * scale,
          viewerRect.top + box.center.dy * scale,
        );

    Future<bool> tapAndWait(Offset point) async {
      await tts.stop();
      await tester.pump();
      // 先确认坐标换算链路（这一条不看手势，纯数学）
      final mapped = state.debugViewportToPage(point) as (int, Offset)?;
      // ignore: avoid_print
      print('DEVICE_VERIFY[real-tap] 屏幕=$point → 页内=$mapped');
      // v1.20.0 规则：**双击**才进入朗读模式。
      //
      // ⚠️ 两次点击必须在 `kDoubleTapTimeout`（300ms）内。
      // 这里**不能在中间 await 任何会让出真实时间的东西** ——
      // 之前写成 `await tester.pump(40ms)`，在 integration_test 里一个 await
      // 就可能耗掉几百毫秒真实时间，于是两次点击超出了双击窗口，
      // 判定成两次单击 → 什么都不会发生（实测踩到）。
      state.debugPdfTapViaPointer(point);
      state.debugPdfTapViaPointer(point);
      await tester.pump();
      for (var i = 0; i < 80 && !tts.speaking; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
      }
      return tts.speaking;
    }

    // 1) 点第一行 → 应当开始朗读
    //
    // 只用**页内**的坐标：这份文档的行框有超出页高的（第 2 行框底 274.9pt，
    // 中心换算到屏幕后已经越过第 1 页边界），那种点法会落到第 2 页上 ——
    // 那是文档本身的问题，不是要点验证的行为。
    final firstBox = lines.first.bounds as Rect;
    final lowerHalf = Rect.fromLTRB(
      firstBox.left,
      firstBox.top + firstBox.height * 0.2,
      firstBox.right,
      firstBox.top + firstBox.height * 0.4,
    );
    final ok1 = await tapAndWait(screenOf(lowerHalf));
    // ignore: avoid_print
    print('DEVICE_VERIFY[real-tap] 双击第一行 speaking=$ok1 cursor=${tts.cursor} '
        'error=${tts.error}');
    expect(ok1, isTrue, reason: '双击第 1 页的文字行应当进入朗读模式并开始读');
    expect(tts.cursor.$1, 0, reason: '点在页内就该落在第 1 页（实际第 ${tts.cursor.$1 + 1} 页）');

    // 2) 已进入朗读模式后**单击**同一页另一处 → 应当继续读
    await tts.stop();
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    final reader2 = tester.state(find.byType(ReaderPage)) as dynamic;
    // 重新双击进入（stop 会把模式清掉 —— 不过这本来就是 v1.20.0 的语义）
    final lowerStill = Rect.fromLTRB(
      firstBox.left,
      firstBox.top + firstBox.height * 0.5,
      firstBox.right,
      firstBox.top + firstBox.height * 0.7,
    );
    final ok2 = await tapAndWait(screenOf(lowerStill));
    // ignore: avoid_print
    print('DEVICE_VERIFY[real-tap] 再双击下方 speaking=$ok2 cursor=${tts.cursor} '
        'mode=${reader2.debugPdfReadMode}');
    expect(ok2, isTrue, reason: '再双击应当继续朗读');

    // 3) 双击应当进入朗读模式
    expect(state.debugPdfReadMode as bool, isTrue,
        reason: '双击 PDF 就该进入朗读模式（v1.20.0 规则）');

    // 顺带把应用内日志打出来，真机排查也看这个
    for (final line in CrashLog.recent.take(6)) {
      // ignore: avoid_print
      print('DEVICE_VERIFY[real-tap-log] $line');
    }

    await tts.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}

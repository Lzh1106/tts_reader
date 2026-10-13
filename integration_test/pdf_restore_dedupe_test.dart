import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tts_reader/features/pdf_reading/pdf_reading_page.dart';

/// **「恢复位置」重复下发不再被误判成连续快速翻页**（v1.21.37 修，设备侧）
///
/// ## 修的是什么
///
/// 真机诊断日志（v1.21.36+87）报了红：`R6 连续快速翻页 x3`，上下文是
/// `turn seq=24..28 16->15 trigger=恢复位置`，5 条挤在 **2 毫秒**内，
/// 而且第 2~5 条的 `elapsedSinceLastTurnMs` 全是 **0**。
///
/// 也就是说：**用户并没有连翻页** —— 是"恢复位置"这一条指令在**同一帧内**
/// 被重复下发了 5 次，每次 `attempt == 0` 都记一笔翻页事件，
/// 于是判据 R6（间隔 <500ms 连续 ≥3 次）把它当成"连续快速翻页"。
///
/// 修法：`_revealToPageIndex` 里对**同一次收敛窗口内的同一目标页**去重
/// （见那里的注释）。这条用例守的就是"只记一笔"。
///
/// 为什么必须设备上跑：`PdfReadingPage` 要真 PDF 才能建 `ListView` 与页块，
/// 纯 widget 测试里 `pdfrx` 起不来。
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

  testWidgets('同一目标页重复进入「恢复位置」：只记一笔翻页事件（不再触发 R6）',
      (tester) async {
    final file = await adopt('abc.pdf');
    expect(file, isNotNull,
        reason: '需要 /data/local/tmp/abc.pdf（用 adb push 放一份）');

    await tester.pumpWidget(MaterialApp(
      home: PdfReadingPage(filePath: file!.path, title: '恢复位置去重验证'),
    ));
    // 等 PDF 与页块就绪（与其它设备用例同一套等待方式）
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      if (find.byKey(PdfReadingPage.viewKey).evaluate().isNotEmpty) break;
    }
    expect(find.byKey(PdfReadingPage.viewKey), findsOneWidget,
        reason: 'PDF 视图应当建起来');

    final PdfReadingPageState state =
        tester.state(find.byType(PdfReadingPage)) as PdfReadingPageState;

    // 第 3 页（下标 2）：既不是当前页（0），也不是相邻页，确保真的会走定位
    const int target = 2;
    final int before = state.debugTurnEventCount();
    // 模拟"同一帧内被重复下发 5 次"（真机日志里的样子）
    await tester.runAsync(() async {
      state.debugRevealPageRepeatedly(target, times: 5);
    });
    // 让收敛链与去重窗口的清理跑起来
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    final int after = state.debugTurnEventCount();
    final int recorded = after - before;

    // ignore: avoid_print
    print('DEVICE_VERIFY[restore-dedupe] 重复下发 5 次 → 记录 $recorded 笔 '
        '（before=$before after=$after）'
        ' displayedPage=${state.debugDisplayedPage()} '
        'scrollPixels=${state.debugScrollPixels().toStringAsFixed(1)}');

    expect(recorded, greaterThanOrEqualTo(1),
        reason: '「恢复位置」本身要留下记录（否则诊断看不到这次定位）');
    expect(recorded, lessThanOrEqualTo(2),
        reason: '同一次定位最多记 1~2 笔；5 笔说明同帧重复下发又回来了'
            '（真机 R6 红就是这么来的）');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });
}

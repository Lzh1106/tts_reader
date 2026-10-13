import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/features/pdf_reading/pdf_reading_page.dart';
import 'package:tts_reader/pages/settings_page.dart';
import 'package:tts_reader/services/crash_log.dart';
import 'package:tts_reader/services/speech_diag_export.dart';
import 'package:tts_reader/services/speech_diagnostics.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 朗读诊断正式版（v1.21.13 任务 B）的**设备侧**验证。
///
/// 交接文档 ⑤ 里列的三条「手工确认」在这里落成可复现的断言：
///   ① 设置页开关：每次都弹确认框、取消回退关、关闭不弹
///   ② PDF 原版式页：开启后指示灯在**左下角**（右下角是「回到朗读位置」FAB），
///      关闭时零尺寸不占布局
///   ③ 导出落 `app_flutter/speech_diag/` 子目录、首行 `speech_diag_v1`；
///      滚动落盘同目录；复制走真实 Android 剪贴板
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
  });

  tearDown(() async {
    await StorageService.instance.setSpeechDiagEnabled(false);
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<TtsManager>.value(
        value: TtsManager.instance,
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder speechDiagTile() => find.ancestor(
        of: find.text('朗读诊断（跳动检测）'),
        matching: find.byType(SwitchListTile),
      );

  /// 设置页是长列表，「朗读诊断」卡片在下面，先滚到它。
  Future<void> revealTile(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.text('朗读诊断（跳动检测）'),
      260,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 60,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('① 开关每次都弹确认框；取消 → 回退关；关闭不弹', (tester) async {
    await pumpSettings(tester);
    await revealTile(tester);

    final Finder tile = speechDiagTile();
    expect(tile, findsOneWidget, reason: '设置页必须有「朗读诊断（跳动检测）」开关');
    expect(StorageService.instance.speechDiagEnabled.value, isFalse,
        reason: '默认必须是关');

    // ---- 第一次点开：必须弹确认框 ----
    await tester.tap(tile);
    await tester.pumpAndSettle();
    final Finder dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget, reason: '点开开关必须弹确认框');
    expect(
      find.descendant(of: dialog, matching: find.text('开启朗读诊断？')),
      findsOneWidget,
    );

    // 取消 → 回退到关
    await tester.tap(find.descendant(of: dialog, matching: find.text('取消')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(StorageService.instance.speechDiagEnabled.value, isFalse,
        reason: '未确认必须回退到关');

    // ---- 第二次点开：**仍然**要弹（不做「首次只弹一次」优化）----
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget,
        reason: '每次都弹，不缓存「已确认」');
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('开启')),
    );
    await tester.pumpAndSettle();
    expect(StorageService.instance.speechDiagEnabled.value, isTrue,
        reason: '确认后必须真的开');

    // ---- 关闭：不弹窗 ----
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing, reason: '关闭不弹窗');
    expect(StorageService.instance.speechDiagEnabled.value, isFalse);

    // ignore: avoid_print
    print('DEVICE_VERIFY[diag-switch] 三次点击：弹/取消回退关/再弹并确认开/关闭不弹 → 全通过');
  });

  testWidgets('② PDF 原版式页：指示灯在左下角，关闭时零尺寸', (tester) async {
    // abc.pdf 从 /data/local/tmp 搬进应用文档目录（与既有 PDF 用例一致）
    final File src = File('/data/local/tmp/abc.pdf');
    expect(src.existsSync(), isTrue, reason: '需要 /data/local/tmp/abc.pdf');
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory books = Directory('${base.path}/books');
    if (!books.existsSync()) await books.create(recursive: true);
    final File pdf = File('${books.path}/abc.pdf');
    await src.copy(pdf.path);

    final Finder diagFab = find.byWidgetPredicate(
      (Widget w) =>
          w is FloatingActionButton &&
          w.heroTag == 'speech-diag-indicator-pdf',
    );

    // ---- 关闭状态：不该有指示灯 ----
    await tester.pumpWidget(
      MaterialApp(home: PdfReadingPage(filePath: pdf.path, title: '共产主义ABC')),
    );
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      if (find.byKey(PdfReadingPage.viewKey).evaluate().isNotEmpty) break;
    }
    expect(find.byKey(PdfReadingPage.viewKey), findsOneWidget,
        reason: 'PDF 视图应当建起来');
    expect(diagFab, findsNothing, reason: '诊断默认关 → 不挂指示灯（零尺寸）');

    // ---- 开启：指示灯出现，且在左半屏 ----
    await StorageService.instance.setSpeechDiagEnabled(true);
    await tester.pumpAndSettle();
    expect(diagFab, findsOneWidget, reason: '开启后 PDF 原版式页必须有指示灯');

    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final Rect rect = tester.getRect(diagFab);
    // ignore: avoid_print
    print('DEVICE_VERIFY[diag-pdf] 指示灯 rect=$rect 屏幕=$screen');
    expect(rect.center.dx, lessThan(screen.width / 2),
        reason: '指示灯必须在**左**半屏（右下角是「回到朗读位置」FAB 的地盘）');
    expect(rect.bottom, greaterThan(screen.height / 2),
        reason: '指示灯应当贴在底部区域');

    // 若「回到朗读位置」也在，两者不得相交
    final Finder backFab = find.byKey(PdfReadingPage.backToReadingKey);
    if (backFab.evaluate().isNotEmpty) {
      final Rect backRect = tester.getRect(backFab);
      // ignore: avoid_print
      print('DEVICE_VERIFY[diag-pdf] 回到朗读位置 rect=$backRect');
      expect(rect.overlaps(backRect), isFalse, reason: '两个按钮不得重叠');
    } else {
      // ignore: avoid_print
      print('DEVICE_VERIFY[diag-pdf] 「回到朗读位置」本轮未出现（未滚动离开朗读位置）'
          '→ 只断言指示灯在左半屏；Scaffold FAB 固定右下，几何上不可能重叠');
    }

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('③ 导出落 speech_diag 子目录、首行 schema、滚动文件同目录、复制走真实剪贴板',
      (tester) async {
    // 造一点事件，免得导出是空文件
    final SpeechDiagnostics diag = SpeechDiagnostics.instance;
    diag.clear();
    final DateTime t0 = DateTime.now();
    diag.speakEvents.add(
      SpeakEvent(
        seq: 1,
        epoch: 1,
        textPrefix: '设备侧导出的第一句',
        issuedAt: t0,
        cursorBefore: '0:0:0',
        doneAt: t0.add(const Duration(milliseconds: 900)),
        durationMs: 900,
        ok: true,
      ),
    );
    diag.advanceEvents.add(
      AdvanceEvent(
        seq: 2,
        cursorBefore: '0:0:0',
        cursorAfter: '0:0:1',
        delta: 1,
        source: '自动',
        epoch: 1,
        at: t0.add(const Duration(milliseconds: 950)),
      ),
    );

    final String dir = await SpeechDiagExport.dirPath();
    // ignore: avoid_print
    print('DEVICE_VERIFY[diag-export] dir=$dir');

    final SpeechDiagWriteResult result =
        await SpeechDiagExport.writeFile(includeAllEvents: true);
    // ignore: avoid_print
    print('DEVICE_VERIFY[diag-export] 导出 path=${result.path} '
        'lines=${result.lines} size=${result.sizeText}');

    expect(result.path, contains('/speech_diag/'),
        reason: '必须落在 app_flutter/speech_diag/ 子目录里');
    expect(result.path, endsWith('.log'));
    final File file = File(result.path);
    expect(file.existsSync(), isTrue, reason: '文件必须真的写出来了');

    final List<String> lines = await file.readAsLines();
    expect(lines.first, 'speech_diag_v1', reason: '首行必须是 schema 版本号');
    expect(lines.length, result.lines, reason: '写出的行数要和返回的一致');
    expect(lines.any((String l) => l.startsWith('app_version=1.21.')), isTrue,
        reason: 'meta 里要带着本次发布版本号');
    expect(lines.contains('[events]'), isTrue, reason: '勾了全量就该有事件段');

    // 滚动落盘文件同目录
    final SpeechDiagWriteResult rolling = await SpeechDiagExport.writeRolling();
    expect(rolling.path, endsWith('/speech_diag/speech_diag.log'));
    expect(File(rolling.path).existsSync(), isTrue);

    // 真实 Android 剪贴板
    final SpeechDiagCopyResult copy =
        await SpeechDiagExport.copyToClipboard(includeAllEvents: false);
    // ignore: avoid_print
    print('DEVICE_VERIFY[diag-export] 剪贴板 ${copy.message}');
    expect(copy.bytes, greaterThan(0));
    expect(copy.truncated, isFalse, reason: '这么小的诊断不该被截断');
  });

  testWidgets('④ 诊断日志导出成文件：不抛异常、内容非空（v1.21.19）', (tester) async {
    // 先写两行，保证日志里一定有东西
    CrashLog.mark('导出用例：打点一');
    CrashLog.mark('导出用例：打点二');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final SpeechDiagWriteResult? result =
        await SpeechDiagExport.exportCrashLog();
    // ignore: avoid_print
    print('DEVICE_VERIFY[crash-export] 结果=${result?.path ?? "null"} '
        '行数=${result?.lines ?? -1} 体积=${result?.sizeText ?? "-"}');

    expect(result, isNotNull, reason: '导出必须成功（失败会返回 null，UI 提示而不崩）');
    expect(result!.path, contains('/speech_diag/crash_'));
    final File file = File(result.path);
    expect(file.existsSync(), isTrue);
    expect(await file.length(), greaterThan(0));
    final String text = await file.readAsString();
    expect(text.contains('导出用例：打点二'), isTrue,
        reason: '导出的内容必须是当前日志（含刚写的两行）');
  });
}

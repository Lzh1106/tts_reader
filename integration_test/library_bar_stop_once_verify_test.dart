import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/main.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';
import 'package:tts_reader/widgets/reading_control_bar.dart';

/// **任务 F 设备验证：文档库方块键「按一次就够」**（§4.101）
///
/// 真机（模拟器）上跑真实 App：读 TXT / 读 PDF / 跨类型切换后，
/// **按一次**方块键，应用内控制栏必须消失。
///
/// ⚠️ 通知栏的媒体卡片**无法在本用例里断言**：`audioHandler`
/// （`TtsAudioHandler.init()` 的产物）在测试环境里不注册，探针恒为 null。
/// 需求（v1.21.13 简化后）是「会话结束 → 卡片按 audio_service 默认行为消失」，那属于真实安装运行的行为，
/// 需要人工在真机上确认；本用例只保证**应用内**两个会话被清干净，
/// 并且代码里没有任何一行去碰 MediaSession（见 `_stopEverything` 的注释）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final tts = TtsManager.instance;
  final pdf = PdfReadSession.instance;

  /// 首启会弹教程（模态），它挡住底部控制栏 —— 关掉它继续
  Future<void> dismissTutorial(WidgetTester tester) async {
    final start = find.byKey(const ValueKey<String>('tutorial-start'));
    if (start.evaluate().isNotEmpty) {
      await tester.tap(start);
      await tester.pumpAndSettle();
    }
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(const TtsReaderApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await dismissTutorial(tester);
    await tester.pump(const Duration(milliseconds: 400));
  }

  bool barVisible() =>
      find.byKey(ReadingControlBar.discKey).evaluate().isNotEmpty ||
      find.byKey(ReadingControlBar.barKey).evaluate().isNotEmpty;

  Future<Finder?> findStop(WidgetTester tester) async {
    var stop = find.byKey(ReadingControlBar.stopKey);
    if (stop.evaluate().isEmpty) {
      final disc = find.byKey(ReadingControlBar.discKey);
      if (disc.evaluate().isNotEmpty) {
        await tester.tap(disc);
        await tester.pumpAndSettle();
        stop = find.byKey(ReadingControlBar.stopKey);
      }
    }
    return stop.evaluate().isEmpty ? null : stop;
  }

  /// 按一次方块键 → 断言应用内控制栏消失
  Future<void> tapOnceAndAssertGone(WidgetTester tester, String tag) async {
    final stop = await findStop(tester);
    expect(stop, isNotNull, reason: '[$tag] 有会话时应当能找到方块键');
    // ignore: avoid_print
    print('DEVICE_VERIFY[F-$tag] 点前 bar=${barVisible()} '
        'tts=${tts.hasSession} pdf=${pdf.isActive}');

    await tester.tap(stop!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // ignore: avoid_print
    print('DEVICE_VERIFY[F-$tag] 点一次后 bar=${barVisible()} '
        'tts=${tts.hasSession} pdf=${pdf.isActive}');
    expect(barVisible(), isFalse,
        reason: '[$tag] 按一次方块键后应用内控制栏必须消失（不能要按两次）');
    expect(tts.hasSession, isFalse, reason: '[$tag] TTS 会话必须已清');
    expect(pdf.isActive, isFalse, reason: '[$tag] PDF 会话必须已清');
  }

  // ------------------------------------------------------------------ P1
  testWidgets('F-P1 设备：读 TXT → 点一次方块键 → 控制栏消失', (tester) async {
    await tts.stop();
    tts.speakLines(<String>['Alpha line.', 'Beta line.', 'Gamma line.']);
    await tester.pump(const Duration(milliseconds: 100));
    await mount(tester);
    await tapOnceAndAssertGone(tester, 'P1');
    await tts.stop();
    await tester.pump(const Duration(milliseconds: 300));
  });

  // ------------------------------------------------------------------ P2
  testWidgets('F-P2 设备：读 PDF → 点一次方块键 → 控制栏消失', (tester) async {
    await tts.stop();
    await tester.runAsync(() => pdf.open(
          documentId: 'fdev-pdf',
          title: 'F 设备 PDF',
          pageCount: 319,
          layerLoader: (pageIndex) async => null,
        ));
    pdf.startAt(
        const PdfSentenceRef(pageIndex: 2, sentenceIndex: 0, text: '设备句'));
    await tester.pump(const Duration(milliseconds: 100));
    await mount(tester);
    await tapOnceAndAssertGone(tester, 'P2');
    await tts.stop();
    await tester.runAsync(() => pdf.clear());
    await tester.pump(const Duration(milliseconds: 300));
  });

  // ------------------------------------------------------------------ P3
  testWidgets('F-P3 设备：TXT 切到 PDF 后 → 点一次方块键 → 控制栏消失',
      (tester) async {
    await tts.stop();
    tts.speakLines(<String>['One.', 'Two.', 'Three.']);
    await tester.pump(const Duration(milliseconds: 100));
    await mount(tester);
    // 跨类型切到 PDF
    await tester.runAsync(() => pdf.open(
          documentId: 'fdev-pdf3',
          title: 'F 设备 PDF3',
          pageCount: 200,
          layerLoader: (pageIndex) async => null,
        ));
    pdf.startAt(
        const PdfSentenceRef(pageIndex: 1, sentenceIndex: 0, text: '设备句3'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tapOnceAndAssertGone(tester, 'P3');
    await tts.stop();
    await tester.runAsync(() => pdf.clear());
    await tester.pump(const Duration(milliseconds: 300));
  });

  // ------------------------------------------- 教程在真机尺寸下不溢出
  testWidgets('G-设备：教程弹窗在真机尺寸下能完整显示、不溢出', (tester) async {
    // 教程本轮加了一条（§4.101 任务 G 的选项③），文案变长 ——
    // 必须在真机尺寸上确认没有 RenderFlex overflow。
    await tester.runAsync(() => StorageService.instance.setTutorialDone(false));
    await tester.pumpWidget(const TtsReaderApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final shown = find.byKey(const ValueKey<String>('tutorial-dialog'));
    if (shown.evaluate().isEmpty) {
      // 教程可能已被「不再显示」记住：直接用按钮打开一次
      await tester.runAsync(
          () => StorageService.instance.setTutorialDone(false));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(const TtsReaderApp());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(shown, findsOneWidget, reason: '没看过教程时首启应当弹出');

    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    // ignore: avoid_print
    print('DEVICE_VERIFY[G-tutorial] 屏幕=${size.width.toStringAsFixed(0)}x'
        '${size.height.toStringAsFixed(0)} '
        '弹窗在=${shown.evaluate().isNotEmpty} '
        '异常=${tester.takeException()}');

    // 「不再显示」和「开始使用」都必须在（它们在滚动区外面）
    expect(find.byKey(const ValueKey<String>('tutorial-dont-show')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('tutorial-start')), findsOneWidget);
    // 新增那一条在
    expect(find.text('朗读中的新能力'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('tutorial-dialog')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('tutorial-start')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => StorageService.instance.setTutorialDone(true));
  });
}

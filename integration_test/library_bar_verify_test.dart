import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tts_reader/main.dart';
import 'package:tts_reader/tts/tts_manager.dart';
import 'package:tts_reader/widgets/reading_control_bar.dart';

/// 设备层验证：**文档库底部可折叠朗读控制栏**
///
/// 用真实系统 TTS 起一个纯文本朗读会话（不用文件、不用解析），
/// 然后在真机上确认：碟片出现 → 点开成控制栏 → 按钮在「导入文件」左侧 → 能收起。
///
/// 跑法：flutter test integration_test/library_bar_verify_test.dart -d emulator-5554
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final tts = TtsManager.instance;

  /// 轮询等待条件成立（真机上朗读状态是异步的，且要跑真实时间）
  Future<bool> waitFor(
    WidgetTester tester,
    bool Function() condition, {
    int tries = 60,
  }) async {
    for (var i = 0; i < tries; i++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      if (condition()) return true;
    }
    return false;
  }

  testWidgets('文档库：碟片收起 → 点开成控制栏 → 在导入按钮左侧', (tester) async {
    await tts.stop();
    addTearDown(() async {
      await tts.stop();
    });

    // 起一个纯文本会话：真实系统 TTS 会真的读出来
    tts.speakLines(<String>[
      'The wind rose before dawn.',
      'Nobody was on the road that morning.',
    ]);

    await tester.pumpWidget(const TtsReaderApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 首次启动会弹使用教程（模态），它会挡住底部控制栏。
    // 这个用例测的是控制栏，所以把教程关掉（教程本身由
    // `test/tutorial_dialog_test.dart` 覆盖）。
    final tutorial = find.byKey(const ValueKey<String>('tutorial-start'));
    if (tutorial.evaluate().isNotEmpty) {
      await tester.tap(tutorial);
      await tester.pumpAndSettle();
    }

    // 1) 收起态：碟片出现
    // 用 Key 找碟片：tooltip 会随播放状态变（读完了就变成「已暂停」）
    final disc = find.byKey(ReadingControlBar.discKey);
    final discShown = await waitFor(tester, () => disc.evaluate().isNotEmpty);
    expect(discShown, isTrue, reason: '开始朗读后底部应当出现碟片');
    // 空库时页面上有两个「导入文件」（空状态按钮 + 悬浮按钮），要指名取悬浮按钮
    final fab = find.widgetWithText(FloatingActionButton, '导入文件');
    final discX = tester.getCenter(disc).dx;
    final fabX = tester.getCenter(fab).dx;
    // ignore: avoid_print
    print('DEVICE_VERIFY[bar] 收起：碟片 x=$discX 导入按钮 x=$fabX');
    expect(discX, lessThan(fabX), reason: '碟片应当在「导入文件」左侧');
    expect(find.byIcon(Icons.play_arrow), findsNothing, reason: '收起时不该有控制按钮');

    // 2) 点碟片展开
    await tester.tap(disc);
    await tester.pumpAndSettle();
    for (final icon in <IconData>[
      Icons.play_arrow,
      Icons.fast_forward,
      Icons.my_location,
      Icons.stop,
      Icons.chevron_right,
    ]) {
      expect(find.byIcon(icon), findsOneWidget, reason: '展开后应当有 ${icon.codePoint} 这个按钮');
    }
    final playX = tester.getCenter(find.byIcon(Icons.play_arrow)).dx;
    final stopX = tester.getCenter(find.byIcon(Icons.stop)).dx;
    final chevronX = tester.getCenter(find.byIcon(Icons.chevron_right)).dx;
    // ignore: avoid_print
    print('DEVICE_VERIFY[bar] 展开：播放 x=$playX 停止 x=$stopX 收起 x=$chevronX '
        '导入按钮 x=$fabX 标题行=${find.text('未命名文档').evaluate().length}');
    expect(playX, lessThan(stopX), reason: '播放应当在停止左边');
    expect(chevronX, lessThan(fabX), reason: '整条控制栏都要在「导入文件」左侧');
    expect(find.text('未命名文档'), findsOneWidget, reason: '纯文本会话没有书名，用占位标题');

    // 3) 让界面停在展开态，方便宿主截图
    // ignore: avoid_print
    print('DEVICE_VERIFY[bar] READY_FOR_SCREENSHOT');
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 6)));
    await tester.pump();

    // 4) 收起：回到碟片
    // （先做收起、后测「返回朗读页」—— 那条会弹 SnackBar，正好盖住底部控制栏）
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fast_forward), findsNothing);
    final collapsed = await waitFor(tester, () => disc.evaluate().isNotEmpty);
    expect(collapsed, isTrue, reason: '收起后应当回到碟片');
    // ignore: avoid_print
    print('DEVICE_VERIFY[bar] 收起完成，碟片 x=${tester.getCenter(disc).dx}');
    // 停一下让宿主截一张「碟片」的图
    // ignore: avoid_print
    print('DEVICE_VERIFY[bar] READY_FOR_SCREENSHOT_COLLAPSED');
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 5)));
    await tester.pump();

    // 5) 再展开，「返回朗读页」：纯文本会话没有阅读页，应当给提示而不是崩
    await tester.tap(disc);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.my_location));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('当前朗读的是文本片段，没有对应的阅读页'), findsOneWidget);
    // ignore: avoid_print
    print('DEVICE_VERIFY[bar] 返回朗读页给出提示（纯文本会话）');

    // 6) 停止后按钮回到「播放」：会话还留着（可以接着读），但不再是朗读中
    await tts.stop();
    await tester.pump();
    final stopped = await waitFor(
      tester,
      () => !tts.speaking && find.byIcon(Icons.play_arrow).evaluate().isNotEmpty,
    );
    expect(stopped, isTrue, reason: '停止后应当停在「播放」状态，会话仍可继续');
    // ignore: avoid_print
    print('DEVICE_VERIFY[bar] 停止后仍保留控制栏（播放按钮可继续）');
  });
}

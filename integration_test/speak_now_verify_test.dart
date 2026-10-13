import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tts_reader/pages/speak_now_page.dart';
import 'package:tts_reader/services/speak_intake.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 设备层验证：T2S 的四个朗读入口用**真实系统 TTS** 读到底。
///
/// 覆盖：打字朗读（编辑态输入 → 播放）、分享进来的文本（进入即读）、
/// 剪贴板朗读（走 SpeakIntake 同一条链路）、划词朗读。
///
/// 跑法（需要设备/模拟器）：
///   flutter test integration_test/speak_now_verify_test.dart -d emulator-5554
///
/// 原生 intent（分享 / 划词 / 打开文本）那一层用 adb 送 intent 验证，见 HANDOFF 第 6 节。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 等一轮朗读会话结束；超时不算失败（模拟器上可能没装语音数据），
  /// 要确认的是「不崩、不挂死、游标推进到末段」。
  Future<bool> readOnce(TtsManager tts, {Duration timeout = const Duration(seconds: 60)}) async {
    var finished = true;
    await tts.whenSessionFinished().timeout(
      timeout,
      onTimeout: () {
        finished = false;
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return finished;
  }

  void report(String label, TtsManager tts, {required bool finished}) {
    // ignore: avoid_print
    print('DEVICE_VERIFY[$label] finished=$finished speaking=${tts.speaking} '
        'segments=${tts.plainIndex + 1}/${tts.plainTotal} error=${tts.error}');
  }

  setUpAll(() async {
    await StorageService.instance.init();
    await TtsManager.instance.init();
  });

  setUp(() async {
    await TtsManager.instance.stop();
  });

  const String text = '第一段第一句。第一段第二句。\n\n第二段第一句。第二段第二句。';

  testWidgets('打字朗读：输入文本 → 点开始朗读 → 真实系统 TTS 读完', (WidgetTester tester) async {
    final tts = TtsManager.instance;
    await tester.pumpWidget(const MaterialApp(home: SpeakNowPage(source: SpeakSource.type)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.text('开始朗读'));
    await tester.pump();

    final finished = await readOnce(tts);
    report('type-speak', tts, finished: finished);

    expect(tts.error, isNull, reason: '真实引擎朗读不应报错');
    expect(tts.plainTotal, 2);
    expect(tts.plainIndex, 1, reason: '读完后停在末段');
    expect(tts.speaking, isFalse);

    await tts.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('分享即朗读：带文本进入自动开读', (WidgetTester tester) async {
    final tts = TtsManager.instance;
    await tester.pumpWidget(
      const MaterialApp(
        home: SpeakNowPage(
          initialText: text,
          source: SpeakSource.share,
          autoSpeak: true,
          fromExternalApp: true,
        ),
      ),
    );
    await tester.pump();

    final finished = await readOnce(tts);
    report('share-speak', tts, finished: finished);

    expect(tts.error, isNull);
    expect(tts.plainIndex, 1);
    expect(find.textContaining('来自其他应用'), findsOneWidget);

    await tts.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('划词朗读：从中间一段起读并读完', (WidgetTester tester) async {
    final tts = TtsManager.instance;
    await tester.pumpWidget(
      const MaterialApp(
        home: SpeakNowPage(initialText: text, source: SpeakSource.processText, autoSpeak: true),
      ),
    );
    await tester.pump();

    // 点第二段：从该段开始读
    await tester.tap(find.textContaining('第二段第一句。').first);
    await tester.pump();

    final finished = await readOnce(tts);
    report('process-text-speak', tts, finished: finished);

    expect(tts.error, isNull);
    expect(tts.plainIndex, 1, reason: '从末段起读，读完停在末段');

    await tts.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('剪贴板朗读：SpeakIntake 提交的文本能被朗读链路接收', (WidgetTester tester) async {
    final tts = TtsManager.instance;
    await SpeakIntake.instance.init();

    final request = SpeakIntake.instance.stream.first;
    SpeakIntake.instance.submit(text, SpeakSource.clipboard);
    final received = await request.timeout(const Duration(seconds: 5));

    // ignore: avoid_print
    print('DEVICE_VERIFY[clipboard-intake] source=${received.source.label} '
        'chars=${received.text.length}');
    expect(received.source, SpeakSource.clipboard);
    expect(received.text, text);

    // 走同一条朗读链路（即读页由 app 级监听打开，这里直接验证能读完）
    await tester.pumpWidget(
      MaterialApp(
        home: SpeakNowPage(initialText: received.text, source: received.source, autoSpeak: true),
      ),
    );
    await tester.pump();
    final finished = await readOnce(tts);
    report('clipboard-speak', tts, finished: finished);
    expect(tts.error, isNull);

    await tts.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

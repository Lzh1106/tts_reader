import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/pages/speak_now_page.dart';
import 'package:tts_reader/services/speak_intake.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 即读页（打字朗读 / 剪贴板朗读 / 分享朗读 / 划词朗读的落点）行为验证。
///
/// 用假引擎把整段文本真的读完：验证「开始朗读 → 逐段推进 → 停在末段」这条链路，
/// 以及从中间某段起读、上一段 / 下一段、空文本提示、外部文本自动朗读、剪贴板粘贴。
///
/// 注意：`TtsManager` 是单例，且 testWidgets 跑在 fake-async 区域，
/// 收尾一律用 `unawaited(stop())` + pump 把定时器跑完，
/// **不要 await TtsManager 的 Future**（fake-async 下没人推进微任务，会直接挂住）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeEngine engine;

  /// 把兜底超时压到毫秒级：测试环境没有真实插件，靠超时分支收尾才不会等 30 秒
  void shrinkTimeouts(TtsManager tts) {
    tts
      ..speakTimeout = const Duration(milliseconds: 200)
      ..initTimeout = const Duration(milliseconds: 200)
      ..voiceTimeout = const Duration(milliseconds: 200)
      ..controlTimeout = const Duration(milliseconds: 200);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await StorageService.instance.init();
    engine = _FakeEngine();
    final tts = TtsManager.instance;
    tts.resetTimeouts();
    shrinkTimeouts(tts);
    await tts.registerEngine(engine, makeActive: true);
  });

  tearDown(() {
    // 同步收尾：只做不依赖事件循环的事（await 会挂住 fake-async）
    TtsManager.instance.resetTimeouts();
  });

  /// 一边推进页面帧，一边给真实事件循环留时间（假引擎的 await 需要两者）
  Future<void> settle(WidgetTester tester, {int frames = 40}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
    }
  }

  /// 收尾：停朗读、拆页面、把兜底超时的定时器跑完，避免 "A Timer is still pending"
  Future<void> cleanup(WidgetTester tester) async {
    TtsManager.instance.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
  }

  const String twoParagraphs = '第一段第一句。第一段第二句。\n\n第二段第一句。第二段第二句。';

  testWidgets('打字朗读：输入文本 → 开始朗读 → 逐段读完后停在末段', (WidgetTester tester) async {
    final tts = TtsManager.instance;

    await tester.pumpWidget(const MaterialApp(home: SpeakNowPage(source: SpeakSource.type)));
    expect(find.byType(TextField), findsOneWidget, reason: '打字朗读进入时是编辑态');

    await tester.enterText(find.byType(TextField), twoParagraphs);
    await tester.tap(find.text('开始朗读'));
    await settle(tester);

    expect(engine.error, isNull);
    expect(tts.error, isNull, reason: '不该留下朗读错误');
    expect(tts.plainTotal, 2, reason: '空行分成两段');
    expect(tts.plainIndex, 1, reason: '读完后游标停在末段');
    expect(tts.speaking, isFalse, reason: '读完后应停下');
    expect(engine.spoken.length, greaterThanOrEqualTo(2));
    expect(tester.takeException(), isNull);

    await cleanup(tester);
  });

  testWidgets('分享进来的文本：自动开始朗读 + 顶部提示条', (WidgetTester tester) async {
    final tts = TtsManager.instance;

    await tester.pumpWidget(
      const MaterialApp(
        home: SpeakNowPage(
          initialText: twoParagraphs,
          source: SpeakSource.share,
          autoSpeak: true,
          fromExternalApp: true,
        ),
      ),
    );
    await settle(tester);

    expect(find.textContaining('来自其他应用'), findsOneWidget);
    expect(engine.spoken, isNotEmpty, reason: '进入即开始朗读');
    expect(tts.plainIndex, 1);
    expect(tester.takeException(), isNull);

    await cleanup(tester);
  });

  testWidgets('划词朗读：来源标题正确，且不显示「来自其他应用」提示', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SpeakNowPage(initialText: '划词内容第一句。', source: SpeakSource.processText),
      ),
    );
    await tester.pump();
    expect(find.textContaining('划词朗读'), findsOneWidget);
    expect(find.textContaining('来自其他应用'), findsNothing);

    await cleanup(tester);
  });

  testWidgets('点某一段从该段开始重读', (WidgetTester tester) async {
    final tts = TtsManager.instance;

    await tester.pumpWidget(
      const MaterialApp(home: SpeakNowPage(initialText: twoParagraphs, source: SpeakSource.view)),
    );
    await tester.pump();

    engine.spoken.clear();
    await tester.tap(find.textContaining('第二段第一句。').first);
    await settle(tester);

    expect(engine.spoken.first, contains('第二段第一句。'), reason: '应从被点的那一段开始读');
    expect(tts.plainIndex, 1);

    await cleanup(tester);
  });

  testWidgets('上一段 / 下一段按钮能跳读，且不越界', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SpeakNowPage(initialText: twoParagraphs, source: SpeakSource.share)),
    );
    await tester.pump();

    engine.spoken.clear();
    await tester.tap(find.byTooltip('下一段'));
    await settle(tester, frames: 12);
    expect(engine.spoken.first, contains('第二段第一句。'), reason: '下一段应从第二段开始读');

    // 末段再按「下一段」：夹取到末段重读，不能越界崩溃
    engine.spoken.clear();
    await tester.tap(find.byTooltip('下一段'));
    await settle(tester, frames: 12);
    expect(engine.spoken.first, contains('第二段第一句。'));
    expect(tester.takeException(), isNull);

    // 首段按「上一段」：不越界，从头读
    engine.spoken.clear();
    await tester.tap(find.byTooltip('上一段'));
    await settle(tester, frames: 12);
    expect(engine.spoken.first, contains('第一段第一句。'), reason: '上一段应回到第一段');
    expect(tester.takeException(), isNull);

    await cleanup(tester);
  });

  testWidgets('空文本点开始朗读：给提示且不出声', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SpeakNowPage(source: SpeakSource.type)));

    await tester.tap(find.text('开始朗读'));
    await tester.pump();

    expect(find.text('请先输入或粘贴要朗读的文本'), findsOneWidget);
    expect(engine.spoken, isEmpty);

    await cleanup(tester);
  });

  testWidgets('编辑态粘贴剪贴板文本后可直接朗读', (WidgetTester tester) async {
    final tts = TtsManager.instance;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, Object?>{'text': '剪贴板里的第一段。\n\n剪贴板里的第二段。'};
        }
        return null;
      },
    );

    await tester.pumpWidget(const MaterialApp(home: SpeakNowPage(source: SpeakSource.type)));
    await tester.tap(find.text('粘贴'));
    await tester.pump();
    expect(find.textContaining('剪贴板里的第一段。'), findsOneWidget);

    await tester.tap(find.text('开始朗读'));
    await settle(tester);
    expect(tts.plainTotal, 2);
    expect(engine.spoken.first, contains('剪贴板里的第一段。'));

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await cleanup(tester);
  });

  testWidgets('编辑按钮在编辑态与朗读态之间切换', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SpeakNowPage(initialText: '一段文本。', source: SpeakSource.share)),
    );
    await tester.pump();
    expect(find.byType(TextField), findsNothing, reason: '有初始文本时直接是朗读态');

    await tester.tap(find.byTooltip('编辑文本'));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);

    await cleanup(tester);
  });
}

/// 假引擎：每次 speak 后完成，记录读过的文本
class _FakeEngine with SyntheticTtsEngine implements TtsEngine {
  final List<String> spoken = <String>[];
  Object? error;

  @override
  String get id => 'fake';

  @override
  String get displayName => '假引擎（测试）';

  @override
  bool get isAvailable => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<TtsVoice>> getVoices() async => const <TtsVoice>[];

  @override
  Future<void> setVoice(String voiceId) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  Future<void> speak(String text) async {
    try {
      spoken.add(text);
      await Future<void>.delayed(Duration.zero);
    } catch (e) {
      error = e;
      rethrow;
    }
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async {}
}

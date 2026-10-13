import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// **第 0 步：时序验证**（不改生产代码）
///
/// 要回答一个问题：`TtsManager.speakText` 是 fire-and-forget（立刻返回），
/// 那么「先订阅 whenSessionFinished()、再 speakText、然后 await」这套写法
/// 能不能可靠地等到**这一句读完了**？
///
/// 单句场景与「连续两句」场景都要验：
/// - 单句：订阅在前、朗读在后 → Future 必须在读完时完成；
/// - 连发：第二次 speakText 会让第一次的会话被强制收尾（`_beginSession`
///   会 complete 掉旧的 Completer）—— 这点决定了 PDF 推进循环能不能
///   靠它当「这一句读完」的信号。
class _CompletingEngine with SyntheticTtsEngine implements TtsEngine {
  _CompletingEngine({this.speakDelay = const Duration(milliseconds: 40)});

  final Duration speakDelay;
  final List<String> spoken = <String>[];
  void Function()? _onComplete;

  @override
  String get id => 'step0-completing';

  @override
  String get displayName => '假引擎（自然完成）';

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
    spoken.add(text);
    // 真实引擎读完会回调完成处理器（HANDOFF §4.22：假引擎必须真的回调，
    // 否则「引擎报完成 → 管理器误收尾」这类 bug 单测抓不到）
    await Future<void>.delayed(speakDelay);
    _onComplete?.call();
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) {
    _onComplete = handler;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  // TtsManager 是单例，构造时会 new SystemTtsEngine(flutter_tts) → 立刻建
  // MethodChannel，所以**必须先初始化 binding**，否则报
  // 「Cannot set the method call handler before the binary messenger has been
  // initialized」（纯 test() 用例也不例外）。
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TtsManager.instance.resetSessionForTest();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.speakTimeout = const Duration(seconds: 5);
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.resetSessionForTest();
  });

  test('单句：先订阅 whenSessionFinished 再 speakText → Future 会完成', () async {
    final engine = _CompletingEngine();
    final tts = TtsManager.instance;
    await tts.registerEngine(engine, makeActive: true);

    // 顺序必须是「先订阅、再 speak」（顺序反了会拿到上一次会话的 Future）
    final done = tts.whenSessionFinished();
    tts.speakText('只读这一句。');
    // ignore: avoid_print
    print('STEP0 单句：speakText 返回后 speaking=${tts.speaking} '
        'error=${tts.error} spoken=${engine.spoken} '
        'activeDocumentId=${tts.activeDocumentId}');

    // 给事件循环几个回合：speakText 是 fire-and-forget，引擎调用在后面的微任务里
    await Future<void>.delayed(const Duration(milliseconds: 30));
    // ignore: avoid_print
    print('STEP0 单句：等 30ms 后 speaking=${tts.speaking} spoken=${engine.spoken}');

    await done.timeout(const Duration(seconds: 3));
    // ignore: avoid_print
    print('STEP0 单句：whenSessionFinished 完成，读过的内容=${engine.spoken}');
    expect(engine.spoken, <String>['只读这一句。']);
    // ⚠️ 注意：`whenSessionFinished` 只是**会话收尾信号**，
    // 它不等价于 `speaking == false` —— `_endSession` 不动 `_speaking`，
    // 只有 `stop()` / 读完路径里的 `_stopAtEnd()` 才会把它置假。
    // 所以推进循环里判「这一句读完了」要用 whenSessionFinished，
    // **不要**用 `speaking`（那是个常驻状态，不是「读完」的信号）。
    // ignore: avoid_print
    print('STEP0 单句：会话已收尾，speaking=${tts.speaking}（不能拿它当读完信号）');
  });

  test('连发两句：第二次 speakText 会不会把第一次的 Future 收尾', () async {
    final engine = _CompletingEngine(speakDelay: const Duration(milliseconds: 120));
    final tts = TtsManager.instance;
    await tts.registerEngine(engine, makeActive: true);

    final first = tts.whenSessionFinished();
    tts.speakText('第一句。');
    // 立刻再发第二句（模拟「用户很快点了另一句」）
    final second = tts.whenSessionFinished();
    tts.speakText('第二句。');

    // ignore: avoid_print
    print('STEP0 连发：发送完毕 speaking=${tts.speaking}');

    // 第一次的 Future 是否完成？用较短的超时探测，避免用例卡住
    var firstCompleted = false;
    try {
      await first.timeout(const Duration(milliseconds: 600));
      firstCompleted = true;
    } on TimeoutException {
      firstCompleted = false;
    }
    // ignore: avoid_print
    print('STEP0 连发：第一个 Future 完成=$firstCompleted '
        '（true = 被第二次 speakText 强制收尾）');

    // 第二次 speakText 会**立刻**让 `second` 完成 —— 因为 `_beginSession`
    // 一进来就把旧的 Completer complete 掉（它是「会话换了」的信号，
    // 不只是「读完了」的信号）。这一点必须记住，否则会写出
    // 「等了个寂寞」的循环。
    var secondCompletedEarly = false;
    try {
      await second.timeout(const Duration(milliseconds: 200));
      secondCompletedEarly = true;
    } on TimeoutException {
      secondCompletedEarly = false;
    }
    // ignore: avoid_print
    print('STEP0 连发：第二个 Future 完成=$secondCompletedEarly '
        '（true = speakText 后立刻完成，不能拿它判「读完了」）'
        ' spoken=${engine.spoken}');

    // 真正等第二句读完：用轮询兜住（这里只是为了观察，不作为实现范式）
    for (var i = 0; i < 40 && engine.spoken.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    // ignore: avoid_print
    print('STEP0 连发：最终读过=${engine.spoken}');

    expect(engine.spoken, <String>['第二句。'],
        reason: '连发两句时，第一句在**到达引擎之前**就被第二句顶掉了'
            '（`_runLines` 开头的 token 检查直接 return）—— '
            '这正是「先 cancel 再 speak」的效果：点新句子不会两句叠着读。'
            '也说明推进循环必须**串行**：await 完上一句才发下一句。');
    expect(firstCompleted, isTrue,
        reason: '连发时第一个 Future 会被新会话强制收尾');
    expect(secondCompletedEarly, isTrue,
        reason: '连发时第二个 Future 也会在新会话开始时立刻完成 —— '
            '所以「先订阅再 speak」这套写法只在**串行**推进时可靠。');
  });

  test('连读三句（模拟 PDF 推进循环）：每句的 Future 都能依次完成', () async {
    final engine = _CompletingEngine(speakDelay: const Duration(milliseconds: 40));
    final tts = TtsManager.instance;
    await tts.registerEngine(engine, makeActive: true);

    final order = <String>[];
    for (final sentence in <String>['第一句。', '第二句。', '第三句。']) {
      final done = tts.whenSessionFinished(); // 先订阅
      tts.speakText(sentence); // 再朗读
      await done.timeout(const Duration(seconds: 3)); // 等这一句读完
      order.add(sentence);
    }

    // ignore: avoid_print
    print('STEP0 连读：完成顺序=$order');
    expect(order, <String>['第一句。', '第二句。', '第三句。'],
        reason: '依次读三句的循环必须能跑通 —— 这是 PDF 自动连读的基础');
  });
}

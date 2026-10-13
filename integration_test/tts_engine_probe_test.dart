import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tts_reader/tts/system_tts_engine.dart';

/// **直连真实 `SystemTtsEngine`：它到底有没有真的合成？（§4.108 装置核查）**
///
/// 为什么需要这一份：真机验证 ③ 显示「不打断时位置也不推进」，
/// 说明**引擎可能根本没出声**（或从不回调完成）。在确认这件事之前，
/// 任何「打断判据」的验证都没有意义 —— 这正是 HANDOFF §4.107 承认的"验证装置失真"
/// 的根源。本用例不带任何业务逻辑，只问引擎三个问题：
///
///   1. `initialize()` 能不能成功？`isAvailable` 是什么？
///   2. `getVoices()` 能列出几个音色？（0 个 = 没装语音包 / 未选音色）
///   3. `speak('短句')` 的 Future **多久**返回？返回时**离发出过了多久**？
///      —— 若它"立刻返回"，说明引擎根本没在合成；
///        若它挂住很久，说明在合成但完成回调可能不来。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('直连 SystemTtsEngine 的三问', (tester) async {
    final engine = SystemTtsEngine();

    // 问 1：初始化
    Object? initErr;
    final initSw = Stopwatch()..start();
    await tester.runAsync(() async {
      try {
        await engine.initialize();
      } catch (e) {
        initErr = e;
      }
    });
    initSw.stop();
    // ignore: avoid_print
    print('ENGINE_PROBE[1] initialize 耗时=${initSw.elapsedMilliseconds}ms '
        'err=$initErr isAvailable=${engine.isAvailable} '
        'displayName=${engine.displayName}');

    // 问 2：音色列表
    var voices = <dynamic>[];
    Object? voiceErr;
    await tester.runAsync(() async {
      try {
        voices = await engine.getVoices();
      } catch (e) {
        voiceErr = e;
      }
    });
    // ignore: avoid_print
    print('ENGINE_PROBE[2] getVoices 数量=${voices.length} err=$voiceErr');
    for (final v in voices.take(8)) {
      // ignore: avoid_print
      print('ENGINE_PROBE[2]   音色: $v');
    }

    // 问 3：speak 的行为（这是关键）
    final finished = <int>[];
    engine.setCompletionHandler(() {
      finished.add(DateTime.now().millisecondsSinceEpoch);
      // ignore: avoid_print
      print('ENGINE_PROBE[3] ★ 完成回调触发（第 ${finished.length} 次）');
    });

    final t0 = DateTime.now();
    Object? speakErr;
    await tester.runAsync(() async {
      try {
        await engine.speak('测试朗读，这是一句中文。');
      } catch (e) {
        speakErr = e;
      }
    });
    final speakMs = DateTime.now().difference(t0).inMilliseconds;
    // ignore: avoid_print
    print('ENGINE_PROBE[3] speak() 返回，耗时=${speakMs}ms err=$speakErr '
        '完成回调次数=${finished.length}');

    // 再等一会儿，看完成回调会不会迟到
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 8)));
    // ignore: avoid_print
    print('ENGINE_PROBE[3] 再等 8 秒后：完成回调次数=${finished.length} '
        '（speak 耗时 ${speakMs}ms）');

    // 诊断结论（只打印，不断言 —— 这一份是核查装置，不是回归）
    final verdict = <String>[];
    if (voices.isEmpty) verdict.add('音色列表为空 → 引擎没有可用语音（语音包/音色未就绪）');
    if (speakMs < 200) verdict.add('speak() 在 ${speakMs}ms 内就返回 → **没有真的在合成**');
    if (finished.isEmpty) verdict.add('完成回调从未触发 → 上层永远等不到"读完"');
    // ignore: avoid_print
    print('ENGINE_PROBE[结论] ${verdict.isEmpty ? "引擎看起来是好的（有音色、speak 挂住、有回调）" : verdict.join("；")}');

    await tester.runAsync(() => engine.dispose());
  }, timeout: const Timeout(Duration(minutes: 3)));
}

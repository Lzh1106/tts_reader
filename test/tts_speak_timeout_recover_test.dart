import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/system_tts_engine.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 回归测试：**朗读超时之后同一位置重复卡死**。
///
/// 真机（2026-10-17）症状：
/// ```
/// 朗读失败：本地 TTS · multitts 朗读超时（30000ms）
/// 用户再按播放（同一位置）→ 又卡满 30 秒
/// ```
///
/// 根因不在超时值上：`_fail()` 只清播放状态，而 `_ensureReady` 的就绪记账
/// 没变，于是下一次**跳过 initialize**，把同一句又压给同一个卡死的
/// `FlutterTts` 实例（它 `speaking` / `speakResult` 还挂着，完成回调永不回来）。
///
/// 本文件守两件事：
///   1. 超时后**必须作废就绪记账 + 清系统队列**（下次重新 initialize）；
///   2. 连续超时后重试**不再等满 speakTimeout**（降到 ≤3 秒）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    final tts = TtsManager.instance;
    tts.resetTimeouts();
    tts.resetSessionForTest();
    tts
      ..speakTimeout = const Duration(milliseconds: 120)
      ..initTimeout = const Duration(milliseconds: 300)
      ..voiceTimeout = const Duration(milliseconds: 300)
      ..controlTimeout = const Duration(milliseconds: 300);
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
  });

  test('超时后作废就绪记账：再按播放必须重新 initialize，而不是直接压给同一个插件', () async {
    final TtsManager tts = TtsManager.instance;
    final _HangingEngine engine = _HangingEngine();
    await tts.registerEngine(engine, makeActive: true);

    tts.speakLines(<String>['第一次：插件不回应']);
    await tts.whenSessionFinished().timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('超时分支没有收尾'),
        );
    expect(tts.error, isNotNull, reason: '插件不回应必须报错');
    expect(tts.speakTimeoutStreak, 1, reason: '这次超时必须被记进引擎健康度');

    final int initAfterFirst = engine.initializeCalls;
    final int stopAfterFirst = engine.stopCalls;
    expect(stopAfterFirst, greaterThanOrEqualTo(2),
        reason: '超时那一刻要额外发一次 stop 清系统侧队列'
            '（第一次 stop 是 _runBody 开头那次）——'
            '不清的话上一句的 speakResult 会把下一句吞掉');

    // 用户在同一位置再按一次播放
    tts.speakLines(<String>['第一次：插件不回应']);
    await tts.whenSessionFinished().timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('第二次朗读没有收尾'),
        );

    expect(engine.initializeCalls, greaterThan(initAfterFirst),
        reason: '★超时后必须重新 initialize：'
            '否则同一句会被再次压给那个卡死的插件实例，又是 30 秒');
    expect(tts.speakTimeoutStreak, 2, reason: '第二次仍然超时 → 计数继续累积');
  });

  test('连续超时后重试只等 speakTimeout/3，不再重复等满一整个 speakTimeout', () async {
    final TtsManager tts = TtsManager.instance;
    final _HangingEngine engine = _HangingEngine();
    await tts.registerEngine(engine, makeActive: true);

    // 生产值 30 秒 → 重试上限 10 秒。用例里按比例压到 4 秒 → 1.32 秒，
    // 判据仍然可分辨（不压的话第二次要等满 4 秒）。
    tts.speakTimeout = const Duration(seconds: 4);
    tts.speakLines(<String>['卡住的一句']);
    await tts.whenSessionFinished().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('第一次朗读没有收尾'),
        );
    expect(tts.speakTimeoutStreak, 1);

    // 第二次：只等 speakTimeout/3，必须明显比第一次快
    final Stopwatch watch = Stopwatch()..start();
    tts.speakLines(<String>['卡住的一句']);
    await tts.whenSessionFinished().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('第二次朗读没有收尾'),
        );
    watch.stop();

    expect(watch.elapsed, lessThan(const Duration(milliseconds: 2500)),
        reason: '★第一次超时已经证明插件不回应，重试不能再等满 speakTimeout：'
            '真机症状就是「同一位置连续两次卡死、每次 30 秒」');
  });

  test('引擎恢复回应 → 健康度清零，下次照常等 speakTimeout', () async {
    final TtsManager tts = TtsManager.instance;
    final _HangingEngine engine = _HangingEngine();
    await tts.registerEngine(engine, makeActive: true);

    tts.speakLines(<String>['先卡一次']);
    await tts.whenSessionFinished().timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('超时分支没有收尾'),
        );
    expect(tts.speakTimeoutStreak, 1);

    // 放行：之后的 speak 正常完成
    engine.release();
    tts.speakLines(<String>['这次能读完']);
    await tts.whenSessionFinished().timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('恢复后的朗读没有收尾'),
        );

    expect(tts.error, isNull, reason: '引擎恢复后不该再报错');
    expect(tts.speakTimeoutStreak, 0,
        reason: '★成功一次就清零，否则正常引擎会一直被 3 秒上限误伤');
  });

  // ---------------- 引擎层：reset() 必须是一条真正的重绑链路 ----------------

  group('SystemTtsEngine.reset()', () {
    const MethodChannel channel = MethodChannel('flutter_tts');
    late List<String> calls;

    setUp(() {
      calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call.method);
        if (call.method == 'getEngines' || call.method == 'getDefaultEngine') {
          return <String>[];
        }
        return 1;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('依次发 stop → setEngine → 重新注册回调（awaitSpeakCompletion）', () async {
      final SystemTtsEngine engine = SystemTtsEngine(enginePackage: 'com.google.android.tts');
      await engine.reset();

      expect(calls, contains('stop'), reason: '要先清系统侧队列与 speakResult');
      expect(calls, contains('setEngine'),
          reason: '★setEngine 才会让 Android 重建 TextToSpeech 实例；'
              '只新建 FlutterTts 对象没用（原生插件是单例，状态还挂着）');
      expect(calls, contains('awaitSpeakCompletion'),
          reason: '重绑后必须重新注册完成回调，否则以后每句都收不到读完信号');
      expect(calls.indexOf('stop'), lessThan(calls.indexOf('setEngine')),
          reason: '顺序不能反：先停再重绑');
      await engine.dispose();
    });

    test('没选过本地引擎（包名为空）时不发 setEngine：空串会让部分 ROM 的引擎彻底哑掉', () async {
      final SystemTtsEngine engine = SystemTtsEngine();
      await engine.reset();

      expect(calls, contains('stop'));
      expect(calls, isNot(contains('setEngine')),
          reason: '拿不到默认引擎包名时只能做 stop + 重新 initialize，'
              '绝不能把空串交给 setEngineByPackageName');
      await engine.dispose();
    });
  });
}

/// 假引擎：**一直不回应**（模拟 flutter_tts 的 speak 永远不回完成回调）。
///
/// [release] 之后恢复正常完成，用来验证「引擎恢复回应 → 健康度清零」。
class _HangingEngine with SyntheticTtsEngine implements TtsEngine {
  final List<String> spoken = <String>[];
  int initializeCalls = 0;
  int stopCalls = 0;
  bool _released = false;
  final Completer<void> _hang = Completer<void>();

  void release() {
    _released = true;
    if (!_hang.isCompleted) _hang.complete();
  }

  @override
  String get id => 'hanging-timeout';

  @override
  String get displayName => '卡住的假引擎（超时用例）';

  @override
  bool get isAvailable => true;

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

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
    if (_released) return;
    await _hang.future; // 不回应
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async {}
}

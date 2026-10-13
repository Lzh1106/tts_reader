import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 回归测试：**朗读中换位置**不能误报「朗读超时」。
///
/// 真机（模拟器 + 真实系统 TTS）上复现过的缺陷：
/// 朗读时点另一段 / 按上一页，旧循环刚好已经把 speak 交给插件——而插件要等这一句
/// 读完才回复，于是「重入即失败」的插件锁把新循环的第一次 speak 挡了下来，
/// 被上层当成朗读超时 → `_fail()` → 界面弹「朗读超时」而且不读了。
///
/// 这里用一个「第一次 speak 永不返回」的假引擎把那个时间窗稳定造出来：
/// 旧调用确实还挂在插件上，然后立刻换位置重新朗读。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await StorageService.instance.init();
    final tts = TtsManager.instance;
    tts.resetTimeouts();
    tts
      ..speakTimeout = const Duration(milliseconds: 300)
      ..initTimeout = const Duration(milliseconds: 300)
      ..voiceTimeout = const Duration(milliseconds: 300)
      ..controlTimeout = const Duration(milliseconds: 300);
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
  });

  /// 等条件成立（真实事件循环，5 秒兜底）
  Future<void> waitFor(bool Function() condition, {String what = '条件'}) async {
    final stopwatch = Stopwatch()..start();
    while (!condition()) {
      if (stopwatch.elapsed > const Duration(seconds: 5)) fail('等待「$what」超时');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('旧 speak 还挂在插件上时换位置：不报超时，新位置照常朗读', () async {
    final tts = TtsManager.instance;
    final engine = _HangingEngine();
    await tts.registerEngine(engine, makeActive: true);

    tts.speakLines(<String>['第一段', '第二段']);
    // 等旧循环真的把第一段交给插件（此后它不会回复）
    await waitFor(() => engine.spoken.isNotEmpty, what: '旧循环发起朗读');

    // 朗读中换到第二段：这一步以前会把新循环的 speak 挡下来 → 误报超时
    tts.speakLines(<String>['第一段', '第二段'], start: 1);
    await tts.whenSessionFinished().timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('换位置后的朗读会话没有结束'),
        );

    expect(tts.error, isNull, reason: '换位置不该留下「朗读超时」错误');
    expect(engine.spoken, <String>['第一段', '第二段'], reason: '新位置要读出来，旧循环不能重复抢插件');
    expect(tts.plainIndex, 1, reason: '读完停在末段');
    expect(tts.speaking, isFalse);
  });

  test('确实超时（插件一直不回复且没人打断）仍然报错并停下', () async {
    final tts = TtsManager.instance;
    final engine = _HangingEngine();
    await tts.registerEngine(engine, makeActive: true);

    tts.speakLines(<String>['一直不回复的一段']);
    await tts.whenSessionFinished().timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('超时分支没有收尾'),
        );

    expect(tts.error, isNotNull, reason: '插件不回复必须报错，不能静默挂住');
    expect(tts.error, contains('朗读超时'));
    expect(tts.speaking, isFalse);
  });

  test('换位置后旧循环不再发起新的插件调用（排队期间令牌失效即退出）', () async {
    final tts = TtsManager.instance;
    final engine = _HangingEngine();
    await tts.registerEngine(engine, makeActive: true);

    tts.speakLines(<String>['A 段', 'B 段', 'C 段']);
    await waitFor(() => engine.spoken.isNotEmpty, what: '旧循环发起朗读');
    tts.speakLines(<String>['A 段', 'B 段', 'C 段'], start: 1);
    await tts.whenSessionFinished().timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('会话没有结束'),
        );

    // 新循环读 B、C 两段；旧循环只发过 A 段这一次调用
    expect(engine.spoken, <String>['A 段', 'B 段', 'C 段']);
    expect(tts.error, isNull);
  });
}

/// 假引擎：**第一次 speak 永不返回**（模拟真实插件在等这一句读完），之后正常完成
class _HangingEngine with SyntheticTtsEngine implements TtsEngine {
  final List<String> spoken = <String>[];
  final Completer<void> _hang = Completer<void>();

  @override
  String get id => 'hanging';

  @override
  String get displayName => '卡住的假引擎（测试）';

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
    if (spoken.length == 1) {
      await _hang.future; // 第一次调用永远不返回
      return;
    }
    await Future<void>.delayed(Duration.zero);
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

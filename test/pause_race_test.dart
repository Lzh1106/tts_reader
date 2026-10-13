import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// **pause 在「下一句已排队但还没开口」的窗口里也必须生效**（v1.21.27 修）。
///
/// 用户症状（PDF 朗读时按暂停，小概率"本句照读完才停"）：界面已显示暂停、
/// 声音继续播到这一句自然结束。窗口只有几十毫秒，但真机上撞得到。
///
/// 根因：`pause()` 用 `_speaking` 做短路，而 `_speaking` 是 `_runLinesBody` 里
/// **异步**置真的（它前面还有 `await _awt(..., lock: 'run-stop')` 在排队）——
/// 在「上一句刚收尾、下一句已排队但还没开口」这个窗口里它仍是 false，
/// 于是这次 pause **整个失效**：`_generation` 不递增、`_paused` 不置真，
/// 排队的 `_runLinesBody` 照常走到 `speak`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    final tts = TtsManager.instance;
    tts.resetTimeouts();
    tts.resetSessionForTest();
    tts.speakTimeout = const Duration(seconds: 5);
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.resetSessionForTest();
  });

  test('pause 在"下一句已排队但还没开口"的窗口里也必须生效', () async {
    final engine = _SlowStopEngine();
    await TtsManager.instance.registerEngine(engine, makeActive: true);
    TtsManager.instance.speakLines(<String>['甲。', '乙。']);

    // 给 `_speakLinesInternal` 一点时间跑完同步部分，
    // 但 `_runLinesBody` 会卡在 `_awt(stop)` 里 —— 此刻 `_speaking` 仍是 false。
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(TtsManager.instance.playing, isFalse,
        reason: '前提：还没走到 `_speaking = true`（pause 被短路的就是这个窗口）');

    await TtsManager.instance.pause();
    expect(TtsManager.instance.paused, isTrue,
        reason: 'pause 必须在会话开口前就生效；'
            '修前 `!_speaking` 短路，`_paused` 仍是 false');

    // 再等一会儿：如果 pause 没生效，`_runLinesBody` 会走到 speak
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(engine.spoken, isEmpty,
        reason: 'pause 之后不该再发起任何 speak；'
            '修前这里会看到 `spoken=[甲。]`（本句照读）');
  });
}

/// `stop()` 慢 100ms：`_runLinesBody` 开头的 `_awt(lock: 'run-stop')` 会阻塞
/// 在这里，`_speaking` 停在 false —— 这就是用户撞上的那个窗口。
class _SlowStopEngine with SyntheticTtsEngine implements TtsEngine {
  final List<String> spoken = <String>[];
  void Function()? _onComplete;

  @override
  String get id => 'pause-race';
  @override
  String get displayName => '慢停止假引擎';
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
    await Future<void>.delayed(const Duration(milliseconds: 10));
    _onComplete?.call();
  }

  @override
  Future<void> stop() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  @override
  Future<void> pause() async {}
  @override
  void setCompletionHandler(void Function()? handler) => _onComplete = handler;
  @override
  Future<void> dispose() async {}
}

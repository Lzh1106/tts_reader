import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/auto_sleep.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 自动休眠（T2S 的 tts.autosleep.settings）验证：
/// 空闲暂停与定时停止两条阈值的行为、边界，以及接进 TtsManager 后的真实链路。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final auto = AutoSleepController.instance;
  var clock = DateTime(2024, 1, 1, 9);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    auto.resetForTest();
    await StorageService.instance.init();
    clock = DateTime(2024, 1, 1, 9);
    auto.now = () => clock;
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
    AutoSleepController.instance.resetForTest();
  });

  /// 往前推时间
  void advance(int minutes, {int seconds = 0}) =>
      clock = clock.add(Duration(minutes: minutes, seconds: seconds));

  group('空闲暂停', () {
    test('无操作满阈值就暂停一次，不会反复触发', () async {
      var paused = 0;
      auto.onIdleTimeout = () async => paused++;
      await auto.configure(idle: 10);

      auto.beginSession();
      auto.setPlaying(true);
      advance(9);
      auto.check();
      expect(paused, 0, reason: '还没到阈值就不该动手');

      advance(2);
      auto.check();
      expect(paused, 1);
      expect(auto.notice.value, contains('自动暂停'));

      advance(30);
      auto.check();
      expect(paused, 1, reason: '暂停过一次后不该反复触发');
    });

    test('用户有操作就重新计时', () async {
      var paused = 0;
      auto.onIdleTimeout = () async => paused++;
      await auto.configure(idle: 10);

      auto.beginSession();
      auto.setPlaying(true);
      advance(9);
      auto.notifyUserActivity(); // 翻了一页
      advance(9);
      auto.check();
      expect(paused, 0);

      advance(2);
      auto.check();
      expect(paused, 1);
    });

    test('暂停期间不计空闲（否则暂停着也会被判定为空闲）', () async {
      var paused = 0;
      auto.onIdleTimeout = () async => paused++;
      await auto.configure(idle: 5);

      auto.beginSession();
      auto.setPlaying(true);
      auto.setPlaying(false); // 用户按了暂停
      advance(60);
      auto.check();
      expect(paused, 0);
    });

    test('重新播起来会重置空闲计时', () async {
      var paused = 0;
      auto.onIdleTimeout = () async => paused++;
      await auto.configure(idle: 5);

      auto.beginSession();
      auto.setPlaying(true);
      advance(4);
      auto.setPlaying(false);
      advance(30);
      auto.setPlaying(true); // 恢复播放
      auto.check();
      expect(paused, 0);

      advance(5);
      auto.check();
      expect(paused, 1);
    });

    test('关闭（0 分钟）时不建定时器也不触发', () async {
      var paused = 0;
      auto.onIdleTimeout = () async => paused++;
      auto.beginSession();
      auto.setPlaying(true);
      advance(600);
      auto.check();
      expect(paused, 0);
      expect(auto.enabled, isFalse);
    });

    test('会话结束后不再触发', () async {
      var paused = 0;
      auto.onIdleTimeout = () async => paused++;
      await auto.configure(idle: 5);
      auto.beginSession();
      auto.setPlaying(true);
      auto.endSession(); // 读完了
      advance(60);
      auto.check();
      expect(paused, 0);
    });
  });

  group('定时停止', () {
    test('朗读满阈值就停止，且会话立即收尾', () async {
      var stopped = 0;
      auto.onStopTimeout = () async => stopped++;
      await auto.configure(stop: 30);

      auto.beginSession();
      auto.setPlaying(true);
      advance(29);
      auto.check();
      expect(stopped, 0);

      advance(1);
      auto.check();
      expect(stopped, 1);
      expect(auto.inSession, isFalse, reason: '停止后会话必须收尾，否则会再触发一次');
      expect(auto.notice.value, contains('自动停止'));
    });

    test('定时停止不受「有没有在播」影响（暂停中也会到点）', () async {
      var stopped = 0;
      auto.onStopTimeout = () async => stopped++;
      await auto.configure(stop: 10);
      auto.beginSession();
      auto.setPlaying(false);
      advance(11);
      auto.check();
      expect(stopped, 1);
    });

    test('两条阈值同时开启时各管各的', () async {
      var paused = 0;
      var stopped = 0;
      auto.onIdleTimeout = () async => paused++;
      auto.onStopTimeout = () async => stopped++;
      await auto.configure(idle: 5, stop: 60);

      auto.beginSession();
      auto.setPlaying(true);
      advance(6);
      auto.check();
      expect(paused, 1);
      expect(stopped, 0);

      advance(60);
      auto.check();
      expect(stopped, 1);
    });

    test('阈值持久化，重启后还在', () async {
      await auto.configure(idle: 15, stop: 45);
      auto.resetForTest();
      auto.now = () => clock;
      await auto.init();
      expect(auto.idleMinutes, 15);
      expect(auto.stopMinutes, 45);
      expect(auto.summary, '无操作 15 分钟后暂停，朗读满 45 分钟后停止');
    });

    test('nextIn 给出最近一次自动动作的剩余时间', () async {
      await auto.configure(idle: 10, stop: 30);
      auto.beginSession();
      auto.setPlaying(true);
      advance(4);
      expect(auto.nextIn, const Duration(minutes: 6), reason: '空闲还剩 6 分钟');

      advance(20); // 会话已经进行 24 分钟
      auto.notifyUserActivity(); // 刚有过操作，空闲重新计时
      expect(
        auto.nextIn,
        const Duration(minutes: 6),
        reason: '停止还剩 6 分钟、空闲还剩 10 分钟，取更近的那个',
      );
    });
  });

  group('与 TtsManager 集成', () {
    setUp(() {
      // 真实事件循环里必须用真实时钟（上面的用例注入的是冻结时钟）
      auto.now = DateTime.now;
    });

    test('空闲到点后真的暂停了朗读（真实事件循环 + 毫秒级阈值）', () async {
      final engine = _SlowEngine();
      final tts = TtsManager.instance;
      tts.resetTimeouts();
      await tts.registerEngine(engine, makeActive: true);

      auto.idleOverride = const Duration(milliseconds: 120);
      auto.stopOverride = null;
      auto.onIdleTimeout = tts.pause;
      auto.onStopTimeout = tts.stop;
      auto.tickIntervalOverride = const Duration(milliseconds: 20);

      tts.loadDocument(
        StructuredDocument(
          chapters: <Chapter>[
            const Chapter(
              title: '第一章',
              paragraphs: <Paragraph>[
                Paragraph(sentences: <Sentence>[Sentence('第一句。'), Sentence('第二句。')]),
              ],
            ),
          ],
        ),
        title: '测试文档',
      );
      tts.speakFrom(0, 0, 0);

      // 每句读 300ms，而空闲阈值是 120ms：中途必然到点
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(tts.paused, isTrue, reason: '空闲到点应当自动暂停');
      expect(auto.notice.value, contains('自动暂停'));

      tts.resume();
      expect(tts.paused, isFalse);
      expect(auto.notice.value, contains('自动暂停'), reason: '提示留给界面消费');
      auto.clearNotice();
      expect(auto.notice.value, isNull);
    });

    test('定时到点后真的停止了朗读', () async {
      final engine = _SlowEngine();
      final tts = TtsManager.instance;
      tts.resetTimeouts();
      await tts.registerEngine(engine, makeActive: true);

      auto.idleOverride = null;
      auto.stopOverride = const Duration(milliseconds: 80);
      auto.onIdleTimeout = tts.pause;
      auto.onStopTimeout = tts.stop;
      auto.tickIntervalOverride = const Duration(milliseconds: 20);

      tts.loadDocument(
        StructuredDocument(
          chapters: <Chapter>[
            const Chapter(
              title: '第一章',
              paragraphs: <Paragraph>[
                Paragraph(sentences: <Sentence>[Sentence('第一句。'), Sentence('第二句。')]),
              ],
            ),
          ],
        ),
        title: '测试文档',
      );
      tts.speakFrom(0, 0, 0);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(tts.speaking, isFalse, reason: '定时到点应当停止');
      expect(tts.paused, isFalse);
      expect(auto.notice.value, contains('自动停止'));
    });

    test('两条阈值都关闭时不建定时器（测试环境不能留悬挂定时器）', () async {
      final engine = _SlowEngine();
      final tts = TtsManager.instance;
      tts.resetTimeouts();
      await tts.registerEngine(engine, makeActive: true);

      tts.speakLines(<String>['一句话。']);
      expect(auto.enabled, isFalse);
      expect(auto.inSession, isTrue, reason: '会话边界仍然登记，只是不设阈值');
      await tts.whenSessionFinished().timeout(const Duration(seconds: 5));
      expect(auto.inSession, isFalse);
    });
  });
}

/// 每句读 300 毫秒的假引擎：留出足够窗口让空闲 / 定时阈值介入
class _SlowEngine with SyntheticTtsEngine implements TtsEngine {
  @override
  String get id => 'slow';

  @override
  String get displayName => '慢速假引擎（测试）';

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
  Future<void> speak(String text) async =>
      Future<void>.delayed(const Duration(milliseconds: 300));

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async {}
}

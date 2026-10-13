
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/system_tts_engine.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// **路径 B：提交成功、但引擎在几毫秒内主动回调「完成」**（真机 238 微秒那种）。
///
/// 与路径 A（提交被拒绝 → 插件返回 0 → 重投）不是一回事：
/// 这里提交是**成功**的，插件也不会返回 0，所以上一轮的重投修法拦不住它。
/// 真机 diag2 的 R5=181 / R4=194 主要来自这条。
///
/// 两条断言分别在两层：
///   · 引擎层（`SystemTtsEngine.speak`）：< 100ms 的完成回调必须被丢弃，继续等真实回调；
///   · 共享层（`TtsManager._speakUnit`）：< 100ms 的"读完"一律判假完成，不推进游标。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------- 共享层：假引擎 5ms 回调完成 ----------------

  group('共享层（TtsManager）', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      final tts = TtsManager.instance;
      tts.resetTimeouts();
      tts.resetSessionForTest();
      await tts.registerEngine(_InstantCompleteEngine(), makeActive: true);
    });

    tearDown(() async {
      await TtsManager.instance.stop();
    });

    test('路径 B①：提交后 5ms 就回调完成 → 不算读完、游标不推进、按失败上报', () async {
      final TtsManager tts = TtsManager.instance;
      tts.loadDocument(_doc(), title: '假完成', documentId: 'instant-complete');
      tts.speakFrom(0, 0, 0);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(tts.cursor, (0, 0, 0),
          reason: '引擎 5ms 就报完成 → 绝不能让游标推进（真机症状就是这里被推飞的）');
      expect(tts.error, isNotNull,
          reason: '必须按失败上报（走既有失败链路），而不是静默当读完');
    });

    test('反向：引擎 300ms 后才回调完成 → 正常推进（判据不误伤）', () async {
      final TtsManager tts = TtsManager.instance;
      await tts.registerEngine(_SlowRealisticEngine(), makeActive: true);
      tts.loadDocument(_doc(), title: '正常朗读', documentId: 'normal');
      tts.speakFrom(0, 0, 0);
      await tts.whenSessionFinished().timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('正常朗读不该在 10 秒内结束不了'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(tts.cursor, isNot((0, 0, 0)), reason: '真实读完必须照常推进');
      expect(tts.error, isNull);
    });
  });

  // ---------------- 引擎层：mock flutter_tts 通道 ----------------

  group('引擎层（SystemTtsEngine）', () {
    const MethodChannel channel = MethodChannel('flutter_tts');

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        return 1; // speak 提交成功（不返回 0），awaitSpeakCompletion 等一律成功
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<void> emit(String method) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
        (ByteData? _) {},
      );
    }

    test('路径 B②：5ms 的完成回调是假的 → speak() 必须继续等真实完成回调', () async {
      final engine = SystemTtsEngine();
      var completed = false;
      final Future<void> future =
          engine.speak('这一句会先收到一次假的完成回调，用来验证时长判据。')
            ..then((_) => completed = true);

      // 提交后 5ms：引擎主动报「完成」——真机 238µs 那一种
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await emit('speak.onComplete');
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(completed, isFalse,
          reason: '距发起仅几毫秒的「完成」必须被丢弃，speak() 不能返回');

      // 真实读完（> 100ms 之后）再来一次完成回调
      await emit('speak.onComplete');
      await future;
      expect(completed, isTrue);
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('反向：正常完成（一次、且在 100ms 之后）→ 立刻放行', () async {
      final engine = SystemTtsEngine();
      var completed = false;
      final Future<void> future = engine.speak('正常读完的一句话，用来验证不误伤。')
        ..then((_) => completed = true);

      await Future<void>.delayed(const Duration(milliseconds: 150));
      await emit('speak.onComplete');
      await future;
      expect(completed, isTrue);
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('反向：stop() 打断 → 立刻放行、不卡死', () async {
      final engine = SystemTtsEngine();
      var completed = false;
      final Future<void> future = engine.speak('被打断的一句，必须尽快放行。')
        ..then((_) => completed = true);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await engine.stop();
      await future.timeout(const Duration(seconds: 3),
          onTimeout: () => fail('stop() 之后必须尽快放行，不能等到时长判据'));
      expect(completed, isTrue);
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));
  });
}

StructuredDocument _doc() => StructuredDocument(
      chapters: const <Chapter>[
        Chapter(
          title: 'C0',
          paragraphs: <Paragraph>[
            Paragraph(
              sentences: <Sentence>[
                Sentence('第一句话，用来观察假完成会不会把游标推飞。'),
                Sentence('第二句话，读完之后才允许推进一次。'),
                Sentence('第三句话，用来确认没有累积跳跃。'),
              ],
            ),
          ],
        ),
      ],
    );

/// **路径 B 的假引擎**：提交成功（不返回 0），但 5ms 内主动回调「完成」。
///
/// 它**不**声明「合成语义」，所以共享层的时长判据对它照常生效 —— 这正是本用例要测的。
class _InstantCompleteEngine implements TtsEngine {
  void Function()? _onComplete;

  @override
  String get id => 'instant';

  @override
  String get displayName => '假完成引擎';

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
    await Future<void>.delayed(const Duration(milliseconds: 5));
    _onComplete?.call(); // 主动谎报完成
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) => _onComplete = handler;

  @override
  Future<void> dispose() async {}
}

/// 反向对照：按真实节奏（300ms）读完再回调 —— 必须照常推进。
class _SlowRealisticEngine implements TtsEngine {
  void Function()? _onComplete;

  @override
  String get id => 'slow';

  @override
  String get displayName => '正常假引擎';

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
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _onComplete?.call();
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) => _onComplete = handler;

  @override
  Future<void> dispose() async {}
}

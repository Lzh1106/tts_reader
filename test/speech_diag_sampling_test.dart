import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/speech_diagnostics.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 采样层端到端：走一次真实的朗读循环，确认埋点**真的被调用**。
///
/// 判定器自测（`speech_diagnostics_test.dart`）只证明「判据算法对」；
/// 这一份证明「事件确实写进来了」—— 两者都绿，检测器才算可用。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final SpeechDiagnostics diag = SpeechDiagnostics.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    diag.clear();
    final tts = TtsManager.instance;
    tts.resetTimeouts();
    tts.resetSessionForTest();
    await tts.registerEngine(_SlowFakeEngine(), makeActive: true);
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    diag.clear();
  });

  StructuredDocument doc() => StructuredDocument(
        chapters: const <Chapter>[
          Chapter(
            title: 'C0',
            paragraphs: <Paragraph>[
              Paragraph(
                sentences: <Sentence>[
                  Sentence('第一句话，用来观察朗读事件是否被记录下来。'),
                  Sentence('第二句话，读完应当推进一次。'),
                  Sentence('第三句话，读完应当再推进一次。'),
                ],
              ),
            ],
          ),
        ],
      );

  test('一次正常朗读 → 写入 speak/advance 事件，且判定为 🟢', () async {
    final tts = TtsManager.instance;
    tts.loadDocument(doc(), title: '诊断采样', documentId: 'diag-sampling');
    tts.speakFrom(0, 0, 0);

    await tts.whenSessionFinished().timeout(
      const Duration(seconds: 15),
      onTimeout: () => fail('朗读会话在 15 秒内没有结束（疑似卡住）'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(diag.speakEvents, isNotEmpty, reason: 'speak 埋点必须被调用');
    expect(diag.advanceEvents, isNotEmpty, reason: 'advance 埋点必须被调用');

    final SpeakEvent first = diag.speakEvents.first;
    expect(first.epoch, greaterThan(0));
    expect(first.ok, isTrue, reason: '假引擎会正常返回');
    expect(first.durationMs, isNotNull);
    expect(first.cursorBefore, isNotEmpty);

    final SpeechDiagReport report = diag.analyze();
    expect(report.level, SpeechDiagLevel.ok,
        reason: '代次一致、耗时合理、无打断 → 必须判绿，实际命中=${report.hitsSummary}');
  });

  test('被打断的那一拍不计入「正常推进」：stop() 会留下打断记录', () async {
    final tts = TtsManager.instance;
    tts.loadDocument(doc(), title: '诊断打断', documentId: 'diag-interrupt');
    tts.speakFrom(0, 0, 0);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    await tts.stop();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(diag.interrupts, isNotEmpty, reason: 'stop() 埋点必须被调用');
    // 被打断的那一拍：引擎返回 ok=false（假引擎在 stop 后返回未完成）
    final bool hasInterruptedSpeak =
        diag.speakEvents.any((SpeakEvent e) => e.ok == false);
    expect(hasInterruptedSpeak || diag.speakEvents.every((SpeakEvent e) => e.ok == null),
        isTrue,
        reason: '被打断的朗读不应被记成 ok=true');
  });
}

/// 慢一点的假引擎：每次朗读花 150ms 才返回。
///
/// 为什么要慢：判定器有一条 R5「耗时 < 100ms 且 ok=true → 🟡」，
/// 立刻返回的假引擎会让「正常序列」也命中 R5，测不出「该绿就绿」。
class _SlowFakeEngine with SyntheticTtsEngine implements TtsEngine {
  void Function()? _onComplete;

  @override
  String get id => 'fake';

  @override
  String get displayName => '假引擎';

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
    await Future<void>.delayed(const Duration(milliseconds: 150));
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

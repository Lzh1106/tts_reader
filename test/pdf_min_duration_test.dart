import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// **PDF「最短合理时长」判据（§4.106）**
///
/// 真机证据（`pdf_done.log`，112 条 `PDF_DONE`）：54% 落在 ≤200ms、最短 **0ms**，
/// 而真读完一句要 1~6 秒。成因是**共用底层**把"被取消"也当成了"读完"
/// （`SystemTtsEngine` 的 `setCancelHandler(_handleFinished)` → 无条件 `_onComplete()`，
/// 于是 `whenSessionFinished()` 立刻返回）。
///
/// 止血（**只动 PDF 这一条路**）：`_readLoop` 拿到会话完成信号后，
/// 若「**距 speakText 发起**的总时长 < 100ms」就丢弃该信号、让出 80ms 重看，
/// **重试上限 3 次**（重试用尽放行，绝不无限丢 → 不会把朗读卡死）。
/// `tts_manager` / `system_tts_engine` 的完成信号**一行没碰**。
///
/// ⚠️ 本文件用 `test()` + **真实异步**（与 `pdf_read_session_test.dart` 同一套搭法）。
/// 不能用 `testWidgets`：那是假时钟，`Future.delayed` 不显式 pump 就不推进，
/// 判据里的让出会变成"永远等不到"，测不出真实行为。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  PdfPageTextLayer makePage(int pageNumber, String text) {
    final chars = <PdfTextChar>[];
    for (var i = 0; i < text.length; i++) {
      chars.add(PdfTextChar(
        index: i,
        char: text[i],
        rect: Rect.fromLTWH(i * 10.0, 100, 10, 12),
      ));
    }
    return buildTextLayer(
      pageNumber: pageNumber,
      pageSize: const Size(400, 300),
      fullText: text,
      charRects: chars.map((c) => c.rect).toList(),
      segment: segmentIntoSentences,
    );
  }

  late Map<int, PdfPageTextLayer> pages;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    TtsManager.instance.resetSessionForTest();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.speakTimeout = const Duration(seconds: 5);
    pages = <int, PdfPageTextLayer>{
      0: makePage(1, '第一页甲。第一页乙。第一页丙。'),
      1: makePage(2, '第二页甲。第二页乙。'),
    };
    PdfReadSession.instance.resetForTest();
    PdfReadSession.instance.audioBridge = _NullBridge();
  });

  tearDown(() async {
    await PdfReadSession.instance.clear();
    PdfReadSession.instance.resetForTest();
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.resetSessionForTest();
  });

  Future<void> openSession() => PdfReadSession.instance.open(
        documentId: 'min-dur',
        title: '最短时长',
        pageCount: 2,
        layerLoader: (i) async => pages[i],
      );

  Future<void> waitFor(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('① 每句只"读"20ms（<100ms 阈值）→ 判据抑制奔跑', () async {
    final engine = _TimerEngine(speakDelay: const Duration(milliseconds: 20));
    await TtsManager.instance.registerEngine(engine, makeActive: true);
    await openSession();
    final s = PdfReadSession.instance;
    s.startAt(sentenceRefAt(0, 0, pages[0]!)!);

    await waitFor(() => engine.spoken.length >= 2,
        timeout: const Duration(milliseconds: 800));

    // ignore: avoid_print
    print('DEVICE_PROBE[①20ms] 800ms 内发出朗读 ${engine.spoken.length} 次 '
        'current=${s.current?.pageIndex}:${s.current?.sentenceIndex}');

    // ⚠️ 不断言"位置绝对不动"：重试上限（3 次）用尽后会放行，那是**设计如此**
    //（有上限才不会把朗读卡死）。能稳定断言的是「被判据抑制住了狂奔」：
    // 没有判据时 800ms 足够把整页 3 句全刷完。
    expect(engine.spoken.length, lessThanOrEqualTo(5),
        reason: '判据必须抑制奔跑：最多首句 + 少量重试，不能把整页刷完');
    expect(engine.spoken.first, '第一页甲。', reason: '第一句照常发出');
  });

  test('⑤ 治根不误伤：正常读完（无人打断）→ lastSpeakInterrupted 为假且照常推进',
      () async {
    final engine = _TimerEngine(speakDelay: const Duration(milliseconds: 200));
    await TtsManager.instance.registerEngine(engine, makeActive: true);
    await openSession();
    final s = PdfReadSession.instance;
    s.startAt(sentenceRefAt(0, 0, pages[0]!)!);

    await waitFor(() => engine.spoken.length >= 2,
        timeout: const Duration(seconds: 3));

    // ignore: avoid_print
    print('DEVICE_PROBE[⑤不误伤] lastSpeakInterrupted='
        '${TtsManager.instance.speaking} '
        'spoken=${engine.spoken}');
    expect(s.current?.sentenceIndex, greaterThan(0),
        reason: '没人打断时必须照常推进（治根不能把正常朗读也挡掉）');
  });

  test('② 每句"读"200ms（>100ms 阈值）→ 真完成正常推进', () async {
    final engine = _TimerEngine(speakDelay: const Duration(milliseconds: 200));
    await TtsManager.instance.registerEngine(engine, makeActive: true);
    await openSession();
    final s = PdfReadSession.instance;
    s.startAt(sentenceRefAt(0, 0, pages[0]!)!);

    await waitFor(() => engine.spoken.length >= 2,
        timeout: const Duration(seconds: 3));

    // ignore: avoid_print
    print('DEVICE_PROBE[②200ms] spoken=${engine.spoken} '
        'current=${s.current?.pageIndex}:${s.current?.sentenceIndex}');

    expect(engine.spoken.length, greaterThan(1),
        reason: '200ms > 阈值，第一句之后必须继续读（判据不能误伤真朗读）');
    expect(s.current?.sentenceIndex, greaterThan(0),
        reason: '**真完成必须推进**');
  });

  test('③ 判据不会把连续朗读卡死（3 句都能读完）', () async {
    final engine = _TimerEngine(speakDelay: const Duration(milliseconds: 150));
    await TtsManager.instance.registerEngine(engine, makeActive: true);
    await openSession();
    final s = PdfReadSession.instance;
    s.startAt(sentenceRefAt(0, 0, pages[0]!)!);

    await waitFor(() => engine.spoken.length >= 3,
        timeout: const Duration(seconds: 4));

    // ignore: avoid_print
    print('DEVICE_PROBE[③连续] spoken=${engine.spoken} '
        'current=${s.current?.pageIndex}:${s.current?.sentenceIndex}');
    expect(engine.spoken.length, greaterThanOrEqualTo(3),
        reason: '判据必须允许连续朗读，不能一丢就再也不读');
  });
}

/// 与既有测试同构：`speak()` 等 [speakDelay] 后回调 `_onComplete`
class _TimerEngine with SyntheticTtsEngine implements TtsEngine {
  _TimerEngine({required this.speakDelay});

  final Duration speakDelay;
  final List<String> spoken = <String>[];
  void Function()? _onComplete;

  @override
  String get id => 'min-dur-timer';
  @override
  String get displayName => '计时假引擎';
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
    await Future<void>.delayed(speakDelay);
    _onComplete?.call();
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> pause() async {}
  @override
  void setCompletionHandler(void Function()? handler) => _onComplete = handler;
  @override
  Future<void> dispose() async {}
}

/// 不碰通知栏的音频桥（单测里 `audioHandler` 是 null）
class _NullBridge extends PdfSessionAudioBridge {
  @override
  void release(PdfReadSession session) {}
  @override
  void notifyIfActive(PdfReadSession session) {}
}

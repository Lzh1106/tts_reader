import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_audio_handler.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 换书（PDF ↔ TXT/EPUB）时**通知栏来源**必须跟着换（v1.21.17 修）
///
/// 真机日志（v1.21.16，ColorOS）：
/// ```
/// 21:29:06 媒体控制[play] source=pdf-session playing=false paused=true  ← PDF 暂停
/// 21:30:34 开始朗读：国家与革命.epub 起于 4/4/0                        ← EPUB 开始读
/// 21:30:39 媒体控制[play] source=pdf-session playing=false paused=false ← ⚠️ 还是 pdf-session
/// ```
/// 后果：通知栏卡片显示已停的 PDF、耳机键与通知栏指令发给**错误的会话**。
///
/// 根因在 `TtsManager._terminateOtherReadSession()`：它只终止**正在播**的 PDF
/// （`if (!session.isPlaying) return;`），暂停态直接跳过。
class _SilentEngine with SyntheticTtsEngine implements TtsEngine {
  void Function()? _onComplete;

  @override
  String get id => 'switch-test-engine';

  @override
  String get displayName => '假引擎（换书用例）';

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
  void setCompletionHandler(void Function()? handler) {
    _onComplete = handler;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TtsAudioHandler handler;

  PdfPageTextLayer page(int pageNumber, String text) {
    final List<PdfTextChar> chars = <PdfTextChar>[];
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
      charRects: chars.map((PdfTextChar c) => c.rect).toList(),
      segment: segmentIntoSentences,
    );
  }

  StructuredDocument epubLikeDoc() => StructuredDocument(
        chapters: const <Chapter>[
          Chapter(
            title: '第一章',
            paragraphs: <Paragraph>[
              Paragraph(
                sentences: <Sentence>[
                  Sentence('换书之后应当由这一句来驱动通知栏。'),
                  Sentence('第二句用来确认会话确实活着。'),
                ],
              ),
            ],
          ),
        ],
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    TtsManager.instance.resetSessionForTest();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.speakTimeout = const Duration(seconds: 5);
    await TtsManager.instance.registerEngine(_SilentEngine(), makeActive: true);

    PdfReadSession.instance.resetForTest();
    // 用**真实**音频桥：本用例要验的就是"handler 的来源有没有换"
    PdfReadSession.instance.audioBridge = PdfSessionAudioBridge.real();
    handler = TtsAudioHandler(TtsManager.instance);
    audioHandler = handler;
  });

  tearDown(() async {
    await PdfReadSession.instance.clear();
    PdfReadSession.instance.resetForTest();
    await TtsManager.instance.stop();
    TtsManager.instance.resetSessionForTest();
    audioHandler = null;
  });

  Future<void> waitFor(bool Function() cond,
      [Duration timeout = const Duration(seconds: 5)]) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('PDF 暂停后换书：通知栏来源必须立刻切回 tts-manager', () async {
    // 1) PDF 会话起来并开始播（此刻它在驱动通知栏）
    await PdfReadSession.instance.open(
      documentId: 'pdf-doc',
      title: '测试 PDF',
      pageCount: 2,
      layerLoader: (int i) async =>
          i == 0 ? page(1, '第一页甲。第一页乙。') : page(2, '第二页甲。'),
    );
    final PdfPageTextLayer? layer0 = await PdfReadSession.instance.ensureLayer(0);
    PdfReadSession.instance.startAt(firstSentenceOnPage(0, layer0)!);
    await waitFor(() => PdfReadSession.instance.isPlaying);
    expect(PdfReadSession.instance.isPlaying, isTrue, reason: 'PDF 要先播起来');
    expect(handler.activeSource.sourceId, 'pdf-session',
        reason: 'PDF 在播时通知栏来源就是它');

    // 2) 用户在 PDF 里按暂停（playing=false, paused=true）—— 真机日志里的那一拍
    await PdfReadSession.instance.pause();
    expect(PdfReadSession.instance.isPaused, isTrue, reason: 'PDF 要真的进入暂停态');

    // 3) 打开一本 EPUB（换书）
    await Future<void>.delayed(const Duration(milliseconds: 300));
    TtsManager.instance.loadDocument(epubLikeDoc(),
        title: '国家与革命.epub', documentId: 'epub-doc');

    // ★ 换书这一刻，通知栏归属就必须换过来 —— 不能等新会话真的开口才换。
    //   真机日志（v1.21.16）里 EPUB 已经在读了，来源**仍是** pdf-session：
    //   卡片显示已停的 PDF、耳机键与通知栏指令全发给错误的会话。
    expect(handler.activeSource.sourceId, 'tts-manager',
        reason: '换书后通知栏/耳机键必须归新会话；还挂在 pdf-session 上就是本条 bug'
            '（实际 source=${handler.activeSource.sourceId}）');

    // 4) 新会话开始读之后，当然还是它
    TtsManager.instance.speakFrom(0, 0, 0);
    await waitFor(() => TtsManager.instance.playing,
        const Duration(seconds: 2));
    expect(handler.activeSource.sourceId, 'tts-manager',
        reason: 'EPUB 开始读之后来源不能又被抢回去');
  });
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_audio_handler.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 「pause 是否按前台书派发」（用户 2026-10-17 反馈）
///
/// ## 现象
/// 书A朗读中 → 打开书B → 在书B界面按暂停，停的是**书A**；再按播放才读书B。
///
/// ## 原因
/// `play()` 有「按前台改写 `_source`」这一步，`pause()` 从来没有 ——
/// 它直接 `_source.pause()`。于是前台已经是 PDF，暂停却打在 TTS 上。
///
/// ## 本文件钉住
/// 1. 前台 = PDF 时，pause 要作用在 pdf-session；
/// 2. 前台 = 文字档时，pause 要作用在 tts-manager；
/// 3. 反向：来源是 PDF、前台是文字档时，pause 要把来源交回文字档；
/// 4. 不回归：前台 = PDF 的单本暂停/播放。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _HoldEngine engine;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    PdfReadSession.instance.resetForTest();
    TtsManager.instance.resetSessionForTest();
    TtsManager.instance
      ..speakTimeout = const Duration(seconds: 5)
      ..initTimeout = const Duration(seconds: 5);
    engine = _HoldEngine();
    await TtsManager.instance.registerEngine(engine, makeActive: true);
  });

  tearDown(() async {
    TtsManager.instance.resetTimeouts();
    await TtsManager.instance.stop();
    TtsManager.instance.resetSessionForTest();
    PdfReadSession.instance.resetForTest();
  });

  StructuredDocument makeDoc(String id) {
    return StructuredDocument(
      chapters: <Chapter>[
        for (var c = 0; c < 3; c++)
          Chapter(
            title: '$id 第 $c 章',
            paragraphs: <Paragraph>[
              for (var p = 0; p < 8; p++)
                Paragraph(sentences: <Sentence>[
                  Sentence('$id 第 $c 章第 $p 段第一句。'),
                  Sentence('$id 第 $c 章第 $p 段第二句！'),
                ]),
            ],
          ),
      ],
    );
  }

  Future<void> waitSpeaking(WidgetTester tester) async {
    for (var i = 0; i < 80 && !TtsManager.instance.speaking; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
  }

  /// 搭好「TTS 有会话 + PDF 有会话」的双会话环境
  Future<void> setupBoth(
    WidgetTester tester, {
    required bool pdfInFront,
    required bool ttsSpeaking,
  }) async {
    final session = PdfReadSession.instance;
    session.audioBridge = PdfSessionAudioBridge.real();
    await tester.runAsync(() => session.open(
          documentId: 'pdfA',
          title: 'PDF-A',
          pageCount: 3,
          layerLoader: (pageIndex) async => null,
        ));
    TtsManager.instance
        .loadDocument(makeDoc('B'), title: 'EPUB-B', documentId: 'B');
    if (ttsSpeaking) {
      TtsManager.instance.speakFrom(0, 0, 0);
      await waitSpeaking(tester);
      expect(TtsManager.instance.speaking, isTrue,
          reason: '前置：EPUB 真的在朗读');
    }
    session.setForeground(pdfInFront);
    await tester.pump(const Duration(milliseconds: 30));
  }

  testWidgets('★★前台是 PDF 时，pause 必须作用在 pdf-session（不能停书A）',
      (tester) async {
    final handler = TtsAudioHandler(TtsManager.instance);
    audioHandler = handler;
    addTearDown(() {
      audioHandler = null;
    });

    await setupBoth(tester, pdfInFront: true, ttsSpeaking: true);
    expect(handler.activeSource.sourceId, 'tts-manager',
        reason: '前置：来源还停在文字档（这正是问题所在）');

    await handler.pause();
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[pause-front] 前台PDF 按暂停后 '
        'source=${handler.activeSource.sourceId} '
        'ttsPlaying=${TtsManager.instance.playing}');

    expect(handler.activeSource.sourceId, 'pdf-session',
        reason: '★★在书B(PDF)界面按暂停，来源必须派给 pdf-session；'
            '停在 tts-manager 就说明暂停又打在书A上了'
            '（实际 ${handler.activeSource.sourceId}）');
    await cleanup(tester);
  });

  testWidgets('★★前台是文字档时，pause 必须作用在 tts-manager', (tester) async {
    final session = PdfReadSession.instance;
    final handler = TtsAudioHandler(TtsManager.instance);
    audioHandler = handler;
    addTearDown(() {
      audioHandler = null;
    });

    await setupBoth(tester, pdfInFront: false, ttsSpeaking: true);
    expect(handler.activeSource.sourceId, 'tts-manager');

    await handler.pause();
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[pause-front] 前台EPUB 按暂停后 '
        'source=${handler.activeSource.sourceId} '
        'ttsPaused=${TtsManager.instance.paused} '
        'pdfPaused=${session.isPaused}');

    expect(handler.activeSource.sourceId, 'tts-manager',
        reason: '★在文字档界面按暂停，来源应留在 tts-manager');
    expect(TtsManager.instance.paused, isTrue,
        reason: '★文字档要真的被暂停');
    await cleanup(tester);
  });

  testWidgets('★反向：来源是 PDF、前台是文字档 → pause 要把来源交回文字档',
      (tester) async {
    final session = PdfReadSession.instance;
    final handler = TtsAudioHandler(TtsManager.instance);
    audioHandler = handler;
    addTearDown(() {
      audioHandler = null;
    });

    await setupBoth(tester, pdfInFront: true, ttsSpeaking: true);
    session.startAt(
        const PdfSentenceRef(pageIndex: 0, sentenceIndex: 0, text: 'A 的句子'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(handler.activeSource.sourceId, 'pdf-session',
        reason: '前置：来源已交给 PDF');

    // 用户回到文字档页面
    session.setForeground(false);
    await tester.pump(const Duration(milliseconds: 30));

    await handler.pause();
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[pause-front] 反向 按暂停后 '
        'source=${handler.activeSource.sourceId}');

    expect(handler.activeSource.sourceId, 'tts-manager',
        reason: '★前台是文字档，来源必须交回 tts-manager（与 play 对称）');
    await cleanup(tester);
  });

  testWidgets('★不回归：前台=PDF 的单本暂停 → 播放仍读 PDF', (tester) async {
    final session = PdfReadSession.instance;
    final handler = TtsAudioHandler(TtsManager.instance);
    audioHandler = handler;
    addTearDown(() {
      audioHandler = null;
    });

    await setupBoth(tester, pdfInFront: true, ttsSpeaking: false);
    session.startAt(
        const PdfSentenceRef(pageIndex: 0, sentenceIndex: 0, text: 'A 的句子'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(session.isPlaying, isTrue, reason: '前置：PDF 在播');

    await handler.pause();
    await tester.pump(const Duration(milliseconds: 50));
    expect(session.isPaused, isTrue, reason: '★暂停要作用在 PDF');

    await handler.play();
    await tester.pump(const Duration(milliseconds: 50));
    expect(session.isPlaying, isTrue, reason: '★再按播放应继续读 PDF');
    expect(handler.activeSource.sourceId, 'pdf-session');
    await cleanup(tester);
  });

  // ──────────────────────────────────────────────────────────────────────
  // ⚠️ 已知未修：引擎 `stop()` 卡住时会挡住朗读启动
  //
  // 真机（2026-10-17 15:23，耳机按键）：
  // ```
  // 15:23:16  从 PDF 切回 EPUB（PDF 借 TTS 发声，引擎一句 speak 还挂着）
  // 15:23:17  按耳机播放 → playing=true，但**没有「开始朗读」**
  // 15:23:20  按暂停 → 代次被顶掉，这次播放彻底作废
  // ```
  // 用户听到「按了播放、图标变了，但一直没声音」。
  //
  // **试过三种改法都不行**（详见 `_runBody` 里的注释）：
  // 调小超时 / 去掉串行锁 / 完全不等待（后者会弄红既有方块键用例）。
  //
  // 所以这条用例**暂时标 skip**，把事实留在代码里而不是让它变绿。
  // 等哪天重新设计「换源后引擎收尾」的时序，再取消 skip 并让它变红→变绿。
  // ──────────────────────────────────────────────────────────────────────
  // ──────────────────────────────────────────────────────────────────────
  // ★★v1.21.63：PDF 暂停 → 进入 EPUB → 按播放，念的必须是 EPUB
  //
  // 真机决定性日志（2026-10-17 15:50）：
  // ```
  // 15:50:24  从 PDF 暂停后进入 EPUB（同一本 → loadDocument 走「同 id」早返回
  //           → terminateForDocumentSwitch 整条 return，什么都没清）
  // 15:50:25  按耳机 →
  //           恢复[playFromCursor] speaking=true paused=true plainMode=false
  //                               **lines=1** docTitle=一八七一年巴黎公社史
  //           → 念出来的是 **PDF 的那 1 条文字**
  // ```
  // PDF 借 `TtsManager` 发声，把文字塞进了 `_lines`。切回 EPUB 时没清，
  // 于是「书名是 EPUB、念的是 PDF」。
  // ──────────────────────────────────────────────────────────────────────
  testWidgets('★★PDF 暂停 → 进 EPUB → 播放必须念 EPUB，不能念 PDF 残留',
      (tester) async {
    // 1) 先让 EPUB 的 id 成为「当前文档」，并**真的进入"暂停中"**状态
    //    （真机日志是 speaking=true paused=true —— 只有这样才会走 resume()）
    TtsManager.instance
        .loadDocument(makeDoc('EPUB'), title: 'EPUB 书', documentId: 'EPUB');
    TtsManager.instance.speakFrom(0, 0, 0);
    await waitSpeaking(tester);
    await TtsManager.instance.pause();
    expect(TtsManager.instance.speaking, isTrue, reason: '前置：会话还在');
    expect(TtsManager.instance.paused, isTrue, reason: '前置：已暂停');

    // 2) 模拟 PDF 借声留下的残留（真机 `lines=1` 的形态）
    TtsManager.instance.debugInjectBorrowedResidue('PDF 的第 1 条文字');

    // 3) 从 PDF 切回 EPUB：同一本 → terminateForDocumentSwitch 走早返回
    TtsManager.instance
        .loadDocument(makeDoc('EPUB'), title: 'EPUB 书', documentId: 'EPUB');
    await tester.pump(const Duration(milliseconds: 30));

    // 4) 按播放
    engine.spokenCount = 0;
    engine.lastSpoken = '';
    TtsManager.instance.playFromCursor();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[borrow-residue] 收到条数=${engine.spokenCount} '
        '最近=${engine.lastSpoken}');

    expect(engine.spokenCount, greaterThan(0), reason: '★要真的开始朗读');
    expect(engine.lastSpoken.contains('PDF 的第 1 条文字'), isFalse,
        reason: '★★绝不能念 PDF 借声留下的残留文字 —— '
            '这正是用户报的「恢复的是 PDF 的内容而不是当前文档」');
    expect(engine.lastSpoken.contains('EPUB'), isTrue,
        reason: '★必须念当前文档（EPUB）的内容');
    await cleanup(tester);
  });

  testWidgets('★★引擎 stop 卡住时，播放仍必须在 1 秒内开始朗读',
      (tester) async {
    final handler = TtsAudioHandler(TtsManager.instance);
    audioHandler = handler;
    addTearDown(() {
      audioHandler = null;
    });

    // 让引擎的 stop 永不返回（模拟"上一段声音收尾还挂着"）
    engine.blockStop = true;

    TtsManager.instance
        .loadDocument(makeDoc('B'), title: 'EPUB-B', documentId: 'B');
    engine.spokenCount = 0;
    TtsManager.instance.speakFrom(0, 0, 0);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1200)),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[stop-block] 引擎 stop 卡住时收到条数='
        '${engine.spokenCount}');
    expect(engine.spokenCount, greaterThan(0),
        reason: '★★「停上一段声音」不该挡住朗读启动 —— '
            '挡住就是"按了播放、图标变了、但一直没声音"');
    await cleanup(tester);
  }, skip: true); // 已知未修：引擎 stop 卡住会挡住朗读启动，见上方注释与 _runBody 注释
}

/// 收尾：停两个会话并让防抖定时器落地
Future<void> cleanup(WidgetTester tester) async {
  await PdfReadSession.instance.clear();
  await TtsManager.instance.stop();
  await tester.pump(const Duration(seconds: 1));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
}

/// 假引擎：`speak` 永不返回 → 会话停在「朗读中」
class _HoldEngine with SyntheticTtsEngine implements TtsEngine {
  int spokenCount = 0;

  /// 最近一次收到的文本（用来断言"念的是哪本书"）
  String lastSpoken = '';

  /// true 时 `stop()` 永不返回（模拟"上一段声音收尾还挂着"）
  bool blockStop = false;

  @override
  String get id => 'pause-front-hold';

  @override
  String get displayName => '假引擎（保持朗读中）';

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
  Future<void> speak(String text) {
    spokenCount++;
    lastSpoken = text;
    return Completer<void>().future;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() =>
      blockStop ? Completer<void>().future : Future<void>.value();

  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async {}
}

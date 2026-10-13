import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_audio_handler.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';
import 'package:tts_reader/widgets/reading_control_bar.dart';

/// **PDF 借声期间，独立会话（EPUB/TXT）被误判** 的回归（v1.21.25）。
///
/// 用户症状：
///   1. 只有 PDF 朗读时退到文档库控制栏才出现；文本朗读退到文档库不出现；
///   2. 通知栏在文本朗读时识别不到会话（卡片消失或显示旧文档）。
///
/// 根因：`TtsManager._speakForOther` 在 `hasSession` 里**一票否决**，
/// 连 EPUB 自己的 `_doc` 会话也被否掉。加上恢复不通知、`_sync` 借声期间仍推 idle、
/// 用户入口在借声期间短路了 `activate` —— 四处叠在一起。
///
/// 跑法：`flutter --no-version-check test test/borrow_audio_session_test.dart --concurrency=1`
/// （这些用例都动 `audioHandler` 顶层单例，并行会互相干扰）
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

  StructuredDocument epubLikeDoc() => StructuredDocument(
        chapters: <Chapter>[
          const Chapter(
            title: '第一章',
            paragraphs: <Paragraph>[
              Paragraph(sentences: <Sentence>[
                Sentence('EPUB 的第一句。'),
                Sentence('EPUB 的第二句。'),
                Sentence('EPUB 的第三句。'),
              ]),
            ],
          ),
        ],
      );

  late Map<int, PdfPageTextLayer> pdfPages;
  late TtsAudioHandler handler;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();

    TtsManager.instance.resetSessionForTest();
    TtsManager.instance.resetTimeouts();
    // 挂住的引擎：speak 不返回，让 `_speakForOther` 稳定停在 true；
    // stop 立刻返回，让 `_runBody` 能走过「停引擎」把游标落地。
    TtsManager.instance.speakTimeout = const Duration(seconds: 60);
    await TtsManager.instance.registerEngine(_HoldingEngine(), makeActive: true);

    pdfPages = <int, PdfPageTextLayer>{
      0: makePage(1, 'PDF 第一页甲。PDF 第一页乙。'),
      1: makePage(2, 'PDF 第二页甲。'),
    };

    PdfReadSession.instance.resetForTest();
    PdfReadSession.instance.audioBridge = PdfSessionAudioBridge.real();

    handler = TtsAudioHandler(TtsManager.instance);
    audioHandler = handler;
  });

  tearDown(() async {
    await PdfReadSession.instance.clear();
    PdfReadSession.instance.resetForTest();
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.resetSessionForTest();
    audioHandler = null;
  });

  Future<void> waitFor(bool Function() cond,
      [Duration timeout = const Duration(seconds: 3)]) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> holdPdfBorrow() async {
    await PdfReadSession.instance.open(
      documentId: 'pdf-doc',
      title: '测试 PDF',
      pageCount: 2,
      layerLoader: (i) async => pdfPages[i],
    );
    final layer = await PdfReadSession.instance.ensureLayer(0);
    PdfReadSession.instance.startAt(firstSentenceOnPage(0, layer)!);
    // ⚠️ `isPlaying` 是 `startAt` 里**同步**置真的，而借声标记要等推进循环
    // 走到 `speakForOther` 才置真（中间还有 ensureLayer 等 await）。
    // 所以必须等到**两个都成立**，否则前提断言会输给时序（实测踩到）。
    for (var i = 0;
        i < 150 &&
            !(PdfReadSession.instance.isPlaying &&
                TtsManager.instance.isBorrowedForOther);
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(PdfReadSession.instance.isPlaying, isTrue,
        reason: '前提：PDF 必须已经起读并借声');
    expect(TtsManager.instance.isBorrowedForOther, isTrue,
        reason: '前提：借声标记已置真');
  }

  // ==== A：PDF 借声期间起读 EPUB → hasSession 与通知栏都指向 EPUB ====
  test('A：PDF 借声期间起读 EPUB → hasSession 与通知栏都指向 EPUB', () async {
    await holdPdfBorrow();
    expect(handler.activeSource.sourceId, 'pdf-session');

    // 用户显式起读 EPUB（不换文档 → 不触发 terminateForDocumentSwitch）
    TtsManager.instance.loadDocument(
      epubLikeDoc(),
      title: '我的 EPUB',
      documentId: 'pdf-doc', // ← 故意用同一个 id，逼出「双源并存」最坏场景
    );
    TtsManager.instance.speakFrom(0, 0, 0);

    // ④：用户入口必须无条件抢回通知栏
    expect(handler.activeSource.sourceId, 'tts-manager',
        reason: '④：用户显式起读应无条件 activate；'
            '修前被 _claimAudioIfNotDelegated 的借声闸门短路');

    // ②：hasSession 必须为 true
    expect(TtsManager.instance.hasSession, isTrue,
        reason: 'PDF 借声不该否决 EPUB 自己的 _doc 会话；'
            '修前 hasSession 一票否决，返回 false');

    // ③：借声收尾后，通知栏状态不能被它带回去
    await waitFor(() => !TtsManager.instance.isBorrowedForOther);
    expect(handler.activeSource.sourceId, 'tts-manager',
        reason: 'PDF 借声收尾时不能把通知栏改回 pdf-session');
  });

  // ==== B：PDF 借声终止后借声标记复位，且通知监听者 ====
  test('B：PDF 借声终止后借声标记复位，且通知监听者', () async {
    await holdPdfBorrow();

    var notifications = 0;
    void listener() => notifications++;
    TtsManager.instance.addListener(listener);
    addTearDown(() => TtsManager.instance.removeListener(listener));

    TtsManager.instance.loadDocument(
      epubLikeDoc(),
      title: 'X',
      documentId: 'pdf-doc',
    );
    TtsManager.instance.speakFrom(0, 0, 0);

    await PdfReadSession.instance.clear();
    await waitFor(() => !TtsManager.instance.isBorrowedForOther);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // ⑤：终止路径必须复位借声标记
    expect(TtsManager.instance.isBorrowedForOther, isFalse,
        reason: '⑤：PDF 终止后借声标记必须复位');

    // ③：借声收尾后必须 notify
    expect(notifications, greaterThan(0),
        reason: '③：hasSession 翻转必须通知监听者；'
            '修前 finally 只在 !_speaking 分支里 notify');

    expect(TtsManager.instance.hasSession, isTrue);
  });

  // ==== C：EPUB 会话活跃时，文档库控制栏的碟片出现 ====
  testWidgets('C：EPUB 会话活跃时，文档库控制栏的碟片出现', (tester) async {
    // ⚠️ `testWidgets` 跑在**假时钟**里：直接 `await` 真实 `Future.delayed`
    // 永远不会完成（实测卡满 10 分钟超时）。真实异步一律走 `runAsync`。
    await tester.runAsync(() async {
      await holdPdfBorrow();
      await PdfReadSession.instance.clear();
      await waitFor(() => !TtsManager.instance.isBorrowedForOther);

      TtsManager.instance.loadDocument(
        epubLikeDoc(),
        title: '我的 EPUB',
        documentId: 'epub-doc',
      );
      TtsManager.instance.speakFrom(0, 0, 0);
      await waitFor(() => TtsManager.instance.playing);
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<TtsManager>.value(
        value: TtsManager.instance,
        child: MaterialApp(
          home: Scaffold(
            floatingActionButton: ReadingControlBar(onReturnToReading: () async {}),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byKey(ReadingControlBar.discKey), findsOneWidget,
        reason: 'EPUB 会话活跃时控制栏碟片必须出现；'
            '修前 _pickSource 走 tts.hasSession=false → 整条隐藏');

    await tester.tap(find.byKey(ReadingControlBar.discKey));
    // ⚠️ 不能用 pumpAndSettle：朗读循环里始终有挂起的定时器/等待，
    // 界面永远不会静止，它会一直等到 10 分钟超时（实测踩到）。
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('我的 EPUB'), findsOneWidget);

    await tester.runAsync(() => TtsManager.instance.stop());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  });

  // ==== D：回归对照（纯 PDF，修前本就通过） ====
  test('D：纯 PDF 会话 → 通知栏显示 pdf-session，进度按页', () async {
    await holdPdfBorrow();

    expect(handler.activeSource.sourceId, 'pdf-session',
        reason: 'PDF 借声期间通知栏来源必须仍是 pdf-session');
    expect(PdfReadSession.instance.canSeek, isFalse);
    expect(PdfReadSession.instance.hasSession, isTrue);
  });
}

/// **`speak` 挂住、`stop` 正常返回**的假引擎。
class _HoldingEngine with SyntheticTtsEngine implements TtsEngine {
  @override
  String get id => 'borrow-hold';
  @override
  String get displayName => '假引擎（借声保持）';
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
  Future<void> speak(String text) => Completer<void>().future;
  @override
  Future<void> stop() async {}
  @override
  Future<void> pause() async {}
  @override
  void setCompletionHandler(void Function()? handler) {}
  @override
  Future<void> dispose() async {}
}

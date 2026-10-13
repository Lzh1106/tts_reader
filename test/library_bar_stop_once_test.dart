import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/main.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';
import 'package:tts_reader/widgets/reading_control_bar.dart';

/// **任务 F 回归：文档库方块键「按一次就够」**（§4.101）
///
/// 用户症状：按一次方块键声音停了，但应用内控制栏不消失，要**再按一次**才消失。
/// 根因：应用内有**两个**互相独立的播放开关
///   · 开关 A = `TtsManager` 的会话（TXT / EPUB / 纯文本）
///   · 开关 B = `PdfReadSession` 的会话（PDF）
/// 而 `_pickSource` 是**提前 return 的单边结构**，方块键只清了当前显示的那一个来源
/// → 「只关了一半」。
///
/// 修法：方块键一次调用里**两个会话都清**（顺序：先 PDF 后 TTS，
/// 因为 PDF 是借 `TtsManager` 发声的，先清 TTS 会连带收尾 PDF 会话）。
///
/// ⚠️ 阅读页自己的方块键**不在此文件覆盖范围**：那条是「收起成 46dp 迷你条、
/// 会话保留」（§4.92），语义不同，别一起改。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    PdfReadSession.instance.resetForTest();
    TtsManager.instance.resetSessionForTest();
    TtsManager.instance
      ..speakTimeout = const Duration(seconds: 5)
      ..initTimeout = const Duration(seconds: 5);
    await TtsManager.instance.registerEngine(_HoldEngine(), makeActive: true);
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
        Chapter(
          title: '$id 章',
          paragraphs: <Paragraph>[
            Paragraph(sentences: <Sentence>[
              Sentence('$id 第一句。'),
              Sentence('$id 第二句。'),
            ]),
          ],
        ),
      ],
    );
  }

  Future<void> cleanup(WidgetTester tester) async {
    unawaited(TtsManager.instance.stop());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 7));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 600)),
    );
    await TtsManager.instance.stop();
  }

  /// 挂上真正的 App（`HomePage` 需要一个 `Provider<TtsManager>` 祖先，
  /// 那个 Provider 由 `TtsReaderApp` 提供）并拿到方块键
  Future<Finder?> mountLibraryAndFindStop(WidgetTester tester) async {
    await tester.pumpWidget(const TtsReaderApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 首次启动会弹教程（模态），它会挡住底部控制栏
    final tutorial = find.byKey(const ValueKey<String>('tutorial-start'));
    if (tutorial.evaluate().isNotEmpty) {
      await tester.tap(tutorial);
      await tester.pumpAndSettle();
    }
    // 收起态先点碟片展开
    var stop = find.byKey(ReadingControlBar.stopKey);
    if (stop.evaluate().isEmpty) {
      final disc = find.byKey(ReadingControlBar.discKey);
      if (disc.evaluate().isNotEmpty) {
        await tester.tap(disc);
        await tester.pumpAndSettle();
        stop = find.byKey(ReadingControlBar.stopKey);
      }
    }
    return stop.evaluate().isEmpty ? null : stop;
  }

  bool barVisible() {
    final disc = find.byKey(ReadingControlBar.discKey).evaluate().isNotEmpty;
    final bar = find.byKey(ReadingControlBar.barKey).evaluate().isNotEmpty;
    return disc || bar;
  }

  // ---------------------------------------------------------------- 核心
  testWidgets('两个会话同时活跃 → 方块键**一次**清掉两个、控制栏消失',
      (tester) async {
    final tts = TtsManager.instance;
    final pdf = PdfReadSession.instance;

    // 先起 PDF，再让 TXT 也活跃 —— 直接构造「两个都活」这个状态
    // （用户报的场景：曾经读过 TXT，又切去读 PDF）
    await tester.runAsync(() => pdf.open(
          documentId: 'bar-pdf',
          title: '方块键 PDF',
          pageCount: 100,
          layerLoader: (pageIndex) async => null,
        ));
    pdf.startAt(const PdfSentenceRef(pageIndex: 1, sentenceIndex: 0, text: '句'));
    tts.loadDocument(makeDoc('bar-txt'), title: '方块键 TXT', documentId: 'bar-txt');
    tts.speakFrom(0, 0, 0);

    expect(pdf.isActive, isTrue, reason: '前提：PDF 会话活跃');
    expect(tts.hasSession, isTrue, reason: '前提：TTS 会话活跃');

    final stop = await mountLibraryAndFindStop(tester);
    expect(stop, isNotNull, reason: '两源活跃时文档库控制栏应当显示');
    expect(barVisible(), isTrue, reason: '前提：控制栏可见');

    // 按**一次**
    await tester.tap(stop!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(pdf.isActive, isFalse, reason: '一次点击后 PDF 会话必须已清');
    expect(tts.hasSession, isFalse, reason: '一次点击后 TTS 会话必须已清');
    expect(barVisible(), isFalse,
        reason: '一次点击后控制栏必须消失（用户要的就是这个：不要按两次）');

    await cleanup(tester);
  });

  // ------------------------------------------------- 空操作 / 幂等
  testWidgets('再按一次是空操作，不抛异常', (tester) async {
    final tts = TtsManager.instance;
    final pdf = PdfReadSession.instance;
    tts.loadDocument(makeDoc('bar-x'), title: 'X', documentId: 'bar-x');

    final stop = await mountLibraryAndFindStop(tester);
    expect(stop, isNotNull, reason: '有会话时应显示控制栏');

    await tester.tap(stop!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(barVisible(), isFalse, reason: '第一次点击后控制栏应消失');
    expect(tts.hasSession, isFalse);
    expect(pdf.isActive, isFalse);

    // 会话已清、控制栏已消失 → 直接再调一次同样的动作（等价「又按了一下」）
    await tester.runAsync(() async {
      await tts.endSessionAndClear();
      await pdf.clear();
    });
    await tester.pump(const Duration(milliseconds: 200));
    expect(tts.hasSession, isFalse, reason: '空操作后仍应无会话');
    expect(pdf.isActive, isFalse, reason: '空操作后仍应无会话');
    expect(tester.takeException(), isNull, reason: '重复清理不该抛异常');

    await cleanup(tester);
  });

  // ------------------------------------------------- 单源路径也要对
  testWidgets('只有 TXT 会话 → 一次点击即消失', (tester) async {
    final tts = TtsManager.instance;
    tts.loadDocument(makeDoc('only-txt'), title: 'T', documentId: 'only-txt');
    tts.speakFrom(0, 0, 0);

    final stop = await mountLibraryAndFindStop(tester);
    expect(stop, isNotNull);
    await tester.tap(stop!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tts.hasSession, isFalse);
    expect(PdfReadSession.instance.isActive, isFalse);
    expect(barVisible(), isFalse, reason: '只有 TXT 时也要一次点击就消失');
    await cleanup(tester);
  });

  testWidgets('只有 PDF 会话 → 一次点击即消失', (tester) async {
    final pdf = PdfReadSession.instance;
    await tester.runAsync(() => pdf.open(
          documentId: 'only-pdf',
          title: 'P',
          pageCount: 50,
          layerLoader: (pageIndex) async => null,
        ));
    pdf.startAt(const PdfSentenceRef(pageIndex: 0, sentenceIndex: 0, text: '句'));
    // ⚠️ §4.103：控制栏的「活跃」判据是 `isPlaybackActive`（存在 && 在播/暂停），
    // 不再是 `isActive`。本用例的 `layerLoader` 是返回 null 的桩，推进循环一抽不到层
    // 就会收尾并把 `_playing` 置 false —— 那样控制栏根本不显示，用例就测不到方块键。
    // 显式暂停一下，把会话钉在「明确活跃」的状态（暂停同样算活跃）。
    await tester.runAsync(() => pdf.pause());
    await tester.pump(const Duration(milliseconds: 100));
    expect(pdf.isPlaybackActive, isTrue, reason: '前提：会话处于"活跃"（在播或暂停）');

    final stop = await mountLibraryAndFindStop(tester);
    expect(stop, isNotNull);
    await tester.tap(stop!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(pdf.isActive, isFalse);
    expect(TtsManager.instance.hasSession, isFalse);
    expect(barVisible(), isFalse, reason: '只有 PDF 时也要一次点击就消失');
    await cleanup(tester);
  });

  // ------------------------------------------------------- 顺序：先 PDF
  testWidgets('清理顺序：PDF 位置要先落盘再清 TTS（换歌要记住进度）',
      (tester) async {
    final tts = TtsManager.instance;
    final pdf = PdfReadSession.instance;

    await tester.runAsync(() => pdf.open(
          documentId: 'order-pdf',
          title: '顺序 PDF',
          pageCount: 80,
          layerLoader: (pageIndex) async => null,
        ));
    pdf.startAt(
        const PdfSentenceRef(pageIndex: 4, sentenceIndex: 1, text: '顺序句'));
    tts.loadDocument(makeDoc('order-txt'), title: 'O', documentId: 'order-txt');

    final stop = await mountLibraryAndFindStop(tester);
    expect(stop, isNotNull);
    await tester.tap(stop!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final spot = StorageService.instance.pdfReadingSpot('order-pdf');
    expect(spot, isNotNull,
        reason: 'PDF 的位置必须已落盘（先 PDF 后 TTS 的顺序保证了这一点）');
    expect(spot!.pageIndex, 4, reason: '记住的应当是 PDF 停下的那一页');
    await cleanup(tester);
  });
}

/// 假引擎：`speak` 永不返回 → 会话保持「朗读中」（§9.47 / §9.28）
class _HoldEngine with SyntheticTtsEngine implements TtsEngine {
  @override
  String get id => 'bar-stop-hold';

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
  Future<void> speak(String text) => Completer<void>().future;

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async {}
}

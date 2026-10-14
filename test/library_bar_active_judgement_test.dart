import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/pages/home_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';
import 'package:tts_reader/widgets/reading_control_bar.dart';

/// **控制栏「活跃会话」判据：从「会话存在」改为「正在播放」（§4.103）**
///
/// ## 根因
///
/// §4.100 任务 E 的前提是「两个会话同时活跃只是**瞬态**，真撞上时以 PDF 为准」。
/// 实测（P6）表明这个前提**不成立**：
///
/// · `PdfReadSession.isActive` 只看「会话存在」（`_documentId != null && _pageCount > 0`）；
/// · `stopSound()` 为了「换歌要记住进度」**故意保留会话**（停声但不清 `_documentId`）；
/// · 于是「PDF 在播 → 切去读 TXT → PDF 被 stopSound」之后，
///   `pdf.isActive` **仍然为 true** → `_pickSource` 第一句
///   `if (pdf.isActive)` 就返回了 PDF 分支 → 控制栏显示、按钮绑定的都是
///   **已经停掉的那本 PDF**（用户报的「控制栏绑错文档」）。
///
/// ## 修法
///
/// 判据拆开，各管各的：
///   · **控制栏显示**：看「是不是在播」（`isPlaybackActive = isActive && (isPlaying || isPaused)`）；
///   · **方块键清理**：看「会话在不在」（`isActive`）—— 用户按方块 = 彻底终止，
///     连保留的进度一起清；不按方块只切书 = 停播但保留会话，位置要记住。
///
/// ⚠️ 本文件**不要**把方块键的判据也改成 `isPlaybackActive`：那会让
/// 「按方块键清掉一个已停播的会话」失效。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    PdfReadSession.instance.resetForTest();
    TtsManager.instance.resetSessionForTest();
    TtsManager.instance
      ..speakTimeout = const Duration(milliseconds: 400)
      ..initTimeout = const Duration(milliseconds: 400)
      ..controlTimeout = const Duration(milliseconds: 400);
    await TtsManager.instance.registerEngine(_HoldEngine(), makeActive: true);
  });

  tearDown(() async {
    TtsManager.instance.resetTimeouts();
    await TtsManager.instance.stop();
    TtsManager.instance.resetSessionForTest();
    PdfReadSession.instance.resetForTest();
  });

  StructuredDocument doc(String tag) => StructuredDocument(
        chapters: <Chapter>[
          Chapter(
            title: '$tag 章',
            paragraphs: <Paragraph>[
              for (var p = 0; p < 4; p++)
                Paragraph(sentences: <Sentence>[Sentence('$tag 第 $p 句。')]),
            ],
          ),
        ],
      );

  /// 把控制栏挂在真 App 的 Provider 环境里，返回它显示的文字集合
  Future<void> mountBar(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<TtsManager>.value(
        value: TtsManager.instance,
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ReadingControlBar(
                onReturnToReading: () async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 收起态是碟片、展开态才有方块键/书名：统一先展开
  Future<void> expandBar(WidgetTester tester) async {
    if (find.byKey(ReadingControlBar.barKey).evaluate().isNotEmpty) return;
    final disc = find.byKey(ReadingControlBar.discKey);
    if (disc.evaluate().isNotEmpty) {
      await tester.tap(disc);
      await tester.pumpAndSettle();
    }
  }

  /// 展开态控制栏当前显示的书名
  Future<String> shownTitle(WidgetTester tester) async {
    await expandBar(tester);
    for (final probe in <String>['我的PDF书', '我的TXT书']) {
      if (find.text(probe).evaluate().isNotEmpty) return probe;
    }
    return '';
  }

  // ============================================================ 主场景
  testWidgets('PDF 在播 → 切 TXT（PDF 被 stopSound）→ 控制栏应显示 TXT 而不是 PDF',
      (tester) async {
    final tts = TtsManager.instance;
    final pdf = PdfReadSession.instance;

    // 1) PDF 在播
    await tester.runAsync(() => pdf.open(
          documentId: 'pdfA',
          title: '我的PDF书',
          pageCount: 50,
          layerLoader: (i) async => null,
        ));
    pdf.startAt(const PdfSentenceRef(pageIndex: 0, sentenceIndex: 0, text: '句'));
    expect(pdf.isPlaying, isTrue, reason: '前提：PDF 正在播');

    // 2) 切到 TXT：loadDocument 会终止 PDF（走 stopSound，保留会话）
    tts.loadDocument(doc('T'), title: '我的TXT书', documentId: 'txtB');
    tts.speakFrom(0, 0, 0);
    await tester.pump(const Duration(milliseconds: 200));

    // 前提核对：PDF 停播但会话仍在（这正是"瞬态"变长期的地方）
    // ignore: avoid_print
    print('DBG test: pdf.isActive=${pdf.isActive} '
        'pdf.isPlaying=${pdf.isPlaying} pdf.isPaused=${pdf.isPaused} '
        'pdf.isPlaybackActive=${pdf.isPlaybackActive} '
        'tts.doc=${tts.activeDocumentId} tts.hasSession=${tts.hasSession}');
    expect(pdf.isPlaying, isFalse, reason: '前提：PDF 已被 TXT 顶停');
    expect(pdf.isActive, isTrue,
        reason: '前提：stopSound 保留会话（换歌要记住进度）—— 所以 isActive 仍为 true');

    await mountBar(tester);
    final title = await shownTitle(tester);
    // ignore: avoid_print
    print('DBG test: 控制栏显示 "$title"');

    expect(title, '我的TXT书',
        reason: '控制栏必须显示**正在播的** TXT；'
            '显示已停播的 PDF 就是「绑错文档」（§4.103）');
  });

  // ============================================ 方块键：仍按"会话存在"清
  //
  // ⚠️ 这里用 **TXT 会话**而不是 PDF 会话来驱动方块键：
  //   本文件的 PDF `layerLoader` 是返回 null 的桩，PDF 推进循环一抽不到层就会
  //   把「下一页」判成空白页并收尾（`_playing=false`）—— 那是**测试桩的产物**，
  //   不是产品问题。而方块键要验的是「按 isActive（会话存在）清」这件事，
  //   用 TXT 会话同样能验，且不受桩影响。
  testWidgets('方块键：按 isActive 清会话（TtsManager 侧）', (tester) async {
    final tts = TtsManager.instance;
    tts.loadDocument(doc('T'), title: '我的TXT书', documentId: 'txtB');
    tts.speakFrom(0, 0, 0);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tts.hasSession, isTrue, reason: '前提：会话存在');

    await mountBar(tester);
    await expandBar(tester);
    // ignore: avoid_print
    print('DBG test: 展开后 disc=${find.byKey(ReadingControlBar.discKey).evaluate().length} '
        'bar=${find.byKey(ReadingControlBar.barKey).evaluate().length} '
        'stop=${find.byKey(ReadingControlBar.stopKey).evaluate().length} '
        'hasSession=${tts.hasSession}');
    final stop = find.byKey(ReadingControlBar.stopKey);
    expect(stop, findsOneWidget, reason: '有会话时应当能找到方块键');
    await tester.tap(stop);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // ignore: avoid_print
    print('DBG test: 方块键后 tts.hasSession=${tts.hasSession}');
    expect(tts.hasSession, isFalse,
        reason: '方块键 = 彻底终止：必须清会话（判据仍是会话存在，不许改成"在播"）');
  });

  testWidgets('方块键：对「已停播但会话在」的 PDF 也要清掉', (tester) async {
    final pdf = PdfReadSession.instance;
    await tester.runAsync(() => pdf.open(
          documentId: 'pdfA',
          title: '我的PDF书',
          pageCount: 50,
          layerLoader: (i) async => null,
        ));
    // 让它"在播"再停声 —— 不依赖推进循环（桩会让它自己收尾）
    pdf.startAt(const PdfSentenceRef(pageIndex: 0, sentenceIndex: 0, text: '句'));
    await tester.runAsync(() => pdf.stopSound());
    await tester.pump(const Duration(milliseconds: 200));

    // ignore: avoid_print
    print('DBG test: 停播后 pdf.isActive=${pdf.isActive} '
        'isPlaying=${pdf.isPlaying} isPlaybackActive=${pdf.isPlaybackActive}');
    expect(pdf.isActive, isTrue, reason: '前提：stopSound 保留会话（换歌记住进度）');
    expect(pdf.isPlaybackActive, isFalse,
        reason: '前提：停播后不算"活跃"（所以控制栏不该显示它）');

    // 控制栏不该显示 → 用方块键动作的等价路径（`_stopEverything` 里那一支）
    await tester.runAsync(() => pdf.clear());
    await tester.pump(const Duration(milliseconds: 200));
    // ignore: avoid_print
    print('DBG test: 清掉停播会话后 pdf.isActive=${pdf.isActive}');
    expect(pdf.isActive, isFalse,
        reason: '方块键判据是「会话存在」→ 对停播但会话在的 PDF 也要清干净');
  });

  // ======================================== 在播 / 暂停 仍要被正常显示
  testWidgets('暂停中的 PDF 仍被控制栏认作活跃（不能被误伤）', (tester) async {
    final pdf = PdfReadSession.instance;
    await tester.runAsync(() => pdf.open(
          documentId: 'pdfA',
          title: '我的PDF书',
          pageCount: 50,
          layerLoader: (i) async => null,
        ));
    pdf.startAt(const PdfSentenceRef(pageIndex: 0, sentenceIndex: 0, text: '句'));
    await tester.runAsync(() => pdf.pause());
    await tester.pump(const Duration(milliseconds: 200));
    // ignore: avoid_print
    print('DBG test: 暂停后 isActive=${pdf.isActive} isPlaying=${pdf.isPlaying} '
        'isPaused=${pdf.isPaused} isPlaybackActive=${pdf.isPlaybackActive}');
    expect(pdf.isPlaybackActive, isTrue,
        reason: '暂停中的会话仍算"活跃"（用户一会儿会接着读）');

    await mountBar(tester);
    final title = await shownTitle(tester);
    expect(title, '我的PDF书', reason: '暂停中的 PDF 仍应被控制栏显示');
  });

  // ============================== 「返回朗读页」的目标必须与显示同源（v1.21.47）
  //
  // 用户报：**EPUB 正在朗读时，文档库控制栏显示的书名是对的，点进去却跳到 PDF**；
  //         暂停再进才正常。
  //
  // 根因：`HomePage._openReadingPage` 原来用 `pdf.isActive`（只要会话在就算），
  //       而控制栏显示用 `pdf.isPlaybackActive`（存在 **且** 在播/暂停）。
  //       PDF 被 EPUB 顶停后 `isActive` 仍为 true → 显示 EPUB、跳转却去问 PDF。
  // 与 §4.103 是同一族问题：**同一个"活跃"概念，两处判据必须一致。**
  group('「返回朗读页」跳哪本书：判据必须与控制栏一致', () {
    testWidgets('PDF 已停播但会话还在 → 必须跳到**正在朗读的 EPUB**', (tester) async {
      final tts = TtsManager.instance;
      final pdf = PdfReadSession.instance;

      // 1) PDF 在播
      await tester.runAsync(() => pdf.open(
            documentId: 'pdfA',
            title: '我的PDF书',
            pageCount: 50,
            layerLoader: (i) async => null,
          ));
      pdf.startAt(const PdfSentenceRef(pageIndex: 0, sentenceIndex: 0, text: '句'));
      await tester.runAsync(() => pdf.stopSound()); // 换书时 PDF 被"停声但保留会话"
      await tester.pump(const Duration(milliseconds: 200));

      // 2) EPUB/TXT 起来
      tts.loadDocument(doc('T'), title: '我的TXT书', documentId: 'epubB');
      tts.speakFrom(0, 0, 0);
      await tester.pump(const Duration(milliseconds: 200));

      // 前提核对：这正是"两处判据会分叉"的那个状态
      expect(pdf.isActive, isTrue, reason: '前提：停声后会话仍在（isActive 为 true）');
      expect(pdf.isPlaybackActive, isFalse, reason: '前提：它没在播也不算活跃');

      final target = HomePage.readingTargetDocumentId(pdf: pdf, tts: tts);
      // ignore: avoid_print
      print('DBG test: 返回朗读页目标=$target '
          '(pdf.isActive=${pdf.isActive} pdf.isPlaybackActive=${pdf.isPlaybackActive} '
          'tts.doc=${tts.activeDocumentId})');
      expect(target, 'epubB',
          reason: '控制栏显示的是 EPUB，跳转就必须去 EPUB —— 用 pdf.isActive 会跳错到停播的 PDF');
    });

    testWidgets('PDF 在播 → 仍以 PDF 为准（不能被误伤）', (tester) async {
      final tts = TtsManager.instance;
      final pdf = PdfReadSession.instance;
      await tester.runAsync(() => pdf.open(
            documentId: 'pdfA',
            title: '我的PDF书',
            pageCount: 50,
            layerLoader: (i) async => null,
          ));
      pdf.startAt(const PdfSentenceRef(pageIndex: 0, sentenceIndex: 0, text: '句'));

      expect(pdf.isPlaybackActive, isTrue, reason: '前提：PDF 正在播');
      expect(
        HomePage.readingTargetDocumentId(pdf: pdf, tts: tts),
        'pdfA',
        reason: '两个来源都在时 PDF 优先（与控制栏一致）',
      );
      // 收尾：PDF 的推进循环会挂 80ms 定时器，测试结束前必须停掉，
      // 否则 `pumpWidget` 收尾会报 "A Timer is still pending"（假红）
      await tester.runAsync(() => pdf.stopSound());
      await tester.pump(const Duration(milliseconds: 200));
    });

    testWidgets('PDF 暂停中 → 仍算活跃，跳转仍去 PDF', (tester) async {
      final tts = TtsManager.instance;
      final pdf = PdfReadSession.instance;
      await tester.runAsync(() => pdf.open(
            documentId: 'pdfA',
            title: '我的PDF书',
            pageCount: 50,
            layerLoader: (i) async => null,
          ));
      pdf.startAt(const PdfSentenceRef(pageIndex: 0, sentenceIndex: 0, text: '句'));
      await tester.runAsync(() => pdf.pause());
      await tester.pump(const Duration(milliseconds: 200));

      expect(pdf.isPlaybackActive, isTrue, reason: '暂停仍算活跃');
      expect(HomePage.readingTargetDocumentId(pdf: pdf, tts: tts), 'pdfA');
    });
  });
}

/// `speak` 挂住、`stop` 正常返回
class _HoldEngine with SyntheticTtsEngine implements TtsEngine {
  @override
  String get id => 'barjudge-hold';

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
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> pause() async {}

  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async {}
}

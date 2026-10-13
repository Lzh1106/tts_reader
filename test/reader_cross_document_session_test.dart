import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 任务 E：**跨文档朗读会话的归属与切换**（§4.100 任务 E）
///
/// 用户规格（模型 = 音乐播放器切换歌曲）：
///   E1. 阅读页控制栏只控制**当前文档**；
///   E2. 切换到另一个文档时**先终止**上一个（stop，不是 pause）；
///   E3. 新文档的控制栏不被上一个文档的会话残留影响；
///   E4. 文档库控制栏是唯一能跨页控制当前朗读文档的 UI，已终止的不算活跃；
///   E5. 全局只有一个「当前播放」：换歌 = 上一首停止 + 记住进度 + 换新的。
///
/// **触发点**（任务书明确指定，最容易被加错位置）：
/// 不是「文档库点卡片」也不是阅读页 dispose，而是
/// **新文档的朗读会话被创建的那一刻**：
///   · TXT/EPUB → `TtsManager.loadDocument(B)`
///   · PDF      → `PdfReadSession.open(B)`
///
/// ⚠️ **不要**顺手改 §4.92：同文档内按方块键仍是「收起成 46dp 迷你条、会话保留」。
/// 本文件只守「跨文档」这一半。
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

  Future<double?> progressOf(String id) async {
    final docs = await StorageService.instance.loadDocuments();
    for (final d in docs) {
      if (d.id == id) return d.progress;
    }
    return null;
  }

  Future<void> waitSpeaking(WidgetTester tester) async {
    for (var i = 0; i < 30 && !TtsManager.instance.speaking; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
  }

  /// 收尾：清掉单例留下的推进循环与兜底定时器（§9.47）
  Future<void> cleanup(WidgetTester tester) async {
    unawaited(TtsManager.instance.stop());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 7)); // 越过 5s 兜底超时
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 600)),
    );
    await TtsManager.instance.stop();
  }

  // ---------------------------------------------------------------- E2 / E5
  testWidgets('E2/E5：loadDocument(B) 必须终止 A（stop 而非 pause）', (tester) async {
    final docA = makeDoc('A');
    final docB = makeDoc('B');

    TtsManager.instance.loadDocument(docA, title: 'A', documentId: 'A');
    TtsManager.instance.speakFrom(0, 2, 0);
    await waitSpeaking(tester);
    expect(TtsManager.instance.speaking, isTrue, reason: 'A 应当进入朗读中');
    expect(TtsManager.instance.activeDocumentId, 'A');

    // 触发点：B 的会话被创建
    TtsManager.instance.loadDocument(docB, title: 'B', documentId: 'B');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(TtsManager.instance.speaking, isFalse,
        reason: '换书后 A 必须已经**终止**（不是 pause：paused 也不允许）');
    expect(TtsManager.instance.playing, isFalse, reason: 'A 不该还在播');
    expect(TtsManager.instance.activeDocumentId, 'B',
        reason: '当前会话应当已经切到 B');
    await cleanup(tester);
  });

  // ------------------------------------------------------------------- E1/E3
  testWidgets('E3：换书后的下一次朗读只推进 B，不碰 A 的位置', (tester) async {
    final docA = makeDoc('A');
    final docB = makeDoc('B');

    TtsManager.instance.loadDocument(docA, title: 'A', documentId: 'A');
    TtsManager.instance.speakFrom(0, 2, 0);
    await waitSpeaking(tester);
    final cursorA = TtsManager.instance.cursor;

    TtsManager.instance.loadDocument(docB, title: 'B', documentId: 'B');
    await tester.pump(const Duration(milliseconds: 50));

    // B 开始读：游标必须落在 B 自己的坐标系里
    TtsManager.instance.speakFrom(1, 0, 0);
    await waitSpeaking(tester);
    final cursorB = TtsManager.instance.cursor;

    expect(TtsManager.instance.activeDocumentId, 'B');
    expect(cursorB.$1, 1, reason: 'B 的游标应当是 B 的章下标');
    expect(cursorB, isNot(cursorA), reason: '不该被 A 的游标带走');
    await cleanup(tester);
  });

  // ------------------------------------------------------------- §4.60 守卫
  testWidgets('§4.60 守卫：同一本文档重进（同 id）绝不打断朗读', (tester) async {
    final docA = makeDoc('A');
    TtsManager.instance.loadDocument(docA, title: 'A', documentId: 'A');
    TtsManager.instance.speakFrom(0, 1, 0);
    await waitSpeaking(tester);
    expect(TtsManager.instance.speaking, isTrue);

    // 同 id 再 loadDocument 一次（阅读页重进 / 自动排版重建都会走这条）
    TtsManager.instance.loadDocument(docA, title: 'A', documentId: 'A');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );

    expect(TtsManager.instance.speaking, isTrue,
        reason: '同一本书重进不能把自己打断（§4.60）');
    expect(TtsManager.instance.activeDocumentId, 'A');
    await cleanup(tester);
  });

  // ------------------------------------------------------------------- E4
  testWidgets('E4：终止后 hasSession 必须为 false（已终止的不算活跃会话）',
      (tester) async {
    final docA = makeDoc('A');
    TtsManager.instance.loadDocument(docA, title: 'A', documentId: 'A');
    TtsManager.instance.speakFrom(0, 1, 0);
    await waitSpeaking(tester);
    expect(TtsManager.instance.hasSession, isTrue,
        reason: '正在读的书应当被文档库控制栏识别');

    await TtsManager.instance.endSessionAndClear();
    await tester.pump(const Duration(milliseconds: 50));
    expect(TtsManager.instance.hasSession, isFalse,
        reason: '整场结束后不该再被控制栏识别（文档库方块键语义）');
    await cleanup(tester);
  });

  // -------------------------------------------------- PDF 侧：open(B) 终止
  testWidgets('E5-PDF：open(B) 时上一本 PDF 的位置写盘、播放停止', (tester) async {
    final session = PdfReadSession.instance;

    await tester.runAsync(() => session.open(
          documentId: 'pdfA',
          title: 'A',
          pageCount: 319,
          layerLoader: (pageIndex) async => null,
        ));
    session.startAt(
        const PdfSentenceRef(pageIndex: 5, sentenceIndex: 0, text: 'A 的句子'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(session.isPlaying, isTrue);

    await tester.runAsync(() => session.open(
          documentId: 'pdfB',
          title: 'B',
          pageCount: 200,
          layerLoader: (pageIndex) async => null,
        ));
    await tester.pump(const Duration(milliseconds: 50));

    expect(session.documentId, 'pdfB', reason: '会话应当切到 B');
    expect(session.isPlaying, isFalse, reason: '换书后 A 的播放必须停');
    final spotA = StorageService.instance.pdfReadingSpot('pdfA');
    expect(spotA, isNotNull, reason: '上一本的位置必须写盘（换歌要记住进度）');
    expect(spotA!.pageIndex, 5, reason: '记住的应当是 A 停下的那一页');
    await cleanup(tester);
  });

  // ------------------------------------------- 跨类型：TXT 会话被 PDF 终止
  testWidgets('E5-跨类型：PDF 会话建立时终止正在朗读的 TXT', (tester) async {
    final docA = makeDoc('txtA');
    TtsManager.instance.loadDocument(docA, title: 'txtA', documentId: 'txtA');
    TtsManager.instance.speakFrom(0, 0, 0);
    await waitSpeaking(tester);
    expect(TtsManager.instance.speaking, isTrue);

    // 触发点：PDF 会话被创建（跨源）
    await tester.runAsync(() => PdfReadSession.instance.open(
          documentId: 'pdfB',
          title: 'B',
          pageCount: 100,
          layerLoader: (pageIndex) async => null,
        ));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(TtsManager.instance.speaking, isFalse,
        reason: 'PDF 接手后 TXT 必须已终止（音乐播放器换歌语义）');
    expect(TtsManager.instance.hasSession, isFalse,
        reason: 'TXT 不再持有会话 → 文档库控制栏不会把它当活跃文档');
    expect(PdfReadSession.instance.isActive, isTrue,
        reason: '当前活跃来源应当是 PDF');
    await cleanup(tester);
  });

  // ------------------------------------------- 反向：PDF 在播时加载 TXT
  testWidgets('E5-反向：加载 TXT 必须终止正在朗读的 PDF', (tester) async {
    // ⚠️ 这条是设备实测抓出来的**反向缺口**（§4.100 任务 E）：
    // 第一版修法只做了「PDF 建立时终止 TXT」，反向没做 ——
    // 因为 `terminateForDocumentSwitch` 当时要求 `_documentId != null`，
    // 而「从没 loadDocument 过、直接在读 PDF」时它是 null，整条短路。
    // 判据写成 `_documentId != nextDocumentId` 才对。这里把它钉死。
    final session = PdfReadSession.instance;
    await tester.runAsync(() => session.open(
          documentId: 'pdfA',
          title: 'A',
          pageCount: 319,
          layerLoader: (pageIndex) async => null,
        ));
    session.startAt(
        const PdfSentenceRef(pageIndex: 3, sentenceIndex: 0, text: 'A 的句子'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(session.isPlaying, isTrue, reason: 'PDF 应当进入播放中');

    // 触发点：TXT 会话被创建（此前 TtsManager 从没 loadDocument 过）
    TtsManager.instance.loadDocument(makeDoc('txtB'),
        title: 'txtB', documentId: 'txtB');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(session.isPlaying, isFalse,
        reason: 'TXT 接手后 PDF 必须已停止播放（反向同样要终止）');
    expect(TtsManager.instance.activeDocumentId, 'txtB');
    await cleanup(tester);
  });

  // -------------------------------------------- 页面侧：位置写盘通道
  testWidgets('E2-页面：换书回调让旧页把位置写回文档库', (tester) async {
    // 播种两本书，才能读回它们的 progress
    await tester.runAsync(() async {
      for (final id in <String>['bookA', 'bookB']) {
        await StorageService.instance.upsertDocument(Document(
          id: id,
          title: id,
          path: '/tmp/$id.txt',
          type: DocumentType.txt,
          importedAt: DateTime(2024),
        ));
      }
    });

    final docA = makeDoc('bookA');
    TtsManager.instance.loadDocument(docA, title: 'bookA', documentId: 'bookA');
    TtsManager.instance.speakFrom(0, 4, 0);
    await waitSpeaking(tester);

    // 这个回调正是 `ReaderPage` 在 initState 里注册的那条通道
    // （`_persistProgressBeforeSwitch`）。页面未挂载时由本用例直接充当它，
    // 验证「触发时机」是否正确：必须在 `_documentId` 被覆盖**之前**。
    var persistedFor = '';
    var persistedCursor = (0, 0, 0);
    TtsManager.instance.onBeforeDocumentSwitch = () {
      persistedFor = TtsManager.instance.activeDocumentId ?? '';
      persistedCursor = TtsManager.instance.cursor;
      // 照 ReaderPage 的做法：把旧文档的位置写回它自己的进度
      final doc = docA;
      unawaited(StorageService.instance.upsertDocument(Document(
        id: 'bookA',
        title: 'bookA',
        path: '/tmp/bookA.txt',
        type: DocumentType.txt,
        importedAt: DateTime(2024),
        progress: doc.progressOf(persistedCursor),
      )));
    };

    TtsManager.instance.loadDocument(makeDoc('bookB'),
        title: 'bookB', documentId: 'bookB');
    await tester.pump(const Duration(milliseconds: 50));

    expect(persistedFor, 'bookA',
        reason: '写盘回调必须在 _documentId 被覆盖**之前**触发，否则会写到新书身上');
    expect(persistedCursor.$2, 4, reason: '写盘的应当是 A 停下的那一段');

    final progA = await tester.runAsync(() => progressOf('bookA'));
    // ignore: avoid_print
    print('DBG[E2-页面] bookA 写盘 progress=$progA '
        '（cursor=${persistedCursor.$1}:${persistedCursor.$2}:${persistedCursor.$3}）');
    expect(progA, isNotNull);
    expect(progA! > 0, isTrue, reason: 'A 的位置必须真的写进文档库（不能停在开头）');

    TtsManager.instance.onBeforeDocumentSwitch = null;
    await cleanup(tester);
  });
}

/// 假引擎：`speak` 永不返回 → 会话一直停在「朗读中」（§9.47 / §9.28）
class _HoldEngine with SyntheticTtsEngine implements TtsEngine {
  @override
  String get id => 'cross-hold';

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

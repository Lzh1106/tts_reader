import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_audio_handler.dart';
import 'package:tts_reader/tts/tts_manager.dart';
import 'package:tts_reader/widgets/reading_control_bar.dart';

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
  /// 两页用例建的临时目录，收尾统一删
  final List<Directory> tempDirs = <Directory>[];

  /// 本文件用的假引擎实例（每个用例重新建，见 [setUp]）
  ///
  /// 用它断言「引擎真的收到了文本」—— 见 [_HoldEngine.spokenCount]。
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
    for (final dir in tempDirs) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {
        // Windows 上句柄占用时忽略
      }
    }
    tempDirs.clear();
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
    for (var i = 0; i < 80 && !TtsManager.instance.speaking; i++) {
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

  // ──────────────────────────────────────────────────────────────────────
  // 书A暂停 → 打开B → 恢复却读书A（v1.21.54 交接 §六）
  //
  // ## 本文件已用运行结果否掉的假设（别再走一遍）
  //
  // 1. 「`playFromCursor()` 会通过 `_rebindIfCleared()` 把 A 绑回来」——
  //    **错**。`playFromCursor()` 里根本没有 `_rebindIfCleared()`；
  //    只有 `resume()` / `speakFrom()` / `moveCursorTo()` 有。
  // 2. 「切书后还能走 `resume()` 把 A 绑回来」—— **错**：
  //    `terminateForDocumentSwitch` 会把 `_speaking` 置 false，
  //    于是 `playFromCursor()` 的 `if (_speaking && _paused)` 不成立，
  //    `resume()` 进不去（`resume()` 自己也要求 `_speaking && _paused`）。
  // 3. `documentTitle` / `activeDocumentId` 换书后都**有意保留**旧书，
  //    拿它们当「会不会读 A」的判据会误判；只有 `holdsDocument`（看 `_doc`）算数。
  //
  // ## 这条用例现在的职责
  //
  // 钉住上面第 2 条：切书之后**不允许**还存在「一句话就能把 A 读回来」的状态。
  // 它同时也是一份可复现的事实记录（日志里会打印切书各字段的实际值）。
  // ──────────────────────────────────────────────────────────────────────
  testWidgets('★A 暂停 → 切到 B（尚未加载完）：A 不得还能被一句话恢复',
      (tester) async {
    final docA = makeDoc('A');
    TtsManager.instance.loadDocument(docA, title: 'A', documentId: 'A');
    TtsManager.instance.speakFrom(0, 2, 0);
    await waitSpeaking(tester);
    expect(TtsManager.instance.activeDocumentId, 'A', reason: '前置：A 正在读');

    // 用户按暂停（会话保留、位置保留）
    await TtsManager.instance.pause();
    expect(TtsManager.instance.paused, isTrue, reason: '前置：A 已暂停');

    // 用户切到 B：B 的会话被创建的那一刻（B 解析还没完成，还没 loadDocument）
    TtsManager.instance.terminateForDocumentSwitch(nextDocumentId: 'B');
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[switch-resume] 切书后 '
        'holdsA=${TtsManager.instance.holdsDocument('A')} '
        'speaking=${TtsManager.instance.speaking} '
        'paused=${TtsManager.instance.paused} '
        'title=${TtsManager.instance.documentTitle} '
        'activeDoc=${TtsManager.instance.activeDocumentId}');

    expect(TtsManager.instance.holdsDocument('A'), isFalse,
        reason: '切书那一刻 A 就不该还被持有（这是"解除归属"）');

    // 两个真实入口都点一遍：通知栏（playFromCursor）与应用内（resume）。
    // 期望：两条路都不该把 A 重新装回来。
    TtsManager.instance.playFromCursor();
    TtsManager.instance.resume();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[switch-resume] 两入口点过之后 '
        'holdsA=${TtsManager.instance.holdsDocument('A')} '
        'speaking=${TtsManager.instance.speaking} '
        'cursor=${TtsManager.instance.cursor}');

    expect(TtsManager.instance.holdsDocument('A'), isFalse,
        reason: '★切到 B 之后，无论哪个入口都不能把 A 重新装回来继续读 A');
    await cleanup(tester);
  });

  // ──────────────────────────────────────────────────────────────────────
  // ★真机上唯一的窗口差异：B 解析慢
  //
  // 测试环境里 B 毫秒级就 `loadDocument` 了；真机上解析要几秒。
  // 这段窗口里：A 已被 `terminateForDocumentSwitch` 清掉（`_doc == null`），
  // 而 B 还没绑上 —— **`_lastDoc` 仍指向 A**。
  //
  // 决定性判据：窗口内点一次播放，会不会把 A 装回来。
  // ──────────────────────────────────────────────────────────────────────
  testWidgets('★★窗口期（B 还没解析完）点播放：不能把 A 装回来', (tester) async {
    final docA = makeDoc('A');
    TtsManager.instance.loadDocument(docA, title: 'A', documentId: 'A');
    TtsManager.instance.speakFrom(0, 2, 0);
    await waitSpeaking(tester);
    await TtsManager.instance.pause();
    expect(TtsManager.instance.paused, isTrue, reason: '前置：A 已暂停');

    // 进入 B 的阅读页 → 解析还没完，此刻 `loadDocument(B)` 尚未发生
    TtsManager.instance.terminateForDocumentSwitch(nextDocumentId: 'B');
    await tester.pump(const Duration(milliseconds: 30));
    expect(TtsManager.instance.holdsDocument('B'), isFalse,
        reason: '前置：B 还没绑上（这就是解析窗口）');

    // ★用户在这个窗口里点了播放（解析慢时完全可能）
    TtsManager.instance.playFromCursor();
    await tester.pump(const Duration(milliseconds: 30));

    // ignore: avoid_print
    print('DEVICE_VERIFY[window] 窗口期点播放后 '
        'holdsA=${TtsManager.instance.holdsDocument('A')} '
        'holdsB=${TtsManager.instance.holdsDocument('B')} '
        'title=${TtsManager.instance.documentTitle} '
        'speaking=${TtsManager.instance.speaking} '
        'cursor=${TtsManager.instance.cursor}');

    expect(TtsManager.instance.holdsDocument('A'), isFalse,
        reason: '★★窗口期点播放绝不能把 A 装回来 —— '
            'A 已经切走了，此时"A 正被 _lastDoc 记着"，'
            '一旦被绑回就会继续读 A（真机解析慢时才会撞上这个窗口）');
    await cleanup(tester);
  });

  // ──────────────────────────────────────────────────────────────────────
  // ★★★ 真机日志复现的那条（2026-10-17 11:54）
  //
  // 真机时序：
  //   11:54:07  打开 EPUB(B)                 → _documentId = B
  //   11:54:29  在 PDF(A) 里起读并暂停        → 通知栏来源 = pdf-session
  //   11:54:40  再次打开 EPUB(B)              → loadDocument(B)
  //   11:54:55  按播放 → 读的是 **PDF(A)** 第 20 页
  //
  // 根因：第 3 步时 `_documentId` 已经是 B → `switching == false`
  // → `terminateForDocumentSwitch` 整条 return，**连"终止 PDF"一起跳过**。
  // §4.60 只想保护"同一本书重进不打断自己"，不该顺带放过另一个会话。
  // ──────────────────────────────────────────────────────────────────────
  testWidgets('★★真机复现：B 已打开过 → PDF(A) 暂停 → 回 B 点播放必须读 B',
      (tester) async {
    final session = PdfReadSession.instance;
    session.audioBridge = PdfSessionAudioBridge.real();
    final handler = TtsAudioHandler(TtsManager.instance);
    audioHandler = handler;
    addTearDown(() {
      audioHandler = null;
    });

    // 1) 先打开 EPUB(B)：让 TtsManager 的 `_documentId` 变成 B
    TtsManager.instance
        .loadDocument(makeDoc('B'), title: 'EPUB-B', documentId: 'B');
    await tester.pump(const Duration(milliseconds: 50));
    expect(TtsManager.instance.activeDocumentId, 'B', reason: '前置：B 已绑过');

    // 2) 在 PDF(A) 里起读，然后暂停（此刻通知栏来源 = pdf-session）
    await tester.runAsync(() => session.open(
          documentId: 'pdfA',
          title: 'PDF-A',
          pageCount: 3,
          layerLoader: (pageIndex) async => null,
        ));
    session.startAt(
        const PdfSentenceRef(pageIndex: 1, sentenceIndex: 0, text: 'A 的句子'));
    await tester.pump(const Duration(milliseconds: 50));
    await session.pause();
    expect(session.isPaused, isTrue, reason: '前置：PDF A 已暂停');
    expect(handler.activeSource.sourceId, 'pdf-session',
        reason: '前置：通知栏来源停在 PDF');

    // 3) 用户重新打开 EPUB(B) —— 与真机 11:54:40 那一拍一致（同 id 重进）
    TtsManager.instance
        .loadDocument(makeDoc('B'), title: 'EPUB-B', documentId: 'B');
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[same-id-switch] 重开 B 之后 '
        'handler来源=${handler.activeSource.sourceId} '
        'pdf.isPlaybackActive=${session.isPlaybackActive} '
        'pdf.paused=${session.isPaused} '
        'tts.holdsB=${TtsManager.instance.holdsDocument('B')}');

    // ★bug 就在这一行：同 id 重进时 PDF 没被终止，来源还停在 pdf-session
    expect(handler.activeSource.sourceId, 'tts-manager',
        reason: '★用户已经回到 EPUB(B)，通知栏来源必须换回 tts-manager；'
            '还停在 pdf-session 就说明"终止另一条朗读路径"被跳过了'
            '（实际 ${handler.activeSource.sourceId}）');
    expect(session.isPlaybackActive, isFalse,
        reason: '★旧的 PDF 会话必须已停（换歌语义：停声但保留位置）');

    // 4) 按播放（通知栏 / 耳机）：必须读 B，不能读 A
    await handler.play();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[same-id-switch] 点播放后 '
        'handler来源=${handler.activeSource.sourceId} '
        'pdf.isPlaying=${session.isPlaying} '
        'tts.holdsB=${TtsManager.instance.holdsDocument('B')}');

    expect(session.isPlaying, isFalse,
        reason: '★★点播放绝不能把旧 PDF(A) 读起来 —— 这就是用户听到的"读回书A"');
    expect(handler.activeSource.sourceId, 'tts-manager',
        reason: '★播放必须落在 EPUB(B) 这一侧');
    await cleanup(tester);
  });

  // ──────────────────────────────────────────────────────────────────────
  // ★核心嫌疑：A 是「暂停中的 PDF」→ 打开 EPUB 书 B（已加载完）→ 点播放
  //
  // 这是用户给的两个额外线索唯一能同时满足的形态：
  //   · 「两个入口都有」→ 两入口都先看 `isPlaybackActive`（PDF 优先）；
  //   · 「和位置无关」→ 只要 PDF 会话还处于"暂停"，派发就换成 PDF，与读哪页无关；
  //   · 「B 已加载出正文」→ 说明 EPUB 侧 `_doc` 已是 B（上一轮已证 A 已脱离）。
  //
  // 代码事实：`PdfReadSession.stopSound()` **不清** `_current` / `_documentId`，
  // 所以「A 暂停」之后会话仍然 `isActive && isPaused` → `isPlaybackActive == true`，
  // 而 `resume()` 会 `startAt(_current)` 把 **A** 继续读下去。
  // ──────────────────────────────────────────────────────────────────────
  testWidgets('★暂停中的 PDF(A) → 打开 EPUB(B) 并加载完 → 播放不能读回 A',
      (tester) async {
    final session = PdfReadSession.instance;
    await tester.runAsync(() => session.open(
          documentId: 'pdfA',
          title: 'PDF-A',
          pageCount: 3,
          layerLoader: (pageIndex) async => null,
        ));
    session.startAt(
        const PdfSentenceRef(pageIndex: 1, sentenceIndex: 0, text: 'A 的句子'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(session.isPlaying, isTrue, reason: '前置：PDF A 在播');

    // 用户在 A 里按暂停
    await session.pause();
    expect(session.isPaused, isTrue, reason: '前置：PDF A 已暂停');
    expect(session.isPlaybackActive, isTrue,
        reason: '暂停的会话仍是"播放中来源"（§4.103 的口径）——这正是派发依据');

    // 打开 EPUB 书 B 并加载完（真实链路：ReaderPage._parse → loadDocument(B)）
    TtsManager.instance
        .loadDocument(makeDoc('B'), title: 'EPUB-B', documentId: 'B');
    await tester.pump(const Duration(milliseconds: 50));
    expect(TtsManager.instance.holdsDocument('B'), isTrue,
        reason: '前置：B 已经绑好（用户说 B 已加载出正文）');

    // 此刻 PDF 会话该不该还活着？换书=解除归属，不该。
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-switch] 切到 B 之后 '
        'pdf.isActive=${session.isActive} '
        'pdf.isPlaybackActive=${session.isPlaybackActive} '
        'pdf.paused=${session.isPaused} '
        'pdf.docId=${session.documentId} '
        'tts.doc=${TtsManager.instance.activeDocumentId}');

    // 控制栏派发判据（与应用内、通知栏两入口同源）
    final picked = session.isPlaybackActive
        ? 'PDF(${session.documentId})'
        : 'TTS(${TtsManager.instance.activeDocumentId})';
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-switch] 点播放会被派发到 → $picked');

    expect(session.isPlaybackActive, isFalse,
        reason: '★换书到 B 之后，旧的 PDF 会话必须已解除归属；'
            '仍 isPlaybackActive=true 就会把播放派发给 A（$picked）');
    await cleanup(tester);
  });

  // ──────────────────────────────────────────────────────────────────────
  // ★走完整媒体链路：暂停中的 PDF(A) → 打开 EPUB(B) → 通知栏点播放
  //
  // 上面那条只验到"派发判据"，这条把 `TtsAudioHandler` 也拉进来，
  // 因为通知栏这条路的入口是 `handler.play()` → `_source.playFromCursor()`，
  // 而 `_source` 是**独立于两个管理器**的一份引用 —— 它可能还指着 A。
  // ──────────────────────────────────────────────────────────────────────
  testWidgets('★暂停中的 PDF(A) → 打开 EPUB(B) → 通知栏播放只能读 B',
      (tester) async {
    final session = PdfReadSession.instance;
    session.audioBridge = PdfSessionAudioBridge.real();
    final handler = TtsAudioHandler(TtsManager.instance);
    audioHandler = handler;
    addTearDown(() {
      audioHandler = null;
    });

    // 1) PDF A 播起来并暂停（此刻通知栏来源 = pdf-session）
    await tester.runAsync(() => session.open(
          documentId: 'pdfA',
          title: 'PDF-A',
          pageCount: 3,
          layerLoader: (pageIndex) async => null,
        ));
    session.startAt(
        const PdfSentenceRef(pageIndex: 1, sentenceIndex: 0, text: 'A 的句子'));
    await tester.pump(const Duration(milliseconds: 50));
    await session.pause();
    expect(handler.activeSource.sourceId, 'pdf-session',
        reason: '前置：暂停中，通知栏来源仍是 PDF');
    expect(session.isPaused, isTrue);

    // 2) 打开 EPUB 书 B（真实链路会 loadDocument(B)）
    TtsManager.instance
        .loadDocument(makeDoc('B'), title: 'EPUB-B', documentId: 'B');
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-hl] 切到 B 后 handler 来源='
        '${handler.activeSource.sourceId} '
        'pdf.isPlaybackActive=${session.isPlaybackActive} '
        'tts.holdsB=${TtsManager.instance.holdsDocument('B')}');

    // 3) 通知栏点播放 —— 真正走 handler
    await handler.play();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-hl] 播放后 handler 来源=${handler.activeSource.sourceId} '
        'pdf.isPlaying=${session.isPlaying} '
        'tts.holdsB=${TtsManager.instance.holdsDocument('B')}');

    expect(session.isPlaying, isFalse,
        reason: '★切到 B 之后从通知栏点播放，绝不能把 A 的 PDF 会话读起来');
    expect(handler.activeSource.sourceId, isNot('pdf-session'),
        reason: '★通知栏来源不该还停在已经交棒给 B 的 PDF 会话上');
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

  // ──────────────────────────────────────────────────────────────────────
  // ★结构性缺口：页面侧入口全部直接调 `_tts`，**不校验 TtsManager 绑的是谁**
  //
  // `reader_page.dart` 里有 7 个朗读入口（点句 / 点行 / 章标题 / 目录 / 书签 /
  // 播放键 …），全都是 `_tts.speakFrom(章, 段, 句)`，而这些参数来自**当前页
  // 自己那份文档**。只要 TtsManager 那一刻还绑着**另一本书**，
  // 传进去的下标就会被套到另一本书的正文上 —— 用户看到的就是"读回旧书"。
  //
  // 这条用例直接钉这个契约：拿 B 的章号去调，必须读的是 B，不能是 A。
  // ──────────────────────────────────────────────────────────────────────
  testWidgets('★用 B 的章号朗读：来源必须仍是 B（不能被旧书吃掉）',
      (tester) async {
    // A 先读起来再暂停，制造"旧会话还在"的真实前提
    TtsManager.instance
        .loadDocument(makeDoc('A'), title: '书A', documentId: 'A');
    TtsManager.instance.speakFrom(0, 2, 0);
    await waitSpeaking(tester);
    await TtsManager.instance.pause();
    expect(TtsManager.instance.paused, isTrue, reason: '前置：A 已暂停');

    // 切到 B（真实链路：B 的 ReaderPage 解析完会 loadDocument(B)）
    TtsManager.instance
        .loadDocument(makeDoc('B'), title: '书B', documentId: 'B');
    await tester.pump(const Duration(milliseconds: 50));
    expect(TtsManager.instance.holdsDocument('B'), isTrue, reason: '前置：已绑定 B');

    // 页面侧入口：把自己那份文档的章号传过去
    TtsManager.instance.speakFrom(1, 0, 0);
    await waitSpeaking(tester);
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[page-entry] 点 B 的章标题后 '
        'holdsB=${TtsManager.instance.holdsDocument('B')} '
        'holdsA=${TtsManager.instance.holdsDocument('A')} '
        'title=${TtsManager.instance.documentTitle} '
        'cursor=${TtsManager.instance.cursor}');

    expect(TtsManager.instance.holdsDocument('B'), isTrue,
        reason: '★点 B 的章标题，读的必须是 B');
    expect(TtsManager.instance.holdsDocument('A'), isFalse,
        reason: '★绝不能被 A 吃掉（holdsA=true 就是用户报的"读回书A"）');
    await cleanup(tester);
  });

  // ──────────────────────────────────────────────────────────────────────
  // ★★★ 真实两页测试：这才是用户的操作路径
  //
  // 上面所有用例都是**在 TtsManager 层直接调方法**，绕过了页面生命周期。
  // 而用户报的现象发生在「A 页朗读并暂停 → 打开 B 页 → 在 B 里点播放」，
  // A 页**仍然活在 Navigator 栈里**（它没 dispose）。
  //
  // 所以必须真的把两个 ReaderPage 挂起来，否则测不到 A 页的残留状态。
  // ──────────────────────────────────────────────────────────────────────
  testWidgets('★★真实两页：A 朗读并暂停 → 打开 B → B 里点播放必须读 B',
      (tester) async {
    // ReaderPage 要的是真实文件（它会去解析），所以先落两个临时 TXT
    Future<Document> makeTxt(String tag) async {
      final dir = await tester.runAsync(
          () => Directory.systemTemp.createTemp('tts54_$tag'));
      final file = File('${dir!.path}/$tag.txt')
        ..writeAsStringSync(
          List<String>.generate(40, (i) => '$tag 第 $i 段第一句。$tag 第 $i 段第二句！')
              .join('\n\n'),
        );
      tempDirs.add(dir);
      return Document(
        id: tag,
        title: tag,
        path: file.path,
        type: DocumentType.txt,
        importedAt: DateTime(2024),
      );
    }

    final docA = await makeTxt('A');
    final docB = await makeTxt('B');

    // 1) 挂一个外壳，用 **push** 打开 A（真实压栈，A 页不会因切换而被 dispose）
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      home: const Scaffold(body: SizedBox.shrink()),
    ));    navigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => ReaderPage(document: docA),
    ));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 900)),
    );
    await tester.pump();

    TtsManager.instance.speakFrom(0, 2, 0);
    await waitSpeaking(tester);
    expect(TtsManager.instance.holdsDocument('A'), isTrue,
        reason: '前置：A 页在读');

    // 2) 用户按暂停
    await TtsManager.instance.pause();
    expect(TtsManager.instance.paused, isTrue, reason: '前置：A 已暂停');

    // 3) 再 push 打开 B —— A 页仍然活在栈里（用户从文档库点另一本书就是这个形态）
    navigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => ReaderPage(document: docB),
    ));
    await tester.pump();
    for (var i = 0; i < 25; i++) {
      if (TtsManager.instance.holdsDocument('B')) break;
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }

    // ignore: avoid_print
    print('DEVICE_VERIFY[two-page] 打开 B 之后 '
        'holdsA=${TtsManager.instance.holdsDocument('A')} '
        'holdsB=${TtsManager.instance.holdsDocument('B')} '
        'title=${TtsManager.instance.documentTitle} '
        'speaking=${TtsManager.instance.speaking} '
        'activeDoc=${TtsManager.instance.activeDocumentId}');

    // 4) 在 B 里点播放（底部控制条 / 通知栏最终都落到这组 API）
    TtsManager.instance.speakFrom(0, 0, 0);
    await waitSpeaking(tester);
    await tester.pump(const Duration(milliseconds: 100));

    // ignore: avoid_print
    print('DEVICE_VERIFY[two-page] B 里点播放后 '
        'holdsA=${TtsManager.instance.holdsDocument('A')} '
        'holdsB=${TtsManager.instance.holdsDocument('B')} '
        'title=${TtsManager.instance.documentTitle} '
        'cursor=${TtsManager.instance.cursor}');

    expect(TtsManager.instance.holdsDocument('A'), isFalse,
        reason: '★★打开 B 并且在 B 里点播放，绝不能再读 A —— '
            '这正是用户报的现象（holdsA=true 就是复现了）');
    await cleanup(tester);
  });

  // ──────────────────────────────────────────────────────────────────────
  // ⚠️ v1.21.55 记录一次**被真机证伪的修法**（别再走一遍）
  //
  // 曾经在 `PdfReadSession.open()` 的「同一本 PDF 重进」早返回里加过
  // 「把音频来源抢回来」，并用下面这样一条用例守住它（当时是绿的）：
  //   重开同一本 PDF → 断言 handler.activeSource == 'pdf-session'
  //
  // **真机反馈证明这个方向是错的**：
  // ```
  // 12:43:22  用户打开 EPUB(B) → 来源正确切回 tts-manager，EPUB 开始读
  // 12:43:32  没有任何人按播放，来源自己跳回 pdf-session，EPUB 被停
  // 12:43:34  按播放 → 读回 PDF
  // 随后用户反馈「耳机控制失效了」
  // ```
  // 原因：`open()` 在**页面重建 / 重新进入**时也会被调用，
  // 「抢占音频」于是变成「页面一刷新就把音频抢走」，还让媒体来源反复切换，
  // 破坏媒体键路由。
  //
  // **教训（写在这里防止后人重犯）**：
  // 1. 「打开一个页面」≠「要开始读」。换源只能由用户的播放动作触发
  //    （`startAt` / `playFromCursor`），**不能挂在 `open()` 上**。
  // 2. 下面那样的用例**只能证明代码按我设想的方式跑，不能证明行为是对的** ——
  //    它当时是绿的，但功能已经坏了。
  // ──────────────────────────────────────────────────────────────────────

  // ──────────────────────────────────────────────────────────────────────
  // ★重开同一本 PDF **不许**动音频来源（上一条教训的守卫）
  //
  // 这条与上面那条假绿用例**断言相反**：重开页面不得抢走别人正在读的音频。
  // ──────────────────────────────────────────────────────────────────────
  testWidgets('★重开同一本 PDF 不得抢走 EPUB 正在读的音频', (tester) async {
    final session = PdfReadSession.instance;
    session.audioBridge = PdfSessionAudioBridge.real();
    final handler = TtsAudioHandler(TtsManager.instance);
    audioHandler = handler;
    addTearDown(() {
      audioHandler = null;
    });

    // 1) 先建立过这本 PDF 的会话
    await tester.runAsync(() => session.open(
          documentId: 'pdfA',
          title: 'PDF-A',
          pageCount: 3,
          layerLoader: (pageIndex) async => null,
        ));

    // 2) 去读 EPUB(B)
    TtsManager.instance
        .loadDocument(makeDoc('B'), title: 'EPUB-B', documentId: 'B');
    TtsManager.instance.speakFrom(0, 0, 0);
    await waitSpeaking(tester);
    expect(handler.activeSource.sourceId, 'tts-manager',
        reason: '前置：音频归 EPUB');

    // 3) 重新打开同一本 PDF（真实运行时=页面重建 / 再进阅读页）
    // ignore: avoid_print
    print('DEVICE_VERIFY[no-steal-pre] open 前：'
        'docId=${session.documentId} '
        'pageCount=${session.pageCount} '
        'ttsSpeaking=${TtsManager.instance.speaking} '
        'ttsPaused=${TtsManager.instance.paused} '
        'ttsPlaying=${TtsManager.instance.playing} '
        'ttsHasSession=${TtsManager.instance.hasSession}');
    await tester.runAsync(() => session.open(
          documentId: 'pdfA',
          title: 'PDF-A',
          pageCount: 3,
          layerLoader: (pageIndex) async => null,
        ));
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[no-steal] 重开页面后 '
        'source=${handler.activeSource.sourceId} '
        'tts.speaking=${TtsManager.instance.speaking}');

    // ★★v1.21.64 按用户新要求改写（原断言已废弃）：
    //
    // 用户要求（2026-10-17 16:20）：
    // > 「进入别的文档时当前朗读停止（记住停止位置，方便重新进入阅读界面
    // >   继续朗读），并且保证当前文档的控制不受上个文档影响」
    //
    // 这条用例原来断言「打开 PDF 页面**不许**停掉正在读的 EPUB」，
    // 与上面这条要求**直接冲突** —— 用户已经明确"换书就该停上一本"。
    // （那条旧断言是为 v1.21.55 的「耳机控制失效」设的防线，现在由
    //  `play()/pause()` 的按前台派发来保证，不再靠"打开页面不停"。）
    //
    // 现在断言：换到 PDF → 上一本 EPUB **要停**，且位置写回（换歌语义）。
    expect(TtsManager.instance.playing, isFalse,
        reason: '★★进入另一本文档，上一本的朗读必须停止（换歌语义）');
    expect(handler.activeSource.sourceId, 'tts-manager',
        reason: '★打开页面本身不改来源 —— 派发在按播放时按前台决定');
    await cleanup(tester);
  });

  // ──────────────────────────────────────────────────────────────────────
  // ★★v1.21.58（用户 2026-10-17 反馈）：
  //   「从上一本书，换到 pdf 时，用耳机控制启停控制的还是上一本书」
  //
  // 场景：EPUB 暂停着（会话还在）→ 用户切到 PDF 阅读页（同一本，走早返回）
  // → 来源仍是 tts-manager（有会话、只是暂停）→ 按耳机继续读 EPUB。
  // ──────────────────────────────────────────────────────────────────────
  testWidgets('★★EPUB 暂停 → 切到 PDF → 按耳机必须读 PDF，不能读 EPUB',
      (tester) async {
    final session = PdfReadSession.instance;
    session.audioBridge = PdfSessionAudioBridge.real();
    final handler = TtsAudioHandler(TtsManager.instance);
    audioHandler = handler;
    addTearDown(() {
      audioHandler = null;
    });

    // 1) 先建立这本 PDF 的会话（让后面的 open 走"同书重进"早返回）
    await tester.runAsync(() => session.open(
          documentId: 'pdfA',
          title: 'PDF-A',
          pageCount: 3,
          layerLoader: (pageIndex) async => null,
        ));

    // 2) 去读 EPUB 并**暂停**（会话还在）
    TtsManager.instance
        .loadDocument(makeDoc('B'), title: 'EPUB-B', documentId: 'B');
    TtsManager.instance.speakFrom(0, 0, 0);
    await waitSpeaking(tester);
    await TtsManager.instance.pause();
    expect(TtsManager.instance.playing, isFalse, reason: '前置：EPUB 已暂停');
    expect(TtsManager.instance.hasSession, isTrue,
        reason: '前置：EPUB 会话还在（这正是问题所在）');
    expect(handler.activeSource.sourceId, 'tts-manager');

    // 3) ★用户切到 PDF 阅读页（同一本 → 早返回路径）
    await tester.runAsync(() => session.open(
          documentId: 'pdfA',
          title: 'PDF-A',
          pageCount: 3,
          layerLoader: (pageIndex) async => null,
        ));
    // 真实运行时这一步由 `PdfReadingPage.initState` → `attach()` 完成；
    // 测试里没有真页面，必须显式登记（v1.21.59 的派发依据）。
    session.setForeground(true);
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[epub-to-pdf] 切到 PDF 后 '
        'source=${handler.activeSource.sourceId} '
        'pdfForeground=${session.isForeground} '
        'ttsHasSession=${TtsManager.instance.hasSession} '
        'ttsPlaying=${TtsManager.instance.playing}');

    // ⚠️ 这里不断言"打开页面前后来源不变" —— 实测该断言不稳定，
    // 且**不是**这条用例要保护的行为。真正要钉的是下面"按播放派给谁"。
    expect(session.isForeground, isTrue, reason: '前置：PDF 页已登记为前台');

    // 4) ★按耳机 / 通知栏播放 —— 必须落到 PDF
    await handler.play();
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[epub-to-pdf] 按播放后 '
        'source=${handler.activeSource.sourceId} '
        'pdfIsPlaying=${session.isPlaying} '
        'ttsHoldsB=${TtsManager.instance.holdsDocument('B')}');

    expect(handler.activeSource.sourceId, 'pdf-session',
        reason: '★★按播放必须派给 PDF（用户正看着它）；'
            '留在 tts-manager 就是"按耳机还在读上一本书"'
            '（实际 ${handler.activeSource.sourceId}）');

    await session.clear();
    await tester.pump(const Duration(milliseconds: 100));
    await cleanup(tester);
  });

  testWidgets('★v1.21.58 闸门：TTS 正在朗读时打开 PDF，不许抢走',
      (tester) async {
    final session = PdfReadSession.instance;
    session.audioBridge = PdfSessionAudioBridge.real();
    final handler = TtsAudioHandler(TtsManager.instance);
    audioHandler = handler;
    addTearDown(() {
      audioHandler = null;
    });

    // PDF 会话已存在（走早返回），但 EPUB **正在朗读**
    await tester.runAsync(() => session.open(
          documentId: 'pdfA',
          title: 'PDF-A',
          pageCount: 3,
          layerLoader: (pageIndex) async => null,
        ));
    // ⚠️ 这次 open 在 TTS 空闲时会接管来源，而接管会给 tts-manager 发
    // `onStop()`（异步 `stop()`）。必须等它落定，否则它会晚一步打到
    // 下面刚启动的朗读上（用例会以"朗读没起来"的形式假失败）。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump(const Duration(milliseconds: 50));

    TtsManager.instance
        .loadDocument(makeDoc('B'), title: 'EPUB-B', documentId: 'B');
    TtsManager.instance.speakFrom(0, 0, 0);
    await waitSpeaking(tester);
    expect(TtsManager.instance.playing, isTrue, reason: '前置：EPUB 正在读');

    await tester.runAsync(() => session.open(
          documentId: 'pdfA',
          title: 'PDF-A',
          pageCount: 3,
          layerLoader: (pageIndex) async => null,
        ));
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-idle-gate] TTS 朗读中打开 PDF 后 '
        'source=${handler.activeSource.sourceId} '
        'ttsPlaying=${TtsManager.instance.playing}');

    // ★★v1.21.64 按用户新要求改写（原断言已废弃）。
    //
    // 用户要求（2026-10-17 16:20）：「进入别的文档时当前朗读停止」。
    // 这条原来断言"朗读必须继续、不能被打断"，与此冲突。
    //
    // 仍然保留的那一半：**来源不在这里改**（派发留给 play/pause 按前台决定），
    // 这保证「当前文档的控制不受上个文档影响」。
    expect(handler.activeSource.sourceId, 'tts-manager',
        reason: '★打开页面本身不改来源（派发由前台决定）');
    expect(TtsManager.instance.playing, isFalse,
        reason: '★★进入另一本文档，上一本的朗读必须停止（换歌语义）');
    await cleanup(tester);
  });

  // ── 被真机证伪的那条用例已删除（它断言 open() 抢音频，方向是错的）──

  // ──────────────────────────────────────────────────────────────────────
  // ★v1.21.57：打开 PDF 后「按播放没反应」
  //
  // 真机日志（2026-10-17 13:11）：
  // ```
  // 13:11:08  打开 PDF → terminateForDocumentSwitch 清空 TTS 会话
  //           pushState→idle（卡片消失） source=tts-manager hasSession=false
  // 13:11:11  按播放 → 媒体控制[play source=tts-manager … hasSession=false]
  // 13:11:11  pushState→idle（卡片消失）        ← 什么都没发生
  // ```
  // 原因：TTS 被终止后 `hasSession == false`，但来源**仍指着它** ——
  // 播放键派给了一个没有会话的来源。
  //
  // 判据必须精确：**只在 TTS 真没会话时**才把来源收给 PDF；
  // 正在朗读的 EPUB 不能被抢（那正是 v1.21.55 犯错的地方）。
  // ──────────────────────────────────────────────────────────────────────
  testWidgets('★打开 PDF 后（TTS 已被终止）按播放必须能读 PDF', (tester) async {
    final session = PdfReadSession.instance;
    session.audioBridge = PdfSessionAudioBridge.real();
    final handler = TtsAudioHandler(TtsManager.instance);
    audioHandler = handler;
    addTearDown(() {
      audioHandler = null;
    });

    // 1) 让 TTS 有一个会话，来源会是 tts-manager
    TtsManager.instance
        .loadDocument(makeDoc('B'), title: 'EPUB-B', documentId: 'B');
    TtsManager.instance.speakFrom(0, 0, 0);
    await waitSpeaking(tester);
    await TtsManager.instance.pause();
    expect(handler.activeSource.sourceId, 'tts-manager');

    // 2) 打开 PDF：换书路径会 terminate TTS 会话
    await tester.runAsync(() => session.open(
          documentId: 'pdfA',
          title: 'PDF-A',
          pageCount: 3,
          layerLoader: (pageIndex) async => null,
        ));
    session.setForeground(true); // 真机由 PdfReadingPage.initState → attach 做
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[open-pdf] 打开 PDF 后 '
        'ttsHasSession=${TtsManager.instance.hasSession} '
        'source=${handler.activeSource.sourceId}');

    expect(TtsManager.instance.hasSession, isFalse,
        reason: '前置：TTS 会话已被终止（真机日志 hasSession=false）');

    // 3) ★用户按播放（通知栏 / 耳机）—— 接管发生在这一拍
    await handler.play();
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[open-pdf] 按播放后 '
        'source=${handler.activeSource.sourceId} '
        'pdfIsPlaying=${session.isPlaying}');

    expect(handler.activeSource.sourceId, 'pdf-session',
        reason: '★来源原本停在"没有会话"的 tts-manager 上，'
            '按播放时必须改派给还活着的 pdf-session —— '
            '不改派就是"按了没反应"（实际 ${handler.activeSource.sourceId}）');

    // 收尾：把会话里的防抖定时器也清掉，否则测试框架会报 timersPending
    await session.clear();
    await tester.pump(const Duration(milliseconds: 100));
    await cleanup(tester);
  });

  // ──────────────────────────────────────────────────────────────────────
  // ★★v1.21.58 往返：PDF 接管之后切回 EPUB，必须还能正常朗读
  //
  // 真机日志抓到过：接管时若调 `terminateForDocumentSwitch`（清太狠），
  // 回 EPUB 按播放**连「开始朗读」都不打印**，进度停在 `index=0/1`。
  // 这条钉住"接管只换来源、不清会话内容"。
  // ──────────────────────────────────────────────────────────────────────
  testWidgets('★★往返：PDF 接管后切回 EPUB，仍能正常朗读', (tester) async {
    final session = PdfReadSession.instance;
    session.audioBridge = PdfSessionAudioBridge.real();
    final handler = TtsAudioHandler(TtsManager.instance);
    audioHandler = handler;
    addTearDown(() {
      audioHandler = null;
    });

    // 1) 读 EPUB 并暂停
    TtsManager.instance
        .loadDocument(makeDoc('B'), title: 'EPUB-B', documentId: 'B');
    TtsManager.instance.speakFrom(0, 0, 0);
    await waitSpeaking(tester);
    await TtsManager.instance.pause();
    expect(TtsManager.instance.hasSession, isTrue);

    // 2) 切到 PDF（同书重进；页面进入 → 登记前台）
    await tester.runAsync(() => session.open(
          documentId: 'pdfA',
          title: 'PDF-A',
          pageCount: 3,
          layerLoader: (pageIndex) async => null,
        ));
    session.setForeground(true); // 真机由 PdfReadingPage.initState → attach 做
    await tester.pump(const Duration(milliseconds: 50));
    expect(handler.activeSource.sourceId, 'tts-manager',
        reason: '前置：打开页面**不改来源**（v1.21.59 的刻意设计）');

    // 3) ★切回 EPUB：内容必须还在（打开 PDF 页不该清掉会话内容）
    session.setForeground(false); // 真机由 ReaderPage.initState 做
    TtsManager.instance
        .loadDocument(makeDoc('B'), title: 'EPUB-B', documentId: 'B');
    await tester.pump(const Duration(milliseconds: 50));
    expect(TtsManager.instance.holdsDocument('B'), isTrue,
        reason: '★回到 EPUB 后必须真的持有这本书的内容');

    // 4) 按播放：必须真的读起来
    // ★★关键判据：**引擎真的收到了要朗读的文本**。
    // 只看 `speaking` 会漏掉真机那个故障：`activate()` 先给旧来源发
    // `onStop()` → `stopSound()` 里停掉 TTS → 把 `_restart` 刚领的代次顶掉
    // → `_runBody` 在 `token != _generation` 处直接 return，
    // 于是「图标变了、没声音、进度停在 index=0/1、日志里没有开始朗读」。
    // 所以**必须在这次 play 之前**清零计数（放后面的话，那次 play 会因为
    // "正在播→按 ROM 兼容当暂停"而不产生新的朗读，测出来是假失败）。
    engine.spokenCount = 0;
    engine.lastSpoken = '';
    await handler.play();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[round-trip] 回 EPUB 播放后 '
        'source=${handler.activeSource.sourceId} '
        'speaking=${TtsManager.instance.speaking} '
        'holdsB=${TtsManager.instance.holdsDocument('B')} '
        'cursor=${TtsManager.instance.cursor}');

    expect(handler.activeSource.sourceId, 'tts-manager',
        reason: '★来源要切回文字档');
    expect(TtsManager.instance.speaking, isTrue,
        reason: '★朗读状态要起来');
    // ignore: avoid_print
    print('DEVICE_VERIFY[round-trip] 引擎收到条数=${engine.spokenCount} '
        '最近=${engine.lastSpoken}');
    expect(engine.spokenCount, greaterThan(0),
        reason: '★★引擎必须真的收到要朗读的文本 —— '
            '收到 0 条就是"状态变了但没出声"（代次被顶掉）');
    await cleanup(tester);
  });

  testWidgets('★反方向：TTS 正在朗读时打开 PDF，不能抢走有声的会话',
      (tester) async {
    final session = PdfReadSession.instance;
    session.audioBridge = PdfSessionAudioBridge.real();
    final handler = TtsAudioHandler(TtsManager.instance);
    audioHandler = handler;
    addTearDown(() {
      audioHandler = null;
    });

    // TTS 正在朗读（有声）→ 打开 PDF 时它会被 terminate（这是既有的换书语义）
    TtsManager.instance
        .loadDocument(makeDoc('B'), title: 'EPUB-B', documentId: 'B');
    TtsManager.instance.speakFrom(0, 0, 0);
    await waitSpeaking(tester);
    expect(TtsManager.instance.speaking, isTrue, reason: '前置：EPUB 正在读');

    await tester.runAsync(() => session.open(
          documentId: 'pdfA',
          title: 'PDF-A',
          pageCount: 3,
          layerLoader: (pageIndex) async => null,
        ));
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[open-pdf-rev] '
        'ttsSpeaking=${TtsManager.instance.speaking} '
        'ttsHasSession=${TtsManager.instance.hasSession} '
        'source=${handler.activeSource.sourceId}');

    // 换书语义：上一本要停（§4.100 任务 E 的要求）
    expect(TtsManager.instance.speaking, isFalse,
        reason: '打开另一本书时上一本要停（换歌语义）');
    // ⚠️ v1.21.59：来源**不在这里换** —— 打开页面不产生音频副作用，
    // 换源留到用户按播放那一拍（由前台标记决定，见 `TtsAudioHandler.play()`）。
    // 前一版断言"来源必须交给 pdf-session"，那会导致来回切换时互相打断。
    expect(handler.activeSource.sourceId, 'tts-manager',
        reason: '打开页面不改来源；派发在按播放时按"前台文档"决定');
    await cleanup(tester);
  });

  // ──────────────────────────────────────────────────────────────────────
  // ★不回归：**单本书内**暂停 → 恢复必须照旧（这是最常见路径）
  //
  // v1.21.55 动的是「同书重进时要不要收音频」。这条钉住它没有把
  // 「同一本书自己暂停再恢复」误伤掉 —— 那会让最基本的功能坏掉。
  // ──────────────────────────────────────────────────────────────────────
  testWidgets('★不回归：单本 EPUB 暂停 → 恢复，正常接着读', (tester) async {
    TtsManager.instance
        .loadDocument(makeDoc('A'), title: '书A', documentId: 'A');
    TtsManager.instance.speakFrom(0, 2, 0);
    await waitSpeaking(tester);
    expect(TtsManager.instance.playing, isTrue, reason: '前置：正在读');

    // 暂停
    await TtsManager.instance.pause();
    await tester.pump(const Duration(milliseconds: 30));
    expect(TtsManager.instance.paused, isTrue, reason: '前置：已暂停');

    // 恢复（应用内 / 通知栏最终都会落到 playFromCursor → resume）
    TtsManager.instance.playFromCursor();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[single-book] 恢复后 speaking=${TtsManager.instance.speaking} '
        'playing=${TtsManager.instance.playing} '
        'holdsA=${TtsManager.instance.holdsDocument('A')} '
        'cursor=${TtsManager.instance.cursor}');

    expect(TtsManager.instance.holdsDocument('A'), isTrue,
        reason: '★单本书暂停再恢复，必须还是这本书（不能被换书逻辑误伤）');
    expect(TtsManager.instance.speaking, isTrue,
        reason: '★恢复后要真的重新开始读');
    await cleanup(tester);
  });

  testWidgets('★不回归：单本 PDF 暂停 → 恢复，正常接着读', (tester) async {
    final session = PdfReadSession.instance;
    session.audioBridge = PdfSessionAudioBridge.real();
    final handler = TtsAudioHandler(TtsManager.instance);
    audioHandler = handler;
    addTearDown(() {
      audioHandler = null;
    });

    await tester.runAsync(() => session.open(
          documentId: 'pdfA',
          title: 'PDF-A',
          pageCount: 3,
          layerLoader: (pageIndex) async => null,
        ));
    session.startAt(
        const PdfSentenceRef(pageIndex: 1, sentenceIndex: 0, text: 'A 的句子'));
    await tester.pump(const Duration(milliseconds: 30));
    await session.pause();
    expect(session.isPaused, isTrue, reason: '前置：已暂停');

    // 通知栏 / 耳机按播放
    await handler.play();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('DEVICE_VERIFY[single-pdf] 恢复后 pdf.isPlaying=${session.isPlaying} '
        'source=${handler.activeSource.sourceId}');

    expect(session.isPlaying, isTrue,
        reason: '★单本 PDF 暂停再恢复，必须继续读这本');
    expect(handler.activeSource.sourceId, 'pdf-session',
        reason: '★来源应当还是这本 PDF');
    await cleanup(tester);
  });

  // ──────────────────────────────────────────────────────────────────────
  // ★★第二个入口：**应用内底部控制条**（不是通知栏）
  //
  // 目标要求"两入口各一"。上面几条测的是 `TtsAudioHandler.play()`
  // （通知栏 / 耳机那条路）；这一条测文档库底部控制条的派发，
  // 它走 `ReadingControlBar._pickSource()`：
  //   `if (pdf.isPlaybackActive) → pdf.resume()  else → tts.playFromCursor()`
  //
  // 修复前：切书后 PDF 仍 `isPlaybackActive` → 派发给 PDF → 读回旧书。
  // ──────────────────────────────────────────────────────────────────────
  testWidgets('★★应用内控制条入口：切书后点播放必须读新书，不能派给旧 PDF',
      (tester) async {
    final session = PdfReadSession.instance;
    session.audioBridge = PdfSessionAudioBridge.real();
    final handler = TtsAudioHandler(TtsManager.instance);
    audioHandler = handler;
    addTearDown(() {
      audioHandler = null;
    });

    // 1) 打开 EPUB(B) 并读起来（当前书 = B）
    TtsManager.instance
        .loadDocument(makeDoc('B'), title: 'EPUB-B', documentId: 'B');
    TtsManager.instance.speakFrom(0, 0, 0);
    await waitSpeaking(tester);
    await TtsManager.instance.pause();

    // 2) 去 PDF(A) 读一下并暂停 —— 制造"旧 PDF 会话还挂着"
    await tester.runAsync(() => session.open(
          documentId: 'pdfA',
          title: 'PDF-A',
          pageCount: 3,
          layerLoader: (pageIndex) async => null,
        ));
    session.startAt(
        const PdfSentenceRef(pageIndex: 1, sentenceIndex: 0, text: 'A 的句子'));
    await tester.pump(const Duration(milliseconds: 30));
    await session.pause();

    // 3) 用户回到 EPUB(B)：同 id 重进（真机就是这一拍出的问题）
    TtsManager.instance
        .loadDocument(makeDoc('B'), title: 'EPUB-B', documentId: 'B');
    await tester.pump(const Duration(milliseconds: 50));

    // 4) 挂上真正的控制条，读它的派发判据
    ReadingControlBar.debugRecent.clear();
    await tester.pumpWidget(
      ListenableProvider<TtsManager>.value(
        value: TtsManager.instance,
        child: MaterialApp(
          home: Scaffold(
            body: ReadingControlBar(onReturnToReading: () async {}),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 30));

    final eval = ReadingControlBar.debugRecent
        .where((line) => line.startsWith('求值 '))
        .toList();
    // ignore: avoid_print
    print('DEVICE_VERIFY[bar-entry] 控制条求值=$eval '
        'pdfPlayback=${session.isPlaybackActive}');

    expect(eval, isNotEmpty, reason: '控制条应当真的求过一次派发判据');
    expect(eval.last.contains('→ 取=TTS'), isTrue,
        reason: '★★应用内控制条必须派给 TTS(书B)，不能派给旧 PDF(A) —— '
            '派给 PDF 就是用户报的"读回上一本书"（实际：${eval.last}）');
    await cleanup(tester);
  });
}

/// 假引擎：`speak` 永不返回 → 会话一直停在「朗读中」（§9.47 / §9.28）
///
/// v1.21.59 起多记一个 [spokenCount]：**引擎真正收到的文本条数**。
/// 这是"到底有没有出声"的唯一可靠判据 —— `TtsManager.speaking` 在
/// 「开始朗读」之前就已经是 true 了，拿它断言会漏掉"代次被顶掉、
/// `_runBody` 提前 return"这类故障（真机表现为图标变了却没声音）。
class _HoldEngine with SyntheticTtsEngine implements TtsEngine {
  @override
  String get id => 'cross-hold';

  @override
  String get displayName => '假引擎（保持朗读中）';

  /// 引擎真正被要求朗读的次数（> 0 才算"真的读起来了"）
  int spokenCount = 0;

  /// 最近一次收到的文本
  String lastSpoken = '';

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
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async {}
}

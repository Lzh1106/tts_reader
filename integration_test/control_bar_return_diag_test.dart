import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/features/pdf_reading/pdf_reading_page.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/pages/home_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';
import 'package:tts_reader/widgets/reading_control_bar.dart';

/// **第 0 步诊断**（设备侧）：三个症状在真实链路上的实测。
///
/// 用户报的三条：
///   1. 文档库控制栏按方块键 → 朗读不停、控制栏不消失
///   2. 文档库控制栏的「返回朗读页」点了不生效
///   3. PDF 阅读页里的「回到朗读位置」键不生效
///
/// 症状 1 与 3 已能从代码定死；**症状 2 只能靠实测** ——
/// 它取决于「读 PDF 时 `TtsManager.hasSession` 是不是也为真」，
/// 而 `home_page._openReadingPage` 的 id 取值优先级正好吃这个。
///
/// 这条用例就把链路走一遍并把每一环打出来，作为第 1 步的依据。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<File?> adopt(String name) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final target = File('${dir.path}/$name');
      if (!await target.exists()) {
        for (final path in <String>['test_assets/$name', '/data/local/tmp/$name']) {
          final source = File(path);
          if (await source.exists()) {
            final copied = await source.copy(target.path);
            return copied;
          }
        }
        return null;
      }
      return target;
    } catch (_) {
      return null;
    }
  }

  // 真实 PDF 的页数（319 页《共产主义ABC》）；下半本判据用得上
  const pageCap = 319;

  testWidgets('症状 2 诊断：PDF 朗读中退回文档库 → 返回朗读页打开的是哪个页面',
      (tester) async {
    final file = await adopt('abc.pdf');
    expect(file, isNotNull, reason: '需要 abc.pdf');

    // 1) 把 PDF 登记进文档库（模拟用户导入）
    final storage = StorageService.instance;
    final doc = Document(
      id: 'diag-pdf-1',
      title: '诊断用PDF',
      path: file!.path,
      type: DocumentType.pdf,
      importedAt: DateTime.now(),
    );
    await storage.upsertDocument(doc);

    // 2) 起一个「打印任何东西都行」的假引擎：真机上真 TTS 太慢且不可控
    final engine = _PrintOnlyEngine();
    await TtsManager.instance.registerEngine(engine, makeActive: true);

    // 3) 打开文档库
    // ⚠️ 先关掉首次教程：它是 `home_page.initState` 里 `maybeShow` 弹出来的模态，
    // 带屏障 —— 不关的话点文档卡片会被屏障吃掉，而 `tester.tap` 报的却是
    // 「widget cannot receive pointer events」，看起来像卡片坏了（实测踩到）。
    await StorageService.instance.setTutorialDone(true);
    await tester.pumpWidget(
      ChangeNotifierProvider<TtsManager>.value(
        value: TtsManager.instance,
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));
    // ignore: avoid_print
    print('DIAG_RET 教程弹窗还在吗='
        '${find.byKey(const ValueKey<String>('tutorial-dialog')).evaluate().isNotEmpty}');

    // 4) 走真实入口打开 PDF：等价于点文档卡片
    // ignore: avoid_print
    print('DIAG_RET 文档库里能看到「诊断用PDF」吗：'
        '${find.text('诊断用PDF').evaluate().isNotEmpty}');
    expect(find.text('诊断用PDF'), findsWidgets, reason: '刚导入的书应当出现在文档库');

    // 点卡片本体（InkWell）而不是文字：文字可能落在卡片内的布局里被裁掉，
    // `tap(text)` 会报 "widget is actually off-screen / cannot receive pointer events"。
    final cardWell = find.ancestor(
      of: find.text('诊断用PDF'),
      matching: find.byType(InkWell),
    );
    // ignore: avoid_print
    print('DIAG_RET 卡片 InkWell 命中数=${cardWell.evaluate().length}'
        '${cardWell.evaluate().isEmpty ? "" : " rect=${tester.getRect(cardWell.first)}"}');
    await tester.tap(cardWell.first, warnIfMissed: true);
    // PDF 解析 + 首帧渲染会持续几百毫秒到几秒，`pumpAndSettle` 容易超时；
    // 改成固定步进，顺便看它到底有没有建出来。
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.byType(PdfReadingPage).evaluate().isNotEmpty) break;
    }
    // ignore: avoid_print
    print('DIAG_RET 打开后的页面类型：'
        'PdfReadingPage=${find.byType(PdfReadingPage).evaluate().isNotEmpty}');

    final session = PdfReadSession.instance;
    // 等页面把会话开起来
    for (var i = 0; i < 60 && !session.isActive; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    // ignore: avoid_print
    print('DIAG_RET 会话：isActive=${session.isActive} '
        'docId=${session.documentId} pageCount=${session.pageCount}');

    // 5) 点第一句开始朗读（真实命中测试那条路）
    final layers = <int, PdfPageTextLayer>{};
    for (var i = 0; i < 40 && layers.isEmpty; i++) {
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      for (var p = 0; p < 3; p++) {
        final layer = session.layerOf(p);
        if (layer != null) layers[p] = layer;
      }
    }
    expect(layers, isNotEmpty, reason: '应当抽到首页文本层');
    final firstPage = layers.keys.first;
    final layer = layers[firstPage]!;
    final state = tester.state(find.byType(PdfReadingPage)) as PdfReadingPageState;
    state.debugEnsureLayer(firstPage + 1);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    // 直接走会话起读（等价于点句；坐标点击在设备上不稳，见 §4.84）
    session.startAt(sentenceRefAt(firstPage, 0, layer)!);
    for (var i = 0; i < 40 && session.current == null; i++) {
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
    }
    // ignore: avoid_print
    print('DIAG_RET 起读：current=${session.current} isPlaying=${session.isPlaying}');
    expect(session.current, isNotNull);

    // 6) 记录此刻的关键状态：**症状 2 的命门在这里**
    // ignore: avoid_print
    print('DIAG_RET 退回前快照：pdfActive=${session.isActive} '
        'pdfDocId=${session.documentId} | '
        'ttsActive=${TtsManager.instance.hasSession} '
        'ttsDocId=${TtsManager.instance.activeDocumentId}');

    // 7) 退回文档库（点返回箭头）
    final back = find.byTooltip('返回');
    if (back.evaluate().isNotEmpty) {
      await tester.tap(back.first);
    } else {
      await tester.pageBack();
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    // ignore: avoid_print
    print('DIAG_RET 已退回文档库：还在阅读页吗='
        '${find.byType(PdfReadingPage).evaluate().isNotEmpty}');
    expect(find.byType(PdfReadingPage), findsNothing, reason: '应当已经退回文档库');

    // 朗读**不该**被退出打断（HANDOFF §4.60）
    // ignore: avoid_print
    print('DIAG_RET 退出后朗读还在吗：isPlaying=${session.isPlaying}');

    // 8) 控制栏应当以 PDF 来源显示；展开它
    ReadingControlBar.debugRecent.clear();
    final disc = find.byKey(ReadingControlBar.discKey);
    // ignore: avoid_print
    print('DIAG_RET 控制栏碟片可见=${disc.evaluate().isNotEmpty}');
    expect(disc, findsOneWidget, reason: '读到一半退回，碟片应当还在');

    await tester.tap(disc);
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    // ignore: avoid_print
    print('DIAG_RET 控制栏显示条件日志：${ReadingControlBar.debugRecent}');

    // 9) 点「返回朗读页」—— 症状 2 的正题
    final ret = find.byKey(ReadingControlBar.returnKey);
    expect(ret, findsOneWidget, reason: '展开态里应当有「返回朗读页」');
    await tester.tap(ret);
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // ignore: avoid_print
    print('DIAG_RET === 点完之后 ===');
    // ignore: avoid_print
    print('DIAG_RET PdfReadingPage=${find.byType(PdfReadingPage).evaluate().isNotEmpty} '
        'SnackBar提示=${find.byType(SnackBar).evaluate().isNotEmpty}');
    for (final t in <String>['这本书已从文档库移除', '当前朗读的是文本片段，没有对应的阅读页']) {
      if (find.text(t).evaluate().isNotEmpty) {
        // ignore: avoid_print
        print('DIAG_RET 命中提示：「$t」  ← 说明 id 没匹配上');
      }
    }
    // 会话是否被重置（打开的是全新页面还是恢复了原会话）
    // ignore: avoid_print
    print('DIAG_RET 会话现状：docId=${session.documentId} '
        'current=${session.current} pageCount=${session.pageCount} '
        'isFinished=${session.isFinished} isPlaying=${session.isPlaying} '
        '当前页有层=${session.layerOf(session.current?.pageIndex ?? 0) != null} '
        '当前页判定空=${session.isPageEmpty(session.current?.pageIndex ?? 0)} '
        '下一页判定空=${session.isPageEmpty((session.current?.pageIndex ?? 0) + 1)}');

    // 停点附近每一页的实况：是「真空白」还是「没抽出来」
    final stopAt = session.current?.pageIndex ?? 0;
    final probe = <String>[];
    for (var i = stopAt; i < stopAt + 14 && i < session.pageCount; i++) {
      probe.add('$i{层=${session.layerOf(i) != null}'
          '空=${session.isPageEmpty(i)}}');
    }

    // ── 关键探针：在**同一个活的会话**上再推一次 ──────────────────────────
    // 单测说「空白页后面几页没抽出来」时不该报读完，但设备上 isFinished=true。
    // 所以直接在同一会话上从停点再推一次，看推不推得动 ——
    // 推得动说明逻辑没问题、是别处把它收尾了；推不动说明判据还是错的。
    final beforeResume = session.current;
    final finishedBefore = session.isFinished;
    session.resume();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (session.current != beforeResume) break;
    }
    // ignore: avoid_print
    print('DIAG_RET 探针：resume 前=$beforeResume(finished=$finishedBefore) '
        '→ 后=${session.current} isFinished=${session.isFinished} '
        'isPlaying=${session.isPlaying}');
    // 再等一会儿，看它能不能自己越过第 9 页的空白
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if ((session.current?.pageIndex ?? 0) > 8) break;
    }
    // ignore: avoid_print
    print('DIAG_RET 探针后续：current=${session.current} '
        'isFinished=${session.isFinished} 读过=${engine.spoken.length} 句');

    // ── 本次修复的核心断言：整本书要读完，不能停在第 8 页 ──────────────
    //
    // 修复前：`current` 停在第 8 页（下标 7）、`isFinished=true` ——
    // 用户看到「319 页的书读到 8 页就说读完了」。
    expect(session.current!.pageIndex, greaterThan(pageCap * 0.5),
        reason: '应当读到后半本（实际停在页下标 ${session.current!.pageIndex}）');
    expect(session.isFinished, isTrue, reason: '读完了才允许报 finished');
    expect(engine.spoken.length, greaterThan(500),
        reason: '真实 319 页的书要读上千句（实际 ${engine.spoken.length}）');

    // 收尾
    await session.clear();
    await TtsManager.instance.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('症状 1 诊断：文档库方块键之后控制栏还在不在', (tester) async {
    final engine = _PrintOnlyEngine();
    await TtsManager.instance.registerEngine(engine, makeActive: true);
    final session = PdfReadSession.instance;

    // 直接造一个有内容的 PDF 会话（不必真解析 PDF：控制栏只看 isActive）
    final pages = <int, PdfPageTextLayer>{
      0: _page(1, '第一页甲。第一页乙。'),
      1: _page(2, '第二页甲。'),
    };
    await session.open(
      documentId: 'diag-pdf-2',
      title: '方块键诊断',
      pageCount: 2,
      layerLoader: (i) async => pages[i],
    );
    final layer = await session.ensureLayer(0);
    session.startAt(sentenceRefAt(0, 0, layer)!);

    await tester.pumpWidget(
      ChangeNotifierProvider<TtsManager>.value(
        value: TtsManager.instance,
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ReadingControlBar(onReturnToReading: () async {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(ReadingControlBar.discKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    ReadingControlBar.debugRecent.clear();
    await tester.tap(find.byKey(ReadingControlBar.stopKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 800));

    final stillThere = find.byKey(ReadingControlBar.barKey).evaluate().isNotEmpty ||
        find.byKey(ReadingControlBar.discKey).evaluate().isNotEmpty;
    // ignore: avoid_print
    print('DIAG_TXT 方块键日志=${ReadingControlBar.debugRecent}');
    // ignore: avoid_print
    print('DIAG_TXT 方块键后：isActive=${session.isActive} 控制栏还在=$stillThere');

    // ignore: avoid_print
    print('DIAG_TXT clear 之后：session.isActive=${session.isActive} '
        'tts.hasSession=${TtsManager.instance.hasSession} '
        'tts.activeDocumentId=${TtsManager.instance.activeDocumentId} '
        'tts.speaking=${TtsManager.instance.speaking}');

    expect(session.isActive, isFalse, reason: '文档库方块键要清掉会话');
    expect(stillThere, isFalse, reason: '会话清掉后整条应当消失（§4.92）');

    await session.clear();
    await TtsManager.instance.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}

PdfPageTextLayer _page(int pageNumber, String text) {
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

/// 只记录不发声的假引擎（真 TTS 在设备上太慢且不可控）
class _PrintOnlyEngine implements TtsEngine {
  final List<String> spoken = <String>[];
  void Function()? _onComplete;

  @override
  String get id => 'diag-print-only';
  @override
  String get displayName => '假引擎（只记录）';
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
    await Future<void>.delayed(const Duration(milliseconds: 40));
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

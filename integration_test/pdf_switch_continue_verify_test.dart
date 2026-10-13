import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:tts_reader/features/pdf_reading/pdf_page_layer.dart';
import 'package:tts_reader/features/pdf_reading/pdf_page_turn_controller.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/crash_log.dart';
import 'package:tts_reader/tts/tts_audio_handler.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 设备验证（v1.21.43）：切书后点「继续」的三条路径（P0-1 / P0-2 真机复验）
///
/// 覆盖三条路径：
///   1) EPUB 到 PDF 切书点继续
///   2) PDF 到 PDF 切书点继续
///   3) 手动滑动 PDF 后再切书点继续（P0-2 核心：_userDriven 必须复位）
///
/// 每条都查四样：高亮回调（ref 是否落在当前页）、会话跳转页、通知栏来源与播放态、
/// 日志三核（无「丢弃过期写」/ 无 AF[turnTo挡下] / AF 埋点有打出）。
///
/// 跑法（设备用例跑完会自动卸载应用）：
///   flutter --no-version-check test integration_test/pdf_switch_continue_verify_test.dart -d emulator-5554
/// 前置：adb push test_assets/abc.pdf /data/local/tmp/abc.pdf
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final tts = TtsManager.instance;
  final pdf = PdfReadSession.instance;
  const pdfPath = '/data/local/tmp/abc.pdf';

  // 监听器绑定的两个列表：只创建一次。
  // 不要在 setUp 里重建监听器 —— 那会让它绑到新的列表对象，而用例里持有的
  // 还是旧引用，于是回调明明发生了、断言却拿到空列表（实测踩到过）。
  final sentences = <PdfSentenceRef>[];
  final pagesToTurn = <int>[];
  final listener = _RecordingListener(sentences, pagesToTurn);

  /// 真机时间推进（假时钟下 Future.delayed 不前进，必须 pump + runAsync）
  Future<void> pumpFor(WidgetTester tester, int ms) async {
    final deadline = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
  }

  /// 读应用自己的 crash.log（与 CrashLog 写的是同一个文件）
  ///
  /// CrashLog.mark 不是同步落盘 —— 它挂在一条串行链上。所以读之前要让链排空，
  /// 否则会读到空文件（实测踩到：报告里「写盘行=0 / AF 行数=0」）。
  Future<String> readLog() async {
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/crash.log');
      return await f.exists() ? await f.readAsString() : '';
    } catch (_) {
      return '';
    }
  }

  Future<void> clearLog() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/crash.log');
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 删不掉就算了：断言只看「有没有」，不看条数
    }
  }

  /// 打开一本真实 PDF；返回页数
  Future<int> openRealPdf(
    WidgetTester tester, {
    required String documentId,
    required String title,
  }) async {
    final doc = await tester.runAsync(() async {
      final dir = await getApplicationDocumentsDirectory();
      final dst = File('${dir.path}/books/$documentId.pdf');
      await dst.parent.create(recursive: true);
      await File(pdfPath).copy(dst.path);
      return PdfDocument.openFile(dst.path);
    });
    final pages = doc!.pages.length;
    await tester.runAsync(() => pdf.open(
          documentId: documentId,
          title: title,
          pageCount: pages,
          layerLoader: (i) async =>
              i < pages ? loadTextLayer(doc.pages[i]) : null,
        ));
    return pages;
  }

  /// 找一个句子够多的正文页（避免落在封面 / 空白页）
  Future<int> findTextPage(WidgetTester tester, int pages) async {
    for (var i = 0; i < 60 && i < pages; i++) {
      final l = await tester.runAsync(() => pdf.ensureLayer(i));
      if (l != null && l.sentences.length >= 5) return i;
    }
    return 0;
  }

  setUp(() async {
    sentences.clear();
    pagesToTurn.clear();
    await tts.stop();
    await pdf.clear();
    tts.resetSessionForTest();
    pdf.resetForTest();
    // 必须注册引擎：PDF 推进循环是 speakText 然后 await 会话完成，
    // 没有引擎就永远等不到「读完」，onSentenceChanged 一次都不会回调。
    await tts.registerEngine(_RealDurationEngine(), makeActive: true);
    // 把 crash.log 装上（应用启动时才装；测试进程要显式装一次，
    // 否则日志文件根本不存在 → 报告里「写盘行=0 / AF 行数=0」）
    try {
      await CrashLog.install();
    } catch (_) {
      // 装不上就只能在内存里看 recent，断言会提示
    }
    pdf.attach(listener);
    await clearLog();
    // ignore: avoid_print
    print('DIAG_SETUP sentences.hash=${sentences.hashCode} '
        'listener.sentences.hash=${listener.sentences.hashCode} '
        'same=${identical(sentences, listener.sentences)}');
  });

  tearDown(() async {
    await tts.stop();
    await pdf.clear();
    pdf.resetForTest();
  });

  // 路径 1：EPUB 到 PDF
  testWidgets('1 EPUB到PDF 切书点继续：高亮/跳转/通知栏 + 日志三核',
      (tester) async {
    // 先造出「上一本是 EPUB」的状态：让 TtsManager 持有另一个 docId
    tts.loadDocument(
      StructuredDocument(
        chapters: <Chapter>[
          const Chapter(
            title: '第一章',
            paragraphs: <Paragraph>[
              Paragraph(sentences: <Sentence>[
                Sentence('这是上一本 EPUB 的第一句。'),
                Sentence('这是上一本 EPUB 的第二句。'),
              ]),
            ],
          ),
        ],
      ),
      title: '上一本 EPUB',
      documentId: 'prev-epub',
    );
    // ignore: avoid_print
    print('DEVICE_VERIFY[switch-1] 前置 EPUB 会话 doc=${tts.activeDocumentId}');

    final pages = await openRealPdf(tester,
        documentId: 'switch-pdf-1', title: '切书目标 PDF');
    final page = await findTextPage(tester, pages);

    await tester.runAsync(() => pdf.jumpToPage(page, autoPlay: false));
    sentences.clear();
    pagesToTurn.clear();
    pdf.resume();
    await pumpFor(tester, 3000);

    _report('switch-1', path: 'EPUB到PDF', pdf: pdf, sentences: sentences,
        pagesToTurn: pagesToTurn, log: await readLog(), expectPage: page,
        listener: listener);
  }, timeout: const Timeout(Duration(minutes: 4)));

  // 路径 2：PDF 到 PDF
  testWidgets('2 PDF到PDF 切书点继续：高亮/跳转/通知栏 + 日志三核',
      (tester) async {
    final pagesA = await openRealPdf(tester,
        documentId: 'switch-pdf-A', title: 'PDF A');
    final pageA = await findTextPage(tester, pagesA);
    await tester.runAsync(() => pdf.jumpToPage(pageA, autoPlay: false));
    await pumpFor(tester, 400);
    // ignore: avoid_print
    print('DEVICE_VERIFY[switch-2] A 就绪 doc=${pdf.documentId} 页=$pageA/$pagesA');

    final pagesB = await openRealPdf(tester,
        documentId: 'switch-pdf-B', title: 'PDF B');
    final pageB = await findTextPage(tester, pagesB);
    await tester.runAsync(() => pdf.jumpToPage(pageB, autoPlay: false));
    sentences.clear();
    pagesToTurn.clear();
    pdf.resume();
    await pumpFor(tester, 3000);

    _report('switch-2', path: 'PDF到PDF', pdf: pdf, sentences: sentences,
        pagesToTurn: pagesToTurn, log: await readLog(), expectPage: pageB,
        listener: listener);
  }, timeout: const Timeout(Duration(minutes: 4)));

  // 路径 4：**恢复定位后，闸门必须与会话在同一页**（第 4 步的核心断言）
  //
  // 真机症状（用户两次复现）：
  // ```
  // 位置[PDF恢复] 落定=21/4 页数=812
  // AF[跟读] ref=21/4 cur=21/4 settled=15 disp=15   ← 差 6 页
  // ```
  // 根因：`resetForDocument` 在 `session.open()` **之前**调用，拿的是旧位置；
  // 恢复完成后**再没人对齐过闸门**。
  testWidgets('4 恢复定位后闸门与会话同页（不许差页）', (tester) async {
    final pages = await openRealPdf(tester,
        documentId: 'restore-sync', title: '恢复对齐验证');
    expect(pages, greaterThan(10), reason: '前置：这本要有足够页数');

    // 走到一个明确的页（离第 0 页远一点，便于暴露"停在旧页"）
    const target = 8;
    await tester.runAsync(() => pdf.jumpToPage(target, autoPlay: false));
    final layer = await tester.runAsync(() => pdf.ensureLayer(target));
    expect(layer, isNotNull, reason: '前置：目标页要有文本层');

    // 关掉会话再重开 = 模拟"退出阅读页再进来"的恢复路径
    await tester.runAsync(() async {
      await pdf.clear();
      await pdf.open(
        documentId: 'restore-sync',
        title: '恢复对齐验证',
        pageCount: pages,
        layerLoader: (i) async => null,
      );
    });
    final restored = pdf.current?.pageIndex;
    // ignore: avoid_print
    print('DEVICE_VERIFY[restore-sync] 恢复页=$restored 闸门=${PdfPageTurnController.debugActiveForTest?.displayedPage}');

    // ⚠️ 这条用例跑在**没有挂载阅读页**的环境里时，闸门是 null —— 如实标注而不是假装通过
    final gate = PdfPageTurnController.debugActiveForTest;
    if (gate == null) {
      // ignore: avoid_print
      print('DEVICE_VERIFY[restore-sync] ⚠️ 没有挂载的阅读页 → 闸门为空，'
          '本项**只验会话侧**，闸门对齐需在真机手测');
      expect(restored, isNotNull, reason: '会话位置必须恢复出来');
      return;
    }
    expect(restored, isNotNull, reason: '会话位置必须恢复出来');
    expect(gate.displayedPage, restored,
        reason: '★恢复之后闸门必须与会话同页（真机症状就是这里差了 6 页）');
  }, timeout: const Timeout(Duration(minutes: 4)));

  // 路径 3：手动滑动后切书（P0-2 核心）
  testWidgets('3 手动滑动后切书点继续：高亮/跳转/通知栏 + 日志三核',
      (tester) async {
    final pagesA = await openRealPdf(tester,
        documentId: 'scroll-pdf-A', title: '滑动前 PDF');
    final pageA = await findTextPage(tester, pagesA);
    await tester.runAsync(() => pdf.jumpToPage(pageA, autoPlay: false));
    await pumpFor(tester, 300);

    // 复现真机那条路径：用户手动翻过页（真机 = 手指拖动触发 markUserDriven）
    final gate = PdfPageTurnController.debugActiveForTest;
    if (gate != null) {
      gate.markUserDriven();
      // ignore: avoid_print
      print('DEVICE_VERIFY[switch-3] 已置用户滑动过 userDriven=${gate.userDriven}');
    } else {
      // ignore: avoid_print
      print('DEVICE_VERIFY[switch-3] 拿不到闸门实例（阅读页未挂载）'
          '—— 本次只验证会话侧与日志');
    }

    final pagesB = await openRealPdf(tester,
        documentId: 'scroll-pdf-B', title: '滑动后切到 PDF');
    final pageB = await findTextPage(tester, pagesB);
    if (gate != null) {
      gate.resetForDocument(pageCount: pagesB, initialPage: pageB);
      // ignore: avoid_print
      print('DEVICE_VERIFY[switch-3] 换书后 userDriven=${gate.userDriven} '
          'displayed=${gate.displayedPage}');
      expect(gate.userDriven, isFalse,
          reason: 'P0-2 核心：换书必须清掉「用户手动翻页」标记');
      expect(gate.turnTo(pageB + 1), isTrue,
          reason: 'P0-2 核心：换书后跟读必须能翻页（修前被静默挡下）');
    }

    await tester.runAsync(() => pdf.jumpToPage(pageB, autoPlay: false));
    sentences.clear();
    pagesToTurn.clear();
    pdf.resume();
    await pumpFor(tester, 3000);

    _report('switch-3', path: '滑动后切书', pdf: pdf, sentences: sentences,
        pagesToTurn: pagesToTurn, log: await readLog(), expectPage: pageB,
        listener: listener);
  }, timeout: const Timeout(Duration(minutes: 4)));
}

/// 真实时长的假引擎（1.2 秒读完一句）
///
/// 为什么必须真实时长：PdfReadSession 有「最短合理时长」判据（100ms），
/// 太快的完成会被当成假完成丢弃、位置不推进 —— 那样 onSentenceChanged
/// 就不会按预期回调，用例会误判成「高亮不显示」。
///
/// 为什么必须由引擎结束会话：PDF 推进循环是 speakText 然后 await 会话完成，
/// 会话必须真的被完成才走下一句。这里用 TtsManager.speakLines 起新会话，
/// 让上一代的 Completer 完成（与既有 PDF 设备用例同一套手法）。
class _RealDurationEngine implements TtsEngine {
  /// 每句朗读时长（1.2 秒，理由见类注释）
  ///
  /// ⚠️ 它原来是构造参数 `speakDuration`，但**从来没有调用点传过它**
  /// （`analyze` 报 `unused_element`），所以收成常量 —— 行为一字不改。
  static const Duration _speakDuration = Duration(milliseconds: 1200);

  int speakCalls = 0;
  Timer? _t;

  @override
  String get id => 'switch-continue-fake';
  @override
  String get displayName => '真实时长假引擎';
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
    speakCalls++;
    _t?.cancel();
    _t = Timer(_speakDuration, () {
      TtsManager.instance.speakLines(const <String>['占位']);
    });
  }

  @override
  Future<void> pause() async => _t?.cancel();
  @override
  Future<void> stop() async => _t?.cancel();
  @override
  void setCompletionHandler(void Function()? handler) {}
  @override
  Future<void> dispose() async => _t?.cancel();
}

/// 记录会话回调（高亮 = onSentenceChanged；跳转 = onPageShouldTurn）
class _RecordingListener implements PdfReadSessionListener {
  _RecordingListener(this.sentences, this.pagesToTurn);
  final List<PdfSentenceRef> sentences;
  final List<int> pagesToTurn;

  @override
  void onSentenceChanged(PdfSentenceRef ref) {
    sentences.add(ref);
    // ignore: avoid_print
    print('DIAG_CALLBACK hash=${sentences.hashCode} len=${sentences.length} '
        'ref=${ref.pageIndex}/${ref.sentenceIndex}');
  }

  @override
  void onPageShouldTurn(int pageIndex) => pagesToTurn.add(pageIndex);
  @override
  void onPlaybackStateChanged() {}
  @override
  void onFinished() {}
}

/// 统一断言 + 日志三核 + 打印
void _report(
  String tag, {
  required String path,
  required PdfReadSession pdf,
  required List<PdfSentenceRef> sentences,
  required List<int> pagesToTurn,
  required String log,
  required int expectPage,
  required _RecordingListener listener,
}) {
  final cur = pdf.current;
  final handler = audioHandler;
  final srcId = handler?.activeSource.sourceId ?? '(无 handler)';
  final notifPlaying = handler?.activeSource.playing ?? false;
  final notifHasSession = handler?.activeSource.hasSession ?? false;

  // 日志三核
  final writeLines =
      log.split('\n').where((l) => l.contains('位置[PDF写盘] seq=')).toList();
  final dropped = log.split('\n').where((l) => l.contains('丢弃过期写')).length;
  final blocked = log.split('\n').where((l) => l.contains('AF[turnTo挡下')).length;
  final afLines = log.split('\n').where((l) => l.contains('AF[')).toList();

  // ignore: avoid_print
  print('DEVICE_VERIFY[$tag] 身份核对: sentences.hash=${sentences.hashCode} '
      'len=${sentences.length} | listener.len=${listener.sentences.length} | '
      '同一对象=${identical(sentences, listener.sentences)}');
  // ignore: avoid_print
  print('DEVICE_VERIFY[$tag] 高亮回调=${sentences.length} '
      '最后ref=${sentences.isEmpty ? "(无)" : "${sentences.last.pageIndex}/${sentences.last.sentenceIndex}"} | '
      '跳转回调=${pagesToTurn.length} 目标=${pagesToTurn.isEmpty ? "(无)" : pagesToTurn.last} | '
      '会话current=${cur?.pageIndex}/${cur?.sentenceIndex} 期望页=$expectPage | '
      '通知栏source=$srcId hasSession=$notifHasSession playing=$notifPlaying | '
      '日志:写盘行=${writeLines.length} 丢弃过期写=$dropped '
      'AF挡下=$blocked AF行数=${afLines.length}');

  // 1 高亮
  //
  // ⚠️ 这里用**显式长度断言**而不是 `isNotEmpty`：实测遇到过
  // 「打印 len=1、same=true」但 `isNotEmpty` 报 `Actual: []` 的怪现象
  // （疑似匹配器在跨 zone 的列表上行为异常）。显式断言能把它说清楚。
  // ignore: avoid_print
  print('DIAG_ASSERT 断言前: 直接读长度=${sentences.length} '
      'listener读长度=${listener.sentences.length} '
      'isEmpty=${sentences.isEmpty}');
  expect(sentences.length, greaterThan(0),
      reason: '高亮：点继续后必须回调 onSentenceChanged（不显示高亮=没回调）');
  expect(sentences.last.pageIndex, expectPage,
      reason: '跳转准确：高亮的 ref 必须落在当前句所在页');

  // 2 跳转
  expect(cur, isNotNull, reason: '会话必须有当前位置');
  expect(cur!.pageIndex, expectPage, reason: '会话位置必须落在期望页');

  // 3 通知栏
  //
  // ⚠️ 集成测试进程里 `audioHandler` 可能是 null（audio_service 要有真实前台
  // 服务才初始化）。此时**不判通知栏**，但要**明确记下来** —— 不能装作验过了。
  if (handler == null) {
    // ignore: avoid_print
    print('DIAG_NOTIF audioHandler 为 null（本进程没起 audio_service）'
        '→ 通知栏同步这一项**本次未验证**，需在真机上另验');
  } else {
    expect(srcId, 'pdf-session',
        reason: '通知栏必须指向 PDF 会话（不同步=还停在旧来源）');
    expect(notifHasSession, isTrue, reason: '通知栏应当有活跃会话');
    expect(notifPlaying, pdf.isPlaying,
        reason: '通知栏播放态必须与会话一致（真机症状就是这里不一致）');
  }

  // 4 日志三核
  expect(dropped, 0, reason: '正常路径不应出现「丢弃过期写」');
  expect(blocked, 0, reason: '正常路径不应出现 AF[turnTo挡下]');
  expect(afLines, isNotEmpty, reason: 'AF 埋点必须打出（否则无法诊断竞态）');

  // 5 AF 埋点**字段齐全**（用户要求核的那一项）
  //
  // 为什么清单里同时要 `curPage` 与 `settled`：v1.21.43 之前 `cur=` 打的是页内
  // 落位去重值（同页内恒为 0），排查时会误以为"位置丢了"。现在 `curPage=` 是
  // 会话当前句所在页、`settled=` 才是页内落位值 —— 两个都要在，缺一个就说明
  // 埋点被改回旧写法了。
  //
  // ★v1.21.43 口径统一：页码字段一律 **1-based**，与界面 / `AF[居中] refPage=`
  // 同口径，可直接对比。原来 `ref=`/`cur=` 打的是 **0-based 原始索引**，
  // 与 `AF[居中]` 的 `pageIndex + 1` 差 1 —— 真机上真的被误判成"位置错位"过。
  // 原始索引另起名 `refPage0=`，绝不与页码混用。
  const afFields = <String>[
    'doc=', 'src=', 'key=', 'token=', 'refPage=', 'refSent=', 'curPage=',
    'refPage0=', 'settled=', '视口页=', 'userDriven=', 'turning=', 'playing=',
    'paused=', 'hasSession=', 'speaking=', 'borrowed=', 'seq=',
  ];
  // ★v1.21.43：`disp=` 已删除 —— 它读的是旧状态机 `_turn.displayedPage`，
  // 旧路静默后会冻住、变成误导源。现在与 `AF[居中]` 同源（滚动位置反推的"视口页"）。
  final afSample = afLines.last;
  final missing = afFields.where((f) => !afSample.contains(f)).toList();
  // ignore: avoid_print
  print('DIAG_AF_FIELDS 样例=${afSample.trim()}');
  // ignore: avoid_print
  print('DIAG_AF_FIELDS 缺字段=${missing.isEmpty ? "无" : missing.join(",")}');
  expect(missing, isEmpty, reason: 'AF 埋点字段必须齐全，缺：$missing');
}

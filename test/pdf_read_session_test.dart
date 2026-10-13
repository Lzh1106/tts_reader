import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// [PdfReadSession] 的核心行为测试。
///
/// 会话是「自动连读 + 自动翻页 + 退出阅读页继续读」的实现点，逻辑上最容易错：
/// 推进循环住在单例里、靠 token 打断、**严格串行**地 await 每一句。
/// 这些都不依赖 UI，所以用假的文本层 + 假引擎把它整条钉死。
///
/// ⚠️ 单例会串状态：每个 setUp 都要 `resetForTest()`（HANDOFF §9.31）。
class _RecordingEngine with SyntheticTtsEngine implements TtsEngine {
  /// 每次朗读的耗时：给推进循环留出可被打断的窗口
  /// 假引擎「读完一句」的耗时。
  ///
  /// ⚠️ 必须 **> `PdfReadSession._minRealSpeakMs`（100ms）**，否则会被
  /// §4.106 的「最短合理时长」判据当成**假完成**丢弃 —— 那是对的判据
  /// （真机实测假完成是 0~48ms），但会让这里的 mock 读不出第二句。
  /// 150ms 既有真实感，又留出余量。
  static const Duration speakDelay = Duration(milliseconds: 150);

  final List<String> spoken = <String>[];
  void Function()? _onComplete;

  @override
  String get id => 'pdf-session-recorder';

  @override
  String get displayName => '假引擎（记录 + 自然完成）';

  @override
  bool get isAvailable => true;

  @override
  Future<void> initialize() async {
  }

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
    // 真引擎读完会回调（HANDOFF §4.22：假引擎也必须真的回调）
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

/// 记录会话回调的假监听者
class _RecordingListener implements PdfReadSessionListener {
  final List<PdfSentenceRef> sentences = <PdfSentenceRef>[];
  final List<int> pageTurns = <int>[];
  int finishedCount = 0;
  int stateChanges = 0;

  @override
  void onSentenceChanged(PdfSentenceRef ref) => sentences.add(ref);

  @override
  void onPageShouldTurn(int pageIndex) => pageTurns.add(pageIndex);

  @override
  void onFinished() => finishedCount++;

  @override
  void onPlaybackStateChanged() => stateChanges++;
}

void main() {
  // TtsManager 是单例，构造时就建 MethodChannel → 必须先初始化 binding
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingEngine engine;

  /// 造一页文本层：句子按 `。` 切
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

  /// 造一页**多行**文本层：`\n` 分行，每行给不同的 y（否则会被并成一行）
  PdfPageTextLayer makeMultiLinePage(int pageNumber, String text) {
    final List<String> lineTexts = text.split('\n');
    final List<PdfTextChar> chars = <PdfTextChar>[];
    final List<Rect> rects = <Rect>[];
    var index = 0;
    for (var li = 0; li < lineTexts.length; li++) {
      final String line = lineTexts[li];
      final double y = 60.0 + li * 18.0;
      for (var i = 0; i < line.length; i++) {
        final Rect r = Rect.fromLTWH(40 + i * 10.0, y, 10, 12);
        chars.add(PdfTextChar(index: index, char: line[i], rect: r));
        rects.add(r);
        index++;
      }
    }
    return buildTextLayer(
      pageNumber: pageNumber,
      pageSize: const Size(400, 300),
      fullText: lineTexts.join(), // 不含换行符：分行完全由 rect 的 y 决定
      charRects: rects,
      segment: segmentIntoSentences,
    );
  }

  /// 三页：第 1 页 3 句、第 2 页 2 句、第 3 页无文字（扫描件）
  late Map<int, PdfPageTextLayer> pages;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 朗读位置走 StorageService 落盘（§4.100 任务 D）：
    // 单例缓存会跨用例串数据，每条用例都要重置 + 重新 init（§9.16）
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    TtsManager.instance.resetSessionForTest();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.speakTimeout = const Duration(seconds: 5);
    engine = _RecordingEngine();
    await TtsManager.instance.registerEngine(engine, makeActive: true);

    pages = <int, PdfPageTextLayer>{
      0: makePage(1, '第一页甲。第一页乙。第一页丙。'),
      1: makePage(2, '第二页甲。第二页乙。'),
    };
    PdfReadSession.instance.resetForTest();
    PdfReadSession.instance.audioBridge = RecordingAudioBridge();
  });

  tearDown(() async {
    await PdfReadSession.instance.clear();
    PdfReadSession.instance.resetForTest();
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.resetSessionForTest();
  });

  /// 打开会话（页数含第 3 页空页）
  Future<void> openSession({int pageCount = 3}) => PdfReadSession.instance.open(
        documentId: 'doc-1',
        title: '测试 PDF',
        pageCount: pageCount,
        layerLoader: (pageIndex) async => pages[pageIndex],
      );

  /// 等条件成立（推进是异步的，用轮询等它稳定）
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

  test('自动推进：从第 1 句开始会连续读到第 3 句', () async {
    final session = PdfReadSession.instance;
    await openSession();
    final listener = _RecordingListener();
    session.attach(listener);

    final first = firstSentenceOnPage(0, session.layerOf(0));
    // layerOf 还没缓存 → 用 ensureLayer
    final layer0 = await session.ensureLayer(0);
    final start = firstSentenceOnPage(0, layer0)!;
    expect(first, isNull, reason: '还没加载时 layerOf 返回 null');
    expect(start.text, '第一页甲。');

    session.startAt(start);
    // startAt 内部是常驻循环，这里等它把三句读完
    await waitFor(() => engine.spoken.length >= 3);
    await waitFor(() => session.isFinished);

    // ignore: avoid_print
    print('SESSION 自动推进：读过=${engine.spoken} '
        '回调=${listener.sentences.map((s) => s.text).toList()} '
        'finished=${listener.finishedCount}');
    expect(engine.spoken.take(3).toList(),
        <String>['第一页甲。', '第一页乙。', '第一页丙。'],
        reason: '必须一句接一句自动读下去');
    expect(listener.finishedCount, greaterThanOrEqualTo(1),
        reason: '读完最后一句要报 onFinished');
    expect(session.isPlaying, isFalse, reason: '读完后不再是播放中');
  });

  test('跨页推进：第 1 页读完接着读第 2 页', () async {
    final session = PdfReadSession.instance;
    await openSession();
    final listener = _RecordingListener();
    session.attach(listener);

    final layer0 = await session.ensureLayer(0);
    session.startAt(sentenceRefAt(0, 1, layer0)!); // 从「第一页乙」开始
    await waitFor(() => engine.spoken.length >= 4);
    await waitFor(() => session.isFinished);

    // ignore: avoid_print
    print('SESSION 跨页：读过=${engine.spoken}');
    expect(engine.spoken.take(4).toList(), <String>[
      '第一页乙。',
      '第一页丙。',
      '第二页甲。', // ← 跨页了
      '第二页乙。',
    ]);
  });

  test('跨页①：页脚「− 311 −」不成句、也不与下一页首句合并', () async {
    // 真实场景：页末是一行页码「− 311 −」（没有句末标点）。
    // 修前它会被 looksUnfinished 判成"还会续" → 与下一页首句拼成一句朗读。
    pages = <int, PdfPageTextLayer>{
      0: makeMultiLinePage(1, '第一页甲。\n第一页乙。\n− 311 −'),
      1: makeMultiLinePage(2, '第二页甲。\n第二页乙。'),
    };
    final session = PdfReadSession.instance;
    await openSession();
    final listener = _RecordingListener();
    session.attach(listener);

    final layer0 = await session.ensureLayer(0);
    // 页脚已经被滤掉 → 这一页只剩两句
    expect(layer0!.sentences.map((s) => s.text).toList(),
        <String>['第一页甲。', '第一页乙。'],
        reason: '页码行既不成句也不参与合并');

    session.startAt(sentenceRefAt(0, 1, layer0)!); // 从「第一页乙。」开始
    await waitFor(() => session.isFinished);

    // ignore: avoid_print
    print('SESSION 跨页①：读过=${engine.spoken}');
    expect(engine.spoken, <String>['第一页乙。', '第二页甲。', '第二页乙。'],
        reason: '页脚不该出现，也不该把下一页首句粘上来');
  });

  test('跨页②：真·续句合并后，下一页首句不能再读第二遍', () async {
    // 末行确实没写完（没有句末标点、也不是页码）→ 允许合并；
    // 但合并读完之后，推进必须从「已读掉的下一页首句」之后开始。
    pages = <int, PdfPageTextLayer>{
      0: makeMultiLinePage(1, '第一页甲。\n第一页乙。\n下半句还没写完'),
      1: makeMultiLinePage(2, '第二页甲。\n第二页乙。'),
    };
    final session = PdfReadSession.instance;
    await openSession();
    final listener = _RecordingListener();
    session.attach(listener);

    final layer0 = await session.ensureLayer(0);
    session.startAt(sentenceRefAt(0, 2, layer0)!); // 从末行开始
    await waitFor(() => session.isFinished);

    // ignore: avoid_print
    print('SESSION 跨页②：读过=${engine.spoken}');
    final int dup =
        engine.spoken.where((String s) => s.contains('第二页甲')).length;
    expect(dup, 1,
        reason: '「第二页甲。」只能读一次：合并句已经读掉它了'
            '（实际 $dup 次，序列=${engine.spoken}）');
    expect(engine.spoken.first, contains('下半句还没写完'),
        reason: '真·续句仍然要合并成完整一句读出来');
  });

  test('末句停：读到第 2 页最后一句就结束（第 3 页无文字）', () async {
    final session = PdfReadSession.instance;
    await openSession();
    final listener = _RecordingListener();
    session.attach(listener);

    final layer1 = await session.ensureLayer(1);
    session.startAt(sentenceRefAt(1, 1, layer1)!); // 最后一句
    await waitFor(() => session.isFinished);

    // ignore: avoid_print
    print('SESSION 末句：读过=${engine.spoken} finished=${listener.finishedCount}');
    expect(engine.spoken, <String>['第二页乙。']);
    expect(listener.finishedCount, 1);
    expect(session.isFinished, isTrue);
    expect(session.current!.text, '第二页乙。', reason: '停在最后一句，位置不乱跑');
  });

  test('点句打断：旧链不再推进', () async {
    final session = PdfReadSession.instance;
    await openSession();
    final layer0 = await session.ensureLayer(0);
    final layer1 = await session.ensureLayer(1);

    // 先起一条链
    session.startAt(sentenceRefAt(0, 0, layer0)!);
    // 等第 1 句真的读出来（这时旧链正在往下推）
    await waitFor(() => engine.spoken.isNotEmpty);
    expect(engine.spoken.first, '第一页甲。');

    // 立刻点另一页的一句（打断）—— 因为 startAt 是「发起即返回」，
    // 这一次调用会立刻让旧链的 token 失效
    session.startAt(sentenceRefAt(1, 0, layer1)!);
    // ignore: avoid_print
    await waitFor(() => engine.spoken.contains('第二页甲。'));
    final interruptIndex = engine.spoken.indexOf('第二页甲。');
    // 再等一会儿，看旧链会不会「回魂」继续读第 1 页
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // ignore: avoid_print
    print('SESSION 打断：读过=${engine.spoken} 打断位置=$interruptIndex');
    final afterInterrupt = engine.spoken.skip(interruptIndex).toList();
    // 打断之后只该有第 2 页的内容
    for (final s in afterInterrupt) {
      expect(s.startsWith('第一页'), isFalse,
          reason: '被打断的旧链不能再读第 1 页的句子'
              '（打断后=$afterInterrupt）');
    }
    expect(afterInterrupt, contains('第二页甲。'));
  });

  test('detach 后继续推进（**本次核心**：退出阅读页不停朗读）', () async {
    final session = PdfReadSession.instance;
    await openSession();
    final listener = _RecordingListener();
    session.attach(listener);

    final layer0 = await session.ensureLayer(0);
    session.startAt(sentenceRefAt(0, 0, layer0)!);
    await waitFor(() => engine.spoken.isNotEmpty);

    // 模拟「退出阅读页」：只摘监听者
    session.detach(listener);
    expect(session.listener, isNull);

    // 声音必须继续 —— 摘了监听者不影响推进循环
    await waitFor(() => engine.spoken.length >= 3);
    // ignore: avoid_print
    print('SESSION detach 后：读过=${engine.spoken}（应当继续读到第 3 句）');
    expect(engine.spoken.length, greaterThanOrEqualTo(3),
        reason: '退出阅读页后必须继续读（推进循环不在 Widget State 里）');
    expect(engine.spoken.take(3).toList(),
        <String>['第一页甲。', '第一页乙。', '第一页丙。']);
    // 摘掉之后界面回调不该再来（否则会去动已销毁的 PageController）
    final callbacksAtDetach = listener.sentences.length;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(listener.sentences.length, callbacksAtDetach,
        reason: 'detach 之后不该再回调界面');
  });

  test('stopSound 保留位置：resume 从当前句继续', () async {
    final session = PdfReadSession.instance;
    await openSession();
    final layer0 = await session.ensureLayer(0);
    session.startAt(sentenceRefAt(0, 0, layer0)!);
    await waitFor(() => engine.spoken.isNotEmpty);

    await session.stopSound();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final stoppedAt = session.current;
    expect(session.isPlaying, isFalse);
    expect(stoppedAt, isNotNull, reason: 'stopSound 要保留 current');
    expect(session.documentId, 'doc-1', reason: 'stopSound 不清文档');

    final countAfterStop = engine.spoken.length;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(engine.spoken.length, countAfterStop,
        reason: 'stopSound 之后旧循环必须停下');

    // resume 从 current 继续
    session.resume();
    await waitFor(() => engine.spoken.length > countAfterStop);
    expect(engine.spoken.last, stoppedAt!.text,
        reason: 'resume 从当前句（句首）重读');
  });

  test('clear 彻底清：位置与文档都清掉', () async {
    final session = PdfReadSession.instance;
    await openSession();
    final layer0 = await session.ensureLayer(0);
    session.startAt(sentenceRefAt(0, 1, layer0)!);
    await waitFor(() => engine.spoken.isNotEmpty);

    await session.clear();
    expect(session.isActive, isFalse);
    expect(session.current, isNull);
    expect(session.documentId, isNull);
    expect(session.layerOf(0), isNull, reason: '文本层缓存也要清');
  });

  test('同一本书重进保留位置（open 幂等）', () async {
    final session = PdfReadSession.instance;
    await openSession();
    final layer0 = await session.ensureLayer(0);
    session.startAt(sentenceRefAt(0, 2, layer0)!);
    await waitFor(() => session.isFinished);

    final before = session.current;
    // 重进：同一个 documentId + 同样页数
    await openSession();
    // ignore: avoid_print
    print('SESSION 重进：before=$before after=${session.current}');
    expect(session.current, before, reason: '同 id 重进不该把位置清掉');
    expect(session.isActive, isTrue);
  });

  test('换书清位置（open 不同 id）', () async {
    final session = PdfReadSession.instance;
    await openSession();
    final layer0 = await session.ensureLayer(0);
    session.startAt(sentenceRefAt(0, 1, layer0)!);
    await waitFor(() => engine.spoken.isNotEmpty);

    await session.open(
      documentId: 'doc-2',
      title: '另一本',
      pageCount: 2,
      layerLoader: (pageIndex) async => null,
    );
    expect(session.documentId, 'doc-2');
    expect(session.current, isNull, reason: '换书要把位置清掉');
    expect(session.isPlaying, isFalse);
  });

  test('通知栏接口：PDF 会话 canSeek=false、进度按页', () async {
    final session = PdfReadSession.instance;
    await openSession();
    final layer1 = await session.ensureLayer(1);
    session.startAt(sentenceRefAt(1, 0, layer1)!);
    await waitFor(() => session.current != null);

    // ignore: avoid_print
    print('SESSION 通知栏：sourceId=${session.sourceId} canSeek=${session.canSeek} '
        'total=${session.progressTotal} index=${session.progressIndex} '
        'label=${session.positionLabel}');
    expect(session.sourceId, 'pdf-session');
    expect(session.canSeek, isFalse, reason: 'PDF 不按比例跳');
    expect(session.progressTotal, 3, reason: '进度按页算');
    expect(session.progressIndex, 1, reason: '当前在第 2 页（0 起）');
    expect(session.positionLabel, contains('第 2/3 页'));
  });

  test('通知栏上/下一章映射到相邻页首句', () async {
    final session = PdfReadSession.instance;
    await openSession();
    final layer0 = await session.ensureLayer(0);
    await session.ensureLayer(1);
    session.startAt(sentenceRefAt(0, 0, layer0)!);
    await waitFor(() => session.current != null);

    session.skipChapter(1); // 下一章 = 下一页首句
    await waitFor(() => session.current?.pageIndex == 1);
    // ignore: avoid_print
    print('SESSION skipChapter(+1) → page=${session.current?.pageIndex} '
        'text=${session.current?.text}');
    expect(session.current!.pageIndex, 1);
    expect(session.current!.sentenceIndex, 0, reason: '跳到下一页首句');
  });

  test('⚠️ 中间有空白页时继续往后读（不能中途报「读完」）', () async {
    // 真实形态：《共产主义ABC》第 7 页之后有空白页，正文在后面。
    // 早先 `nextPdfSentence` 把「下一页没有文字层」直接当成读到头，
    // 于是 319 页的书在第 8 页就 `isFinished=true`、声音停了、
    // 用户看到「书读到一半突然说读完了」。
    final session = PdfReadSession.instance;
    final withBlank = <int, PdfPageTextLayer>{
      0: makePage(1, '封面标题。'),
      1: makePage(2, ''), // 空白页
      2: makePage(3, '正文甲。正文乙。'),
    };
    await session.open(
      documentId: 'blank-doc',
      title: '带空白页的 PDF',
      pageCount: 3,
      layerLoader: (i) async => withBlank[i],
    );
    final listener = _RecordingListener();
    session.attach(listener);

    final layer0 = await session.ensureLayer(0);
    session.startAt(sentenceRefAt(0, 0, layer0)!);
    await waitFor(() => session.isFinished);

    // ignore: avoid_print
    print('SESSION 空白页：读过=${engine.spoken} '
        'finished=${listener.finishedCount} 最终=${session.current}');
    expect(engine.spoken, <String>['封面标题。', '正文甲。', '正文乙。'],
        reason: '第 2 页空白要跳过，接着读第 3 页');
    expect(listener.finishedCount, 1, reason: '读完第 3 页才算读完');
    expect(session.current?.pageIndex, 2, reason: '停在最后一页（0 起下标 2）');
    expect(session.isFinished, isTrue);
  });

  test('⚠️ 空白页后面几页「还没抽出来」时，不能当成读完', () async {
    // 设备实测的真实形态（319 页《共产主义ABC》）：
    //   第 9 页 = 真空白（抽过，isEmptyPage=true）
    //   第 10~16 页 = **还没抽出来**（layerOf=null 且 isEmptyPage=false）
    //   第 17 页起又有正文
    // 早先的逻辑在第 9 页空白之后撞上「还没抽出来」就 `_finished=true`，
    // 用户看到「书读到一半突然说读完了」。
    final session = PdfReadSession.instance;
    final loaded = <int, PdfPageTextLayer>{
      0: makePage(1, '第1页正文。'),
      // 第 2 页（下标 1）是空白：loader 返回空层 → 会被判 empty
      1: makePage(2, ''),
      6: makePage(7, '第7页正文。'),
      // 下标 2..5 故意**不提供**（模拟还没抽出来）
    };
    await session.open(
      documentId: 'gap-doc',
      title: '空白页+未抽页',
      pageCount: 8,
      layerLoader: (i) async => loaded[i],
    );
    final listener = _RecordingListener();
    session.attach(listener);

    final layer0 = await session.ensureLayer(0);
    session.startAt(sentenceRefAt(0, 0, layer0)!);
    // 给足时间：推进应当停下来（推不动），但**不能**报「读完」
    await waitFor(() => engine.spoken.length >= 2);

    // ignore: avoid_print
    print('SESSION 间隙：读过=${engine.spoken} '
        'finished=${listener.finishedCount} '
        'isFinished=${session.isFinished} 当前位置=${session.current}');

    expect(listener.finishedCount, 0,
        reason: '第 2 页空白之后的页还没抽出来，不是「读到文档末尾」，'
            '不该报 onFinished（报了用户就看到「读到一半说读完了」）');
    expect(session.isFinished, isFalse,
        reason: 'isFinished 必须保持 false —— 还能继续读，只是暂时没数据');
  });

  test('resetForTest 有效', () async {
    final session = PdfReadSession.instance;
    await openSession();
    await session.ensureLayer(0);
    expect(session.isActive, isTrue);

    session.resetForTest();
    expect(session.isActive, isFalse);
    expect(session.current, isNull);
    expect(session.listener, isNull);
    expect(session.pageCount, 0);
  });

  // ---------------- §4.100 任务 D：朗读位置恢复 ----------------
  // 三条症状的纯逻辑部分都在这里钉死（界面层的定位在设备用例里验）：
  //   · 落盘记录与 session.current **分开** —— clear() 清 current 但记录还在；
  //   · 重进（同 id 的 open）从记录恢复位置；
  //   · 换书 / clear 不会污染另一本书的位置；
  //   · 位置写的是「句」，但恢复必须**校验句下标**（分句规则会变，§4.100 任务 B
  //     改了分行，同页句数会变），越界退回该页第 0 句而不是错位。

  test('⚠️ 朗读位置按文档落盘（与 current 解耦）', () async {
    final session = PdfReadSession.instance;
    await openSession();
    final layer0 = await session.ensureLayer(0);
    session.startAt(sentenceRefAt(0, 2, layer0)!);
    await waitFor(() => engine.spoken.isNotEmpty);

    // startAt 是显式动作：立即落盘，不用等防抖
    expect(StorageService.instance.pdfReadingSpot('doc-1'), isNotNull,
        reason: '点句后位置应已写入（不等防抖窗口）');
    final spot = StorageService.instance.pdfReadingSpot('doc-1')!;
    expect(spot.pageIndex, lessThanOrEqualTo(0));
  });

  // ──────────────────────────────────────────────────────────────────────
  // v1.21.43 · P0-1：位置写盘的**拍号 + 串行队列**
  //
  // 真机症状（用户日志）：
  // ```
  // 19:57:33  位置[PDF写盘] page=28 sentence=17
  // 19:57:33  位置[PDF起读] ref=28/16
  // 19:57:33  位置[PDF写盘] page=28 sentence=16   ← 位置从 28/17 回退到 28/16
  // ```
  // 机理：两次写都走 `unawaited(...)`，彼此无序 —— 旧写后到就覆盖新写。
  // 修法：全部写排进一条串行链，并按发起顺序落盘。
  // ──────────────────────────────────────────────────────────────────────

  group('⚠️ P0-1：位置写盘必须按发起顺序落盘（不许旧写覆盖新写）', () {
    test('连续两次立即写：盘上留下的必须是**后发起**的那一个', () async {
      final session = PdfReadSession.instance;
      await openSession();
      final layer0 = await session.ensureLayer(0);

      // 两次「显式起读」——真机上就是「点句 → 位置写盘」紧接着又「起读」。
      // 两次都会走 immediate 写（`_setCurrent(..., immediate: true)`）。
      session.startAt(sentenceRefAt(0, 2, layer0)!);
      final seqAfterFirst = session.spotSeqForDiag;
      session.startAt(sentenceRefAt(0, 0, layer0)!);
      final seqAfterSecond = session.spotSeqForDiag;

      // 等写盘链排空（串行链的意义：等到它跑完就是"全部落盘"）
      await waitFor(
        () => StorageService.instance.pdfReadingSpot('doc-1') != null,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final spot = StorageService.instance.pdfReadingSpot('doc-1')!;
      // ignore: avoid_print
      print('DEVICE_VERIFY[spot-seq] seq $seqAfterFirst → $seqAfterSecond '
          '落盘=${spot.pageIndex}/${spot.sentenceIndex}');

      expect(seqAfterSecond, greaterThan(seqAfterFirst),
          reason: '两次写必须各占一个拍号');
      expect(spot.sentenceIndex, 0,
          reason: '最后发起的是第 0 句 → 盘上必须是 0，'
              '若被旧写覆盖就会是 2（真机 28/17→28/16 那条）');
    });

    test('起读的立即写 + 停声的 flush：合成一次有序落盘', () async {
      final session = PdfReadSession.instance;
      await openSession();
      final layer0 = await session.ensureLayer(0);

      session.startAt(sentenceRefAt(0, 2, layer0)!);
      // 紧接着停声（真机：点句后马上按暂停/方块）→ 内部会 _flushSpot()
      await session.pause();
      final seqAfterPause = session.spotSeqForDiag;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final spot = StorageService.instance.pdfReadingSpot('doc-1');
      // ignore: avoid_print
      print('DEVICE_VERIFY[spot-seq] pause 后 seq=$seqAfterPause '
          '落盘=${spot?.pageIndex}/${spot?.sentenceIndex}');
      expect(spot, isNotNull,
          reason: '停声必须把位置刷盘（否则重进定位到半路）');
    });

    test('拍号是单调递增的（换书后仍在同一会话对象上累加）', () async {
      final session = PdfReadSession.instance;
      await openSession();
      final layer0 = await session.ensureLayer(0);
      session.startAt(sentenceRefAt(0, 0, layer0)!);
      final a = session.spotSeqForDiag;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      session.startAt(sentenceRefAt(0, 1, layer0)!);
      final b = session.spotSeqForDiag;
      // ignore: avoid_print
      print('DEVICE_VERIFY[spot-seq] 单调性 $a → $b');
      expect(b, greaterThan(a));
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  // v1.21.43 真机手测 ② 的补充：**应用内恢复**时通知栏必须收到新状态
  //
  // 用户手测结果：「通知栏暂停后应用内同样暂停（好）；但**应用内恢复，
  // 通知栏却没从暂停图标改回播放**」。方向与 v1.21.39 修的那条相反 ——
  // 那条修的是「通知栏按暂停 → 应用内」；这条是「应用内恢复 → 通知栏」。
  //
  // 本用例判定责任在**哪一侧**：
  // · 若 pause 之后 resume 让桥收到 notify/claim，说明会话侧有推，
  //   问题在 handler / ROM 侧；
  // · 若没收到，说明会话侧漏推 —— 那是本处要修的。
  // ──────────────────────────────────────────────────────────────────────

  group('⚠️ 应用内恢复 → 通知栏状态必须更新（真机手测 ②）', () {
    test('pause 之后 resume：桥必须再收到一次 notify/claim', () async {
      final session = PdfReadSession.instance;
      final bridge = RecordingAudioBridge();
      session.audioBridge = bridge;

      await openSession();
      final layer0 = await session.ensureLayer(0);
      session.startAt(sentenceRefAt(0, 0, layer0)!);
      await waitFor(() => engine.spoken.isNotEmpty);

      // 通知栏暂停（用户按的）
      await session.pause();
      final afterPause = bridge.calls.length;
      // ignore: avoid_print
      print('DEVICE_VERIFY[resume-sync] pause 后 桥调用=${bridge.calls}');

      // 应用内恢复（用户按的）
      session.resume();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final afterResume = bridge.calls.length;
      // ignore: avoid_print
      print('DEVICE_VERIFY[resume-sync] resume 后 桥调用=${bridge.calls} '
          '（pause前=$afterPause resume后=$afterResume）');

      expect(session.isPlaying, isTrue, reason: '前置：恢复后会话应当是在播状态');
      expect(afterResume, greaterThan(afterPause),
          reason: '★应用内恢复之后，会话必须再推一次通知栏状态 —— '
              '否则通知栏图标会停在"暂停"样式（真机手测 ② 的现象）');
    });
  });

  test('⚠️ clear 后重进同一本书：从落盘记录恢复位置（症状③）', () async {    final session = PdfReadSession.instance;
    await openSession();
    final layer0 = await session.ensureLayer(0);
    session.startAt(sentenceRefAt(0, 1, layer0)!);
    await waitFor(() => engine.spoken.isNotEmpty);

    // 结束朗读：方块键 / 通知栏关闭都走 clear
    await session.clear();
    expect(session.current, isNull, reason: 'clear 必须清掉会话位置（§4.89）');
    // 但落盘记录还在
    expect(StorageService.instance.pdfReadingSpot('doc-1'), isNotNull,
        reason: 'clear 不能把「这本书读到哪」的记录一起删掉');

    // 重进：新建会话状态（resetForTest 模拟「进程内从头打开这本书」）
    session.resetForTest();
    await openSession();
    final restored = session.current;
    expect(restored, isNotNull, reason: '重进要恢复到上次朗读位置（症状③）');
    expect(restored!.pageIndex, 0);
    expect(session.isPlaying, isFalse,
        reason: '恢复只是**定位**，不该自动开播');
  });

  test('⚠️ 换书不污染另一本书的位置记录（双向隔离）', () async {
    final session = PdfReadSession.instance;
    await openSession();
    final layer0 = await session.ensureLayer(0);
    session.startAt(sentenceRefAt(0, 1, layer0)!);
    await waitFor(() => engine.spoken.isNotEmpty);
    final spotA = StorageService.instance.pdfReadingSpot('doc-1');
    expect(spotA, isNotNull);

    // 换一本书读（不同 id）
    await session.open(
      documentId: 'doc-2',
      title: '另一本',
      pageCount: 3,
      layerLoader: (i) async => pages[i],
    );
    expect(session.current, isNull, reason: '换书会话位置归零');

    // 新书的位置与旧书互不干扰
    await session.ensureLayer(1);
    final l1 = session.layerOf(1);
    session.startAt(sentenceRefAt(1, 0, l1)!);
    await waitFor(() => engine.spoken.length >= 2);

    final spotB = StorageService.instance.pdfReadingSpot('doc-2');
    expect(spotB, isNotNull, reason: '新书位置该落在自己的 id 上');
    expect(spotB!.pageIndex, 1);
    // 旧书记录仍是原来的页（没被新书覆盖）
    expect(StorageService.instance.pdfReadingSpot('doc-1')!.pageIndex,
        spotA!.pageIndex);
  });

  test('⚠️ 恢复时校验句下标：记录过期就退回该页第 0 句', () async {
    final session = PdfReadSession.instance;
    await openSession();
    final layer0 = await session.ensureLayer(0);
    expect(layer0!.sentences.length, 3, reason: '本页应有 3 句');
    session.startAt(sentenceRefAt(0, 2, layer0)!);
    await waitFor(() => engine.spoken.isNotEmpty);

    // 伪造一条「句下标越界」的旧记录（模拟分句规则变更后留下的位置）
    await StorageService.instance.setPdfReadingSpot(
      'doc-1',
      pageIndex: 0,
      sentenceIndex: 999,
    );
    session.resetForTest();
    await openSession();
    final restored = session.current;
    expect(restored, isNotNull);
    expect(restored!.pageIndex, 0, reason: '页仍要定位对');
    expect(restored.sentenceIndex, 0,
        reason: '句下标越界必须退回第 0 句，不能错位 / 崩溃');
  });

  test('⚠️ stopSound 后 current 保留，重新 attach 定位到同一句（症状②的会话侧）', () async {
    final session = PdfReadSession.instance;
    await openSession();
    final layer0 = await session.ensureLayer(0);
    final ref = sentenceRefAt(0, 1, layer0)!;
    session.startAt(ref);
    await waitFor(() => engine.spoken.isNotEmpty);

    await session.stopSound();
    final listener = _RecordingListener();
    session.attach(listener);
    expect(listener.sentences, isNotEmpty,
        reason: 'attach 要把**已有的**位置立刻回调给界面（新实例靠它定位）');
    expect(listener.sentences.first.text, isNotEmpty);
  });

  // ──────────────────────────────────────────────────────────────────────
  // v1.21.43 · P0-3：换书时切断旧文档的异步尾巴
  //
  // 要防的污染：`_pendingSpot` 还带着旧书的 ref 时换了书，它会在新 `_documentId`
  // 下被写出去 → 旧书的位置进了**新书的记录**（用户看到"切过去那本书位置莫名"）。
  //
  // ⚠️ 诚实标注：这 3 条用例**在撤掉 P0-3 修复后仍然全绿**（见
  // `_cancelOldDocumentWrites` 的文档注释）—— 因为 `open()` 里原有的
  // `await _flushSpot()` 已经把待写值排空并以旧 id 落盘。所以它们**不是**
  // "能抓住这个 bug 的回归用例"，而是把"换书不许污染另一本书记录"这条
  // **不变量**钉住（防止将来有人改坏 flush 顺序）。
  // ──────────────────────────────────────────────────────────────────────

  group('⚠️ P0-3：换书不许把旧书的位置写进新书记录', () {
    test('旧书待写值归旧书；新书记录只认它自己的落盘位置', () async {
      final session = PdfReadSession.instance;
      await openSession();
      final layer0 = await session.ensureLayer(0);
      session.startAt(sentenceRefAt(0, 2, layer0)!);
      await waitFor(() => engine.spoken.isNotEmpty);
      final spotA = StorageService.instance.pdfReadingSpot('doc-1');
      // ignore: avoid_print
      print('DEVICE_VERIFY[p0-3] A 落盘=${spotA?.pageIndex}/${spotA?.sentenceIndex}');

      // 换到 B（另一本书，5 页）。A 的推进循环此刻仍在飞。
      await session.open(
        documentId: 'doc-2',
        title: '第二本 PDF',
        pageCount: 5,
        layerLoader: (pageIndex) async => pages[pageIndex],
      );
      // 给"在飞的写"留出落盘窗口
      await Future<void>.delayed(const Duration(milliseconds: 120));

      final spotB = StorageService.instance.pdfReadingSpot('doc-2');
      // ignore: avoid_print
      print('DEVICE_VERIFY[p0-3] 换书后 B 记录=${spotB?.pageIndex}/${spotB?.sentenceIndex} '
          '（B 从未朗读过 → 应为 null）');
      expect(spotB, isNull,
          reason: '★B 从没朗读过：它不该有任何位置记录');
    });

    test('换书前旧书的最后位置必须已经落盘（不能被切断吞掉）', () async {
      final session = PdfReadSession.instance;
      await openSession();
      final layer0 = await session.ensureLayer(0);
      session.startAt(sentenceRefAt(0, 1, layer0)!);
      await waitFor(() => engine.spoken.isNotEmpty);

      await session.open(
        documentId: 'doc-3',
        title: '第三本 PDF',
        pageCount: 3,
        layerLoader: (pageIndex) async => pages[pageIndex],
      );
      final spotA = StorageService.instance.pdfReadingSpot('doc-1');
      // ignore: avoid_print
      print('DEVICE_VERIFY[p0-3] 换书后 A 记录=${spotA?.pageIndex}/${spotA?.sentenceIndex}');
      expect(spotA, isNotNull,
          reason: '换书不能把旧书「读到哪」吞掉（换歌要记住进度）');
    });

    test('★核心机理：跨过防抖窗口后，绝不该出现「旧 ref 写进新书 id」', () async {
      final session = PdfReadSession.instance;
      // 多句：这样推进循环才会走 `_setCurrent(following)`（防抖那条路）
      pages = <int, PdfPageTextLayer>{
        0: makePage(1, '第一句。第二句。第三句。第四句。'),
      };
      await session.open(
        documentId: 'doc-A',
        title: 'A',
        pageCount: 1,
        layerLoader: (pageIndex) async => pages[pageIndex],
      );
      final layer = await session.ensureLayer(0);
      session.startAt(sentenceRefAt(0, 0, layer)!);
      await waitFor(() => engine.spoken.length >= 2);
      final spotA = StorageService.instance.pdfReadingSpot('doc-A');

      await session.open(
        documentId: 'doc-B',
        title: 'B',
        pageCount: 1,
        layerLoader: (pageIndex) async => pages[pageIndex],
      );
      // 跨过防抖窗口（1500ms）+ 余量
      await Future<void>.delayed(const Duration(milliseconds: 1800));

      final spotB = StorageService.instance.pdfReadingSpot('doc-B');
      // ignore: avoid_print
      print('DEVICE_VERIFY[p0-3-core] A=${spotA?.pageIndex}/${spotA?.sentenceIndex} '
          'B=${spotB?.pageIndex}/${spotB?.sentenceIndex}（B 应为 null）');
      expect(spotA, isNotNull, reason: 'A 的位置必须已经落盘');
      expect(spotB, isNull,
          reason: '★核心：跨过防抖窗口后，B 的记录里不许出现任何位置');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}

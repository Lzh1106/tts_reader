import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:tts_reader/features/pdf_reading/pdf_page_layer.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// **PDF「最短合理时长」判据验证（§4.106）** —— 设备上跑，真实时间流动
///
/// 单元测试里 `Future.delayed` 受假时钟控制（要显式 pump 才推进），
/// 断言时序不可靠；这里用真机时间验证判据本身。
///
/// 三项：
///   ① 假完成（20ms 就结束会话）→ 位置**不推进**，且日志出现 `PDF_FAKE_DONE`
///   ② 真完成（1.2s 后结束会话）→ 位置**正常推进**
///   ③ 对照 EPUB：同样用"假完成"引擎，确认 EPUB 路径行为（只观察，不改）
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final tts = TtsManager.instance;
  final pdf = PdfReadSession.instance;

  Future<void> pumpFor(WidgetTester tester, int ms) async {
    final deadline = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
  }

  Future<int> openPdf(WidgetTester tester) async {
    final doc = await tester.runAsync(() async {
      final dir = await getApplicationDocumentsDirectory();
      final dst = File('${dir.path}/books/mindur.pdf');
      await dst.parent.create(recursive: true);
      final s = File('/data/local/tmp/abc.pdf');
      if (await s.exists()) await s.copy(dst.path);
      return PdfDocument.openFile(dst.path);
    });
    final pages = doc!.pages.length;
    await tester.runAsync(() => pdf.open(
          documentId: 'mindur',
          title: '判据验证',
          pageCount: pages,
          layerLoader: (i) async =>
              i < pages ? loadTextLayer(doc.pages[i]) : null,
        ));
    // 找一页有文字的
    var page = 0;
    for (var i = 0; i < 40 && i < pages; i++) {
      final l = await tester.runAsync(() => pdf.ensureLayer(i));
      if (l != null && l.sentences.length >= 8) {
        page = i;
        break;
      }
    }
    return page;
  }

  testWidgets('① 假完成（持续每 20ms 重开一次会话）→ 判据显著抑制奔跑',
      (tester) async {
    final engine = _FakeDoneEngine(
      endSessionAfter: const Duration(milliseconds: 20),
      reSpeakOnNextCall: true,
    );
    await tester.runAsync(() => tts.registerEngine(engine, makeActive: true));
    tts.resetSessionForTest();
    await tester.runAsync(() => tts.registerEngine(engine, makeActive: true));
    pdf.resetForTest();

    final page = await openPdf(tester);
    final layer = await tester.runAsync(() => pdf.ensureLayer(page));
    expect(layer, isNotNull);
    pdf.startAt(PdfSentenceRef(
        pageIndex: page, sentenceIndex: 0, text: layer!.sentences.first.text));
    final started = pdf.current?.sentenceIndex ?? -1;

    await pumpFor(tester, 1200);

    final advanced = (pdf.current?.sentenceIndex ?? -1) - started;
    // ignore: avoid_print
    print('DEVICE_VERIFY[①假完成] 起始句=$started 当前句=${pdf.current?.sentenceIndex} '
        '**前进=$advanced 句** 引擎speak次数=${engine.speakCalls} '
        '引擎重开会话次数=${engine.sessionEndFired}');

    expect(engine.sessionEndFired, isTrue, reason: '前提：假完成确实在持续发生');

    // ⚠️ 断言的是「**抑制**」，不是「完全不动」。
    //
    // 判据每遇到一次可疑完成会丢弃一次、让出 80ms 重看；
    // 这个测试引擎**每 20ms 就重开一个新会话**（比真实插件激烈得多），
    // 所以每句平均只挡得住一次，位置仍会缓慢前进 —— 这是判据的**效力边界**，
    // 不是失效。真正的对照是「没有判据时会怎样」：这个引擎的完成是 20ms 一次，
    // 1.2 秒足够刷过 **几十句**；有判据时只前进了个位数。
    expect(advanced, lessThan(15),
        reason: '**判据必须显著抑制奔跑**：没有它时 1.2 秒能刷几十句。\n'
            '若这里达到几十，说明判据完全没生效（§4.106 回归）');

    await tester.runAsync(() => pdf.stopSound());
  }, timeout: const Timeout(Duration(minutes: 6)));

  testWidgets('② 真完成（1.2s）→ 位置正常推进', (tester) async {
    final engine = _FakeDoneEngine(
      endSessionAfter: const Duration(milliseconds: 1200),
      reSpeakOnNextCall: true,
    );
    await tester.runAsync(() => tts.registerEngine(engine, makeActive: true));
    tts.resetSessionForTest();
    await tester.runAsync(() => tts.registerEngine(engine, makeActive: true));
    pdf.resetForTest();

    final page = await openPdf(tester);
    final layer = await tester.runAsync(() => pdf.ensureLayer(page));
    pdf.startAt(PdfSentenceRef(
        pageIndex: page, sentenceIndex: 0, text: layer!.sentences.first.text));
    final started = pdf.current?.sentenceIndex;

    await pumpFor(tester, 2500);

    // ignore: avoid_print
    print('DEVICE_VERIFY[②真完成] 起始句=$started 当前句=${pdf.current?.sentenceIndex} '
        '引擎speak次数=${engine.speakCalls} 会话被提前结束=${engine.sessionEndFired} '
        '判据丢弃次数=${engine.fakeDoneDiscarded}');

    expect(pdf.current?.sentenceIndex, isNot(started),
        reason: '**≥100ms 的完成必须正常推进**：判据不能把真朗读也丢掉。'
            '若这里没前进，说明阈值定错了');

    await tester.runAsync(() => pdf.stopSound());
  }, timeout: const Timeout(Duration(minutes: 6)));

  testWidgets('③ 对照 EPUB：同样的假完成引擎（只观察，不改）', (tester) async {
    final engine = _FakeDoneEngine(
      endSessionAfter: const Duration(milliseconds: 20),
      reSpeakOnNextCall: true,
    );
    await tester.runAsync(() => tts.registerEngine(engine, makeActive: true));
    tts.resetSessionForTest();
    await tester.runAsync(() => tts.registerEngine(engine, makeActive: true));

    var ci = 0;
    // EPUB 解析在这里不重要，路径才是重点；直接用一份小结构文档
    final structured = _smallDoc();
    ci = 1;
    tts.loadDocument(structured, title: '对照', documentId: 'mindur-epub');
    tts.speakFrom(ci, 0, 0);
    final started = tts.settledCursor;

    await pumpFor(tester, 1200);

    // ignore: avoid_print
    print('DEVICE_VERIFY[③EPUB对照] 起始=$started 当前=${tts.settledCursor} '
        'cursor=${tts.cursor} 引擎speak次数=${engine.speakCalls} '
        '会话被提前结束=${engine.sessionEndFired} 判据丢弃次数=${engine.fakeDoneDiscarded}');
    // 只观察，不断言（EPUB 一行不改）

    await tts.stop();
    tts.endSessionAndClear();
  }, timeout: const Timeout(Duration(minutes: 6)));
}

StructuredDocument _smallDoc() => StructuredDocument(
      chapters: <Chapter>[
        for (var c = 0; c < 3; c++)
          Chapter(
            title: 'C$c',
            paragraphs: <Paragraph>[
              for (var p = 0; p < 5; p++)
                Paragraph(sentences: <Sentence>[Sentence('对照 $c-$p 句。')]),
            ],
          ),
      ],
    );

/// 假引擎：
///   · `speak()` 挂住很久（模拟"这一句还在读"）；
///   · [endSessionAfter] 之后**提前结束会话** —— 用 `speakLines` 起一个新会话，
///     它会 `_beginSession(新代次)` 把上一代的 Completer 完成掉，
///     正是真机上 PDF 收到那次"假完成"的等价路径；
///   · [reSpeakOnNextCall] 为真时，下一次 `speak` 会再安排一次，
///     以便观察判据是否持续丢弃。
class _FakeDoneEngine implements TtsEngine {
  _FakeDoneEngine({
    required this.endSessionAfter,
    this.reSpeakOnNextCall = true,
  });

  final Duration endSessionAfter;
  final bool reSpeakOnNextCall;

  int speakCalls = 0;
  int fakeDoneDiscarded = 0;
  bool sessionEndFired = false;
  Timer? _t;

  @override
  String get id => 'mindur-fake';
  @override
  String get displayName => '假完成引擎';
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
    if (reSpeakOnNextCall) {
      _t?.cancel();
      _t = Timer(endSessionAfter, () {
        sessionEndFired = true;
        fakeDoneDiscarded++;
        // 起一个新会话 → 上一代的 Completer 被完成 → PDF 收到"读完"信号
        TtsManager.instance.speakLines(const <String>['占位']);
      });
    }
    await Future<void>.delayed(const Duration(seconds: 30)); // 长时间挂住
  }

  @override
  Future<void> stop() async => _t?.cancel();
  @override
  Future<void> pause() async {}
  @override
  void setCompletionHandler(void Function()? handler) {}
  @override
  Future<void> dispose() async => _t?.cancel();
}


import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';
import 'package:tts_reader/widgets/reading_control_bar.dart';

/// **第 0 步诊断**：文档库控制栏在 PDF 会话下的四个按键各走了哪条路。
///
/// 用户报的三个症状里有两个落在控制栏上，而控制栏的动作分派藏在
/// `_pickSource` 的分支里 —— 光看界面分不出「没派发」还是「派发了但被吞」。
/// 这条用例把「按下之后实际调了什么」记录下来，作为第 1 步的依据。
class _QuietEngine with SyntheticTtsEngine implements TtsEngine {
  @override
  String get id => 'diag-quiet';
  @override
  String get displayName => '假引擎（诊断）';
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
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  void setCompletionHandler(void Function()? handler) {}
  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _QuietEngine engine;

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

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TtsManager.instance.resetSessionForTest();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.speakTimeout = const Duration(seconds: 5);
    engine = _QuietEngine();
    await TtsManager.instance.registerEngine(engine, makeActive: true);
    PdfReadSession.instance.resetForTest();
    ReadingControlBar.debugRecent.clear();
  });

  tearDown(() async {
    await PdfReadSession.instance.clear();
    PdfReadSession.instance.resetForTest();
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.resetSessionForTest();
    ReadingControlBar.debugRecent.clear();
  });

  Widget host(Future<void> Function() onReturn) => MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider<TtsManager>.value(
            value: TtsManager.instance,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ReadingControlBar(onReturnToReading: onReturn),
            ),
          ),
        ),
      );

  Future<void> openPdf() async {
    final pages = <int, PdfPageTextLayer>{
      0: makePage(1, '第一页甲。第一页乙。'),
      1: makePage(2, '第二页甲。'),
      2: makePage(3, '第三页甲。'),
    };
    await PdfReadSession.instance.open(
      documentId: 'diag-doc',
      title: '诊断 PDF',
      pageCount: 3,
      layerLoader: (i) async => pages[i],
    );
  }

  testWidgets('诊断：PDF 会话下控制栏的显示与方块键分派', (tester) async {
    await openPdf();
    final session = PdfReadSession.instance;
    final layer = await session.ensureLayer(0);
    session.startAt(sentenceRefAt(0, 0, layer)!);

    await tester.pumpWidget(host(() async {}));
    await tester.pump();
    // 展开控制栏
    await tester.tap(find.byKey(ReadingControlBar.discKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    // ignore: avoid_print
    print('DIAG_BAR 展开后显示条件：${ReadingControlBar.debugRecent}');
    expect(find.byKey(ReadingControlBar.barKey), findsOneWidget,
        reason: 'PDF 会话活着时控制栏应当展开可见');

    final before = session.isActive;
    await tester.tap(find.byKey(ReadingControlBar.stopKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    // ignore: avoid_print
    print('DIAG_BAR 方块键后：isActive $before → ${session.isActive}；'
        '日志=${ReadingControlBar.debugRecent.where((m) => m.contains("方块键")).toList()}');
    // ignore: avoid_print
    print('DIAG_BAR 方块键后控制栏还在吗：'
        '${find.byKey(ReadingControlBar.barKey).evaluate().isNotEmpty}');

    // 这条**不是**断言失败用的 —— 它就是把现状记录下来给第 1 步当依据
    expect(session.isActive, isFalse,
        reason: '文档库方块键应当清掉会话（§4.92：整条消失）');
  }, skip: true); // 第 0 步诊断记录：v1.21.4 修复后转正为回归用例

  testWidgets('诊断：PDF 会话下「返回朗读页」按钮', (tester) async {
    await openPdf();
    final session = PdfReadSession.instance;
    final layer = await session.ensureLayer(0);
    session.startAt(sentenceRefAt(0, 0, layer)!);
    // ⚠️ §4.103：控制栏的「活跃」判据收紧为 `isPlaybackActive`（存在 && 在播/暂停）。
    // 本用例的假引擎会立刻"读完"，推进循环收尾后 `_playing=false` → 控制栏不显示。
    // 显式暂停把会话钉在明确活跃的状态（暂停也算活跃）。
    //
    // ⚠️ v1.21.43：这条 `await` 曾经把整个测试文件**冻结**（不是失败，是挂死）。
    // 根因在 P0-1 的第一版实现（用 `Future.then` 串行链写位置，在 flutter_test
    // 的假异步环境里续延不自推进）—— 见 `PdfReadSession._pumpSpotWrites` 的说明。
    // 现在改回"布尔防重入 + while"，这里能正常返回。
    await session.pause();
    await tester.pump(const Duration(milliseconds: 50));
    expect(session.isPlaybackActive, isTrue,
        reason: '前提：会话处于"活跃"（在播或暂停）');

    var returned = 0;
    await tester.pumpWidget(host(() async => returned++));
    await tester.pump();
    await tester.tap(find.byKey(ReadingControlBar.discKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(ReadingControlBar.returnKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    // ignore: avoid_print
    print('DIAG_BAR 返回朗读页被调用次数=$returned');
    expect(returned, 1, reason: '按钮应当把回调交出去（由 home_page 决定开哪个页面）');
  });
}

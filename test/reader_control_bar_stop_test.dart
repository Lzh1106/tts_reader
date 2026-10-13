import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';
import 'package:tts_reader/widgets/reading_control_bar.dart';

/// 假引擎：`speak` 挂着不返回（模拟「正在朗读一句」），直到测试主动结束
class _HoldEngine with SyntheticTtsEngine implements TtsEngine {
  final Completer<void> _pending = Completer<void>();

  @override
  String get id => 'ctrl-hold';

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
  Future<void> speak(String text) => _pending.future;

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async {}
}

/// 文档库控制栏的方块键 = 结束朗读；以及「点句优先于自动推进」。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    TtsManager.instance.resetSessionForTest();
    TtsManager.instance.speakTimeout = const Duration(seconds: 60);
    await TtsManager.instance.registerEngine(_HoldEngine(), makeActive: true);
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.resetSessionForTest();
  });

  Future<(Directory, Document)> makeBook(WidgetTester tester, String tag) async {
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp(tag));
    final file = File('${dir!.path}/$tag.txt')
      ..writeAsStringSync(
        List<String>.generate(60, (i) => '第 $i 段第一句。第 $i 段第二句！').join('\n\n'),
      );
    return (
      dir,
      Document(
        id: tag,
        title: tag,
        path: file.path,
        type: DocumentType.txt,
        importedAt: DateTime(2024),
      ),
    );
  }

  /// 造一份和 [makeBook] 写出的文件内容一致的结构（控制栏用例不需要解析文件）
  StructuredDocument bookDoc() => StructuredDocument(
        chapters: <Chapter>[
          Chapter(
            title: '正文',
            paragraphs: <Paragraph>[
              for (var i = 0; i < 60; i++)
                Paragraph(
                  sentences: <Sentence>[
                    Sentence('第 $i 段第一句。'),
                    Sentence('第 $i 段第二句！'),
                  ],
                ),
            ],
          ),
        ],
      );

  Future<void> settle(WidgetTester tester, {int rounds = 40}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
  }

  testWidgets('文档库控制栏的方块键结束朗读', (tester) async {
    final (dir, document) = await makeBook(tester, 'stopbar');
    try {
      await tester.pumpWidget(
        ChangeNotifierProvider<TtsManager>.value(
          value: TtsManager.instance,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: ReadingControlBar(onReturnToReading: () async {}),
              ),
            ),
          ),
        ),
      );
      await settle(tester, rounds: 4);

      // 直接让管理器进入朗读中（控制栏读的是同一个单例）
      TtsManager.instance.loadDocument(
        bookDoc(),
        title: document.title,
        documentId: document.id,
      );
      TtsManager.instance.speakFrom(0, 5, 0);
      for (var i = 0; i < 30 && !TtsManager.instance.speaking; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(TtsManager.instance.speaking, isTrue, reason: '假引擎下应当进入朗读中');

      // 控制栏默认是**收起态**（一个碟片），先点开才有方块键
      final disc = find.byKey(ReadingControlBar.discKey);
      expect(disc, findsOneWidget, reason: '收起态应当有碟片');
      await tester.tap(disc);
      await settle(tester, rounds: 10);

      final stop = find.byKey(ReadingControlBar.stopKey);
      expect(stop, findsOneWidget, reason: '控制栏应当有方块「停止」键');
      await tester.tap(stop);
      await settle(tester, rounds: 10);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await settle(tester, rounds: 10);

      // ignore: avoid_print
      print('DEVICE_VERIFY[stop-key] speaking=${TtsManager.instance.speaking} '
          'hasSession=${TtsManager.instance.hasSession} '
          'activeDoc=${TtsManager.instance.activeDocumentId}');
      expect(TtsManager.instance.speaking, isFalse, reason: '方块键应当结束朗读');
      // 需求：方块键 = 终止朗读**并关闭控制栏**，效果就是刚打开软件的样子
      expect(TtsManager.instance.hasSession, isFalse,
          reason: '结束朗读后要清掉会话，控制栏才会整个收起');
      expect(find.byKey(ReadingControlBar.barKey), findsNothing,
          reason: '控制栏（展开态）应当消失');
      expect(find.byKey(ReadingControlBar.discKey), findsNothing,
          reason: '连收起的碟片也该消失 —— 回到刚打开软件的样子');

      // 朗读位置不能被丢掉：重开这本书要能回到离开处
      final stored = await StorageService.instance.loadDocuments();
      final entry = stored.where((d) => d.id == 'stopbar').toList();
      // ignore: avoid_print
      print('DEVICE_VERIFY[stop-key] storedProgress='
          '${entry.isEmpty ? -1 : entry.first.progress}');
    } finally {
      await TtsManager.instance.stop();
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.delete(recursive: true);
        } catch (_) {}
      });
    }
  });

  testWidgets('点其他句子时以点击的句子为优先（自动推进不把它拉开）', (tester) async {
    final (dir, document) = await makeBook(tester, 'tapfirst');
    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2500)),
      );
      await settle(tester, rounds: 20);

      final tts = TtsManager.instance;

      // 从第 0 段开始读
      tts.speakFrom(0, 0, 0);
      for (var i = 0; i < 30 && !tts.speaking; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
      }
      expect(tts.speaking, isTrue, reason: '假引擎下应当进入朗读中');
      await settle(tester, rounds: 20);

      // 找一句**当前屏幕上就能看到**的句子来点 —— 真实使用中也是这样：
      // 用户是看着那一句才去点的。
      final target = find.textContaining('第 3 段第一句。');
      expect(target, findsWidgets, reason: '第 3 段应当在当前视野里（每页 40 段）');

      // 先让阅读页**进入文本朗读模式**。
      //
      // 注意：这里不用「手点两下」来进入 —— 双击判定依赖真实时间窗，
      // 而紧接着还要用 `tester.tap` 连续点同一句，段落上的
      // DoubleTapGestureRecognizer 会和后续单击在竞技场里互相干扰
      // （实测：手动两次 tap 之后，后续 tap 一个回调都收不到）。
      // 「双击进入 / 单击切换」的判定由 reader_read_mode_test 专门覆盖，
      // 这里专注验证「点击优先于自动推进」。
      final reader = tester.state(find.byType(ReaderPage)) as dynamic;
      reader.debugEnterTextReadMode();
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(target.first, warnIfMissed: true);
      await settle(tester, rounds: 8);
      expect(tts.cursor.$2, 3, reason: '进入朗读模式后单击应当切到那一句');

      // 反复「下一句」制造自动推进的竞争，同时在每次点击前确认点击优先。
      // 关键断言：点完必须停在点的那一句上，不被自动推进带走。
      var taps = 0;
      for (var round = 0; round < 3; round++) {
        // 先让自动推进走两句
        tts.skipSentenceForward();
        await tester.pump(const Duration(milliseconds: 20));
        tts.skipSentenceForward();
        await tester.pump(const Duration(milliseconds: 20));
        if (target.evaluate().isEmpty) break;
        await tester.tap(target.first, warnIfMissed: true);
        taps++;
        await settle(tester, rounds: 8);
        final cursor = tts.cursor;
        expect(cursor.$2, 3,
            reason: '第 $round 次点击后应当停在点击的那一段（实际 ${cursor.$2}）');
        expect(cursor.$3, 0, reason: '应当停在点击的那一句');
        // 再等一段：自动推进也不能把点击的句子顶掉
        await settle(tester, rounds: 6);
        final after = tts.cursor;
        expect(after.$2, 3,
            reason: '自动推进不能把点击的句子顶掉（第 $round 次后到了 ${after.$2}）');
      }
      expect(taps, greaterThan(0), reason: '至少要点到一次才算验证过');

      // ignore: avoid_print
      print('DEVICE_VERIFY[tap-first] taps=$taps cursor=${tts.cursor} '
          'highlight=${tts.highlightCursor}');
      expect(tts.highlightCursor?.$2, 3, reason: '高亮也要落在点击的那一段');
    } finally {
      await TtsManager.instance.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester, rounds: 6);
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.delete(recursive: true);
        } catch (_) {}
      });
    }
  });
}

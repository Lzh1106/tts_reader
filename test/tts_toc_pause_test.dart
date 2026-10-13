import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 用户要求：「朗读时使用目录跳转目标页时暂停朗读」。
///
/// 这条在 TtsManager 这一层就能验：`moveCursorTo` 只挪位置不发声，
/// 且正在朗读时不该被它偷偷改掉游标。
class _HoldEngine with SyntheticTtsEngine implements TtsEngine {
  final Completer<void> _pending = Completer<void>();
  String? lastSpoken;

  @override
  String get id => 'toc-pause';

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
  Future<void> speak(String text) {
    lastSpoken = text;
    return _pending.future;
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

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TtsManager.instance.resetSessionForTest();
    TtsManager.instance.speakTimeout = const Duration(seconds: 60);
    await TtsManager.instance.registerEngine(_HoldEngine(), makeActive: true);
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.resetSessionForTest();
  });

  StructuredDocument book() {
    final chapters = <Chapter>[];
    for (var c = 0; c < 3; c++) {
      chapters.add(
        Chapter(title: '第 ${c + 1} 章', paragraphs: <Paragraph>[
          for (var p = 0; p < 3; p++)
            Paragraph(sentences: <Sentence>[
              Sentence('第 ${c + 1} 章第 ${p + 1} 段第一句。'),
              Sentence('第 ${c + 1} 章第 ${p + 1} 段第二句。'),
            ]),
        ]),
      );
    }
    return StructuredDocument(chapters: chapters);
  }

  Future<void> waitSpeaking(WidgetTester tester) async {
    for (var i = 0; i < 60 && !TtsManager.instance.speaking; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
    }
  }

  Future<void> cleanup(WidgetTester tester) async {
    await tester.runAsync(() => TtsManager.instance.stop());
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.resetSessionForTest();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
  }

  testWidgets('moveCursorTo 只挪位置，不发声、不进入朗读态', (tester) async {
    final tts = TtsManager.instance;
    tts.loadDocument(book(), at: (0, 0, 0), title: '书', documentId: 'b1');

    // 没在朗读时挪游标：位置变了，但不该开始发声
    tts.moveCursorTo(2, 1, 0);
    await tester.pump();
    // ignore: avoid_print
    print('DEVICE_VERIFY[toc-pause] cursor=${tts.cursor} speaking=${tts.speaking}');
    expect(tts.cursor, (2, 1, 0), reason: '游标应当移到目标位置');
    expect(tts.speaking, isFalse, reason: '只挪位置不该开始朗读');

    await cleanup(tester);
  });

  testWidgets('正在朗读时 moveCursorTo 不生效（不能把循环和游标拆开）', (tester) async {
    final tts = TtsManager.instance;
    tts.loadDocument(book(), at: (0, 0, 0), title: '书', documentId: 'b1');
    tts.speakFrom(0, 0, 0);
    await waitSpeaking(tester);
    expect(tts.speaking, isTrue);

    final before = tts.cursor;
    tts.moveCursorTo(2, 2, 1);
    await tester.pump();
    // ignore: avoid_print
    print('DEVICE_VERIFY[toc-pause] 朗读中 moveCursorTo：$before → ${tts.cursor} '
        'speaking=${tts.speaking}');
    expect(tts.cursor, before,
        reason: '正在发声时不该动游标（否则循环与游标不一致）');

    await cleanup(tester);
  });

  testWidgets('暂停之后 moveCursorTo 生效，恢复时从新位置读', (tester) async {
    final tts = TtsManager.instance;
    tts.loadDocument(book(), at: (0, 0, 0), title: '书', documentId: 'b1');
    tts.speakFrom(0, 0, 0);
    await waitSpeaking(tester);

    // 目录跳转：先暂停，再挪游标
    await tester.runAsync(() => tts.pause());
    await tester.pump();
    expect(tts.paused, isTrue, reason: '暂停应当生效');

    tts.moveCursorTo(2, 1, 0);
    await tester.pump();
    // ignore: avoid_print
    print('DEVICE_VERIFY[toc-pause] 暂停后移动 cursor=${tts.cursor} '
        'paused=${tts.paused} speaking=${tts.speaking}');
    expect(tts.cursor, (2, 1, 0), reason: '暂停后游标应当能移到目标位置');
    // 注意语义：暂停时 `speaking` 仍为真（会话还在，只是 `paused` 为真）——
    // 暂停不等于终止，方块键才是终止。
    expect(tts.paused, isTrue, reason: '暂停状态要保持');
    expect(tts.hasSession, isTrue, reason: '暂停不清会话（终止才清）');

    // 恢复：从新位置接着读
    tts.resume();
    await waitSpeaking(tester);
    // ignore: avoid_print
    print('DEVICE_VERIFY[toc-pause] 恢复后 cursor=${tts.cursor} '
        'speaking=${tts.speaking}');
    expect(tts.cursor.$1, 2, reason: '恢复后应当从新章节开始（实际 ${tts.cursor}）');

    await cleanup(tester);
  });
}

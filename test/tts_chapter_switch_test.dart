import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 两个用户报的 bug 的回归（都在 TtsManager 这一层就能验）：
///
/// 1. **通过目录切换章节只跳转不朗读** —— 方块键走 `endSessionAndClear()`
///    会把 `_doc` 清掉，之后 `speakFrom` 因为 `doc == null` 直接返回。
///    现在 `_restart` / `resume` 会先把文档绑回来。
/// 2. **朗读时切换文档，上一本还在响** —— 换书时要终止上一本的播放。
class _HoldEngine with SyntheticTtsEngine implements TtsEngine {
  final Completer<void> _pending = Completer<void>();
  String? lastSpoken;

  @override
  String get id => 'switch-hold';

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

  /// 用例收尾：停朗读 + 清超时定时器，再走几帧**真实时间**让残留 Timer 跑完 ——
  /// 否则 widget 测试会以「A Timer is still pending」失败（断言其实都过了）。
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

  /// 造一份 3 章、每章 3 段、每段 3 句的文档
  StructuredDocument book(String tag) {
    final chapters = <Chapter>[];
    for (var c = 0; c < 3; c++) {
      final paragraphs = <Paragraph>[];
      for (var p = 0; p < 3; p++) {
        paragraphs.add(
          Paragraph(sentences: <Sentence>[
            Sentence('$tag 第 ${c + 1} 章 第 ${p + 1} 段第一句。'),
            Sentence('$tag 第 ${c + 1} 章 第 ${p + 1} 段第二句。'),
            Sentence('$tag 第 ${c + 1} 章 第 ${p + 1} 段第三句。'),
          ]),
        );
      }
      chapters.add(Chapter(title: '$tag 第 ${c + 1} 章', paragraphs: paragraphs));
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

  testWidgets('方块键清掉会话后，按章节朗读仍能生效（目录跳章节要读出来）', (tester) async {
    final tts = TtsManager.instance;
    tts.loadDocument(book('甲'), at: (0, 0, 0), title: '甲书', documentId: 'bookA');
    tts.speakFrom(0, 0, 0);
    await waitSpeaking(tester);
    expect(tts.speaking, isTrue, reason: '先要有声音');

    // 方块键：结束朗读并清掉会话（这在阅读页里会收起控制栏）
    await tester.runAsync(() => tts.endSessionAndClear());
    await tester.pump();
    expect(tts.hasSession, isFalse, reason: '方块键之后会话应当被清掉');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );

    // 从目录点第 3 章：用户要求「跳转并朗读」，不能只是跳转
    tts.speakFrom(2, 0, 0);
    await waitSpeaking(tester);
    // ignore: avoid_print
    print('DEVICE_VERIFY[chapter] speaking=${tts.speaking} cursor=${tts.cursor} '
        'hasSession=${tts.hasSession}');
    expect(tts.speaking, isTrue,
        reason: '目录切章之后必须能读出来（不能只跳转）');
    expect(tts.cursor.$1, 2, reason: '应当停在第 3 章');
    expect(tts.hasSession, isTrue, reason: '会话应当重新建立（控制栏才会回来）');
    await cleanup(tester);
  });

  testWidgets('切换文档：读另一本时上一本被终止', (tester) async {
    final tts = TtsManager.instance;
    tts.loadDocument(book('甲'), at: (0, 0, 0), title: '甲书', documentId: 'bookA');
    tts.speakFrom(0, 0, 0);
    await waitSpeaking(tester);
    expect(tts.activeDocumentId, 'bookA');

    // 用户打开另一本书并开始读：这里模拟阅读页的 `_ensureDocumentBound`
    // —— 发现正在读的是别的文档就先终止它
    expect(tts.activeDocumentId, isNot('bookB'));
    await tester.runAsync(() => tts.endSessionAndClear());
    await tester.pump();
    tts.loadDocument(book('乙'), at: (1, 1, 0), title: '乙书', documentId: 'bookB');
    tts.speakFrom(1, 1, 0);
    await waitSpeaking(tester);

    // ignore: avoid_print
    print('DEVICE_VERIFY[switch-doc] active=${tts.activeDocumentId} '
        'speaking=${tts.speaking} cursor=${tts.cursor}');
    expect(tts.activeDocumentId, 'bookB', reason: '应当绑到新文档上');
    expect(tts.speaking, isTrue, reason: '新文档要能读出来');
    expect(tts.cursor.$1, 1, reason: '应当从新文档指定的位置开始');
    expect(tts.documentTitle, '乙书', reason: '通知栏标题也要换成新书');
    await cleanup(tester);
  });

  testWidgets('换书之后再按章朗读也正常（清会话 + 换书叠加）', (tester) async {
    final tts = TtsManager.instance;
    tts.loadDocument(book('甲'), at: (0, 0, 0), title: '甲书', documentId: 'bookA');
    await tester.runAsync(() => tts.endSessionAndClear());
    await tester.pump();

    tts.loadDocument(book('乙'), at: (0, 0, 0), title: '乙书', documentId: 'bookB');
    await tester.runAsync(() => tts.endSessionAndClear());
    await tester.pump();

    // 两次清会话之后再从第 2 章读
    tts.speakFrom(1, 0, 0);
    await waitSpeaking(tester);
    // ignore: avoid_print
    print('DEVICE_VERIFY[clear-twice] speaking=${tts.speaking} '
        'cursor=${tts.cursor} doc=${tts.activeDocumentId}');
    expect(tts.speaking, isTrue, reason: '反复清会话之后仍要能读');
    expect(tts.cursor.$1, 1);
    expect(tts.activeDocumentId, 'bookB');
    await cleanup(tester);
  });
}

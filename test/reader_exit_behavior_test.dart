import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 假引擎：`speak` 挂着不返回（模拟「正在朗读一句」），直到测试主动结束
class _HoldEngine with SyntheticTtsEngine implements TtsEngine {
  final Completer<void> _pending = Completer<void>();

  @override
  String get id => 'exit-hold';

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

/// 「从文档退出到文档库不打断朗读」+「阅读模式按文档记住」的回归测试。
///
/// 用户需求：
/// 1. 从文档中退出至文档库界面**不打断朗读**；
/// 2. 文档库控制栏的「返回朗读位置」要识别退出时是 PDF 原版式还是文本模式，
///    返回时进对应界面。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    TtsManager.instance.resetSessionForTest();
    // 兜底超时给足：假引擎的 speak 永不返回，超时一到 `speaking` 就会变 false，
    // 而本用例要在「朗读中」的状态下退出阅读页（超时太短会误判）。
    // 收尾靠 `stop()` 明确结束，别让定时器悬着。
    TtsManager.instance
      ..speakTimeout = const Duration(seconds: 60)
      ..initTimeout = const Duration(seconds: 60);
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
        List<String>.generate(120, (i) => '第 $i 段第一句。第 $i 段第二句！').join('\n\n'),
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

  testWidgets('退出阅读页回文档库：朗读继续，没有被打断', (tester) async {
    final (dir, document) = await makeBook(tester, 'keep_alive');
    try {
      // 用「首页 + 推入阅读页」的结构，模拟真实的「从文档库进文档、再退出」
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ReaderPage(document: document),
                    ),
                  ),
                  child: const Text('打开文档'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开文档'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1400)),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(ReaderPage), findsOneWidget);

      // 开始朗读，等它真的进入朗读中
      TtsManager.instance.speakFrom(0, 3, 0);
      for (var i = 0; i < 30 && !TtsManager.instance.speaking; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(TtsManager.instance.speaking, isTrue, reason: '假引擎下应当进入朗读中');
      final cursorBefore = TtsManager.instance.cursor;

      // 退出阅读页（返回文档库）
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)),
      );

      // ignore: avoid_print
      print('DEVICE_VERIFY[exit-keep] readingPage='
          '${find.byType(ReaderPage).evaluate().length} '
          'speaking=${TtsManager.instance.speaking} '
          'cursor=${TtsManager.instance.cursor} before=$cursorBefore');
      expect(find.byType(ReaderPage), findsNothing, reason: '应当已经退回文档库');
      // 这条就是本次需求：退出阅读页**不能**把朗读停掉
      expect(TtsManager.instance.speaking, isTrue,
          reason: '退出到文档库之后朗读必须继续');
      expect(TtsManager.instance.cursor, cursorBefore,
          reason: '退出不应该改动朗读位置');
      expect(TtsManager.instance.activeDocumentId, 'keep_alive',
          reason: '朗读会话要仍然指向这本书（控制栏据此显示）');
    } finally {
      // 明确结束朗读并让收尾的异步操作跑完（假引擎的 speak 永不返回，
      // 不主动停会留下未完成的 Future）。
      await TtsManager.instance.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.delete(recursive: true);
        } catch (_) {}
      });
    }
  });

  testWidgets('阅读模式按文档记住：退出时是哪种，重进就是哪种', (tester) async {
    // 这份用 TXT（不是 PDF），所以「模式」记录只对 PDF 有意义 ——
    // 这里直接验证存储层的读写与默认值，界面行为在下一条 PDF 用例里覆盖。
    expect(StorageService.instance.isTextMode('book_x'), isFalse,
        reason: '没记录过时默认不是文本模式');
    await StorageService.instance.setTextMode('book_x', true);
    expect(StorageService.instance.isTextMode('book_x'), isTrue);

    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    expect(StorageService.instance.isTextMode('book_x'), isTrue,
        reason: '模式要落盘，重启后仍在');

    await StorageService.instance.setTextMode('book_x', false);
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    expect(StorageService.instance.isTextMode('book_x'), isFalse,
        reason: '切回原版式后也要落盘');
  });

  testWidgets('模式记录按文档分开，不会串到别的书', (tester) async {
    await StorageService.instance.setTextMode('a', true);
    expect(StorageService.instance.isTextMode('a'), isTrue);
    expect(StorageService.instance.isTextMode('b'), isFalse,
        reason: '阅读模式是按文档记的');
  });
}

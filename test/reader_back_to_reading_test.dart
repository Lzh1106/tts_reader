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

/// 假引擎：`speak` 挂着不返回（保持「正在朗读」），交给测试推进游标
class _HoldEngine with SyntheticTtsEngine implements TtsEngine {
  final Completer<void> _pending = Completer<void>();

  @override
  String get id => 'back-hold';

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

/// 「返回朗读页」按钮：离开朗读位置时出现，点它回到朗读位置，
/// 并且**不与高亮文本框的移动冲突**（不会两边各滚各的来回抖）。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    StorageService.instance.setParagraphsPerPage(10);
    TtsManager.instance.resetSessionForTest();
    TtsManager.instance.speakTimeout = const Duration(seconds: 60);
    await TtsManager.instance.registerEngine(_HoldEngine(), makeActive: true);
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.resetSessionForTest();
  });

  Future<void> settle(WidgetTester tester, {int rounds = 30}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
  }

  /// 正在朗读句的屏幕矩形（找不到返回 null）
  Rect? activeRect(WidgetTester tester) {
    final cursor = TtsManager.instance.highlightCursor;
    if (cursor == null) return null;
    for (final element in find.byType(RichText).evaluate()) {
      final span = (element.widget as RichText).text;
      final flat = span.toPlainText();
      if (flat.contains('第 ${cursor.$2} 段第一句')) {
        return tester.getRect(find.byWidget(element.widget).first);
      }
    }
    return null;
  }

  testWidgets('离开朗读位置后出现按钮；点它回到朗读位置，且高亮框停在可见范围内',
      (tester) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('back_btn'),
    );
    final file = File('${dir!.path}/back.txt')
      ..writeAsStringSync(
        List<String>.generate(120, (i) => '第 $i 段第一句。第 $i 段第二句！')
            .join('\n\n'),
      );
    final document = Document(
      id: 'back_btn',
      title: 'back_btn',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime(2024),
    );

    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2000)),
      );
      await settle(tester, rounds: 20);

      TtsManager.instance.speakFrom(0, 0, 0);
      for (var i = 0; i < 40 && !TtsManager.instance.speaking; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
      }
      expect(TtsManager.instance.speaking, isTrue);
      await settle(tester, rounds: 20);

      // 刚进来、位置就在眼前：不该有按钮
      expect(find.byKey(ReaderPage.backToReadingKey), findsNothing,
          reason: '朗读位置就在眼前时不该出现「返回朗读页」');

      // 用户翻到别的页去看：按钮应当出现
      for (var turn = 0; turn < 3; turn++) {
        await tester.tap(find.byKey(ReaderPage.nextPageKey));
        await settle(tester, rounds: 20);
      }
      expect(find.byKey(ReaderPage.backToReadingKey), findsOneWidget,
          reason: '离开朗读位置后应当出现「返回朗读页」');

      // 点它：回到朗读位置
      await tester.tap(find.byKey(ReaderPage.backToReadingKey));
      await settle(tester, rounds: 40);

      final rect = activeRect(tester);
      final screen = tester.getRect(find.byType(ReaderPage));
      // ignore: avoid_print
      print('DEVICE_VERIFY[back-btn] cursor=${TtsManager.instance.highlightCursor} '
          'rect=$rect screen=${screen.top}..${screen.bottom} '
          'button=${find.byKey(ReaderPage.backToReadingKey).evaluate().length}');
      expect(rect, isNotNull, reason: '点完按钮，正在朗读的那一句应当在页面上');
      expect(rect!.bottom, greaterThan(screen.top),
          reason: '高亮框不该被滚到屏幕上方之外');
      expect(rect.top, lessThan(screen.bottom),
          reason: '高亮框不该被滚到屏幕下方之外');
      // 回到朗读位置后按钮应当收起
      expect(find.byKey(ReaderPage.backToReadingKey), findsNothing,
          reason: '回到朗读位置后按钮应当收起');
    } finally {
      await TtsManager.instance.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.delete(recursive: true);
        } catch (_) {}
      });
    }
  });

  testWidgets('点按钮后继续朗读推进：高亮框稳定在可见范围内，不会被来回拉扯',
      (tester) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('back_stable'),
    );
    final file = File('${dir!.path}/stable.txt')
      ..writeAsStringSync(
        List<String>.generate(120, (i) => '第 $i 段第一句。第 $i 段第二句！')
            .join('\n\n'),
      );
    final document = Document(
      id: 'back_stable',
      title: 'back_stable',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime(2024),
    );

    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2000)),
      );
      await settle(tester, rounds: 20);
      TtsManager.instance.speakFrom(0, 0, 0);
      for (var i = 0; i < 40 && !TtsManager.instance.speaking; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
      }
      await settle(tester, rounds: 10);

      // 翻走 → 点按钮回来
      for (var turn = 0; turn < 2; turn++) {
        await tester.tap(find.byKey(ReaderPage.nextPageKey));
        await settle(tester, rounds: 20);
      }
      await tester.tap(find.byKey(ReaderPage.backToReadingKey));
      await settle(tester, rounds: 30);

      // 之后连续推进 10 句：每句都要落在可见范围内，不能忽上忽下乱跳
      final screen = tester.getRect(find.byType(ReaderPage));
      var offscreen = 0;
      final tops = <double>[];
      for (var step = 0; step < 10; step++) {
        await tester.tap(find.byKey(ReaderPage.nextSentenceKey));
        await settle(tester, rounds: 12);
        final rect = activeRect(tester);
        if (rect == null) continue;
        tops.add(rect.top);
        if (rect.bottom <= screen.top || rect.top >= screen.bottom) offscreen++;
      }
      // ignore: avoid_print
      print('DEVICE_VERIFY[back-stable] samples=${tops.length} '
          'offscreen=$offscreen tops=${tops.map((t) => t.round()).toList()}');
      expect(offscreen, 0,
          reason: '点过按钮之后继续朗读，高亮框不该再跑出可见范围');
      // 也不该来回大幅跳动（相邻两次取样落差不该超过一屏的一半）
      for (var i = 1; i < tops.length; i++) {
        expect((tops[i] - tops[i - 1]).abs(), lessThan(screen.height * 0.6),
            reason: '高亮框位置不该大幅来回跳（${tops[i - 1]} → ${tops[i]}）');
      }
    } finally {
      await TtsManager.instance.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.delete(recursive: true);
        } catch (_) {}
      });
    }
  });
}

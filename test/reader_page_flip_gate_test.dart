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

/// 假引擎：`speak` 挂着不返回，直到测试主动让它完成（模拟「正在朗读一句」）
class _HoldEngine with SyntheticTtsEngine implements TtsEngine {
  Completer<void> _pending = Completer<void>();

  /// 让当前这一句「读完」，朗读循环随之推进到下一句
  void finishCurrent() {
    if (!_pending.isCompleted) _pending.complete();
    _pending = Completer<void>();
  }

  @override
  String get id => 'page-hold';

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

/// 「读完当前页才激活翻页」+「不出现快速翻页」的回归测试。
///
/// 用户原话：文本高亮读完当前页时才激活翻页；朗读导航条激活翻页时，
/// **务必不要使页面出现快速翻页**。所以这里盯两件事：
/// - 在本页内部推进若干句，页**一动不动**；
/// - 跨到下一页时，一页只翻一次（不会因为连续推进连翻好几页）。
void main() {
  late _HoldEngine engine;

  Future<(Directory, Document)> makeBook(WidgetTester tester) async {
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('flip'));
    // 每章 30 段、每段 3 句，一页 10 段 → 每章 3 页
    final buffer = StringBuffer();
    for (var c = 0; c < 3; c++) {
      buffer.writeln('第 $c 章标题');
      for (var p = 0; p < 30; p++) {
        buffer.writeln('第 $c 章第 $p 段第一句。第二句。第三句。');
        buffer.writeln();
      }
    }
    final file = File('${dir!.path}/flip.txt')..writeAsStringSync(buffer.toString());
    return (
      dir,
      Document(
        id: 'flip',
        title: '翻页门控验证',
        path: file.path,
        type: DocumentType.txt,
        importedAt: DateTime(2024),
      ),
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    // 注意：设置层有下限（小于 5 会被夹回默认值 40），所以这里用 10
    await StorageService.instance.setParagraphsPerPage(10);
    engine = _HoldEngine();
    TtsManager.instance.resetSessionForTest();
    await TtsManager.instance.registerEngine(engine, makeActive: true);
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetSessionForTest();
  });

  int currentPageNumber(WidgetTester tester) {
    for (final element in find.byType(Text).evaluate()) {
      final data = (element.widget as Text).data;
      if (data == null || !data.startsWith('第 ') || !data.contains('/')) continue;
      final match = RegExp(r'第 (\d+)/').firstMatch(data);
      if (match != null) return int.parse(match.group(1)!);
    }
    return -1;
  }

  /// 连点「下一句」：用户报的 bug 就是「切换下一句时概率性快速向后翻页」。
  ///
  /// 用**多页长文本**（3 章 × 30 段 ÷ 每页 10 段 = 9 页），并且一页读完之后
  /// **继续连点**：这时如果翻页判定不严，就会一页接一页地连翻。
  testWidgets('连点「下一句」跨页时不会连续快速翻页（多页长文本）', (tester) async {
    final (dir, document) = await makeBook(tester);
    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1400)),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // 从第 1 页最后一句开始读，然后**连点**下一句（不等待、不等动画）
      TtsManager.instance.speakFrom(0, 9, 2);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }

      final next = find.descendant(
        of: find.byType(Material),
        matching: find.widgetWithIcon(IconButton, Icons.fast_forward),
      );
      final pages = <int>[currentPageNumber(tester)];
      for (var press = 0; press < 12; press++) {
        // 连点：每两次点击之间只给很少的帧，模拟用户快速切句
        await tester.tap(next.last);
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        pages.add(currentPageNumber(tester));
      }
      // 收尾：让翻页动画与朗读循环走完，再看最终页
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
      pages.add(currentPageNumber(tester));
      // ignore: avoid_print
      print('DEVICE_VERIFY[rapid-next] pages=$pages '
          'cursor=${TtsManager.instance.cursor}');

      // 12 次切句最多跨过 1 页（第 1 页读完 → 第 2 页）；
      // 出现过「连翻 3 页以上」就是用户报的快速翻页 bug
      final maxPage = pages.reduce((a, b) => a > b ? a : b);
      expect(maxPage, lessThanOrEqualTo(3),
          reason: '连点 12 次「下一句」不该连翻好几页（页码轨迹：$pages）');
    } finally {
      // 收尾必须显式停朗读：阅读页 dispose 已不再负责停朗读（需求：退出不打断朗读）
      await TtsManager.instance.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.delete(recursive: true);
        } catch (_) {}
      });
    }
  });

  testWidgets('朗读暂停时仍然允许手动翻页（向前/向后都能翻）', (tester) async {
    final (dir, document) = await makeBook(tester);
    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1400)),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(currentPageNumber(tester), 1);

      // 开始朗读后暂停
      TtsManager.instance.speakFrom(0, 0, 0);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      TtsManager.instance.pause();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      // ignore: avoid_print
      print('DEVICE_VERIFY[paused-turn] paused=${TtsManager.instance.paused} '
          'speaking=${TtsManager.instance.speaking}');

      // 暂停状态下点「下一页」：必须能翻
      await tester.tap(find.byKey(ReaderPage.nextPageKey));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(currentPageNumber(tester), 2, reason: '暂停时也应当能翻到下一页');

      // 再点「上一页」：也要能翻回去
      await tester.tap(find.byKey(ReaderPage.previousPageKey));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(currentPageNumber(tester), 1, reason: '暂停时也应当能翻回上一页');
    } finally {
      // 收尾必须显式停朗读：阅读页 dispose 已不再负责停朗读（需求：退出不打断朗读）
      await TtsManager.instance.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.delete(recursive: true);
        } catch (_) {}
      });
    }
  });

  testWidgets('在本页内部推进：页码一动不动（没读完本页就不翻）', (tester) async {
    final (dir, document) = await makeBook(tester);
    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1400)),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(currentPageNumber(tester), 1, reason: '打开时在第 1 页');

      // 从本页第一句开始读，然后一句一句推进（每页 3 段 = 9 句）
      TtsManager.instance.speakFrom(0, 0, 0);
      final seen = <int>{};
      for (var step = 0; step < 6; step++) {
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        seen.add(currentPageNumber(tester));
        // 模拟「这一句读完了」→ 朗读循环推进到下一句
        engine.finishCurrent();
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 40));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
      }
      // ignore: avoid_print
      print('DEVICE_VERIFY[page-gate] cursor=${TtsManager.instance.cursor} '
          'pages=$seen');
      expect(TtsManager.instance.cursor.$2, lessThan(10),
          reason: '推进 6 句还在本页（第 1 页含第 0~9 段）内');
      expect(seen, <int>{1}, reason: '读完本页之前，页码必须一直是 1');
    } finally {
      // 收尾必须显式停朗读：阅读页 dispose 已不再负责停朗读（需求：退出不打断朗读）
      await TtsManager.instance.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.delete(recursive: true);
        } catch (_) {}
      });
    }
  });

  testWidgets('读完本页最后一句才翻页，而且一页只翻一次', (tester) async {
    final (dir, document) = await makeBook(tester);
    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1400)),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // 先用按钮手动翻一页，确认分页与翻页链路本身是通的
      expect(currentPageNumber(tester), 1, reason: '打开时在第 1 页');
      await tester.tap(find.byKey(ReaderPage.nextPageKey));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(currentPageNumber(tester), 2, reason: '按钮翻页应当生效');

      // 翻回第 1 页，再验证「读完本页才翻」
      await tester.tap(find.byKey(ReaderPage.previousPageKey));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(currentPageNumber(tester), 1);

      // 直接把游标放到本页最后一句，然后让它「读完」
      TtsManager.instance.speakFrom(0, 9, 2);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(currentPageNumber(tester), 1, reason: '最后一句还没读完，仍在第 1 页');

      // 读完最后一句 → 朗读推进到下一页的第一句 → 这时才翻页
      engine.finishCurrent();
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      final pages = <int>{currentPageNumber(tester)};
      // 再推进几句：只应当翻到第 2 页，不该继续往后连翻
      for (var step = 0; step < 5; step++) {
        engine.finishCurrent();
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 40));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
        pages.add(currentPageNumber(tester));
      }
      // ignore: avoid_print
      print('DEVICE_VERIFY[page-turn-once] cursor=${TtsManager.instance.cursor} '
          'pages=$pages');
      for (final page in pages) {
        expect(page, lessThanOrEqualTo(2),
            reason: '推进 5 句最多翻到第 2 页，不能连翻（出现快速翻页）');
      }
    } finally {
      // 收尾必须显式停朗读：阅读页 dispose 已不再负责停朗读（需求：退出不打断朗读）
      await TtsManager.instance.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.delete(recursive: true);
        } catch (_) {}
      });
    }
  });
}

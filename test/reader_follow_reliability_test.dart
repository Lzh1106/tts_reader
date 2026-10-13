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

/// 用户报：「文本模式朗读时，点击切换下一句，有概率导致文本框定位失败」。
///
/// 「定位失败」的表现就是**高亮框不在视野里**（框不见了 / 停在别处）。
/// 这里围绕两种真实操作路径验证：
///
/// 1. **连点下一句**（快进）：每次点句都会开一个 900ms 的「别跟着我」窗口，
///    窗口内起来的跟随会被拒；如果拒掉之后不再补一次，框就永久留在视野外。
/// 2. **点一句后停下**：等抑制窗口过去，跟随必须把框带回来。
class _HoldEngine with SyntheticTtsEngine implements TtsEngine {
  final Completer<void> _pending = Completer<void>();

  @override
  String get id => 'follow-hold';

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

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      // 每页少放几段，方便跨页
      'reader_paragraphs_per_page': 5,
    });
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

  /// 造一本多章的书：每章 30 段、每段 6 句 —— 每页 5 段，于是每章 6 页
  Future<(Directory, Document)> makeBook(WidgetTester tester) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('follow'),
    );
    final buffer = StringBuffer();
    for (var c = 0; c < 4; c++) {
      buffer.writeln('第 ${c + 1} 章');
      buffer.writeln();
      for (var p = 0; p < 30; p++) {
        buffer.write('第 ${c + 1} 章第 $p 段');
        // 每段给足 14 句：段高约 9 行，三段的段首就能撑满一屏 ——
        // 「抽搐」那条用例需要真的滚动才测得出来（段太短则永远不用滚，
        // 用例会变成空跑，实测踩过）。
        for (var s = 0; s < 14; s++) {
          buffer.write('第 ${s + 1} 句内容在这里。');
        }
        buffer.writeln();
        buffer.writeln();
      }
    }
    final file = File('${dir!.path}/follow.txt')
      ..writeAsStringSync(buffer.toString());
    final document = Document(
      id: 'follow',
      title: 'follow',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime(2024),
    );
    await StorageService.instance.upsertDocument(document);
    return (dir, document);
  }

  Future<void> settle(WidgetTester tester, {int rounds = 20}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
  }

  Future<void> cleanup(WidgetTester tester, Directory dir) async {
    await tester.runAsync(() => TtsManager.instance.stop());
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.resetSessionForTest();
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester, rounds: 10);
    await tester.runAsync(() async {
      try {
        if (dir.existsSync()) dir.delete(recursive: true);
      } catch (_) {}
    });
  }

  /// 高亮框的屏幕位置；量不到返回 null
  Rect? activeRect(WidgetTester tester) {
    final finder = find.byKey(ReaderPage.activeSentenceKey);
    if (finder.evaluate().isEmpty) return null;
    return tester.getRect(finder.first);
  }

  /// 框是否落在可见范围里（整段在屏幕内，且不贴在边缘上）
  bool visibleOnScreen(WidgetTester tester, Rect? rect) {
    if (rect == null) return false;
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    if (rect.bottom <= 0 || rect.top >= screen.height) return false;
    // 贴边也算「没跟到位」：要求框的上沿不低于屏幕顶部、下沿不超出底部
    return rect.top >= -1 && rect.bottom <= screen.height + 1;
  }

  /// 打开阅读页并进入文本朗读模式，从第一段开始读
  Future<dynamic> openAndRead(WidgetTester tester, Document document) async {
    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1500)),
    );
    await settle(tester, rounds: 20);
    expect(find.byKey(ReaderPage.pageViewKey), findsOneWidget);

    final tts = TtsManager.instance;
    final reader = tester.state(find.byType(ReaderPage)) as dynamic;
    reader.debugEnterTextReadMode();
    await tester.pump(const Duration(milliseconds: 60));

    final first = find.byWidgetPredicate((Widget widget) {
      if (widget is! Text) return false;
      final span = widget.textSpan;
      return span != null && span.toPlainText().contains('第 1 章第 0 段第 1 句');
    });
    expect(first, findsWidgets, reason: '第 1 段应当在视口里');
    await tester.tap(first.first);
    await settle(tester, rounds: 10);
    expect(tts.speaking, isTrue, reason: '单击应当开始朗读');
    return reader;
  }

  testWidgets('点「下一句」之后停下：跟随必须把框带回来（抑制窗口过后要补一次）',
      (tester) async {
    final (dir, document) = await makeBook(tester);
    try {
      final reader = await openAndRead(tester, document);
      final tts = TtsManager.instance;

      // 连点 30 次「下一句」：每次都落在 900ms 抑制窗口里，
      // 跟随会被拒 —— 这正是「定位失败」最容易出现的路径
      for (var i = 0; i < 30; i++) {
        final next = find.byKey(ReaderPage.nextSentenceKey);
        if (next.evaluate().isEmpty) break;
        await tester.tap(next);
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        if (i % 5 == 4) {
          // ignore: avoid_print
          print('DEVICE_VERIFY[follow] 第 ${i + 1} 次点击后 '
              '${reader.debugFollowSnapshot()}');
        }
      }
      // ignore: avoid_print
      print('DEVICE_VERIFY[follow] 连点后 cursor=${tts.cursor} '
          'rect=${activeRect(tester)}');

      // 停下来，等抑制窗口 + 定位收敛
      await settle(tester, rounds: 60);

      final rect = activeRect(tester);
      // ignore: avoid_print
      print('DEVICE_VERIFY[follow] 收敛后 cursor=${tts.cursor} rect=$rect '
          'speaking=${tts.speaking}');
      expect(tts.speaking, isTrue, reason: '应当仍在朗读');
      expect(visibleOnScreen(tester, rect), isTrue,
          reason: '停止连点后高亮框必须回到可见范围（rect=$rect）—— '
              '「定位失败」就是这里不成立');
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('连点不同句子：页面不抽搐（滚动方向不来回反复）', (tester) async {
    final (dir, document) = await makeBook(tester);
    try {
      await openAndRead(tester, document);
      final tts = TtsManager.instance;

      /// 当前页内滚动位置（拿不到返回 null）
      double? scrollOffset() {
        final finder = find.byWidgetPredicate(
          (Widget widget) =>
              widget is ListView &&
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('reader-page-'),
        );
        if (finder.evaluate().isEmpty) return null;
        final listView = tester.widget<ListView>(finder.first);
        final controller = listView.controller;
        if (controller == null || !controller.hasClients) return null;
        return controller.position.pixels;
      }
      // 连点不同句子（每次只等很短时间，模拟「多次点击」）
      //
      // 用「双击进入 + 单击切换」这套 v1.20.0 规则：
      // 第一次双击进入朗读模式，之后单击就是切句。
      final offsets = <double>[];
      var taps = 0;
      Finder sentenceOf(int paragraph) => find.byWidgetPredicate((Widget widget) {
            if (widget is! Text) return false;
            final span = widget.textSpan;
            return span != null &&
                span.toPlainText().contains('第 1 章第 $paragraph 段第 1 句');
          });
      // 先双击进入朗读模式
      final firstTarget = sentenceOf(1);
      expect(firstTarget, findsWidgets, reason: '第 1 段应当在视口里');
      await tester.tap(firstTarget.first);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(firstTarget.first);
      await settle(tester, rounds: 12);
      expect(tts.speaking, isTrue, reason: '双击之后应当开始朗读');

      // 连点「下一句」快速推进：每次点击都会让朗读位置往下走，
      // 一个长段落里的逐句推进必然要求页面滚动 —— 这正是「多次点击抽搐」
      // 最容易出现的场景（用户原话：「在朗读时切换别的句子时，多次点击」）。
      for (var i = 0; i < 24; i++) {
        final next = find.byKey(ReaderPage.nextSentenceKey);
        if (next.evaluate().isEmpty) break;
        await tester.tap(next);
        taps++;
        // 只给很短时间：模拟连点（定位还没跑完就点下一下）
        for (var j = 0; j < 2; j++) {
          await tester.pump(const Duration(milliseconds: 40));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
          final off = scrollOffset();
          if (off != null) offsets.add(off);
        }
      }
      await settle(tester, rounds: 30);
      final last = scrollOffset();
      if (last != null) offsets.add(last);

      // 统计方向反转次数：正常跟随是「单调朝一个方向走、然后停」，
      // 抽搐则是「来回反复」——反转次数会明显偏多。
      var reversals = 0;
      for (var i = 2; i < offsets.length; i++) {
        final a = offsets[i - 1] - offsets[i - 2];
        final b = offsets[i] - offsets[i - 1];
        if (a.abs() < 1 || b.abs() < 1) continue;
        if (a.sign != b.sign) reversals++;
      }
      // ignore: avoid_print
      print('DEVICE_VERIFY[no-jitter] 点击=$taps 偏移='
          '${offsets.map((v) => v.round()).toList()} 反转=$reversals '
          'cursor=${tts.cursor}');
      expect(taps, greaterThanOrEqualTo(4),
          reason: '至少要真的点到 4 次（点击=$taps）—— 点不到就测不出抽搐');
      expect(offsets.any((v) => v > 1), isTrue,
          reason: '这一段必须真的发生过滚动，否则用例是空跑（偏移='
              '${offsets.map((v) => v.round()).toList()}）');
      expect(reversals, lessThanOrEqualTo(2),
          reason: '连点不同句子时滚动方向不该来回反复（反转 $reversals 次，'
              '偏移=${offsets.map((v) => v.round()).toList()}）');
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('连点「下一句」跨页：翻页后框也要在可见范围内', (tester) async {
    final (dir, document) = await makeBook(tester);
    try {
      final reader = await openAndRead(tester, document);
      final tts = TtsManager.instance;
      final pages = <int>[reader.debugCurrentPage() as int];
      var invisible = 0;

      // 点足够多次以跨过好几页（每页 5 段 × 6 句 = 30 句）
      for (var i = 0; i < 90; i++) {
        final next = find.byKey(ReaderPage.nextSentenceKey);
        if (next.evaluate().isEmpty) break;
        await tester.tap(next);
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        if (i % 10 == 9) {
          // 每 10 次停一下让它收敛，再看框在不在
          await settle(tester, rounds: 30);
          pages.add(reader.debugCurrentPage() as int);
          if (!visibleOnScreen(tester, activeRect(tester))) invisible++;
        }
      }
      await settle(tester, rounds: 40);
      pages.add(reader.debugCurrentPage() as int);

      // ignore: avoid_print
      print('DEVICE_VERIFY[follow-page] pages=$pages 收敛后不可见=$invisible '
          'cursor=${tts.cursor} rect=${activeRect(tester)}');

      expect(pages.last, greaterThan(pages.first),
          reason: '应当至少翻过一页（pages=$pages）');
      expect(invisible, 0,
          reason: '每次收敛后框都该在可见范围内（不可见=$invisible 次）');
    } finally {
      await cleanup(tester, dir);
    }
  });
}

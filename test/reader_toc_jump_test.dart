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

/// 用户报：「朗读时通过目录跳转，有概率定位失败导致快速翻页」。
///
/// 这里用一本多章、每章多页的书复现：朗读中从目录跳到很远的章节，
/// 检查页码是否**单调、每次只走一页**，而不是「一路快速翻到底」。
class _HoldEngine with SyntheticTtsEngine implements TtsEngine {
  final Completer<void> _pending = Completer<void>();

  @override
  String get id => 'toc-hold';

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

  /// 造一本 60 章、每章 120 段的书 —— 默认每页 40 段 → 每章 3 页
  Future<(Directory, Document)> makeBook(WidgetTester tester) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('tocjump'),
    );
    final buffer = StringBuffer();
    for (var c = 0; c < 60; c++) {
      buffer.writeln('第 ${c + 1} 章');
      buffer.writeln();
      for (var p = 0; p < 120; p++) {
        buffer.writeln('第 ${c + 1} 章第 ${p + 1} 段。这里是正文内容。');
        buffer.writeln();
      }
    }
    final file = File('${dir!.path}/tocjump.txt')
      ..writeAsStringSync(buffer.toString());
    final document = Document(
      id: 'tocjump',
      title: 'tocjump',
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

  /// 当前是第几页（0 起）
  ///
  /// 用阅读页自己的 `debugCurrentPage()`，不要直接读 `controller.page`：
  /// 大跨度跳页走的是 `jumpToPage`，而 `jumpToPage` 之后控制器可能
  /// 一时没有 client，直接读 `.page` 会抛 StateError。
  int page(WidgetTester tester) {
    final reader = find.byType(ReaderPage);
    if (reader.evaluate().isEmpty) return -1;
    final state = tester.state(reader) as dynamic;
    try {
      final current = state.debugCurrentPage() as int;
      return current <= 0 ? -1 : current - 1;
    } catch (_) {
      return -1;
    }
  }

  testWidgets('朗读中从目录跳到很远的章节：不会快速连翻', (tester) async {
    final (dir, document) = await makeBook(tester);
    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1500)),
      );
      await settle(tester, rounds: 20);
      expect(find.byKey(ReaderPage.pageViewKey), findsOneWidget);

      final tts = TtsManager.instance;
      tts.speakFrom(0, 0, 0);
      for (var i = 0; i < 60 && !tts.speaking; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
      }
      expect(tts.speaking, isTrue);
      await settle(tester, rounds: 10);
      final startPage = page(tester);

      // 目录跳到第 50 章（很远），并开始朗读 —— 这就是用户的操作
      tts.speakFrom(49, 0, 0);
      // 密集采样：每次只给很少的帧，模拟「快速连翻」会被抓到的窗口
      final trail = <int>[startPage];
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        trail.add(page(tester));
      }
      await settle(tester, rounds: 30);
      trail.add(page(tester));

      // ignore: avoid_print
      print('DEVICE_VERIFY[toc-jump] trail=$trail cursor=${tts.cursor} '
          'speaking=${tts.speaking}');

      // 1) 页码必须单调不减（朗读只往前走）
      for (var i = 1; i < trail.length; i++) {
        expect(trail[i], greaterThanOrEqualTo(trail[i - 1]),
            reason: '页码不该回退：trail=$trail');
      }
      // 2) 不该「快速翻到底」：跳章之后最多落在目标章附近
      final finalPage = trail.last;
      // 第 50 章从第 49*3 = 147 页起，允许前后一点余量
      expect(finalPage, lessThanOrEqualTo(49 * 3 + 6),
          reason: '跳到第 50 章不该翻过头（trail=$trail）');
      // 3) 目标页要落对：应当在第 50 章的第一页附近
      expect(finalPage, greaterThanOrEqualTo(49 * 3 - 2),
          reason: '应当跳到第 50 章附近（trail=$trail）');
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('朗读中从目录跳到最后一章：不会一路翻到底', (tester) async {
    final (dir, document) = await makeBook(tester);
    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1500)),
      );
      await settle(tester, rounds: 20);

      final tts = TtsManager.instance;
      tts.speakFrom(0, 0, 0);
      for (var i = 0; i < 60 && !tts.speaking; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
      }
      await settle(tester, rounds: 10);

      // 跳到最后一章
      tts.speakFrom(59, 0, 0);
      final trail = <int>[];
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        trail.add(page(tester));
      }
      await settle(tester, rounds: 30);
      trail.add(page(tester));
      // ignore: avoid_print
      print('DEVICE_VERIFY[toc-last] trail=$trail cursor=${tts.cursor}');

      for (var i = 1; i < trail.length; i++) {
        expect(trail[i], greaterThanOrEqualTo(trail[i - 1]),
            reason: '页码不该回退：trail=$trail');
      }
      // 最后一章第一页约 59*3 = 177
      expect(trail.last, lessThanOrEqualTo(59 * 3 + 6),
          reason: '跳到最后一章不该翻过头（trail=$trail）');
    } finally {
      await cleanup(tester, dir);
    }
  });
}

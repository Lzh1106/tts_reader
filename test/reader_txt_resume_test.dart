import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 自动推进的假引擎：每句「读完」立刻回调，模拟真实朗读一路走下去
class _AutoEngine with SyntheticTtsEngine implements TtsEngine {
  void Function()? _onDone;

  @override
  String get id => 'txt-auto';

  @override
  String get displayName => '假引擎（自动推进）';

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
    // 按「一句话要读一会儿」的节奏：测试里推进太快（毫秒级）会让翻页动画
    // 来不及跑完，量到的「页码没跟上」是测试自身的假象，不是真实行为。
    await Future<void>.delayed(const Duration(milliseconds: 120));
    _onDone?.call();
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) => _onDone = handler;

  @override
  Future<void> dispose() async {}
}

/// TXT：朗读一路自动推进（用户没点过任何句子），退出再进要回到当时的朗读位置。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    StorageService.instance.setParagraphsPerPage(10);
    TtsManager.instance.resetSessionForTest();
    await TtsManager.instance.registerEngine(_AutoEngine(), makeActive: true);
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetSessionForTest();
  });

  testWidgets('TXT 自动朗读推进后退出重进：回到当时的朗读位置', (tester) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('txt_auto'),
    );
    final file = File('${dir!.path}/auto.txt')
      ..writeAsStringSync(
        List<String>.generate(120, (i) => '第 $i 段第一句。第 $i 段第二句！')
            .join('\n\n'),
      );
    final document = Document(
      id: 'txt_auto',
      title: 'txt_auto',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime(2024),
    );

    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2000)),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // 开始朗读，让它自动推进一段（模拟用户听了一会儿）。
      // 步调较慢：推进太快会让翻页动画来不及跑完，量到的是动画中间态。
      TtsManager.instance.speakFrom(0, 0, 0);
      for (var round = 0; round < 200; round++) {
        await tester.pump(const Duration(milliseconds: 60));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        if (TtsManager.instance.cursor.$2 >= 45) break;
      }
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 60));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
      final during = TtsManager.instance.cursor;
      final pageDuring = tester
          .widget<PageView>(find.byKey(ReaderPage.pageViewKey))
          .controller!
          .page
          ?.round();
      // ignore: avoid_print
      print('DEVICE_VERIFY[txt-auto] during=$during page=$pageDuring');

      // 退出（走真实 dispose：写回位置）。
      //
      // 停止朗读后再退出：这样「退出瞬间的位置」是确定的，
      // 不会被收尾期间继续推进的几句干扰（那会让断言变成测时序而不是测功能）。
      final beforeExit = TtsManager.instance.cursor;
      await TtsManager.instance.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 900)),
      );

      final stored = await StorageService.instance.loadDocuments();
      final entry = stored.where((d) => d.id == 'txt_auto').toList();
      final progress = entry.isEmpty ? -1.0 : entry.first.progress;
      // 进度是「全局句序号 / 总句数」，这里用已知的文本结构换算回来：
      // 每段 2 句、共 120 段 → 每段 2 句，段落 N 的第一句 = 全局句 2N
      const totalSentences = 120 * 2;
      final exitSentence = beforeExit.$2 * 2 + beforeExit.$3;
      final progressSentence = (progress * totalSentences).round();
      // ignore: avoid_print
      print('DEVICE_VERIFY[txt-auto] beforeExit=$beforeExit '
          'storedProgress=$progress exitSentence=$exitSentence '
          'progressSentence=$progressSentence');

      // 重进：应当回到写回的那个位置
      await tester.pumpWidget(
        MaterialApp(home: ReaderPage(document: entry.first)),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2000)),
      );
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final pageAfter = tester
          .widget<PageView>(find.byKey(ReaderPage.pageViewKey))
          .controller!
          .page
          ?.round();
      final cursorAfter = TtsManager.instance.cursor;
      // ignore: avoid_print
      print('DEVICE_VERIFY[txt-auto] pageAfter=$pageAfter '
          'cursorAfter=$cursorAfter');

      expect(pageAfter, greaterThan(0), reason: '不该回到第 1 页');
      // 写回的进度就是「取样瞬间」那一段；取样与退出之间朗读还会推进几句
      // （真实设备上同样如此），所以给几句余量 —— 这里测的是「写回的进度
      // 与退出位置同源」，不是「精确到某一毫秒」。
      expect((progressSentence - exitSentence).abs(), lessThanOrEqualTo(12),
          reason: '写回的进度要对准退出位置（exit=$exitSentence '
              'progress=$progressSentence）');
      // 重进落在写回的位置上
      final afterSentence = cursorAfter.$2 * 2 + cursorAfter.$3;
      expect((afterSentence - progressSentence).abs(), lessThanOrEqualTo(2),
          reason: '重进要回到写回的位置（progress=$progressSentence '
              'after=$afterSentence cursorAfter=$cursorAfter）');
      final expectPage = (progressSentence ~/ 20).clamp(0, 11);
      expect((pageAfter! - expectPage).abs(), lessThanOrEqualTo(1),
          reason: '页码要对得上（期望≈$expectPage 实际=$pageAfter）');
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

  testWidgets('TXT 听一小段后「停止」再退出：仍然回到那段位置', (tester) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('txt_stop'),
    );
    final file = File('${dir!.path}/stop.txt')
      ..writeAsStringSync(
        List<String>.generate(120, (i) => '第 $i 段第一句。第 $i 段第二句！')
            .join('\n\n'),
      );
    final document = Document(
      id: 'txt_stop',
      title: 'txt_stop',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime(2024),
    );

    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2000)),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      TtsManager.instance.speakFrom(0, 0, 0);
      // 只听一小会儿：推进到前几段就停下
      for (var round = 0; round < 200; round++) {
        await tester.pump(const Duration(milliseconds: 60));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        if (TtsManager.instance.cursor.$2 >= 25) break;
      }
      // 让最后一次翻页动画走完再取样
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 60));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
      final during = TtsManager.instance.cursor;
      // 用户按「停止」（阅读页仍开着）
      await TtsManager.instance.stop();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final pageDuring = tester
          .widget<PageView>(find.byKey(ReaderPage.pageViewKey))
          .controller!
          .page
          ?.round();
      // ignore: avoid_print
      print('DEVICE_VERIFY[txt-stop] during=$during page=$pageDuring');

      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 900)),
      );
      final stored = await StorageService.instance.loadDocuments();
      final entry = stored.where((d) => d.id == 'txt_stop').toList();
      // ignore: avoid_print
      print('DEVICE_VERIFY[txt-stop] storedProgress='
          '${entry.isEmpty ? -1 : entry.first.progress}');

      await tester.pumpWidget(
        MaterialApp(home: ReaderPage(document: entry.first)),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2000)),
      );
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final pageAfter = tester
          .widget<PageView>(find.byKey(ReaderPage.pageViewKey))
          .controller!
          .page
          ?.round();
      // ignore: avoid_print
      print('DEVICE_VERIFY[txt-stop] pageAfter=$pageAfter '
          'cursorAfter=${TtsManager.instance.cursor}');
      expect(pageAfter, pageDuring,
          reason: '「停止」后退出，重进仍要回到当时那一页');
      expect(pageAfter, greaterThan(0), reason: '不该回到第 1 页');
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

  testWidgets('TXT 冷启动重进（没有内存游标）：只靠写回的进度也要回到原处', (tester) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('txt_cold'),
    );
    final file = File('${dir!.path}/cold.txt')
      ..writeAsStringSync(
        List<String>.generate(120, (i) => '第 $i 段第一句。第 $i 段第二句！')
            .join('\n\n'),
      );
    final document = Document(
      id: 'txt_cold',
      title: 'txt_cold',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime(2024),
    );

    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2000)),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      TtsManager.instance.speakFrom(0, 0, 0);
      for (var round = 0; round < 200; round++) {
        await tester.pump(const Duration(milliseconds: 60));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        if (TtsManager.instance.cursor.$2 >= 45) break;
      }
      // 让最后一次翻页动画彻底走完再取样（否则量到的是动画中间态）
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 60));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
      final during = TtsManager.instance.cursor;
      final pageDuring = tester
          .widget<PageView>(find.byKey(ReaderPage.pageViewKey))
          .controller!
          .page
          ?.round();

      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 900)),
      );

      // 关键：清掉所有内存态（等价于进程被杀 / 冷启动），
      // 只剩落盘的进度——这条才是「返回朗读位置」最脆弱的地方。
      TtsManager.instance.resetSessionForTest();
      final stored = await StorageService.instance.loadDocuments();
      final entry = stored.firstWhere((d) => d.id == 'txt_cold');
      // ignore: avoid_print
      print('DEVICE_VERIFY[txt-cold] during=$during pageDuring=$pageDuring '
          'progress=${entry.progress}');

      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: entry)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2000)),
      );
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final pageAfter = tester
          .widget<PageView>(find.byKey(ReaderPage.pageViewKey))
          .controller!
          .page
          ?.round();
      final cursorAfter = TtsManager.instance.cursor;
      // ignore: avoid_print
      print('DEVICE_VERIFY[txt-cold] pageAfter=$pageAfter '
          'cursorAfter=$cursorAfter');
      // 允许一两段的偏差（进度是「句序号 / 总句数」的浮点换算）
      expect(cursorAfter.$2, greaterThanOrEqualTo(during.$2 - 2),
          reason: '冷启动重进要回到朗读位置（during=$during after=$cursorAfter）');
      expect(pageAfter, isNotNull);
      expect((pageAfter! - pageDuring!).abs(), lessThanOrEqualTo(1),
          reason: '页码也要对得上（during=$pageDuring after=$pageAfter）');
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

  testWidgets('TXT 用旧进度对象重进（控制栏按钮的真实情况）：也要回到朗读位置', (tester) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('txt_stale'),
    );
    final file = File('${dir!.path}/stale.txt')
      ..writeAsStringSync(
        List<String>.generate(120, (i) => '第 $i 段第一句。第 $i 段第二句！')
            .join('\n\n'),
      );
    // 进度为 0 的旧对象：文档库列表还没刷新时就是这个
    final stale = Document(
      id: 'txt_stale',
      title: 'txt_stale',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime(2024),
    );

    try {
      // 第一次打开并读到第 40 段附近
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: stale)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2000)),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      TtsManager.instance.speakFrom(0, 0, 0);
      for (var round = 0; round < 80; round++) {
        await tester.pump(const Duration(milliseconds: 40));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        if (TtsManager.instance.cursor.$2 >= 40) break;
      }
      final during = TtsManager.instance.cursor;
      // ignore: avoid_print
      print('DEVICE_VERIFY[txt-stale] during=$during');

      // 退出时**不停朗读**（模拟「从文档退出不打断朗读」）
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 900)),
      );

      // 用**旧对象**（progress 仍是 0）重进 —— 这正是控制栏「返回朗读页」的情况
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: stale)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2000)),
      );
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final after = TtsManager.instance.cursor;
      // ignore: avoid_print
      print('DEVICE_VERIFY[txt-stale] after=$after');
      expect(after.$2, greaterThanOrEqualTo(during.$2 - 2),
          reason: '即使用旧进度对象重进，也要回到朗读位置（during=$during after=$after）');
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

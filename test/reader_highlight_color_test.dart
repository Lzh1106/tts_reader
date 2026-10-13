import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 假的朗读引擎：`speak` 一直挂着不返回，直到测试主动让它完成。
///
/// 高亮只在「会话进行中」才渲染（`highlightCursor` 要求 `speaking`），
/// 而测试环境没有 flutter_tts 原生实现 —— 真引擎的 `speak` 永远不回复，
/// 会话根本进不去。只有注入假引擎才能把「正在朗读」这个状态造出来。
class _HoldEngine with SyntheticTtsEngine implements TtsEngine {
  final Completer<void> _pending = Completer<void>();

  /// 让当前这一句「读完」（模拟引擎回调），朗读循环随之推进到下一句
  void finishCurrent() {
    if (!_pending.isCompleted) _pending.complete();
  }

  @override
  String get id => 'hl-hold';

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

/// 朗读高亮要「尽量贴近 T2S」（用户给的 T2S 截图：
/// 浅蓝底 rgb(181,216,254) + 近黑字，整句一条连续底色）。
///
/// 这里不看配色函数，而是**直接读界面上真正渲染出来的 TextSpan 样式** ——
/// 配色改对了但没接到正文上，是这类改动最常见的失误。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 读出界面上实际生效的 ColorScheme（与正文渲染用的是同一套主题）。
  ColorScheme liveScheme(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(ReaderPage))).colorScheme;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    TtsManager.instance.resetSessionForTest();
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetSessionForTest();
  });

  /// 取出正文里「正在朗读那一句」的样式：它是唯一带 backgroundColor 的 span
  TextSpan? highlightedSpan(WidgetTester tester) {
    for (final element in find.byType(Text).evaluate()) {
      final span = (element.widget as Text).textSpan;
      if (span is! TextSpan || span.children == null) continue;
      for (final child in span.children!) {
        if (child is TextSpan && child.style?.backgroundColor != null) {
          return child;
        }
      }
    }
    return null;
  }

  /// 等朗读开始并渲染出高亮
  Future<TextSpan?> waitForHighlight(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      final span = highlightedSpan(tester);
      if (span != null) return span;
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    return highlightedSpan(tester);
  }

  testWidgets('文字模式：朗读句高亮跟随主题（primaryContainer 系）', (tester) async {
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('hl_txt'));
    final file = File('${dir!.path}/hl.txt')
      ..writeAsStringSync('第一句话在这里。第二句话在这里。第三句话在这里。\n\n又一段文字。');
    final document = Document(
      id: 'hl',
      title: '高亮配色',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime(2024),
    );

    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1200)),
      );
      await tester.pump();
      await TtsManager.instance
          .registerEngine(_HoldEngine(), makeActive: true);
      TtsManager.instance.speakFrom(0, 0, 0);
      // 等真的进入朗读中：`speakFrom` 是异步启动的，
      // 注册引擎 / 引擎就绪都要跨事件循环，不 pump 就可能还没开始读。
      // 给足真实时间：整套用例一起跑时 CPU 忙，引擎就绪会慢一些；
      // 等待窗口太紧会出现「单独跑过、全量跑偶发失败」的假失败。
      for (var i = 0; i < 150 && !TtsManager.instance.speaking; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
      }
      expect(TtsManager.instance.speaking, isTrue,
          reason: '假引擎下应当进入朗读中（否则谈不上高亮）');

      final span = await waitForHighlight(tester);
      // ignore: avoid_print
      print('DEVICE_VERIFY[hl-text] bg=${span?.style?.backgroundColor} '
          'fg=${span?.style?.color} text=${span?.text}');
      expect(span, isNotNull, reason: '应当渲染出一句带底色的高亮');
      // 默认主题（亮面）派生的 primaryContainer 系：与正文渲染同一套 ColorScheme
      final scheme = liveScheme(tester);
      expect(span!.style?.backgroundColor, scheme.primaryContainer,
          reason: '高亮底色应当是主题 primaryContainer（派生，非写死）');
      expect(span.style?.color, scheme.onPrimaryContainer);
      expect(span.style?.backgroundColor, isNot(const Color(0xFFB5D8FE)),
          reason: '旧的写死浅蓝已废弃');
      expect(span.text, isNotEmpty);
    } finally {
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

  testWidgets('换主题种子色后，界面上的高亮真的变', (tester) async {
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('hl_seed'));
    final file = File('${dir!.path}/hl2.txt')
      ..writeAsStringSync('第一句话在这里。第二句话在这里。\n\n又一段文字。');
    final document = Document(
      id: 'hl2',
      title: '高亮换主题',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime(2024),
    );
    // App 的种子色定义在 TtsReaderApp / AppTheme，这里复刻同样的构造方式：
    // 同一个 MaterialApp 结构，只把种子色换成对比度明显的另一套。
    ThemeData themeWith(Color seed) => ThemeData(
          useMaterial3: true,
          colorScheme:
              ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light),
        );
    Future<Color?> readHighlight(Color seed) async {
      await tester.pumpWidget(MaterialApp(
        theme: themeWith(seed),
        home: ReaderPage(document: document),
      ));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1200)),
      );
      await tester.pump();
      await TtsManager.instance.registerEngine(_HoldEngine(), makeActive: true);
      TtsManager.instance.speakFrom(0, 0, 0);
      for (var i = 0; i < 150 && !TtsManager.instance.speaking; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
      }
      final span = await waitForHighlight(tester);
      final bg = span?.style?.backgroundColor;
      await TtsManager.instance.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      return bg;
    }

    try {
      final first = await readHighlight(const Color(0xFF6750A4));
      final second = await readHighlight(const Color(0xFFB00020));
      // ignore: avoid_print
      print('DEVICE_VERIFY[hl-seed] a=$first b=$second');
      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(second, isNot(first),
          reason: '换主题（模拟动态取色换了强调色）后高亮底色必须真的变');
    } finally {
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.delete(recursive: true);
        } catch (_) {}
      });
    }
  });

  testWidgets('PDF 转文字模式：高亮同样派生自主题（与文字模式同源）', (tester) async {
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('hl_pdf'));
    // 造一个小 PDF：体积低于「默认走文本模式」的阈值，所以要点按钮切换
    final pdfFile = File('${dir!.path}/hl.pdf');
    final pdf = PdfDocument();
    final font = PdfStandardFont(PdfFontFamily.helvetica, 12);
    pdf.pages.add().graphics.drawString(
      'First sentence here. Second sentence here. Third one here.',
      font,
      bounds: const Rect.fromLTWH(20, 20, 500, 500),
    );
    pdfFile.writeAsBytesSync(pdf.saveSync());
    pdf.dispose();

    final document = Document(
      id: 'hl_pdf',
      title: 'PDF 高亮配色',
      path: pdfFile.path,
      type: DocumentType.pdf,
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

      // 切到文本模式（PDF 转文字）
      final modeButton = find.byIcon(Icons.article_outlined);
      expect(modeButton, findsWidgets, reason: '应当有「切到文本模式」按钮');
      await tester.tap(modeButton.first);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 800)),
      );

      await TtsManager.instance
          .registerEngine(_HoldEngine(), makeActive: true);
      TtsManager.instance.speakFrom(0, 0, 0);
      // 给足真实时间：整套用例一起跑时 CPU 忙，引擎就绪会慢一些；
      // 等待窗口太紧会出现「单独跑过、全量跑偶发失败」的假失败。
      for (var i = 0; i < 150 && !TtsManager.instance.speaking; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
      }
      expect(TtsManager.instance.speaking, isTrue,
          reason: '假引擎下应当进入朗读中（否则谈不上高亮）');
      final span = await waitForHighlight(tester);
      // ignore: avoid_print
      print('DEVICE_VERIFY[hl-pdf-text] bg=${span?.style?.backgroundColor} '
          'fg=${span?.style?.color} text=${span?.text}');
      expect(span, isNotNull, reason: 'PDF 文本模式也要有整句高亮');
      final scheme = liveScheme(tester);
      expect(span!.style?.backgroundColor, scheme.primaryContainer,
          reason: 'PDF 转文字模式的高亮要与文字模式同源（都派生自主题）');
      expect(span.style?.color, scheme.onPrimaryContainer);
    } finally {
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

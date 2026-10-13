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

/// 文本朗读模式（与 PDF 原版式**同一套规则**）：
/// - **双击**想朗读的句子 → 进入朗读模式并从该句开始读；
/// - 进入朗读模式后**单击**其他句子 → 切换；
/// - 未进入朗读模式时单击**不动作**（避免滑动误触就开读）；
/// - 阅读页控制栏的**方块键**：结束朗读并退出朗读模式。
///
/// 说明：双击判定依赖真实时间窗（300ms），而这里紧接着还要用 `tester.tap`
/// 连续点同一句 —— 段落上的 `DoubleTapGestureRecognizer` 会和后续单击在
/// 手势竞技场里互相干扰（实测手动两次 tap 之后，后续 tap 收不到回调）。
/// 所以「单击切换」的用例用 [ReaderPage.debugEnterTextReadMode] 做前置，
/// 双击判定本身由 PDF 侧的手工验收覆盖。
class _HoldEngine with SyntheticTtsEngine implements TtsEngine {
  final Completer<void> _pending = Completer<void>();

  @override
  String get id => 'readmode-hold';

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

  /// 找「某段第一句」所在的**可点 Text 组件**。
  ///
  /// 不能用 `find.textContaining`：正文是 `Text.rich`（每句一个 span 带点击识别器），
  /// 它的 `data` 是 null，而 `textContaining` 只看 `data`，所以匹配不到 ——
  /// 这里把 rich text 的所有 span 拼起来找。
  Finder sentenceOf(int paragraph) {
    final needle = '第 $paragraph 段第一句。';
    return find.byWidgetPredicate((Widget widget) {
      if (widget is! Text) return false;
      final span = widget.textSpan;
      if (span == null) return false;
      return span.toPlainText().contains(needle);
    });
  }

  /// 造一本多页的书：每段**自成一行 + 空行分隔**
  /// （TXT 按行切章，不这样会被拆成一段一章）。120 段 → 默认每页 40 段 → 3 页。
  Future<(Directory, Document)> makeBook(WidgetTester tester) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('readmode'),
    );
    final buffer = StringBuffer();
    for (var i = 0; i < 120; i++) {
      buffer.writeln('第 $i 段第一句。第 $i 段第二句。第 $i 段第三句。');
      buffer.writeln();
    }
    final file = File('${dir!.path}/readmode.txt')
      ..writeAsStringSync(buffer.toString());
    await StorageService.instance.init();
    final document = Document(
      id: 'readmode',
      title: 'readmode',
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

  Future<void> openReader(WidgetTester tester, Document document) async {
    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1200)),
    );
    await settle(tester, rounds: 20);
    expect(find.byKey(ReaderPage.pageViewKey), findsOneWidget,
        reason: '应当进入分页阅读界面');
  }

  /// 统一收尾：先停朗读、卸载界面，再走几帧**真实时间**让跟随 / 定位留下的
  /// Timer 跑完 —— 否则 widget 测试会以「A Timer is still pending」失败
  /// （用例本身的断言其实都过了）。
  Future<void> cleanup(WidgetTester tester, Directory dir) async {
    await TtsManager.instance.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester, rounds: 8);
    await tester.runAsync(() async {
      try {
        if (dir.existsSync()) dir.delete(recursive: true);
      } catch (_) {}
    });
  }

  testWidgets('单击句子立即开始朗读（原版 1.20.0 的点击即读）', (tester) async {
    final (dir, document) = await makeBook(tester);
    try {
      await openReader(tester, document);
      final tts = TtsManager.instance;
      final before = tts.cursor;

      final target = sentenceOf(5);
      expect(target, findsWidgets, reason: '第 5 段应当在视口里');
      await tester.tap(target.first);
      await settle(tester, rounds: 10);

      final reader = tester.state(find.byType(ReaderPage)) as dynamic;
      expect(reader.debugTextReadMode as bool, isTrue,
          reason: '单击就应当进入朗读模式（原版 1.20.0 是点击即读）');
      expect(tts.speaking, isTrue, reason: '单击就应当开始朗读');
      expect(tts.cursor.$2, 5,
          reason: '应当从点的那一段开始（之前 $before，实际 ${tts.cursor}）');
      expect(find.text('已从这一句开始朗读：点其他句子可直接切换'), findsOneWidget,
          reason: '提示语要与原版 1.20.0 一致');
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('点段落空白处也从该段第一句开始读（点击即读）', (tester) async {
    final (dir, document) = await makeBook(tester);
    try {
      await openReader(tester, document);
      final tts = TtsManager.instance;

      // 段落的 GestureDetector 覆盖整段（含空白区）：点正文任意位置都能起读
      final pageView = find.byKey(ReaderPage.pageViewKey);
      expect(pageView, findsOneWidget);
      await tester.tapAt(
        tester.getTopLeft(pageView) + const Offset(400, 120),
      );
      await settle(tester, rounds: 12);

      final reader = tester.state(find.byType(ReaderPage)) as dynamic;
      // ignore: avoid_print
      print('DEVICE_VERIFY[paragraph-tap] speaking=${tts.speaking} '
          'cursor=${tts.cursor} mode=${reader.debugTextReadMode}');
      expect(tts.speaking, isTrue,
          reason: '点正文就应当开始朗读（实际 cursor=${tts.cursor}）');
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('进入朗读模式后：单击其他句子能切换（反复多次都生效）', (tester) async {
    final (dir, document) = await makeBook(tester);
    try {
      await openReader(tester, document);
      final tts = TtsManager.instance;
      final reader = tester.state(find.byType(ReaderPage)) as dynamic;
      reader.debugEnterTextReadMode();
      await tester.pump(const Duration(milliseconds: 60));

      // 连着点不同段落，每次都必须切过去（这是本功能的核心）。
      //
      // 段落是**懒加载**的：只有视口附近的段才在树里，所以这里逐步往回想，
      // 保证每次点的段确实看得见（真实使用也是这样：看得见才点得到）。
      for (final paragraph in <int>[5, 4, 3, 1]) {
        final target = sentenceOf(paragraph);
        expect(target, findsWidgets, reason: '第 $paragraph 段应当在视口里');
        await tester.tap(target.first);
        await settle(tester, rounds: 8);
        expect(tts.speaking, isTrue, reason: '单击应当开始 / 继续朗读');
        expect(tts.cursor.$2, paragraph,
            reason: '单击第 $paragraph 段应当切到那一段（实际 ${tts.cursor}）');
      }
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('方块键终止朗读进程：控制栏保持展开，再点一下句子即重新开始', (tester) async {
    final (dir, document) = await makeBook(tester);
    try {
      await openReader(tester, document);
      final tts = TtsManager.instance;
      final reader = tester.state(find.byType(ReaderPage)) as dynamic;

      // 阅读页控制栏应当一直有方块键（用户要求与文档库控制栏一致）
      expect(find.byKey(ReaderPage.stopReadingKey), findsOneWidget,
          reason: '阅读页控制栏应当有方块键');

      // 单击即开始朗读（原版 1.20.0 的点击即读）
      final target = sentenceOf(5);
      expect(target, findsWidgets, reason: '第 5 段应当在视口里');
      await tester.tap(target.first);
      await settle(tester, rounds: 10);
      expect(reader.debugTextReadMode as bool, isTrue);
      expect(tts.speaking, isTrue, reason: '单击应当开始朗读');

      // 方块键终止朗读进程
      await tester.tap(find.byKey(ReaderPage.stopReadingKey));
      await settle(tester, rounds: 12);
      expect(tts.speaking, isFalse, reason: '方块键应当终止朗读');
      expect(reader.debugTextReadMode as bool, isFalse,
          reason: '方块键应当退出朗读模式');
      // 控制中心**保持展开可见** —— 方块键只退出朗读模式，
      // 不改变控制栏的折叠状态（折叠是用户自己按收起键的选择）。
      expect(find.byKey(ReaderPage.controlCenterKey), findsOneWidget,
          reason: '方块键之后控制中心应当仍然可见');
      expect(find.byKey(ReaderPage.collapsedControlKey), findsNothing,
          reason: '方块键不该顺手把它折成迷你条');

      // 再点一下句子：点击即读，应当立刻重新开始
      await tester.tap(target.first);
      await settle(tester, rounds: 12);
      expect(reader.debugTextReadMode as bool, isTrue,
          reason: '点句应当重新进入朗读模式');
      expect(tts.speaking, isTrue, reason: '点句应当重新开始朗读（点击即读）');
      expect(tts.cursor.$2, 5, reason: '应当从点的那一段开始（实际 ${tts.cursor}）');
    } finally {
      await cleanup(tester, dir);
    }
  });
}

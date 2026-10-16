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

  /// 打开「高段落」书并进入朗读模式（`openAndRead` 的软换行版）
  ///
  /// 与 [openAndRead] 的区别只在于点的是**第 0 段第 0 句**的文本
  /// （高段落书里的句子文本格式不同），其余流程一致。
  Future<dynamic> openAndReadTall(
    WidgetTester tester,
    Document document,
  ) async {
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
      return span != null && span.toPlainText().contains('第0段第0句');
    });
    expect(first, findsWidgets, reason: '第 0 段应当在视口里');
    // ⚠️ 段落比视口高时，「第 0 段第 0 句」这行文字**可能落在折叠线以下** ——
    // 直接 `tap` 会点到别的控件上（实测点到进度条，然后断言"应当开始朗读"失败）。
    // 所以先把目标滚进视野再点：这是"用户先滑一下再点句"的等价动作。
    await tester.ensureVisible(first.first);
    await settle(tester, rounds: 10);
    await tester.tap(first.first);
    await settle(tester, rounds: 10);
    expect(tts.speaking, isTrue, reason: '单击应当开始朗读');
    return reader;
  }

  /// 造一本「**段落比视口高**」的书 —— 软换行跟随用例专用（v1.21.53）
  ///
  /// ## 为什么必须专门造这样的书
  ///
  /// 原来的用例里每段是「第 1 章第 0 段第 1 句内容在这里。……」这种**短段**
  /// （段高约 9 行），三段的段首就撑满一屏 —— 于是「按段顶对齐」和
  /// 「按句心对齐」看不出区别，**软换行那个 bug 一条用例都没抓到**。
  ///
  /// 真机上的中文 EPUB 段落动辄几百字、**比屏幕高好几倍**（实测：段高 580px，
  /// 视口 483px，一个段就有 12 行以上）。只有这种段落才能区分：
  /// * 按**段顶**对齐 38% → 正在读的那句落在屏幕外（旧行为，实测句心 696px）
  /// * 按**句心**对齐 38% → 那句真的在 38% 处（新行为）
  ///
  /// 所以这里每段给足 ~260 字（约 12+ 行），并且**段内没有 `\n`**
  /// —— 正是「软换行」的定义。
  Future<(Directory, Document)> makeTallParagraphBook(
    WidgetTester tester, {
    int paragraphs = 8,
    int sentencesPerParagraph = 12,
    int charsPerSentence = 22,
  }) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('follow-tall'),
    );
    final buffer = StringBuffer();
    buffer.writeln('第一章');
    buffer.writeln();
    for (var p = 0; p < paragraphs; p++) {
      // 段内**不写 \n**：全部靠软换行折行（中文段的真实形态）
      for (var s = 0; s < sentencesPerParagraph; s++) {
        final filler = '字' * charsPerSentence;
        buffer.write('第$p段第$s句$filler。');
      }
      buffer.writeln();
      buffer.writeln();
    }
    final file = File('${dir!.path}/tall.txt')
      ..writeAsStringSync(buffer.toString());
    final document = Document(
      id: 'follow-tall',
      title: 'follow-tall',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime(2024),
    );
    await StorageService.instance.upsertDocument(document);
    return (dir, document);
  }

  testWidgets('软换行长段落：跟随必须按**实测句心**对齐，不能拿段顶当句位', (tester) async {
    final (dir, document) = await makeTallParagraphBook(tester);
    try {
      final reader = await openAndReadTall(tester, document);
      final tts = TtsManager.instance;

      /// 收集推进过程中的「实测几何」样本
      final samples = <Map<String, Object?>>[];
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

      // 在**同一个长段落内**连点推进：旧实现下「句位」恒等于段顶，
      // 于是句心不会随句号推进而变 —— 新实现必须真的往下走。
      var advanced = 0;
      for (var i = 0; i < 10; i++) {
        final before = tts.cursor;
        final geo = reader.debugSentenceGeometry() as Map<String, Object?>?;
        if (geo != null) samples.add(geo);
        final next = find.byKey(ReaderPage.nextSentenceKey);
        if (next.evaluate().isEmpty) break;
        await tester.tap(next);
        advanced++;
        await settle(tester, rounds: 24);
        final after = tts.cursor;
        // 只要还在同一段里，就说明"段不变、句在动"——正是判别点
        if (after.$1 != before.$1 || after.$2 != before.$2) break;
      }
      final lastGeo = reader.debugSentenceGeometry() as Map<String, Object?>?;
      if (lastGeo != null) samples.add(lastGeo);
      final off = scrollOffset();

      // ignore: avoid_print
      print('DEVICE_VERIFY[tall-follow] 推进=$advanced 偏移=$off 样本='
          '${samples.map((s) => "${s['measureTag']}@${(s['sentenceCenter'] as double?)?.round()}").toList()}');

      expect(advanced, greaterThanOrEqualTo(3),
          reason: '至少要在同一段里推进 3 句，否则测不出"句位是否随句推进"');
      // ★核心断言 1：句位必须是**实测**得到的（旧实现恒为估算且偏移恒 0）
      final measuredCount = samples.where((s) => s['measured'] == true).length;
      expect(measuredCount, greaterThan(0),
          reason: '段落已渲染时句位必须走**实测**（RenderParagraph.getBoxesForSelection）；'
              '实测样本=$measuredCount/${samples.length}');
      // ★核心断言 2：同一段内，句心必须随句子推进而**变化**
      //   （旧实现：句内偏移恒为 0 → 句心恒定在段顶，这条必红）
      final centers = samples
          .map((s) => (s['topInParagraph'] as double?)?.round())
          .whereType<int>()
          .toSet();
      expect(centers.length, greaterThan(1),
          reason: '同一段内不同句的实测句位必须不同（旧实现恒等于段顶）—— '
              '实测到的段内位置=${centers.toList()}');
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('朗读推进：高亮句必须真的在屏幕上（越界即失败）', (tester) async {
    final (dir, document) = await makeTallParagraphBook(tester);
    try {
      final reader = await openAndReadTall(tester, document);
      final visibleRatios = <double>[];
      final inParagraphPositions = <int>[];

      for (var i = 0; i < 12; i++) {
        final next = find.byKey(ReaderPage.nextSentenceKey);
        if (next.evaluate().isEmpty) break;
        await tester.tap(next);
        await settle(tester, rounds: 30);
        final geo = reader.debugSentenceGeometry() as Map<String, Object?>?;
        if (geo == null) continue;
        final center = geo['sentenceCenter'] as double;
        final height = geo['viewportHeight'] as double;
        if (height <= 0) continue;
        visibleRatios.add(center / height);
        final inPara = (geo['topInParagraph'] as double?)?.round();
        if (inPara != null) inParagraphPositions.add(inPara);
      }

      // ignore: avoid_print
      print('DEVICE_VERIFY[tall-visible] 占比='
          '${visibleRatios.map((v) => (v * 100).round()).toList()} '
          '段内位置=$inParagraphPositions '
          '高亮框=${activeRect(tester)}');

      expect(visibleRatios, isNotEmpty, reason: '至少要有一次能量到几何');
      // ★核心断言：**高亮框必须真的落在屏幕上**（用户看到的就是这个框）。
      //
      // 这条才是用户报的现象本身（"不居中 / 位置不对"）。只断"占比在 0~1"
      // 是**假测试**：旧实现里估算值恒为段顶、看起来"稳定"在 73%，照样过 ——
      // 负向自检实测过（置 _negativeDisableMeasure=true 时那条断言仍绿）。
      // 所以这里改成断真正的可见性：框的上下沿都必须落在屏幕内。
      final rect = activeRect(tester);
      expect(rect, isNotNull, reason: '高亮框必须能量到');
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(rect!.top >= -1 && rect.bottom <= screen.height + 1, isTrue,
          reason: '高亮框必须完整落在屏幕内（rect=$rect 屏幕高=${screen.height}）');
      // ★且句心必须随句子**推进**（旧实现恒等于段顶 → 段内位置只有一个值）
      expect(inParagraphPositions.toSet().length, greaterThan(1),
          reason: '同一段内推进时实测句位必须变化（旧实现恒为段顶）—— '
              '段内位置=$inParagraphPositions');
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('重回阅读页（朗读已停）：进入定位必须把**那一句**拉进视野', (tester) async {
    // 与上一条的区别：这条在**朗读已停**的状态下重进。
    // 这正是进入定位那条链唯一存在的意义所在 ——
    // `_tts.highlightCursor` 在没朗读时恒为 null，所以「按句校验并补正」
    // 必须用**请求恢复的 spot** 量几何（见 `_geometryForCursor` 的说明）。
    // 与上一条的区别：这条在**朗读已停**的状态下重进，而且段落被撑到
    // **明显高于视口** —— 那才是"段顶进视野 ≠ 这一句进视野"的真实条件。
    //
    // ⚠️ 这条用例的段落必须够高：段落整体能塞进视口时，`_revealBlock`
    // （把段落按 5% 对齐）本身就把句子带进视野了，句子级补正**不需要出场**，
    // 用例也就守不住那条线（负向自检实测：跳过补正仍然绿）。真机上一个中文段
    // 580px > 视口 483px，所以必须造出同样的关系。
    final (dir, document) = await makeTallParagraphBook(
      tester,
      paragraphs: 3,
      sentencesPerParagraph: 26,
      charsPerSentence: 30,
    );
    try {
      await openAndReadTall(tester, document);
      final tts = TtsManager.instance;
      // 推进到某一段靠后的句子（深在长段落内部 —— 段顶进视野≠这句进视野）
      for (var i = 0; i < 9; i++) {
        final next = find.byKey(ReaderPage.nextSentenceKey);
        if (next.evaluate().isEmpty) break;
        await tester.tap(next);
        await settle(tester, rounds: 20);
      }
      final cursorBefore = tts.cursor;
      // ★停掉朗读：进入定位不再有 highlightCursor 可用
      await tester.runAsync(() => tts.stop());
      await settle(tester, rounds: 10);

      // 重新进入（此时朗读已停）
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester, rounds: 20);
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1500)),
      );
      await settle(tester, rounds: 50);

      // 量「正在读的那一句」在屏幕上的位置 —— 用恢复出来的 spot 直接算
      final reader2 = tester.state(find.byType(ReaderPage)) as dynamic;
      final geo = reader2.debugGeometryForSpot(cursorBefore)
          as Map<String, Object?>?;
      // ignore: avoid_print
      print('DEVICE_VERIFY[reenter-stopped] 退出前 cursor=$cursorBefore '
          '重进后 geometry=$geo 高亮框=${activeRect(tester)}');

      expect(geo, isNotNull,
          reason: '重进后必须能量到请求恢复那一句的几何（朗读已停也要能量）');
      final center = geo!['sentenceCenter'] as double;
      final height = geo['viewportHeight'] as double;
      final ratio = center / height;
      expect(ratio >= 0 && ratio <= 1, isTrue,
          reason: '重进后那一句的句心必须落在视口内（占比=${(ratio * 100).round()}%，'
              '句心=$center 视口高=$height）—— 这就是「重回不在朗读位置」');
    } finally {
      await cleanup(tester, dir);
    }
  });

  testWidgets('重回阅读页：定位必须落到**朗读句**（不只是朗读段）', (tester) async {
    final (dir, document) = await makeTallParagraphBook(tester);
    try {
      // 1) 先读到某一段的**靠后**的句子
      await openAndReadTall(tester, document);
      final tts = TtsManager.instance;
      for (var i = 0; i < 8; i++) {
        final next = find.byKey(ReaderPage.nextSentenceKey);
        if (next.evaluate().isEmpty) break;
        await tester.tap(next);
        await settle(tester, rounds: 20);
      }
      final cursorBefore = tts.cursor;
      // ignore: avoid_print
      print('DEVICE_VERIFY[reenter] 退出前 cursor=$cursorBefore');

      // 2) 退出阅读页（朗读会话保留），再重新进来
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester, rounds: 20);
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1500)),
      );
      await settle(tester, rounds: 40);

      // 3) 断言：落在**同一句**上（旧实现会给到段首/段顶，句号对不上）
      final reader2 = tester.state(find.byType(ReaderPage)) as dynamic;
      final snapshot = reader2.debugFollowSnapshot() as Map<String, Object?>;
      final spot = reader2.debugLastSpot as (int, int, int);
      // ignore: avoid_print
      print('DEVICE_VERIFY[reenter] 重进后 spot=$spot 快照=$snapshot');

      expect(spot.$1, cursorBefore.$1, reason: '章必须一致');
      expect(spot.$2, cursorBefore.$2, reason: '段必须一致');
      expect(spot.$3, cursorBefore.$3,
          reason: '**句**必须一致（旧实现只保证段，句会回退到段首）');
    } finally {
      await cleanup(tester, dir);
    }
  });
}

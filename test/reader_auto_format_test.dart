import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 「自动排版」可逆开关的行为：
/// - **点一次是排版**；
/// - **再点一次恢复原排版**；
/// - **不点就不改当前生效的排版**；
/// - **退出重进保持这个选择**（选择落盘，不靠内存）。
void main() {
  /// 造一份会**因为排版而改变**的 PDF
  ///
  /// 每页都是「一句话被硬折行切成 4 行」，三页 → 未排版时 3 段（每页一段）、
  /// 排版后仍是 3 段但**每段内部的句子被接回整句**。
  /// 为了让「形态」可比较，这里让重排前后**段落里的句子数**不同：
  /// 每页画 4 行，其中第 1~2 行构成一句、第 3~4 行构成另一句。
  File makePdf(Directory dir) {
    final file = File('${dir.path}/reflow.pdf');
    final pdf = PdfDocument();
    final font = PdfStandardFont(PdfFontFamily.helvetica, 11);
    for (var page = 0; page < 3; page++) {
      final graphics = pdf.pages.add().graphics;
      final lines = <String>[
        'Page $page first sentence begins here and the',
        'typesetter broke it across two lines, then the',
        'second sentence begins here and it is also',
        'broken across two lines by the layout engine.',
      ];
      for (var i = 0; i < lines.length; i++) {
        graphics.drawString(lines[i], font,
            bounds: Rect.fromLTWH(40, 40 + i * 18, 520, 18));
      }
    }
    file.writeAsBytesSync(pdf.saveSync());
    pdf.dispose();
    return file;
  }

  /// 只取**正文段落**的文字（排除章节标题、控制栏、SnackBar 提示）
  ///
  /// 用正文特征词筛：每页正文都含 'sentence' 或 'broken'。
  /// 不筛的话，恢复原排版后 SnackBar 的提示文字混进来会让「和之前一样」的比较失败。
  String bodyOnly(WidgetTester tester) {
    bool isBody(String text) =>
        text.contains('sentence') || text.contains('broken');
    final parts = <String>[];
    for (final element in find.byType(Text).evaluate()) {
      final widget = element.widget as Text;
      final direct = widget.data;
      if (direct != null && isBody(direct)) {
        parts.add(direct);
        continue;
      }
      final span = widget.textSpan;
      if (span is TextSpan && span.children != null) {
        for (final child in span.children!) {
          final text = child is TextSpan ? child.text : null;
          if (text != null && isBody(text)) parts.add(text);
        }
      }
    }
    return parts.join('|');
  }

  /// 正文（段落视图）里的文字：`Text.rich` 的文本在 textSpan 里，不在 `data` 上
  String bodyText(WidgetTester tester) {
    final parts = <String>[];
    for (final element in find.byType(Text).evaluate()) {
      final widget = element.widget as Text;
      final direct = widget.data;
      if (direct != null && direct.isNotEmpty) {
        parts.add(direct);
        continue;
      }
      final span = widget.textSpan;
      if (span is TextSpan && span.children != null) {
        for (final child in span.children!) {
          if (child is TextSpan && (child.text?.isNotEmpty ?? false)) {
            parts.add(child.text!);
          }
        }
      }
    }
    return parts.join('|');
  }

  Future<void> openReader(WidgetTester tester, Document document) async {
    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2000)),
    );
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// 切到文本模式（自动排版只在文本模式下可用）
  Future<void> switchToTextMode(WidgetTester tester) async {
    final button = find.byIcon(Icons.article_outlined);
    if (button.evaluate().isEmpty) return;
    await tester.tap(button.first);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 900)),
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
  });

  testWidgets('点一次排版、再点恢复原排版；不点就不改', (tester) async {
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('af'));
    final file = makePdf(dir!);
    final document = Document(
      id: 'af_toggle',
      title: '排版开关',
      path: file.path,
      type: DocumentType.pdf,
      importedAt: DateTime(2024),
    );

    try {
      await openReader(tester, document);
      await switchToTextMode(tester);

      final toggle = find.byKey(ReaderPage.autoFormatKey);
      expect(toggle, findsOneWidget, reason: '文本模式下应当有排版按钮');
      expect(
        StorageService.instance.isAutoFormat('af_toggle'),
        isFalse,
        reason: '没点过就不该生效',
      );

      final bodyOnlyBefore = bodyOnly(tester);
      // ignore: avoid_print
      print('DEVICE_VERIFY[auto-format] before="$bodyOnlyBefore"');

      // 第一次点击 → 排版
      await tester.tap(toggle);
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)),
      );
      final formatted = bodyOnly(tester);
      // ignore: avoid_print
      print('DEVICE_VERIFY[auto-format] formatted="$formatted" '
          'flag=${StorageService.instance.isAutoFormat('af_toggle')}');
      expect(StorageService.instance.isAutoFormat('af_toggle'), isTrue,
          reason: '点一次应当开启排版并落盘');
      expect(formatted, isNot(bodyOnlyBefore), reason: '排版后正文形态应当变化');

      // 第二次点击 → 恢复原排版
      await tester.tap(find.byKey(ReaderPage.autoFormatKey));
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)),
      );
      // ignore: avoid_print
      print('DEVICE_VERIFY[auto-format] restored="${bodyText(tester)}" '
          'flag=${StorageService.instance.isAutoFormat('af_toggle')}');
      expect(StorageService.instance.isAutoFormat('af_toggle'), isFalse,
          reason: '再点一次应当恢复原排版并落盘');
      expect(bodyOnly(tester), bodyOnlyBefore, reason: '恢复后应当回到原来的正文形态');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
    } finally {
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.delete(recursive: true);
        } catch (_) {}
      });
    }
  });

  testWidgets('排版后退出再进入：回到同一句（不会跳回开头）', (tester) async {
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('af3'));
    final file = makePdf(dir!);
    Document make() => Document(
          id: 'af_return',
          title: '返回位置',
          path: file.path,
          type: DocumentType.pdf,
          importedAt: DateTime(2024),
        );

    try {
      await openReader(tester, make());
      await switchToTextMode(tester);
      expect(find.byKey(ReaderPage.autoFormatKey), findsOneWidget);

      // 打开自动排版
      await tester.tap(find.byKey(ReaderPage.autoFormatKey));
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)),
      );
      expect(StorageService.instance.isAutoFormat('af_return'), isTrue);

      // 读到第 3 页中间某句（重排后每页 1 段，所以这是文档后半部分）
      TtsManager.instance.speakFrom(2, 0, 0);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      final before = TtsManager.instance.cursor;
      // ignore: avoid_print
      print('DEVICE_VERIFY[af-return] before=$before');

      // 退出（走真实的 dispose：它会把停留位置与排版选择写回）
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 800)),
      );
      await TtsManager.instance.stop();

      // 重进：排版选择仍在，位置也要回到同一句
      await openReader(tester, make());
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final after = TtsManager.instance.cursor;
      // ignore: avoid_print
      print('DEVICE_VERIFY[af-return] after=$after '
          'autoFormat=${StorageService.instance.isAutoFormat('af_return')}');

      expect(StorageService.instance.isAutoFormat('af_return'), isTrue,
          reason: '排版选择要保留');
      expect(after, before,
          reason: '重进要回到排版后的同一句（旧实现会跳回开头/错位）');
      // 明确不是「回到了开头」——那正是这个 bug 的表现
      expect(after, isNot((0, 0, 0)), reason: '不该跳回文档开头');
      expect(TtsManager.instance.activeDocumentId, 'af_return');
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

  testWidgets('退出重进保持排版选择（开着就还是开着）', (tester) async {
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('af2'));
    final file = makePdf(dir!);
    Document make() => Document(
          id: 'af_persist',
          title: '排版固化',
          path: file.path,
          type: DocumentType.pdf,
          importedAt: DateTime(2024),
        );

    try {
      // 先手动把选择设成「开着」，模拟上次退出时的状态
      await StorageService.instance.setAutoFormat('af_persist', true);

      await openReader(tester, make());
      await switchToTextMode(tester);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // ignore: avoid_print
      print('DEVICE_VERIFY[auto-format] reopen body="${bodyText(tester)}" '
          'flag=${StorageService.instance.isAutoFormat('af_persist')}');
      expect(StorageService.instance.isAutoFormat('af_persist'), isTrue,
          reason: '重进后选择仍在（不被重置）');

      // 按钮应当显示为「已选中」状态（再点一次就是恢复原排版）
      final toggle = tester.widget<IconButton>(
        find.byKey(ReaderPage.autoFormatKey),
      );
      expect(toggle.isSelected, isTrue,
          reason: '排版生效时按钮应当是选中态，提示再点一次可恢复');

      // 关掉 → 重进应当是关的
      await StorageService.instance.setAutoFormat('af_persist', false);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      await openReader(tester, make());
      await switchToTextMode(tester);
      // ignore: avoid_print
      print('DEVICE_VERIFY[auto-format] reopen-off body="${bodyText(tester)}" '
          'flag=${StorageService.instance.isAutoFormat('af_persist')}');
      expect(StorageService.instance.isAutoFormat('af_persist'), isFalse);
      final toggle2 = tester.widget<IconButton>(
        find.byKey(ReaderPage.autoFormatKey),
      );
      expect(toggle2.isSelected, isFalse, reason: '关掉后按钮不再选中');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
    } finally {
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.delete(recursive: true);
        } catch (_) {}
      });
    }
  });
}

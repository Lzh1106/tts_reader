import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 分页版面的核心行为：
/// 1. **一屏一页**：页面列表按「每页 N 段」切，翻页整页替换；
/// 2. **读完本页才翻页**：光标在本页内部推进时绝不翻页；
/// 3. **不快速翻页**：只有「读完当前页最后一句」才往后翻一页，
///    一页最多翻一次 —— 这是用户反复强调不能出现的问题。
void main() {
  testWidgets('分页版面：左右滑动 / 按钮都能翻页，且翻页后内容整页替换', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    await StorageService.instance.setParagraphsPerPage(10);

    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('pg'));
    // 5 章 × 30 段，每页 10 段 → 每章 3 页、共 15 页
    final buffer = StringBuffer();
    for (var c = 0; c < 5; c++) {
      buffer.writeln('第 $c 章标题');
      for (var p = 0; p < 30; p++) {
        buffer.writeln('第 $c 章第 $p 段正文。第二句在这里。');
        buffer.writeln();
      }
    }
    final file = File('${dir!.path}/pg.txt')..writeAsStringSync(buffer.toString());
    final document = Document(
      id: 'pg',
      title: '分页验证',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime(2024),
    );

    try {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1500)),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      String pageLabel() {
        for (final element in find.byType(Text).evaluate()) {
          final data = (element.widget as Text).data;
          if (data != null && data.startsWith('第 ') && data.contains('/')) {
            return data;
          }
        }
        return '';
      }

      // 首页：第 1 页，且显示本章标题 + 前 10 段
      expect(find.byKey(ReaderPage.pageViewKey), findsOneWidget);
      expect(pageLabel(), startsWith('第 1/'), reason: '刚打开应当在第 1 页');
      expect(find.textContaining('第 0 章标题'), findsWidgets, reason: '本章首页要显示章节标题');
      expect(find.textContaining('第 0 章第 0 段正文。'), findsWidgets);
      expect(find.textContaining('第 0 章第 10 段正文。'), findsNothing,
          reason: '第 11 段属于下一页，不该出现在本页');

      // 用「下一页」按钮翻页
      await tester.tap(find.byKey(ReaderPage.nextPageKey));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(pageLabel(), startsWith('第 2/'), reason: '按钮应当翻到第 2 页');
      expect(find.textContaining('第 0 章第 10 段正文。'), findsWidgets,
          reason: '第 2 页应当显示第 11~20 段');
      expect(find.textContaining('第 0 章第 0 段正文。'), findsNothing,
          reason: '翻页后上一页的内容整页替换掉');

      // 左右滑动也能翻页
      final horizontal = find.byWidgetPredicate(
        (widget) => widget is Scrollable && widget.axis == Axis.horizontal,
      );
      expect(horizontal, findsOneWidget, reason: '分页版面应当是横向 PageView');
      await tester.drag(horizontal, const Offset(-600, 0));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(pageLabel(), startsWith('第 3/'), reason: '左滑应当翻到下一页');

      // 「上一页」回去
      await tester.tap(find.byKey(ReaderPage.previousPageKey));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(pageLabel(), startsWith('第 2/'), reason: '「上一页」应当回到第 2 页');

      // 第 1 页时「上一页」禁用
      await tester.tap(find.byKey(ReaderPage.previousPageKey));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(pageLabel(), startsWith('第 1/'));
      expect(
        tester.widget<IconButton>(find.byKey(ReaderPage.previousPageKey)).onPressed,
        isNull,
        reason: '第一页时「上一页」应当禁用',
      );
    } finally {
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

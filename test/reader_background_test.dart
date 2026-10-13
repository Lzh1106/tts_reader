import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/reader_style.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 阅读底色必须真的显示出来。
///
/// 踩过的坑：分页版面的每一页 `DecoratedBox` 硬写了 `scheme.surface`，
/// 把外层的阅读底色整个盖住 —— 用户选纸白 / 羊皮纸 / 护眼绿 / 夜间都没反应。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    TtsManager.instance.resetSessionForTest();
  });

  tearDown(() {
    TtsManager.instance.resetSessionForTest();
  });

  Future<(Directory, Document)> makeBook(WidgetTester tester, String tag) async {
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp(tag));
    final file = File('${dir!.path}/$tag.txt')
      ..writeAsStringSync('第一段第一句。第一段第二句。\n\n第二段第一句。');
    return (
      dir,
      Document(
        id: tag,
        title: tag,
        path: file.path,
        type: DocumentType.txt,
        importedAt: DateTime(2024),
      ),
    );
  }

  /// 分页页面（reader-page-0）实际用的底色
  Color? pageColor(WidgetTester tester) {
    final finder = find.byKey(const ValueKey<String>('reader-page-0'));
    if (finder.evaluate().isEmpty) return null;
    // 页面根部是 DecoratedBox，往外找它
    final box = find
        .ancestor(of: finder, matching: find.byType(DecoratedBox))
        .evaluate();
    for (final element in box) {
      final widget = element.widget as DecoratedBox;
      final decoration = widget.decoration;
      if (decoration is BoxDecoration && decoration.color != null) {
        return decoration.color;
      }
    }
    return null;
  }

  testWidgets('选了阅读底色：分页页面用的就是该底色，而不是主题表面色', (tester) async {
    final (dir, document) = await makeBook(tester, 'bg');
    try {
      await StorageService.instance
          .setReaderStyle(ReaderStyle.defaults.copyWith(theme: ReadingTheme.sepia));
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1500)),
      );
      await tester.pump();
      await tester.pump();

      final color = pageColor(tester);
      // ignore: avoid_print
      print('DEVICE_VERIFY[bg] sepia=${ReadingTheme.sepia.background} '
          'pageColor=$color');
      expect(ReadingTheme.sepia.background, isNotNull);
      expect(color, ReadingTheme.sepia.background,
          reason: '页面底色应当是羊皮纸（不能被 scheme.surface 盖住）');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) dir.delete(recursive: true);
        } catch (_) {}
      });
    }
  });

  testWidgets('每种应有底色的阅读主题都能落到页面上', (tester) async {
    final (dir, document) = await makeBook(tester, 'bgall');
    try {
      for (final theme in ReadingTheme.values) {
        if (theme.background == null) continue; // 「跟随主题」交给主题，不参与
        await StorageService.instance
            .setReaderStyle(ReaderStyle.defaults.copyWith(theme: theme));
        await tester.pumpWidget(
          MaterialApp(home: ReaderPage(document: document)),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1500)),
        );
        await tester.pump();
        await tester.pump();
        final color = pageColor(tester);
        // ignore: avoid_print
        print('DEVICE_VERIFY[bg-all] ${theme.label} expect=${theme.background} '
            'actual=$color');
        expect(color, theme.background, reason: '${theme.label} 底色应当生效');
      }
    } finally {
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

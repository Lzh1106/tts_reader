import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/document_service.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 设备层：**真实文档**（《共产主义ABC》PDF / 《国家与革命》EPUB）
/// 能否被打开、渲染、朗读，以及封面是否生成。
///
/// 文档由用例前推到设备的候选目录（见 [candidates]）：
/// 应用在 Android 13+ 上**读不到** `/sdcard/Download`（分区存储），
/// 所以优先用 `adb push` 到 `/data/local/tmp`（adb shell 可读，应用也能读）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 候选路径：谁在就用谁
  Future<String?> locate(String name) async {
    final dirs = <String>[
      '/data/local/tmp',
      '/sdcard/Android/data/com.example.tts_reader/files',
      '/sdcard/Download',
    ];
    // 再加应用私有目录（用 path_provider 拿到，测试里也能访问）
    try {
      final base = await getApplicationDocumentsDirectory();
      dirs.insert(0, base.path);
      dirs.insert(1, '${base.path}/test_assets');
    } catch (_) {
      // 拿不到就只用固定路径
    }
    for (final dir in dirs) {
      final file = File('$dir/$name');
      if (file.existsSync()) return file.path;
    }
    return null;
  }

  Future<File?> adopt(String name) async {
    final path = await locate(name);
    if (path == null) return null;
    final dir = await getApplicationDocumentsDirectory();
    final dst = File('${dir.path}/books/$name');
    await dst.parent.create(recursive: true);
    // 同路径就不用复制
    if (File(path).absolute.path == dst.absolute.path) return dst;
    await File(path).copy(dst.path);
    return dst;
  }

  testWidgets('真实 PDF（319 页）能解析、能生成封面', (tester) async {
    final file = await adopt('abc.pdf');
    expect(file, isNotNull, reason: '需要先把 abc.pdf 推到 /sdcard/Download');
    final document = Document(
      id: 'dev_abc',
      title: '共产主义ABC',
      path: file!.path,
      type: DocumentType.pdf,
      importedAt: DateTime(2024),
    );
    await StorageService.instance.init();

    final result = await DocumentService.parse(document);
    // ignore: avoid_print
    print('DEVICE_VERIFY[dev-abc-parse] chapters=${result.document.chapters.length} '
        'paras=${result.document.paragraphCount} chars=${result.textCharCount} '
        'pageCount=${result.pageCount} lines=${result.pdfLines?.length} '
        'size=${result.fileSize} hasTextLayer=${result.hasTextLayer}');
    expect(result.document.chapters, isNotEmpty);
    expect(result.pageCount, greaterThan(100), reason: '这是一本 300+ 页的书');

    final dir = await getApplicationDocumentsDirectory();
    final cover = await DocumentService.extractCover(
      document,
      '${dir.path}/covers/dev_abc.jpg',
    );
    final coverFile = File('${dir.path}/covers/dev_abc.jpg');
    // ignore: avoid_print
    print('DEVICE_VERIFY[dev-abc-cover] path=$cover '
        'bytes=${coverFile.existsSync() ? coverFile.lengthSync() : 0}');
    expect(cover, isNotNull, reason: 'PDF 应当拿到封面（默认样式）');
  });

  testWidgets('真实 PDF 能在阅读页打开（原版式或文本模式都不报错）', (tester) async {
    final file = await adopt('abc.pdf');
    expect(file, isNotNull);
    await StorageService.instance.init();
    final tts = TtsManager.instance;
    await tts.init();
    await tts.stop();

    final document = Document(
      id: 'dev_abc_reader',
      title: '共产主义ABC',
      path: file!.path,
      type: DocumentType.pdf,
      importedAt: DateTime(2024),
    );

    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
    // 319 页中文 PDF 解析很慢（真机实测 30s+）：等到出现任一阅读视图为止。
    // 循环里同步盯着进度文案，跑满就打印出来便于判断卡在哪一步。
    String progress = '';
    for (var i = 0; i < 240; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump();
      for (final element in find.byType(Text).evaluate()) {
        final data = (element.widget as Text).data;
        if (data != null && data.contains('%')) progress = data;
      }
      if (find.byKey(ReaderPage.pageViewKey).evaluate().isNotEmpty) break;
      if (find.byType(SfPdfViewer).evaluate().isNotEmpty) break;
    }

    final hasPager = find.byKey(ReaderPage.pageViewKey).evaluate().isNotEmpty;
    final hasViewer = find.byType(SfPdfViewer).evaluate().isNotEmpty;
    final texts = <String>[];
    for (final element in find.byType(Text).evaluate()) {
      final data = (element.widget as Text).data;
      if (data != null && data.isNotEmpty) texts.add(data);
    }
    // ignore: avoid_print
    print('DEVICE_VERIFY[dev-abc-reader] 文本模式=$hasPager 原版式=$hasViewer '
        'progress="$progress" texts=$texts');
    expect(hasPager || hasViewer, isTrue, reason: '应当进入阅读界面（任一种模式）');
    // 不该停在错误提示上
    expect(find.textContaining('打开 PDF 失败'), findsNothing,
        reason: '真实 PDF 不该打不开');
    await tts.stop();
  });

  testWidgets('真实 EPUB 能解析、能抽封面、能进阅读页', (tester) async {
    final file = await adopt('state.epub');
    expect(file, isNotNull, reason: '需要先把 state.epub 推到 /sdcard/Download');
    await StorageService.instance.init();
    final tts = TtsManager.instance;
    await tts.init();
    await tts.stop();

    final document = Document(
      id: 'dev_state',
      title: '国家与革命',
      path: file!.path,
      type: DocumentType.epub,
      importedAt: DateTime(2024),
    );

    final result = await DocumentService.parse(document);
    // ignore: avoid_print
    print('DEVICE_VERIFY[dev-state-parse] chapters=${result.document.chapters.length} '
        'paras=${result.document.paragraphCount} chars=${result.textCharCount}');
    expect(result.document.chapters, isNotEmpty);

    final dir = await getApplicationDocumentsDirectory();
    final cover = await DocumentService.extractCover(
      document,
      '${dir.path}/covers/dev_state.jpg',
    );
    final coverFile = File('${dir.path}/covers/dev_state.jpg');
    // ignore: avoid_print
    print('DEVICE_VERIFY[dev-state-cover] path=$cover '
        'bytes=${coverFile.existsSync() ? coverFile.lengthSync() : 0}');
    expect(cover, isNotNull);

    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump();
      if (find.byKey(ReaderPage.pageViewKey).evaluate().isNotEmpty) break;
    }
    // ignore: avoid_print
    print('DEVICE_VERIFY[dev-state-reader] '
        '分页=${find.byKey(ReaderPage.pageViewKey).evaluate().length}');
    expect(find.byKey(ReaderPage.pageViewKey), findsOneWidget,
        reason: 'EPUB 应当进入分页阅读界面');
    await tts.stop();
  });
}

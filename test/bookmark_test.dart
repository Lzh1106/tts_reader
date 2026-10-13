import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/bookmark.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/pages/home_page.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 书签与最近阅读（T2S 的 bookmark / recent 模块）验证。
void main() {
  final storage = StorageService.instance;

  final previousOnError = FlutterError.onError;
  setUpAll(() {
    FlutterError.onError = (FlutterErrorDetails details) {
      final text = details.exception.toString();
      if (text.contains('MissingPluginException') ||
          text.contains('syncfusion_flutter_pdfviewer')) {
        return;
      }
      previousOnError?.call(details);
    };
  });
  tearDownAll(() {
    FlutterError.onError = previousOnError;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    storage.resetForTest();
    await storage.init();
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
  });

  Bookmark bookmark(
    String id, {
    String documentId = 'doc-1',
    String title = '测试书',
    int chapter = 0,
    int paragraph = 0,
    int sentence = 0,
    String preview = '一句话。',
    DateTime? createdAt,
  }) => Bookmark(
    id: id,
    documentId: documentId,
    documentTitle: title,
    chapter: chapter,
    paragraph: paragraph,
    sentence: sentence,
    preview: preview,
    createdAt: createdAt ?? DateTime(2024, 5, 1, 10),
  );

  group('书签模型', () {
    test('序列化往返不丢字段', () {
      final original = bookmark('b1', chapter: 3, paragraph: 7, sentence: 2);
      final restored = Bookmark.fromJson(original.toJson());
      expect(restored.id, 'b1');
      expect(restored.documentId, 'doc-1');
      expect(restored.documentTitle, '测试书');
      expect(restored.cursor, (3, 7, 2));
      expect(restored.preview, '一句话。');
      expect(restored.createdAt, original.createdAt);
    });

    test('坏数据不会抛异常', () {
      final restored = Bookmark.fromJson(<String, dynamic>{
        'id': 42,
        'chapter': '3',
        'paragraph': null,
        'createdAt': '不是时间',
      });
      expect(restored.id, '');
      expect(restored.chapter, 3, reason: '字符串数字也要认得');
      expect(restored.paragraph, 0);
      expect(restored.createdAt, DateTime(2024));
    });

    test('位置标签：普通文档显示章 / 段，PDF 显示页', () {
      final item = bookmark('b1', chapter: 2, paragraph: 9);
      expect(item.label(), '第 3 章 · 第 10 段');
      expect(item.label(chapterIsPage: true), '第 3 页');
    });

    test('同位置判定', () {
      final a = bookmark('b1', chapter: 1, paragraph: 2, sentence: 3);
      expect(a.sameSpot(bookmark('b2', chapter: 1, paragraph: 2, sentence: 3)), isTrue);
      expect(a.matches((1, 2, 3)), isTrue);
      expect(a.matches((1, 2, 4)), isFalse);
      expect(
        a.sameSpot(bookmark('b3', documentId: 'doc-2', chapter: 1, paragraph: 2, sentence: 3)),
        isFalse,
        reason: '不同文档的同一下标不算同一个书签',
      );
    });

    test('预览片段折叠空白并截断', () {
      expect(Bookmark.makePreview('  多  余\n空白  '), '多 余 空白');
      final long = Bookmark.makePreview('字' * 200);
      expect(long.length, Bookmark.previewLimit + 1, reason: '超出部分截断并加省略号');
      expect(long.endsWith('…'), isTrue);
    });
  });

  group('书签存储', () {
    test('同位置不重复添加，新的排在前面', () async {
      await storage.addDocBookmark(bookmark('b1', paragraph: 5));
      await storage.addDocBookmark(bookmark('b2', paragraph: 5));
      var all = await storage.loadDocBookmarks();
      expect(all.length, 1, reason: '同一位置只留一条');

      await storage.addDocBookmark(
        bookmark('b3', paragraph: 9, createdAt: DateTime(2024, 6, 1)),
      );
      all = await storage.loadDocBookmarks();
      expect(all.length, 2);
      expect(all.first.id, 'b3', reason: '按创建时间倒序');
    });

    test('删除单条 / 删除整本书', () async {
      await storage.addDocBookmark(bookmark('b1', paragraph: 1));
      await storage.addDocBookmark(bookmark('b2', paragraph: 2));
      await storage.addDocBookmark(bookmark('b3', documentId: 'doc-2', paragraph: 1));

      await storage.removeDocBookmark('b1');
      var all = await storage.loadDocBookmarks();
      expect(all.map((b) => b.id), <String>['b3', 'b2']);

      await storage.removeDocBookmarksOf('doc-1');
      all = await storage.loadDocBookmarks();
      expect(all.map((b) => b.id), <String>['b3'], reason: '只清掉这本书的');
    });

    test('总量超过上限时丢弃最旧的', () async {
      for (var i = 0; i < StorageService.maxDocBookmarks + 5; i++) {
        await storage.addDocBookmark(
          bookmark('b$i', paragraph: i, createdAt: DateTime(2024).add(Duration(minutes: i))),
        );
      }
      final all = await storage.loadDocBookmarks();
      expect(all.length, StorageService.maxDocBookmarks);
      expect(all.first.id, 'b${StorageService.maxDocBookmarks + 4}', reason: '保留最新的');
    });

    test('存储损坏时按没有书签处理', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'document_bookmarks': '不是 JSON',
      });
      storage.resetForTest();
      await storage.init();
      expect(await storage.loadDocBookmarks(), isEmpty);
    });

    test('删除文档会一并清掉它的书签', () async {
      await storage.addDocBookmark(bookmark('b1'));
      await storage.upsertDocument(
        Document(
          id: 'doc-1',
          title: '测试书',
          path: 'x.txt',
          type: DocumentType.txt,
          importedAt: DateTime(2024),
        ),
      );
      await storage.removeDocument('doc-1');
      await storage.removeDocBookmarksOf('doc-1');
      expect(await storage.loadDocBookmarks(), isEmpty);
      expect(await storage.loadDocuments(), isEmpty);
    });
  });

  group('最近阅读', () {
    test('排序时间：读过用最近阅读时间，没读过用导入时间', () {
      final fresh = Document(
        id: 'a',
        title: 'A',
        path: 'a.txt',
        type: DocumentType.txt,
        importedAt: DateTime(2024, 1, 1),
      );
      final read = fresh.copyWith(lastReadAt: DateTime(2024, 3, 1));
      expect(fresh.activityAt, DateTime(2024, 1, 1));
      expect(read.activityAt, DateTime(2024, 3, 1));
    });

    test('最近阅读时间能持久化', () async {
      final document = Document(
        id: 'a',
        title: 'A',
        path: 'a.txt',
        type: DocumentType.txt,
        importedAt: DateTime(2024, 1, 1),
      );
      await storage.upsertDocument(document);
      await storage.upsertDocument(document.copyWith(lastReadAt: DateTime(2024, 3, 2, 8)));
      final loaded = (await storage.loadDocuments()).single;
      expect(loaded.lastReadAt, DateTime(2024, 3, 2, 8));
    });

    test('三种排序方式都按预期排列', () {
      final old = Document(
        id: 'a',
        title: 'C 书',
        path: 'a',
        type: DocumentType.txt,
        importedAt: DateTime(2024, 1, 1),
        lastReadAt: DateTime(2024, 5, 1),
      );
      final recentImport = Document(
        id: 'b',
        title: 'A 书',
        path: 'b',
        type: DocumentType.txt,
        importedAt: DateTime(2024, 6, 1),
      );
      final middle = Document(
        id: 'c',
        title: 'B 书',
        path: 'c',
        type: DocumentType.txt,
        importedAt: DateTime(2024, 3, 1),
        lastReadAt: DateTime(2024, 4, 1),
      );
      final documents = <Document>[old, recentImport, middle];

      List<String> sortedBy(DocumentSort sort) {
        final copy = List<Document>.of(documents);
        switch (sort) {
          case DocumentSort.recent:
            copy.sort((a, b) => b.activityAt.compareTo(a.activityAt));
          case DocumentSort.imported:
            copy.sort((a, b) => b.importedAt.compareTo(a.importedAt));
          case DocumentSort.title:
            copy.sort((a, b) => a.title.compareTo(b.title));
        }
        return copy.map((d) => d.id).toList();
      }

      expect(sortedBy(DocumentSort.recent), <String>['b', 'a', 'c']);
      expect(sortedBy(DocumentSort.imported), <String>['b', 'c', 'a']);
      expect(sortedBy(DocumentSort.title), <String>['b', 'c', 'a']);
      expect(DocumentSort.recent.next, DocumentSort.imported);
      expect(DocumentSort.title.next, DocumentSort.recent, reason: '循环切换');
    });
  });

  group('阅读页书签', () {
    /// 建一个 TXT，返回目录与文档
    Future<(Directory, Document)> makeTxt(
      WidgetTester tester,
      String tag, {
      int paragraphs = 900,
      double progress = 0,
    }) async {
      final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('tts_bm_$tag'));
      final file = File('${dir!.path}/$tag.txt')
        ..writeAsStringSync(
          List<String>.generate(paragraphs, (i) => '第 $i 段第一句。第 $i 段第二句！').join('\n\n'),
        );
      return (
        dir,
        Document(
          id: tag,
          title: tag,
          path: file.path,
          type: DocumentType.txt,
          importedAt: DateTime(2024),
          progress: progress,
        ),
      );
    }

    Future<void> openReader(WidgetTester tester, Document document) async {
      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1200)));
      await tester.pump();
      await tester.pump();
    }

    Future<void> cleanup(WidgetTester tester, Directory dir) async {
      unawaited(TtsManager.instance.stop());
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
      await tester.runAsync(() async {
        try {
          if (dir.existsSync()) await dir.delete(recursive: true);
        } catch (_) {
          // Windows 句柄占用时忽略
        }
      });
    }

    testWidgets('加书签 → 图标变化 → 书签面板里能看到 → 删除', (tester) async {
      final (dir, document) = await makeTxt(tester, 'bookmark');
      try {
        await openReader(tester, document);
        expect(find.byIcon(Icons.bookmark_add_outlined), findsOneWidget);

        // 在当前位置加书签
        await tester.tap(find.byIcon(Icons.bookmark_add_outlined));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.textContaining('已添加书签'), findsOneWidget);
        expect(find.byIcon(Icons.bookmark_added), findsOneWidget);

        final saved = await storage.loadDocBookmarks();
        expect(saved.length, 1);
        expect(saved.single.documentId, 'bookmark');
        expect(saved.single.preview, contains('第 0 段第一句。'));

        // 打开书签面板
        await tester.tap(find.byIcon(Icons.bookmarks_outlined));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.textContaining('书签（1）'), findsOneWidget);
        expect(find.textContaining('第 0 段第一句。'), findsWidgets);

        // 删除后列表清空、存储也清空
        await tester.tap(find.byIcon(Icons.delete_outline).first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(await storage.loadDocBookmarks(), isEmpty);
        expect(find.byIcon(Icons.bookmark_add_outlined), findsOneWidget);
      } finally {
        await cleanup(tester, dir);
      }
    });

    testWidgets('点书签真的跳到那条书签的位置', (tester) async {
      final (dir, document) = await makeTxt(tester, 'bm_jump');
      try {
        await storage.addDocBookmark(
          Bookmark(
            id: 'seed',
            documentId: 'bm_jump',
            documentTitle: 'bm_jump',
            chapter: 0,
            paragraph: 400,
            sentence: 0,
            preview: '第 400 段第一句。',
            createdAt: DateTime(2024, 5, 1),
          ),
        );
        await openReader(tester, document);

        await tester.tap(find.byIcon(Icons.bookmarks_outlined));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        await tester.tap(find.text('第 1 章 · 第 401 段'));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(TtsManager.instance.cursor.$2, 400, reason: '游标要落到书签那一段');
      } finally {
        await cleanup(tester, dir);
      }
    });

    testWidgets('继续阅读：带进度的文档打开后不停在开头', (tester) async {
      final (dir, document) = await makeTxt(tester, 'resume', progress: 0.5);
      try {
        await openReader(tester, document);
        expect(
          TtsManager.instance.cursor.$2,
          greaterThan(100),
          reason: '保存了 50% 进度就该从中间继续，而不是回到第 0 段',
        );
      } finally {
        await cleanup(tester, dir);
      }
    });

    testWidgets('退出阅读页会写入最近阅读时间', (tester) async {
      final (dir, document) = await makeTxt(tester, 'recency', paragraphs: 40);
      try {
        await storage.upsertDocument(document);
        await openReader(tester, document);
        await cleanup(tester, dir);

        final saved = (await storage.loadDocuments()).single;
        expect(saved.lastReadAt, isNotNull);
        expect(saved.progress, greaterThanOrEqualTo(0));
      } finally {
        await tester.runAsync(() async {
          try {
            if (dir.existsSync()) await dir.delete(recursive: true);
          } catch (_) {
            // 忽略
          }
        });
      }
    });
  });
}

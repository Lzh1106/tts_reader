import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/pages/toc_sheet.dart';

/// 目录面板的 widget 测试：原书自带目录、层级缩进、跳转结果、两种视图切换。
void main() {
  StructuredDocument build({
    List<DocumentOutlineEntry> outline = const <DocumentOutlineEntry>[],
    bool chapterIsPage = false,
    int chapters = 4,
  }) => StructuredDocument(
    chapters: <Chapter>[
      for (var c = 0; c < chapters; c++)
        Chapter(
          // PDF 的章名就是「第 N 页」（解析时由目录标题或页号决定）
          title: chapterIsPage ? '第 ${c + 1} 页' : '第 ${c + 1} 章',
          paragraphs: <Paragraph>[
            for (var p = 0; p < 6; p++)
              Paragraph(sentences: <Sentence>[Sentence('第 $c 章第 $p 段。')]),
          ],
        ),
    ],
    chapterIsPage: chapterIsPage,
    outline: outline,
  );

  Future<(int, int)?> pumpSheet(
    WidgetTester tester,
    StructuredDocument document, {
    (int, int, int) cursor = (0, 0, 0),
    int perPage = 3,
  }) async {
    (int, int)? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showModalBottomSheet<(int, int)>(
                    context: context,
                    builder: (_) => TocSheet(
                      document: document,
                      cursor: cursor,
                      paragraphsPerPage: perPage,
                    ),
                  );
                },
                child: const Text('打开目录'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开目录'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('没有自带目录时只显示章节列表', (tester) async {
    await pumpSheet(tester, build());
    expect(find.text('第 1 章'), findsOneWidget);
    expect(find.textContaining('6 段'), findsWidgets);
    // 没有目录就不该出现视图切换
    expect(find.byType(SegmentedButton<bool>), findsNothing);
  });

  testWidgets('有自带目录时默认显示目录，层级缩进生效', (tester) async {
    final document = build(
      outline: const <DocumentOutlineEntry>[
        DocumentOutlineEntry(title: '第一章 出发', chapter: 0),
        DocumentOutlineEntry(title: '第一节 雨', chapter: 1, depth: 1),
        DocumentOutlineEntry(title: '第二章 路上', chapter: 2),
      ],
    );
    await pumpSheet(tester, document);

    expect(find.byType(SegmentedButton<bool>), findsOneWidget);
    expect(find.text('第一章 出发'), findsOneWidget);
    expect(find.text('第一节 雨'), findsOneWidget);
    // 副标题给出对应章号
    expect(find.text('第 2 章'), findsOneWidget);

    // 层级缩进：深度 1 的条目左边距更大
    final top = tester.widget<ListTile>(
      find.ancestor(of: find.text('第一章 出发'), matching: find.byType(ListTile)),
    );
    final nested = tester.widget<ListTile>(
      find.ancestor(of: find.text('第一节 雨'), matching: find.byType(ListTile)),
    );
    expect(
      (nested.contentPadding! as EdgeInsets).left,
      greaterThan((top.contentPadding! as EdgeInsets).left),
    );
  });

  testWidgets('点目录条目返回对应章节，关掉面板', (tester) async {
    final document = build(
      outline: const <DocumentOutlineEntry>[
        DocumentOutlineEntry(title: '第一章 出发', chapter: 0),
        DocumentOutlineEntry(title: '第三章 归来', chapter: 2, paragraph: 4),
      ],
    );
    (int, int)? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showModalBottomSheet<(int, int)>(
                    context: context,
                    builder: (_) => TocSheet(document: document, cursor: (0, 0, 0), paragraphsPerPage: 3),
                  );
                },
                child: const Text('打开目录'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开目录'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('第三章 归来'));
    await tester.pumpAndSettle();

    expect(result, (2, 4), reason: '应当带回该目录条目的章与段');
    expect(find.text('第三章 归来'), findsNothing, reason: '面板应当关闭');
  });

  testWidgets('切到「章节」视图看章节列表，再切回目录', (tester) async {
    final document = build(
      outline: const <DocumentOutlineEntry>[
        DocumentOutlineEntry(title: '第一章 出发', chapter: 0),
        DocumentOutlineEntry(title: '第二章 路上', chapter: 1),
      ],
    );
    await pumpSheet(tester, document);
    expect(find.text('第一章 出发'), findsOneWidget);

    await tester.tap(find.text('章节'));
    await tester.pumpAndSettle();
    expect(find.text('第 1 章'), findsOneWidget);
    expect(find.text('第一章 出发'), findsNothing);

    await tester.tap(find.textContaining('原书目录'));
    await tester.pumpAndSettle();
    expect(find.text('第一章 出发'), findsOneWidget);
  });

  testWidgets('PDF：目录条目按页显示，切换到全部页码', (tester) async {
    final document = build(
      chapterIsPage: true,
      outline: const <DocumentOutlineEntry>[
        DocumentOutlineEntry(title: 'Chapter One', chapter: 0),
        DocumentOutlineEntry(title: 'Chapter Two', chapter: 2),
      ],
    );
    await pumpSheet(tester, document);
    expect(find.text('Chapter One'), findsOneWidget);
    expect(find.text('第 1 页'), findsOneWidget, reason: '目录条目显示对应页码');

    await tester.tap(find.text('全部页码'));
    await tester.pumpAndSettle();
    // 先确认真的切到了页码视图（目录条目应当消失）
    expect(find.text('Chapter One'), findsNothing, reason: '切到页码视图后不该再显示目录条目');
    // 页码视图列出各页（当前页的标题带「（当前）」后缀）；
    // 模态面板高度有限，ListView 只构建可见项，所以断言靠前的几页
    expect(find.textContaining('第 1 页'), findsWidgets);
    expect(find.textContaining('第 2 页'), findsWidgets);
    expect(find.textContaining('第 3 页'), findsWidgets);
  });

  testWidgets('搜索：过滤目录条目与章节', (tester) async {
    // 搜索框只在「内容够多」时出现（≥20 章或 ≥20 条目录），所以这里造 24 章
    final document = build(
      chapters: 24,
      outline: const <DocumentOutlineEntry>[
        DocumentOutlineEntry(title: '第一章 出发', chapter: 0),
        DocumentOutlineEntry(title: '第二章 路上', chapter: 1),
      ],
    );
    await pumpSheet(tester, document);

    await tester.enterText(find.byType(TextField).last, '路上');
    await tester.pumpAndSettle();
    expect(find.text('第二章 路上'), findsOneWidget);
    expect(find.text('第一章 出发'), findsNothing);

    await tester.enterText(find.byType(TextField).last, '不存在的章节');
    await tester.pumpAndSettle();
    expect(find.text('目录里没有匹配的条目'), findsOneWidget);

    // 切到章节视图后，同一个关键字过滤章节列表
    await tester.tap(find.text('章节'));
    await tester.pumpAndSettle();
    expect(find.text('第 1 章'), findsNothing);
    expect(find.text('没有匹配的章节'), findsOneWidget);
  });

  testWidgets('目录条目很少且章节也少时不显示搜索框（避免占地方）', (tester) async {
    await pumpSheet(
      tester,
      build(
        outline: const <DocumentOutlineEntry>[
          DocumentOutlineEntry(title: '第一章', chapter: 0),
          DocumentOutlineEntry(title: '第二章', chapter: 1),
        ],
      ),
    );
    // 只有页码输入框（1 个 TextField），没有搜索框
    expect(find.byType(TextField), findsOneWidget);
  });
}

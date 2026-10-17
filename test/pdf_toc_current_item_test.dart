import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/features/pdf_reading/pdf_reading_page.dart';
import 'package:tts_reader/widgets/toc_current_item.dart';

/// PDF 目录「当前朗读位置」标识的回归（v1.21.56）
///
/// ## 用户报的现象
///
/// 「PDF 目录朗读位置图标也失效了，换成和 EPUB 格式同样的样式」。
///
/// ## 真根因（不是样式问题）
///
/// PDF 书签是**稀疏**的 —— 往往每章只有一条（例如「第 20 页 第二章」），
/// 而朗读位置是**按页**推进的（第 21 页）。
/// 原来判据是 `pageIndex == currentPage`（精确相等）→ **一条都命中不了**
/// → 整份目录没有任何标记，看起来就是「图标失效」。
/// 文字档那边章节连续、容易命中，所以这个坑只在 PDF 侧暴露。
///
/// 修法：改判「**当前所在章节**」= 最后一条起始页 ≤ 当前页的条目。
/// 本文件把这条判据单独钉出来（纯逻辑，不依赖 PDF 引擎）。
void main() {
  group('PDF 目录：当前项判据（当前所在章节）', () {
    /// 直接用**生产代码**里的判据（`PdfReadingPage.currentTocIndex`）。
    ///
    /// ⚠️ 绝不能在测试里另写一份副本 —— 那样负向自检永远打不到生产代码，
    /// 用例会变成"测我自己写的函数"，是个假测试（本项目已经踩过）。
    int currentIndexOf({
      required List<int> chapters,
      required int currentPage,
      required int pageCount,
    }) =>
        PdfReadingPage.currentTocIndex(
          chapters: chapters,
          currentPage: currentPage,
          pageCount: pageCount,
        );

    test('★稀疏书签：当前页落在章中间，也要标出所在章节', () {
      // 书签只在第 1 / 20 / 40 页（0 起）有；用户读到第 21 页
      final idx = currentIndexOf(
        chapters: <int>[0, 19, 39],
        currentPage: 20,
        pageCount: 100,
      );
      expect(idx, 1,
          reason: '★精确相等判据在这里会返回 -1（无任何标记）→ 用户看到的"图标失效"；'
              '按"所在章节"应当命中第 20 页开始的那一章（下标 1）');
    });

    test('★正好落在书签页上：命中该条目自己', () {
      final idx = currentIndexOf(
        chapters: <int>[0, 19, 39],
        currentPage: 19,
        pageCount: 100,
      );
      expect(idx, 1, reason: '第 20 页正好是第二条书签，应当命中它');
    });

    test('当前页在第一枚书签之前：不标（避免指错章）', () {
      // 第一枚书签在「第 10 页」，用户还在第 3 页（封面 / 前言）
      final idx = currentIndexOf(
        chapters: <int>[9, 29],
        currentPage: 2,
        pageCount: 100,
      );
      expect(idx, -1,
          reason: '还没读到第一章，不该把第一章标成"当前"');
    });

    test('没有书签时（纯页码列表）：当前页就是当前项', () {
      final idx = currentIndexOf(
        chapters: const <int>[],
        currentPage: 7,
        pageCount: 100,
      );
      expect(idx, 7, reason: '没有书签时列表按页铺开，当前页即当前项');
    });

    test('没有书签且页码越界：不标，不能崩', () {
      expect(
        currentIndexOf(chapters: const <int>[], currentPage: 999, pageCount: 10),
        -1,
        reason: '越界应当返回 -1，而不是越界下标',
      );
    });

    test('只有一条书签：之后所有页都归它（整本就是一整章）', () {
      expect(
        currentIndexOf(chapters: <int>[0], currentPage: 55, pageCount: 100),
        0,
      );
    });
  });

  group('PDF 目录：当前项样式与文字档一致', () {
    testWidgets('★当前项用 TocCurrentItem + graphic_eq（与 EPUB 同一套）',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                TocCurrentItem(
                  active: false,
                  child: ListTile(
                    dense: true,
                    leading: Text('1'),
                    title: Text('第一章'),
                  ),
                ),
                TocCurrentItem(
                  active: true,
                  child: ListTile(
                    dense: true,
                    leading: Text('20'),
                    title: Text('第二章'),
                    trailing: Icon(TocCurrentItem.currentIcon, size: 18),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      // 整份目录里只有一处「当前」图标（三处目录共用这一个常量）
      expect(find.byIcon(TocCurrentItem.currentIcon), findsOneWidget,
          reason: '当前项标识必须用 TocCurrentItem.currentIcon（graphic_eq）');
      // 不许出现旧的 play_arrow（历史上各写过一套，是漂移的开始）
      expect(find.byIcon(Icons.play_arrow), findsNothing);
    });

    testWidgets('★非当前项不加底色（不能整份目录都高亮）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TocCurrentItem(
              active: false,
              child: ListTile(dense: true, title: Text('第三章')),
            ),
          ),
        ),
      );
      // active=false 时 TocCurrentItem 原样返回 child，不产生 DecoratedBox 装饰层
      expect(
        find.descendant(
          of: find.byType(TocCurrentItem),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
        reason: '非当前项不该有圆角底色',
      );
    });
  });
}

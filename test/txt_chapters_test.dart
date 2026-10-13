import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/txt_chapters.dart';

/// TXT 目录解析验证。
///
/// 小说 TXT 的排版五花八门，这里覆盖的是真实会遇到的那些：
/// 一段一行、硬折行、带卷/部、带特殊章节、英文、纯数字编号、
/// 以及「正文里提到第X章」这种绝对不能误判的情况。
void main() {
  List<Chapter> split(String text) =>
      TxtChapterSplitter.split(text, paragraphSplitter: DocumentTextSplitter.splitTextParagraphs);

  group('章标题识别', () {
    test('中文章节：常见写法都认', () {
      for (final title in <String>[
        '第一章 风起',
        '第1章 风起',
        '第 12 章',
        '第一百二十三章 归途',
        '第三十六节 收尾',
        '第十二回 重逢',
        '第二话 相遇',
        '第１２章 全角数字',
        '第两百章 突破',
      ]) {
        expect(TxtChapterSplitter.headingOf(title, line: 0), isNotNull, reason: title);
      }
    });

    test('卷 / 篇 / 部 单独标出来', () {
      final heading = TxtChapterSplitter.headingOf('第三卷 风起云涌', line: 0);
      expect(heading, isNotNull);
      expect(heading!.kind, 'volume');
      expect(heading.number, 3);
    });

    test('特殊章节名', () {
      for (final title in <String>['楔子', '序章', '序言', '番外一', '尾声', '后记', '终章 落幕']) {
        expect(TxtChapterSplitter.headingOf(title, line: 0), isNotNull, reason: title);
      }
    });

    test('英文章节', () {
      final heading = TxtChapterSplitter.headingOf('Chapter 12: The Return', line: 0);
      expect(heading, isNotNull);
      expect(heading!.number, 12);
    });

    test('正文里的「第X章」不会被当成标题', () {
      // 太长
      expect(
        TxtChapterSplitter.headingOf('他翻到第一章的时候已经是深夜了，窗外的雨还在下，桌上那杯茶早就凉透了，'
            '他想起了很多年前的那个夏天，那时候他还不知道后面会发生什么。', line: 0),
        isNull,
      );
      // 带句号 = 正文句子
      expect(TxtChapterSplitter.headingOf('第一章讲的是主角登场。', line: 0), isNull);
      // 问号
      expect(TxtChapterSplitter.headingOf('第三章呢？', line: 0), isNull);
      // 网址
      expect(TxtChapterSplitter.headingOf('https://example.com/第一章', line: 0), isNull);
    });

    test('中文数字解析', () {
      expect(TxtChapterSplitter.parseChineseNumber('12'), 12);
      expect(TxtChapterSplitter.parseChineseNumber('１２'), 12);
      expect(TxtChapterSplitter.parseChineseNumber('一'), 1);
      expect(TxtChapterSplitter.parseChineseNumber('十'), 10);
      expect(TxtChapterSplitter.parseChineseNumber('十二'), 12);
      expect(TxtChapterSplitter.parseChineseNumber('二十'), 20);
      expect(TxtChapterSplitter.parseChineseNumber('一百零三'), 103);
      expect(TxtChapterSplitter.parseChineseNumber('两千零一'), 2001);
      expect(TxtChapterSplitter.parseChineseNumber('一万零一'), 10001);
      expect(TxtChapterSplitter.parseChineseNumber('XII'), 12);
      expect(TxtChapterSplitter.parseChineseNumber('杂乱'), isNull);
      expect(TxtChapterSplitter.parseChineseNumber(''), isNull);
    });
  });

  group('整篇切分', () {
    test('一段一行的小说：章节与段落都对', () {
      final text = <String>[
        '第一章 风起',
        '天还没亮他就出门了。',
        '路上一个人也没有。',
        '',
        '第二章 雨落',
        '雨下了整夜。',
        '他站在门口没动。',
      ].join('\n');
      final chapters = split(text);
      expect(chapters.length, 2);
      expect(chapters[0].title, '第一章 风起');
      expect(chapters[0].paragraphs.length, 2);
      expect(chapters[0].paragraphs.first.text, '天还没亮他就出门了。');
      expect(chapters[0].paragraphs.last.text, '路上一个人也没有。');
      expect(chapters[1].title, '第二章 雨落');
      expect(chapters[1].paragraphs.length, 2);
    });

    test('硬折行的正文会被合并回一段（不按行乱切）', () {
      final text = <String>[
        '第一章 风起',
        '天还没亮他就出门了，路上一个人也没有，',
        '只有风从巷子口吹过来，吹得他缩了缩脖子，',
        '他把领子立起来继续往前走。',
        '第二句。',
        '第二章 雨落',
        '雨下了整夜。',
      ].join('\n');
      final chapters = split(text);
      expect(chapters.length, 2);
      final paragraphs = chapters.first.paragraphs;
      expect(paragraphs.length, 2, reason: '前 3 行是一段（硬折行），最后一行是另一段');
      expect(
        paragraphs.first.text,
        '天还没亮他就出门了，路上一个人也没有，只有风从巷子口吹过来，吹得他缩了缩脖子，他把领子立起来继续往前走。',
      );
      expect(paragraphs.last.text, '第二句。');
    });

    test('第一个标题之前的内容算「开篇」', () {
      final text = <String>[
        '《测试小说》',
        '作者：某人',
        '',
        '第一章 开始',
        '正文一。',
        '第二章 继续',
        '正文二。',
      ].join('\n');
      final chapters = split(text);
      expect(chapters.first.title, TxtChapterSplitter.prologueTitle);
      expect(chapters.first.paragraphs.length, 2);
      expect(chapters[1].title, '第一章 开始');
    });

    test('没有章节标记时仍然是单章「全文」（与旧行为一致）', () {
      final chapters = split('第一段第一句。第一段第二句！\n\n第二段只有一句。');
      expect(chapters.length, 1);
      expect(chapters.single.title, TxtChapterSplitter.wholeTitle);
      expect(chapters.single.paragraphs.length, 2);
    });

    test('只出现一两次「第X章」不足以切章', () {
      final text = <String>[
        '第一章 风起',
        '只有一章的内容，后面两万字都没有标题了。',
        '他继续走。',
        '再走。',
      ].join('\n');
      final chapters = split(text);
      expect(chapters.length, 1);
      expect(chapters.single.title, TxtChapterSplitter.wholeTitle);
    });

    test('标题下面没内容的空章不进目录', () {
      final text = <String>[
        '第一章 有内容',
        '内容一。',
        '第二章 空的',
        '第三章 也有内容',
        '内容三。',
      ].join('\n');
      final chapters = split(text);
      expect(chapters.map((c) => c.title), <String>['第一章 有内容', '第三章 也有内容']);
    });

    test('重复两遍的同一标题只算一次', () {
      final text = <String>[
        '第一章 风起',
        '第一章 风起',
        '内容。',
        '第二章 雨落',
        '内容。',
      ].join('\n');
      final chapters = split(text);
      expect(chapters.length, 2);
      expect(chapters.first.title, '第一章 风起');
    });

    test('纯数字编号：条目太短太少就当成正文列表', () {
      final listLike = <String>[
        '购物清单：',
        '1、苹果',
        '2、牛奶',
        '他看完把纸条塞进口袋。',
      ].join('\n');
      expect(split(listLike).length, 1, reason: '编号条目又短又少，不是章节');

      final threeShort = <String>[
        '待办：',
        '1、写作业',
        '2、买菜',
        '3、取快递',
      ].join('\n');
      expect(split(threeShort).length, 1, reason: '平均每章字数太少，仍然不算章节');
    });

    test('纯数字编号：真的有内容时才切章', () {
      final buffer = StringBuffer();
      for (var i = 1; i <= 5; i++) {
        buffer.writeln('$i、第 $i 节');
        buffer.writeln('这一节讲的是第 $i 件事，${'内容' * 120}。');
      }
      final chapters = split(buffer.toString());
      expect(chapters.length, 5);
      expect(chapters.first.title, '1、第 1 节');
    });

    test('卷 + 章混排：有内容的都进目录，空卷不占位', () {
      final text = <String>[
        '第一卷 少年',
        '第一章 出发',
        '他背上包。',
        '第二章 路上',
        '走了很久。',
        '第二卷 风起',
        '卷首语：这一卷开始起风了。',
        '第三章 归来',
        '他回来了。',
      ].join('\n');
      final chapters = split(text);
      expect(chapters.map((c) => c.title).toList(), <String>[
        '第一章 出发',
        '第二章 路上',
        '第二卷 风起',
        '第三章 归来',
      ]);
    });

    test('几千章的长文也切得动', () {
      final buffer = StringBuffer();
      for (var i = 1; i <= 3000; i++) {
        buffer.writeln('第 $i 章 标题$i');
        buffer.writeln('这是第 $i 章的第一段内容。');
        buffer.writeln('这是第 $i 章的第二段内容。');
      }
      final chapters = split(buffer.toString());
      expect(chapters.length, 3000);
      expect(chapters.last.title, '第 3000 章 标题3000');
      expect(chapters.last.paragraphs.length, 2);
    });
  });
}

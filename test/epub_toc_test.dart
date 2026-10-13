import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/epub_toc.dart';

/// EPUB 目录解析验证（EPUB3 的 nav 文档 + EPUB2 的 NCX）。
///
/// 为什么要单独解析：目录标题通常只写在 nav / NCX 里，
/// 而正文文件的 `<title>` 常常整本书都是同一个书名 —— 直接用它会出现一堆重复章名。
void main() {
  group('EPUB3 nav 文档', () {
    const nav = '''
<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>目录</title></head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>目录</h1>
    <ol>
      <li><a href="Text/ch1.xhtml">第一章 出发</a></li>
      <li><a href="Text/ch2.xhtml">第二章 路上</a>
        <ol>
          <li><a href="Text/ch2.xhtml#sec1">第一节 雨天</a></li>
          <li><a href="Text/ch2.xhtml#sec2">第二节 晴天</a></li>
        </ol>
      </li>
      <li><a href="Text/ch3.xhtml#start">第三章 归来</a></li>
    </ol>
  </nav>
  <nav epub:type="landmarks"><ol><li><a href="Text/ch1.xhtml">正文</a></li></ol></nav>
</body></html>''';

    test('读出条目、层级与锚点', () {
      final entries = EpubTocParser.parseNav(nav, navDir: 'OEBPS/');
      expect(entries.map((e) => e.title).toList(), <String>[
        '第一章 出发',
        '第二章 路上',
        '第一节 雨天',
        '第二节 晴天',
        '第三章 归来',
      ]);
      expect(entries.map((e) => e.depth).toList(), <int>[0, 0, 1, 1, 0]);
      expect(entries[0].href, 'OEBPS/Text/ch1.xhtml');
      expect(entries[2].anchor, 'sec1');
      expect(entries[4].anchor, 'start');
      expect(entries[0].anchor, isNull);
    });

    test('只认 toc 那个 nav，不会把 landmarks 也当成目录', () {
      final entries = EpubTocParser.parseNav(nav);
      expect(entries.any((e) => e.title == '正文'), isFalse);
    });

    test('路径按 nav 所在目录归一化（../ 与 ./ 都要处理）', () {
      expect(EpubTocParser.normalizePath('Text/ch1.xhtml', baseDir: 'OEBPS/'), 'OEBPS/Text/ch1.xhtml');
      expect(EpubTocParser.normalizePath('../Text/ch1.xhtml', baseDir: 'OEBPS/nav/'), 'OEBPS/Text/ch1.xhtml');
      expect(EpubTocParser.normalizePath('./ch1.xhtml', baseDir: 'OEBPS'), 'OEBPS/ch1.xhtml');
      expect(EpubTocParser.normalizePath('/Text/ch1.xhtml', baseDir: 'OEBPS/'), 'Text/ch1.xhtml');
      expect(EpubTocParser.normalizePath('Text/%E7%AC%AC1.xhtml'), 'Text/第1.xhtml');
    });

    test('分组标题（没有链接的 span）会补到子项标题前面', () {
      const grouped = '''
<html><body><nav epub:type="toc"><ol>
  <li><span>第一卷 少年</span>
    <ol>
      <li><a href="a.xhtml">第一章</a></li>
      <li><a href="b.xhtml">第二章</a></li>
    </ol>
  </li>
</ol></nav></body></html>''';
      final entries = EpubTocParser.parseNav(grouped, navDir: 'OEBPS/');
      expect(entries.map((e) => e.title).toList(), <String>['第一卷 少年 · 第一章', '第一卷 少年 · 第二章']);
      expect(entries.every((e) => e.depth == 1), isTrue);
    });

    test('没有 nav 标签、只有一个裸 ol 时也能读', () {
      const bare = '<html><body><ol><li><a href="a.xhtml">甲</a></li></ol></body></html>';
      final entries = EpubTocParser.parseNav(bare, navDir: 'OEBPS/');
      expect(entries.map((e) => e.title), <String>['甲']);
    });

    test('垃圾内容与空串都安全返回空列表', () {
      expect(EpubTocParser.parseNav(''), isEmpty);
      expect(EpubTocParser.parseNav('这不是网页'), isEmpty);
      expect(EpubTocParser.parseNav('<html><body><p>没有目录</p></body></html>'), isEmpty);
    });
  });

  group('EPUB2 NCX', () {
    const ncx = '''
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <docTitle><text>测试书</text></docTitle>
  <navMap>
    <navPoint id="np1" playOrder="1">
      <navLabel><text>第一章</text></navLabel>
      <content src="Text/ch1.xhtml"/>
    </navPoint>
    <navPoint id="np2" playOrder="2">
      <navLabel><text>第二卷</text></navLabel>
      <content src="Text/ch2.xhtml"/>
      <navPoint id="np2-1" playOrder="3">
        <navLabel><text> 第二章  </text></navLabel>
        <content src="Text/ch2.xhtml#p1"/>
      </navPoint>
    </navPoint>
  </navMap>
</ncx>''';

    test('递归读出层级、去空白、带锚点', () {
      final entries = EpubTocParser.parseNcx(ncx, ncxDir: 'OEBPS/');
      expect(entries.map((e) => e.title).toList(), <String>['第一章', '第二卷', '第二章']);
      expect(entries.map((e) => e.depth).toList(), <int>[0, 0, 1]);
      expect(entries[2].href, 'OEBPS/Text/ch2.xhtml');
      expect(entries[2].anchor, 'p1');
    });

    test('没有 navMap / 内容非法时返回空', () {
      expect(EpubTocParser.parseNcx(''), isEmpty);
      expect(EpubTocParser.parseNcx('<ncx><navMap></navMap></ncx>'), isEmpty);
      expect(EpubTocParser.parseNcx('不是 XML'), isEmpty);
    });

    test('缺 navLabel 或 content 的条目会被跳过而不是崩', () {
      const partial = '''
<ncx><navMap>
  <navPoint><navLabel><text>没有链接</text></navLabel></navPoint>
  <navPoint><content src="a.xhtml"/></navPoint>
  <navPoint><navLabel><text>正常</text></navLabel><content src="b.xhtml"/></navPoint>
</navMap></ncx>''';
      final entries = EpubTocParser.parseNcx(partial);
      expect(entries.length, 2, reason: '缺 content 的跳过；缺 navLabel 的用文件名兜底');
      expect(entries.map((e) => e.href), <String>['a.xhtml', 'b.xhtml']);
    });
  });

  group('分组与拆分工具', () {
    test('splitHref 拆出文件与锚点', () {
      expect(EpubTocParser.splitHref('a.xhtml#x'), ('a.xhtml', 'x'));
      expect(EpubTocParser.splitHref('a.xhtml'), ('a.xhtml', null));
      expect(EpubTocParser.splitHref('a.xhtml#'), ('a.xhtml', null));
      expect(EpubTocParser.splitHref('  b.xhtml#y  '), ('b.xhtml', 'y'));
    });

    test('byFile 按文件分组且保持顺序', () {
      final entries = EpubTocParser.parseNav(
        '<html><body><nav epub:type="toc"><ol>'
        '<li><a href="a.xhtml">甲</a></li>'
        '<li><a href="a.xhtml#s">甲一</a></li>'
        '<li><a href="b.xhtml">乙</a></li>'
        '</ol></nav></body></html>',
        navDir: 'OEBPS/',
      );
      final map = EpubTocParser.byFile(entries);
      expect(map['OEBPS/a.xhtml']!.map((e) => e.title), <String>['甲', '甲一']);
      expect(map['OEBPS/b.xhtml']!.single.title, '乙');
    });

    test('标题清洗：压缩空白、截断过长标题', () {
      expect(EpubTocParser.cleanTitle('  第一章\n\t出发  '), '第一章 出发');
      expect(EpubTocParser.cleanTitle('书' * 200).length, 121);
    });
  });
}

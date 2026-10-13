import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/document_service.dart';

/// **EPUB 路径大小写回退**（v1.21.30 / P0）。
///
/// EPUB 规范要求路径**大小写敏感**，但实际文件常有出入：
/// `META-INF/container.xml` vs `meta-inf/container.xml`、
/// OPF 里写 `Images/Cover.jpg` 而 zip 里是 `images/cover.jpg`。
/// 只做精确匹配时这些书会静默退化成「没有目录 / 没有封面」——
/// 用户看到的是"这本 EPUB 打开后没有章节目录"，很难联想到大小写。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 造一本**大小写故意不一致**的 EPUB：
  /// · container.xml 在小写目录 `meta-inf/`
  /// · OPF 文件名是 `Content.opf`（大写 C），container 里也这么写
  /// · OPF 里封面写 `Images/Cover.jpg`，zip 里实际是 `images/cover.jpg`
  /// · 正文清单写 `Text/ch1.xhtml`，zip 里是 `text/ch1.xhtml`
  File buildCaseMismatchedEpub(Directory dir) {
    final Archive archive = Archive();

    void add(String name, String text) {
      final List<int> bytes = utf8.encode(text);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    void addBytes(String name, List<int> bytes) {
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('mimetype', 'application/epub+zip');
    // ⚠️ 小写目录名
    add('meta-inf/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/Content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''');
    // ⚠️ OPF 里声明的都是"另一种大小写"：Text/ 与 Images/
    add('OEBPS/Content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>大小写回退用例</dc:title>
    <dc:identifier id="id">case-test</dc:identifier>
  </metadata>
  <manifest>
    <item id="cov" href="Images/Cover.jpg" media-type="image/jpeg" properties="cover-image"/>
    <item id="c1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
  </spine>
</package>
''');
    // ⚠️ zip 里实际是小写
    add('OEBPS/text/ch1.xhtml', '''
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title></head>
<body><h1>第一章 大小写</h1><p>正文第一段。正文第二段。</p></body></html>
''');
    // 1x1 JPEG（够写出封面文件即可）
    addBytes('OEBPS/images/cover.jpg', <int>[
      0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
      0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9,
    ]);

    final File out = File('${dir.path}/case_mismatch.epub');
    out.writeAsBytesSync(ZipEncoder().encode(archive)!);
    return out;
  }

  test('大小写不一致的 EPUB：章节 / 目录 / 封面都能抽出来', () async {
    final Directory dir = await Directory.systemTemp.createTemp('epub_case');
    addTearDown(() => dir.delete(recursive: true));
    final File epub = buildCaseMismatchedEpub(dir);
    final String coverOut = '${dir.path}/cover.jpg';

    final result = await DocumentService.parseEpubManually(
      epub.path,
      coverOutPath: coverOut,
    );

    // ignore: avoid_print
    print('PROBE[大小写] 章节数=${result.document.chapters.length} '
        '首章=${result.document.chapters.first.title} '
        '封面=${result.coverPath}');

    expect(result.document.chapters, isNotEmpty,
        reason: '正文清单写 Text/ch1.xhtml、zip 里是 text/ch1.xhtml → 必须回退找到');
    expect(result.document.chapters.first.text, contains('正文第一段'),
        reason: '正文文本要真的读出来');
    expect(result.coverPath, isNotNull,
        reason: 'OPF 写 Images/Cover.jpg、zip 里是 images/cover.jpg → 封面必须回退找到');
    expect(await File(result.coverPath!).exists(), isTrue);
    expect(await File(result.coverPath!).length(), greaterThan(0));
  });

  test('对照：完全精确匹配的书仍然正常（回退不影响原路径）', () async {
    final Directory dir = await Directory.systemTemp.createTemp('epub_exact');
    addTearDown(() => dir.delete(recursive: true));

    final Archive archive = Archive();
    void add(String name, String text) {
      final List<int> bytes = utf8.encode(text);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('mimetype', 'application/epub+zip');
    add('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
''');
    add('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>精确匹配用例</dc:title><dc:identifier id="id">exact</dc:identifier>
  </metadata>
  <manifest><item id="c1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="c1"/></spine>
</package>
''');
    add('OEBPS/Text/ch1.xhtml',
        '<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>第一章</h1><p>精确正文。</p></body></html>');

    final File out = File('${dir.path}/exact.epub');
    out.writeAsBytesSync(ZipEncoder().encode(archive)!);

    final result = await DocumentService.parseEpubManually(out.path);
    // ignore: avoid_print
    print('PROBE[精确] 章节数=${result.document.chapters.length}');
    expect(result.document.chapters, isNotEmpty);
    expect(result.document.chapters.first.text, contains('精确正文'));
  });
}

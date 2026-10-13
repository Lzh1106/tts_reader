import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/document_service.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 交付前验证：PDF / EPUB / 网页三种朗读流程**整篇跑完**且不抛异常。
///
/// 做法：注入一个「假引擎」（立刻读完每一段），再用 [TtsManager.whenSessionFinished]
/// 确定地等待一轮朗读会话收尾。真引擎在测试环境没有任何原生实现、调用永不返回，
/// 只能验证「超时后不挂住」，验证不了「整篇读完 + 游标推进 + 界面重建」这条链路。
///
/// 本文件是纯 Dart 测试（不是 testWidgets），跑在真实事件循环上，
/// 因此 isolate 解析、超时、微任务调度都与真机一致；只有最后一组用 testWidgets
/// 验证界面重建。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FakeEngine engine;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 设置项（每页段数等）走 StorageService
    await StorageService.instance.init();
    tempDir = await Directory.systemTemp.createTemp('tts_verify');
    engine = _FakeEngine();
    final tts = TtsManager.instance;
    tts.resetTimeouts();
    await tts.registerEngine(engine, makeActive: true);
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } catch (_) {
      // Windows 句柄占用时忽略
    }
  });

  /// 等一轮朗读会话结束，超时即判失败（挂住就是 bug）
  Future<void> readToEnd(TtsManager tts, {String what = '朗读'}) async {
    await tts.whenSessionFinished().timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail('$what 在 10 秒内没有结束（疑似卡住）'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  // ---------------- PDF ----------------

  group('PDF 朗读', () {
    test('按章（按页）读完整本，空白页不卡住，游标停在末页', () async {
      final file = File('${tempDir.path}/book.pdf')
        ..writeAsBytesSync(_buildPdf(<String>[
          'Page 1 first. Page 1 second.',
          'Page 2 first. Page 2 second.',
          '', // 空白页：解析成空章，朗读时必须跨过去
          'Page 4 first. Page 4 second.',
          'Page 5 first.',
        ]));

      final parsed = await DocumentService.parse(
        Document(
          id: 'pdf1',
          title: 'PDF 整本',
          path: file.path,
          type: DocumentType.pdf,
          importedAt: DateTime(2024),
        ),
      );
      expect(parsed.document.chapters.length, 5, reason: '一页一章，空白页保留');

      final tts = TtsManager.instance;
      tts.loadDocument(parsed.document, title: 'PDF 整本');
      await tts.setGranularity(ReadGranularity.chapter);
      tts.speakFrom(0, 0, 0);
      await readToEnd(tts, what: 'PDF 按章朗读');

      expect(engine.error, isNull, reason: '整本朗读不能抛异常');
      expect(tts.error, isNull, reason: '不应留下朗读错误');
      expect(tts.cursor.$1, 4, reason: '读完应停在最后一页（第 5 页）');
      expect(tts.speaking, isFalse, reason: '读完应自动停下');
      // 4 页有内容（空白页不作为单元），每页一个单元
      expect(engine.spoken.length, 4);
    });

    test('按句朗读逐句推进：页号单调不减且始终在范围内', () async {
      final file = File('${tempDir.path}/sent.pdf')
        ..writeAsBytesSync(_buildPdf(<String>[
          'A one. A two.',
          'B one. B two.',
          'C one.',
        ]));

      final parsed = await DocumentService.parse(
        Document(
          id: 'pdf2',
          title: 'PDF 按句',
          path: file.path,
          type: DocumentType.pdf,
          importedAt: DateTime(2024),
        ),
      );

      final tts = TtsManager.instance;
      tts.loadDocument(parsed.document);
      await tts.setGranularity(ReadGranularity.sentence);

      final seen = <int>[];
      void listener() {
        if (tts.highlightCursor != null) seen.add(tts.cursor.$1);
      }

      tts.addListener(listener);
      try {
        tts.speakFrom(0, 0, 0);
        await readToEnd(tts, what: 'PDF 按句朗读');
      } finally {
        tts.removeListener(listener);
      }

      expect(engine.error, isNull);
      expect(seen, isNotEmpty, reason: '应至少推进过一次');
      for (final chapter in seen) {
        expect(chapter, inInclusiveRange(0, 2), reason: '页号不能越界');
      }
      // 单调不减
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]), reason: '页号不能倒退');
      }
      expect(tts.speaking, isFalse);
    });

    test('按页朗读：整页文本超长时按句切片，不丢字', () async {
      // 一页里塞足够多的句子，超过 300 字的单次朗读上限
      // 注意：测试用 Helvetica 标准字体，不能编码中文，所以这里用 ASCII
      final longPage = List<String>.generate(40, (i) => 'Sentence number $i is here. ').join();
      final file = File('${tempDir.path}/long.pdf')
        ..writeAsBytesSync(_buildPdf(<String>[longPage, 'Second page.']));

      final parsed = await DocumentService.parse(
        Document(
          id: 'pdf3',
          title: 'PDF 长页',
          path: file.path,
          type: DocumentType.pdf,
          importedAt: DateTime(2024),
        ),
      );

      final tts = TtsManager.instance;
      tts.loadDocument(parsed.document);
      await tts.setGranularity(ReadGranularity.page);
      tts.speakFrom(0, 0, 0);
      await readToEnd(tts, what: 'PDF 按页朗读');

      expect(engine.error, isNull);
      // 切片后拼起来应包含全部 40 句
      final joined = engine.spoken.join();
      for (var i = 0; i < 40; i++) {
        expect(joined.contains('number $i '), isTrue, reason: '第 $i 句不能被丢掉');
      }
      // 且每一片都没有超过上限
      for (final chunk in engine.spoken) {
        expect(chunk.length, lessThanOrEqualTo(300));
      }
      expect(engine.spoken.length, greaterThan(1), reason: '超长整页必须被切片');
    });
  });

  // ---------------- EPUB ----------------

  group('EPUB 朗读', () {
    test('按章读完整本，游标停在末章且无异常', () async {
      final file = File('${tempDir.path}/book.epub')
        ..writeAsBytesSync(_buildEpub(<String, String>{
          'OEBPS/c1.xhtml':
              '<html><head><title>第一章</title></head><body><h1>第一章</h1>'
                  '<p>一之一。一之二。</p><p>一之三。</p></body></html>',
          'OEBPS/c2.xhtml':
              '<html><head><title>第二章</title></head><body><h1>第二章</h1>'
                  '<p>二之一。</p><p>二之二。</p></body></html>',
          'OEBPS/c3.xhtml':
              '<html><head><title>第三章</title></head><body><h1>第三章</h1>'
                  '<p>三之一。三之二。三之三。</p></body></html>',
        }));

      final parsed = await DocumentService.parse(
        Document(
          id: 'epub1',
          title: 'EPUB 整本',
          path: file.path,
          type: DocumentType.epub,
          importedAt: DateTime(2024),
        ),
      );
      expect(parsed.document.chapters.length, 3);

      final tts = TtsManager.instance;
      tts.loadDocument(parsed.document, title: 'EPUB 整本');
      await tts.setGranularity(ReadGranularity.chapter);
      tts.speakFrom(0, 0, 0);
      await readToEnd(tts, what: 'EPUB 按章朗读');

      expect(engine.error, isNull, reason: '整本朗读不能抛异常');
      expect(tts.cursor.$1, 2, reason: '读完停在最后一章');
      expect(tts.speaking, isFalse);
      expect(engine.spoken.length, 3);
    });

    test('按句朗读整本 EPUB：游标不越界、章号单调不减', () async {
      final file = File('${tempDir.path}/sent.epub')
        ..writeAsBytesSync(_buildEpub(<String, String>{
          'OEBPS/a.xhtml': '<html><body><p>甲一。甲二。</p><p>甲三。</p></body></html>',
          'OEBPS/b.xhtml': '<html><body><p>乙一。乙二。</p></body></html>',
        }));

      final parsed = await DocumentService.parse(
        Document(
          id: 'epub2',
          title: 'EPUB 按句',
          path: file.path,
          type: DocumentType.epub,
          importedAt: DateTime(2024),
        ),
      );

      final tts = TtsManager.instance;
      tts.loadDocument(parsed.document);
      await tts.setGranularity(ReadGranularity.sentence);

      final chapters = <int>[];
      void listener() {
        if (tts.highlightCursor != null) chapters.add(tts.cursor.$1);
      }

      tts.addListener(listener);
      try {
        tts.speakFrom(0, 0, 0);
        await readToEnd(tts, what: 'EPUB 按句朗读');
      } finally {
        tts.removeListener(listener);
      }

      expect(engine.error, isNull);
      for (final c in chapters) {
        expect(c, inInclusiveRange(0, 1));
      }
      expect(tts.speaking, isFalse);
    });
  });

  // ---------------- 网页朗读（纯文本队列） ----------------

  group('网页朗读', () {
    test('正文分片逐条读完：条数一致、索引不越界、读完自动停下', () async {
      const html = '<html><head><title>标题</title></head><body><article>'
          '<h1>大标题</h1>'
          '<p>第一段第一句。第一段第二句。</p>'
          '<p>第二段。</p>'
          '<script>var x = 1;</script>'
          '<style>.a{color:red}</style>'
          '<p>第三段，稍微长一些，用来确认分片逻辑没有把内容丢掉。</p>'
          '</article></body></html>';

      final text = DocumentService.htmlToPlainText(html);
      final chunks = DocumentService.readChunks(text);
      expect(chunks, isNotEmpty);
      expect(text.contains('var x'), isFalse, reason: '脚本必须被剔除');
      expect(text.contains('color:red'), isFalse, reason: '样式必须被剔除');

      final tts = TtsManager.instance;
      tts.speakLines(chunks);
      await readToEnd(tts, what: '网页朗读');

      expect(engine.error, isNull, reason: '网页朗读不能抛异常');
      expect(tts.speaking, isFalse, reason: '读完自动停下');
      expect(tts.plainTotal, chunks.length);
      expect(engine.spoken.length, chunks.length, reason: '每条分片都读到一次');
      expect(tts.plainIndex, lessThan(chunks.length), reason: '索引不能越界');
    });

    test('从中间某条开始朗读，起点正确且不越界', () async {
      final chunks = <String>['一。', '二。', '三。', '四。', '五。'];
      final tts = TtsManager.instance;

      tts.speakLines(chunks, start: 3);
      expect(tts.plainIndex, 3);
      await readToEnd(tts, what: '从中间开始朗读');

      expect(engine.spoken.first, '四。', reason: '应从第 4 条开始读');
      expect(engine.spoken.length, 2, reason: '只读剩下的两条');
      expect(engine.error, isNull);
    });

    test('越界的起始下标被夹取，不抛异常', () async {
      final chunks = <String>['甲。', '乙。'];
      final tts = TtsManager.instance;

      tts.speakLines(chunks, start: 99);
      await readToEnd(tts, what: '越界起点朗读');

      expect(engine.error, isNull);
      expect(tts.plainIndex, lessThan(chunks.length));
    });

    test('朗读中暂停 / 继续 / 停止都不抛异常，且能停下', () async {
      // 让每段慢一点，否则读得太快，暂停还没生效就整篇读完了
      engine.speakDelay = const Duration(milliseconds: 40);
      final chunks = List<String>.generate(30, (i) => '第 $i 条。');
      final tts = TtsManager.instance;

      tts.speakLines(chunks);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(tts.speaking, isTrue, reason: '前置条件：应当正在朗读');

      await tts.pause();
      expect(tts.paused, isTrue);
      expect(tts.speaking, isTrue, reason: '暂停不等于停止');
      final pausedAt = tts.plainIndex;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(tts.plainIndex, pausedAt, reason: '暂停后不应继续推进');
      expect(engine.error, isNull);

      tts.resume();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(tts.paused, isFalse);
      expect(tts.plainIndex, greaterThanOrEqualTo(pausedAt), reason: '继续后应接着推进');

      await tts.stop();
      expect(tts.speaking, isFalse);
      expect(tts.paused, isFalse);
      expect(engine.error, isNull);
    });

    test('朗读中重复发起新一轮朗读（点别的段）不会串音或抛异常', () async {
      final chunks = List<String>.generate(20, (i) => '内容 $i。');
      final tts = TtsManager.instance;

      tts.speakLines(chunks, start: 0);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      tts.speakLines(chunks, start: 10);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      tts.speakLines(chunks, start: 15);
      await readToEnd(tts, what: '重复发起朗读');

      expect(engine.error, isNull);
      expect(tts.speaking, isFalse);
      // 最后一轮从第 16 条开始，应读到末尾
      expect(tts.plainIndex, greaterThanOrEqualTo(15));
    });
  });

  // ---------------- 界面层 ----------------

  group('界面层', () {
    testWidgets('阅读页整篇朗读 + 逐帧重建：不抛异常、无越界崩溃', (tester) async {
      final tts = TtsManager.instance;
      // testWidgets 跑在 fake-async 区域，假引擎的微任务需要 pump 推进；
      // 这里把兜底超时压短，保证不会留下悬挂定时器。
      tts
        ..speakTimeout = const Duration(milliseconds: 200)
        ..initTimeout = const Duration(milliseconds: 200)
        ..voiceTimeout = const Duration(milliseconds: 200)
        ..controlTimeout = const Duration(milliseconds: 200);

      final file = File('${tempDir.path}/ui.txt')
        ..writeAsStringSync(
          List<String>.generate(80, (i) => '第 $i 段第一句。第 $i 段第二句！').join('\n\n'),
        );
      final document = Document(
        id: 'ui',
        title: '界面朗读',
        path: file.path,
        type: DocumentType.txt,
        importedAt: DateTime(2024),
      );

      await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
      // 解析跑在 isolate 里，需要真实事件循环
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1200)));
      await tester.pump();
      await tester.pump();

      // 点一段开始朗读，然后一边朗读一边不停重建整页
      await tester.tap(find.textContaining('第 0 段第一句。').first);
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      }

      expect(tester.takeException(), isNull, reason: '朗读 + 重建过程中不能有异常');
      expect(engine.error, isNull);

      await tts.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      tts.resetTimeouts();
      expect(tester.takeException(), isNull);
    });
  });
}

/// 假引擎：每次 speak 后按 [speakDelay] 完成，记录读过的文本
class _FakeEngine with SyntheticTtsEngine implements TtsEngine {
  final List<String> spoken = <String>[];
  Object? error;

  /// 每段朗读耗时：太快会让「暂停」这类测试来不及介入（真机上一句话要好几秒）
  Duration speakDelay = Duration.zero;

  @override
  String get id => 'fake';

  @override
  String get displayName => '假引擎（测试）';

  @override
  bool get isAvailable => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<TtsVoice>> getVoices() async => const <TtsVoice>[];

  @override
  Future<void> setVoice(String voiceId) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  Future<void> speak(String text) async {
    try {
      spoken.add(text);
      if (speakDelay > Duration.zero) {
        await Future<void>.delayed(speakDelay);
      } else {
        await Future<void>.delayed(Duration.zero);
      }
      // 真引擎在整段读完时既唤醒 speak() 的 Future，也会调完成回调
      // （SystemTtsEngine._handleFinished）。假引擎必须照做，
      // 否则「读到第二段就被完成回调收尾」这类 bug 在单测里永远暴露不出来。
      _onComplete?.call();
    } catch (e) {
      error = e;
      rethrow;
    }
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  void Function()? _onComplete;

  @override
  void setCompletionHandler(void Function()? handler) => _onComplete = handler;

  @override
  Future<void> dispose() async {}
}

/// 现场生成一个真实 PDF（含空白页）
List<int> _buildPdf(List<String> pages) {
  final pdf = PdfDocument();
  final font = PdfStandardFont(PdfFontFamily.helvetica, 12);
  for (final text in pages) {
    final page = pdf.pages.add();
    if (text.trim().isEmpty) continue;
    page.graphics.drawString(
      text,
      font,
      bounds: const Rect.fromLTWH(20, 20, 500, 700),
    );
  }
  final bytes = pdf.saveSync();
  pdf.dispose();
  return bytes;
}

/// 现场构造一个最小可用的 EPUB（zip + container.xml + OPF + XHTML）
List<int> _buildEpub(Map<String, String> chapters) {
  final archive = Archive();
  void add(String name, String content) {
    final data = utf8.encode(content);
    archive.addFile(ArchiveFile(name, data.length, data));
  }

  add('mimetype', 'application/epub+zip');
  add(
    'META-INF/container.xml',
    '<?xml version="1.0"?><container version="1.0" '
        'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="OEBPS/content.opf" '
        'media-type="application/oebps-package+xml"/></rootfiles></container>',
  );

  final manifest = StringBuffer();
  final spine = StringBuffer();
  var index = 0;
  for (final entry in chapters.entries) {
    index++;
    final id = 'ch$index';
    final href = entry.key.split('/').last;
    manifest.write('<item id="$id" href="$href" media-type="application/xhtml+xml"/>');
    spine.write('<itemref idref="$id"/>');
    add(entry.key, entry.value);
  }
  add(
    'OEBPS/content.opf',
    '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" '
        'unique-identifier="bookid"><metadata '
        'xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>测试书</dc:title><dc:identifier id="bookid">test-book</dc:identifier>'
        '</metadata><manifest>$manifest</manifest><spine>$spine</spine></package>',
  );

  return ZipEncoder().encode(archive)!;
}

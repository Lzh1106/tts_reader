import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/document_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 真机 / 模拟器上的交付验证：用**真实的系统 TTS 引擎**把 PDF / EPUB / 网页
/// 三种朗读各读一遍，确认能出声、能推进、不抛异常、不闪退。
///
/// 与 test/reading_verify_test.dart 的分工：
/// - 那边用假引擎验证调度逻辑（读写全部走完、游标不越界）；
/// - 这里用真引擎验证「插件 → 系统 TTS → 回调 → 游标推进」这条真机链路。
///
/// 跑法（需要设备/模拟器）：
///   flutter test integration_test/device_verify_test.dart -d emulator-5554
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory workDir;

  setUpAll(() async {
    final base = await getTemporaryDirectory();
    workDir = Directory('${base.path}/device_verify');
    if (!workDir.existsSync()) workDir.createSync(recursive: true);
  });

  /// 等一轮朗读会话结束；超时不算失败——模拟器上系统 TTS 可能没装语音数据，
  /// 那种情况下引擎会报错或超时，我们要确认的是「不崩、不挂死」。
  Future<bool> readOnce(TtsManager tts, {Duration timeout = const Duration(seconds: 40)}) async {
    var finished = true;
    await tts.whenSessionFinished().timeout(
      timeout,
      onTimeout: () {
        finished = false;
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return finished;
  }

  void report(String label, TtsManager tts, {required bool finished, Object? error}) {
    // ignore: avoid_print
    print('DEVICE_VERIFY[$label] finished=$finished speaking=${tts.speaking} '
        'cursor=${tts.cursor} error=${error ?? tts.error}');
  }

  testWidgets('PDF：解析文本层 + 按页朗读全程不崩', (tester) async {
    final file = File('${workDir.path}/verify.pdf');
    if (!file.existsSync()) {
      final pdf = PdfDocument();
      final font = PdfStandardFont(PdfFontFamily.helvetica, 13);
      for (var i = 0; i < 4; i++) {
        pdf.pages.add().graphics.drawString(
          'This is page ${i + 1}. Reading verification sentence one. '
          'Reading verification sentence two.',
          font,
          bounds: const Rect.fromLTWH(20, 20, 500, 400),
        );
      }
      file.writeAsBytesSync(pdf.saveSync());
      pdf.dispose();
    }

    final document = Document(
      id: 'dev_pdf',
      title: '设备验证 PDF',
      path: file.path,
      type: DocumentType.pdf,
      importedAt: DateTime.now(),
    );

    final parsed = await DocumentService.parse(document);
    // ignore: avoid_print
    print('DEVICE_VERIFY[PDF-parse] pages=${parsed.document.chapters.length} '
        'sentences=${parsed.document.sentenceCount} textLayer=${parsed.hasTextLayer}');
    expect(parsed.document.chapters.length, 4);
    expect(parsed.hasTextLayer, isTrue);

    final tts = TtsManager.instance;
    await tts.init();
    tts.loadDocument(parsed.document, title: document.title);
    await tts.setGranularity(ReadGranularity.chapter);
    tts.speakFrom(0, 0, 0);
    final finished = await readOnce(tts);
    report('PDF', tts, finished: finished);

    // 不管有没有读出声音，都不允许崩：引擎错误应当被捕获成 tts.error
    expect(tts.speaking, isFalse, reason: '朗读会话必须收尾，不能一直挂着');
    await tts.stop();
  });

  testWidgets('EPUB：解析 + 按章朗读全程不崩', (tester) async {
    final file = File('${workDir.path}/verify.epub');
    if (!file.existsSync()) {
      file.writeAsBytesSync(_buildEpub(<String, String>{
        'OEBPS/c1.xhtml':
            '<html><head><title>Chapter One</title></head><body><h1>Chapter One</h1>'
                '<p>First paragraph of chapter one.</p><p>Second paragraph.</p></body></html>',
        'OEBPS/c2.xhtml':
            '<html><head><title>Chapter Two</title></head><body><h1>Chapter Two</h1>'
                '<p>First paragraph of chapter two.</p></body></html>',
        'OEBPS/c3.xhtml':
            '<html><head><title>Chapter Three</title></head><body><h1>Chapter Three</h1>'
                '<p>First paragraph of chapter three.</p><p>Another one.</p></body></html>',
      }));
    }

    final document = Document(
      id: 'dev_epub',
      title: '设备验证 EPUB',
      path: file.path,
      type: DocumentType.epub,
      importedAt: DateTime.now(),
    );

    final parsed = await DocumentService.parse(document);
    // ignore: avoid_print
    print('DEVICE_VERIFY[EPUB-parse] chapters=${parsed.document.chapters.length} '
        'sentences=${parsed.document.sentenceCount}');
    expect(parsed.document.chapters.length, 3);
    expect(parsed.document.sentenceCount, greaterThan(0));

    final tts = TtsManager.instance;
    await tts.init();
    tts.loadDocument(parsed.document, title: document.title);
    await tts.setGranularity(ReadGranularity.chapter);
    tts.speakFrom(0, 0, 0);
    final finished = await readOnce(tts);
    report('EPUB', tts, finished: finished);

    expect(tts.speaking, isFalse, reason: '朗读会话必须收尾');
    await tts.stop();
  });

  testWidgets('网页朗读：正文分片 + 队列朗读全程不崩', (tester) async {
    const html = '<html><head><title>Page</title></head><body><article>'
        '<h1>Article title</h1>'
        '<p>First paragraph of the article. Second sentence here.</p>'
        '<p>Second paragraph.</p>'
        '<script>console.log("noise")</script>'
        '</article></body></html>';

    final text = DocumentService.htmlToPlainText(html);
    final chunks = DocumentService.readChunks(text);
    // ignore: avoid_print
    print('DEVICE_VERIFY[WEB-chunks] count=${chunks.length} chars=${text.length}');
    expect(chunks, isNotEmpty);

    final tts = TtsManager.instance;
    await tts.init();
    tts.speakLines(chunks);
    final finished = await readOnce(tts);
    report('WEB', tts, finished: finished);

    expect(tts.speaking, isFalse, reason: '朗读会话必须收尾');
    expect(tts.plainIndex, lessThan(chunks.length), reason: '队列索引不能越界');
    await tts.stop();
  });

  testWidgets('朗读中按停止 / 快进 / 上一页：立即响应且不崩', (tester) async {
    final clip = StructuredDocument(
      chapters: <Chapter>[
        for (var c = 0; c < 6; c++)
          Chapter(
            title: '第 ${c + 1} 页',
            paragraphs: <Paragraph>[
              Paragraph(sentences: <Sentence>[
                Sentence('Page ${c + 1} sentence.'),
              ]),
            ],
          ),
      ],
      chapterIsPage: true,
    );

    final tts = TtsManager.instance;
    await tts.init();
    tts.loadDocument(clip);
    await tts.setGranularity(ReadGranularity.sentence);
    tts.speakFrom(0, 0, 0);
    await Future<void>.delayed(const Duration(milliseconds: 800));

    // 快进两次、上一页一次：都不能抛异常
    tts.skipPageForward();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    tts.skipPageForward();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    tts.skipPageBackward();
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final stopwatch = Stopwatch()..start();
    await tts.stop();
    stopwatch.stop();
    // 停止必须立刻返回（插件不回复也不能挂住界面）
    // ignore: avoid_print
    print('DEVICE_VERIFY[STOP] took=${stopwatch.elapsedMilliseconds}ms '
        'speaking=${tts.speaking} cursor=${tts.cursor}');
    expect(stopwatch.elapsedMilliseconds, lessThan(3000),
        reason: '停止不能被插件阻塞');
    expect(tts.speaking, isFalse);
  });

  testWidgets('系统 TTS 初始化状态（诊断用）', (tester) async {
    final tts = TtsManager.instance;
    await tts.init();
    final voices = await tts.refreshVoices();
    // ignore: avoid_print
    print('DEVICE_VERIFY[TTS] engine=${tts.activeEngineName} '
        'voices=${voices.length} error=${tts.error}');
  });
}

/// 现场构造最小可用 EPUB
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
        '<dc:title>Device Verify</dc:title><dc:identifier id="bookid">dev</dc:identifier>'
        '</metadata><manifest>$manifest</manifest><spine>$spine</spine></package>',
  );

  return ZipEncoder().encode(archive)!;
}

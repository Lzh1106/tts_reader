import 'dart:async';
import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/pdf_line_box.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 逐句导航（上一句 / 下一句）与「PDF 点哪一行就从哪一句读」的验证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
  });

  /// 三章、每章两段、每段两句的文档：句序号从 0 开始连续
  StructuredDocument buildDoc() => StructuredDocument(
    chapters: <Chapter>[
      const Chapter(
        title: '第一章',
        paragraphs: <Paragraph>[
          Paragraph(sentences: <Sentence>[Sentence('一甲一。'), Sentence('一甲二。')]),
          Paragraph(sentences: <Sentence>[Sentence('一乙一。'), Sentence('一乙二。')]),
        ],
      ),
      const Chapter(
        title: '第二章',
        paragraphs: <Paragraph>[
          Paragraph(sentences: <Sentence>[Sentence('二甲一。'), Sentence('二甲二。')]),
        ],
      ),
      const Chapter(
        title: '第三章',
        paragraphs: <Paragraph>[
          Paragraph(sentences: <Sentence>[Sentence('三甲一。'), Sentence('三甲二。')]),
          Paragraph(sentences: <Sentence>[Sentence('三乙一。')]),
        ],
      ),
    ],
  );

  group('句序号 ↔ 游标', () {
    test('逐句推进并跨章', () {
      final doc = buildDoc();
      expect(doc.sentenceCount, 9);
      expect(doc.cursorAtIndex(0), (0, 0, 0));
      expect(doc.cursorAtIndex(1), (0, 0, 1));
      expect(doc.cursorAtIndex(2), (0, 1, 0));
      expect(doc.cursorAtIndex(3), (0, 1, 1));
      expect(doc.cursorAtIndex(4), (1, 0, 0), reason: '第 5 句应当跨到第二章');
      expect(doc.cursorAtIndex(5), (1, 0, 1));
      expect(doc.cursorAtIndex(6), (2, 0, 0), reason: '第 7 句应当跨到第三章');
      expect(doc.cursorAtIndex(8), (2, 1, 0));
    });

    test('越界一律夹取，绝不产生非法游标', () {
      final doc = buildDoc();
      expect(doc.cursorAtIndex(-5), (0, 0, 0));
      expect(doc.cursorAtIndex(999), (2, 1, 0), reason: '超出末句应停在最后一句');
      expect(doc.cursorAtIndex(9), (2, 1, 0));
    });

    test('空文档返回 (0,0,0) 而不是抛异常', () {
      expect(StructuredDocument.empty().cursorAtIndex(3), (0, 0, 0));
      expect(StructuredDocument.empty().cursorAt(0.5), (0, 0, 0));
    });

    test('cursorAt 与 cursorAtIndex 完全一致（通知栏拖动进度用的就是它）', () {
      final doc = buildDoc();
      for (var i = 0; i < doc.sentenceCount; i++) {
        expect(doc.cursorAt(i / doc.sentenceCount), doc.cursorAtIndex(i));
      }
      expect(doc.cursorAt(1.0), doc.cursorAtIndex(doc.sentenceCount - 1));
      expect(doc.cursorAt(-1), doc.cursorAtIndex(0));
      expect(doc.cursorAt(9), doc.cursorAtIndex(doc.sentenceCount - 1));
    });

    test('indexOfCursor 与 cursorAtIndex 互逆', () {
      final doc = buildDoc();
      for (var i = 0; i < doc.sentenceCount; i++) {
        expect(doc.indexOfCursor(doc.cursorAtIndex(i)), i);
      }
    });
  });

  group('在一章里定位一段文字（PDF 点行用）', () {
    final doc = StructuredDocument(
      chapters: <Chapter>[
        const Chapter(
          title: '第 1 页',
          paragraphs: <Paragraph>[
            Paragraph(
              sentences: <Sentence>[
                Sentence('地球上最大的洋是太平洋。'),
                Sentence('它占了地球表面约三分之一。'),
              ],
            ),
            Paragraph(sentences: <Sentence>[Sentence('第二段只有一句。')]),
          ],
        ),
      ],
      chapterIsPage: true,
    );

    test('整句精确命中', () {
      expect(doc.locateText(0, '地球上最大的洋是太平洋。'), (0, 0));
      expect(doc.locateText(0, '它占了地球表面约三分之一。'), (0, 1));
      expect(doc.locateText(0, '第二段只有一句。'), (1, 0));
    });

    test('页面上的一行往往是半句：也能定位到所在的那一句', () {
      expect(doc.locateText(0, '地球上最大的洋'), (0, 0));
      expect(doc.locateText(0, '约三分之一'), (0, 1));
    });

    test('忽略空白差异（换行、空格、全角空格）', () {
      expect(doc.locateText(0, '地球上最大的洋\n是太平洋。'), (0, 0));
      expect(doc.locateText(0, '  它占了地球表面\n约三分之一。  '), (0, 1));
      expect(doc.locateText(0, '地球上最大的洋\u3000是太平洋。'), (0, 0));
    });

    test('跨句的长片段定位到起始句', () {
      expect(doc.locateText(0, '地球上最大的洋是太平洋。它占了'), (0, 0));
    });

    test('尾部混入杂字符时用前 8 个字兜底', () {
      expect(doc.locateText(0, '地球上最大的洋是太平洋。①'), (0, 0));
    });

    test('找不到就返回 null（调用方给提示而不是瞎跳）', () {
      expect(doc.locateText(0, '这句话根本不在这一页里'), isNull);
      expect(doc.locateText(0, ''), isNull);
      expect(doc.locateText(3, '地球上'), isNull, reason: '章下标越界');
      expect(doc.locateText(-1, '地球上'), isNull);
    });
  });

  group('PDF 文字行的命中', () {
    final lines = <PdfLineBox>[
      const PdfLineBox(text: '第一行', bounds: Rect.fromLTRB(10, 10, 200, 30)),
      const PdfLineBox(text: '第二行', bounds: Rect.fromLTRB(10, 40, 200, 60)),
      const PdfLineBox(text: '第三行', bounds: Rect.fromLTRB(10, 70, 200, 90)),
    ];

    test('点在行内直接命中', () {
      expect(PdfLineBox.find(lines, const Offset(50, 20))?.text, '第一行');
      expect(PdfLineBox.find(lines, const Offset(50, 50))?.text, '第二行');
      expect(PdfLineBox.find(lines, const Offset(50, 80))?.text, '第三行');
    });

    test('点进行与行之间的空隙也能命中（文字外框比行距小）', () {
      expect(PdfLineBox.find(lines, const Offset(50, 35))?.text, '第一行');
      expect(PdfLineBox.find(lines, const Offset(50, 65))?.text, '第二行');
    });

    test('点在同一行的左右空白处：按横向最近取这一行', () {
      expect(PdfLineBox.find(lines, const Offset(2, 20))?.text, '第一行');
      expect(PdfLineBox.find(lines, const Offset(400, 50))?.text, '第二行');
    });

    test('离所有行都很远（页边、页脚）返回 null', () {
      expect(PdfLineBox.find(lines, const Offset(50, 200)), isNull);
      expect(PdfLineBox.find(lines, const Offset(50, -100)), isNull);
      expect(PdfLineBox.find(const <PdfLineBox>[], const Offset(10, 10)), isNull);
    });
  });

  group('上一句 / 下一句（朗读管理器）', () {
    /// 等游标落到目标位置（引擎被挂住，不会自己往前读，所以是确定的）
    Future<void> waitCursor(TtsManager tts, (int, int, int) expected) async {
      for (var i = 0; i < 200 && tts.cursor != expected; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(tts.cursor, expected);
    }

    /// 等到引擎真的开口，返回它读的第一句
    Future<String> waitSpoken(_HoldingEngine engine) async {
      for (var i = 0; i < 200 && engine.spoken.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(engine.spoken, isNotEmpty, reason: '换位置之后应当立刻开始朗读');
      return engine.spoken.first;
    }

    Future<(TtsManager, _HoldingEngine)> setUpReading() async {
      final engine = _HoldingEngine();
      final tts = TtsManager.instance;
      tts.resetTimeouts();
      // 朗读永不结束（speak 挂着），游标就停在目标位置，断言才有确定性
      tts.speakTimeout = const Duration(seconds: 20);
      await tts.registerEngine(engine, makeActive: true);
      tts.loadDocument(buildDoc(), title: '测试');
      return (tts, engine);
    }

    test('下一句只走一句并从该句开始读，跨段也跨得干净', () async {
      final (tts, engine) = await setUpReading();

      tts.skipSentenceForward();
      await waitCursor(tts, (0, 0, 1));
      expect(await waitSpoken(engine), '一甲二。', reason: '应当从目标句开始读');

      engine.spoken.clear();
      tts.skipSentenceForward();
      await waitCursor(tts, (0, 1, 0));
      expect(await waitSpoken(engine), '一乙一。', reason: '同段读完要跨到下一段第 1 句');

      engine.spoken.clear();
      tts.skipSentenceForward();
      await waitCursor(tts, (0, 1, 1));
      expect(await waitSpoken(engine), '一乙二。');
    });

    test('上一句原路退回，跨章也正确', () async {
      final (tts, engine) = await setUpReading();

      // 跳到第二章第一句，再上一句应当回到第一章最后一句
      tts.speakFrom(1, 0, 0);
      await waitCursor(tts, (1, 0, 0));
      await waitSpoken(engine);

      engine.spoken.clear();
      tts.skipSentenceBackward();
      await waitCursor(tts, (0, 1, 1));
      expect(await waitSpoken(engine), '一乙二。', reason: '跨章上一句要落到上一章最后一句');
    });

    test('开头再上一句 / 末尾再下一句都不越界，也不报错', () async {
      final (tts, engine) = await setUpReading();

      tts.skipSentenceBackward();
      await waitCursor(tts, (0, 0, 0));
      expect(await waitSpoken(engine), '一甲一。');
      expect(tts.error, isNull, reason: '夹取之后仍是合法游标，不该报错');

      engine.spoken.clear();
      tts.speakFrom(2, 1, 0); // 全书最后一句
      await waitCursor(tts, (2, 1, 0));
      await waitSpoken(engine);

      engine.spoken.clear();
      tts.skipSentenceForward();
      await waitCursor(tts, (2, 1, 0));
      expect(await waitSpoken(engine), '三乙一。', reason: '末句再下一句仍停在末句并继续读');
    });

    test('没有文档时调用是安全的', () {
      final tts = TtsManager.instance;
      tts.skipSentenceForward();
      tts.skipSentenceBackward();
      tts.skipSentence(0);
    });
  });

  group('浏览器默认首页', () {
    test('默认是 Edge 系的起始页', () {
      expect(StorageService.defaultHomeUrl, contains('bing.com'));
      expect(StorageService.instance.homeUrl, StorageService.defaultHomeUrl);
    });

    test('预设第一项就是默认首页，且都是可加载的 http(s) 地址', () {
      expect(StorageService.homePresets.first.$2, StorageService.defaultHomeUrl);
      for (final preset in StorageService.homePresets) {
        final uri = Uri.tryParse(preset.$2);
        expect(uri, isNotNull, reason: '${preset.$1} 应当是合法地址');
        expect(uri!.scheme, anyOf('http', 'https'), reason: '${preset.$1} 必须是网页地址');
        expect(preset.$1, isNotEmpty);
      }
    });
  });
}

/// 假引擎：初始化 / 停止都立刻返回，但 speak 永不完成
///
/// 这样朗读会话会一直「正在朗读」，游标停在刚跳到的那一句，
/// 断言不依赖「读完一整篇要花多久」这种时序。
class _HoldingEngine with SyntheticTtsEngine implements TtsEngine {
  final List<String> spoken = <String>[];
  final Completer<void> _never = Completer<void>();

  @override
  String get id => 'sentence-holding';

  @override
  String get displayName => '假引擎（挂住朗读）';

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
    spoken.add(text);
    await _never.future; // 永远不返回，模拟「这一句还在读」
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async {}
}

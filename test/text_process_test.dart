import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/models/text_rule.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/services/text_processor.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 朗读文本预处理（T2S 的 Text Process Rules）验证：
/// 规则本身的行为、异常规则的兜底，以及「送去合成的字符串确实被改写」这条链路。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final processor = TextProcessor.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    processor.resetForTest();
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    await processor.init();
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
  });

  TextRule rule(
    String pattern, {
    String replacement = '',
    bool isRegex = true,
    String id = 'test',
  }) => TextRule(
    id: id,
    name: '测试规则',
    pattern: pattern,
    replacement: replacement,
    isRegex: isRegex,
  );

  group('规则表', () {
    test('首次 init 播种内置预设，并且落盘', () async {
      expect(processor.rules, isNotEmpty, reason: '没配过就该有默认规则');
      expect(
        processor.rules.map((r) => r.id),
        containsAll(<String>['builtin.bracket', 'builtin.triangle', 'builtin.wiki-ref']),
      );

      final stored = await StorageService.instance.loadTextRules();
      expect(stored, isNotNull, reason: '播种后必须写回存储，否则每次启动都会重播');
      expect(stored!.length, processor.rules.length);
    });

    test('用户清空成 0 条后不会被默认规则覆盖', () async {
      await processor.setRules(<TextRule>[]);
      processor.resetForTest();
      await processor.init();
      expect(processor.rules, isEmpty);
      expect(processor.hasActiveRules, isFalse);
    });

    test('停用 / 删除 / 恢复默认', () async {
      await processor.setEnabled('builtin.triangle', false);
      expect(processor.rules.firstWhere((r) => r.id == 'builtin.triangle').enabled, isFalse);

      await processor.remove('builtin.triangle');
      expect(processor.rules.any((r) => r.id == 'builtin.triangle'), isFalse);

      // 自建规则在恢复默认后要留着，内置规则补回来
      await processor.upsert(rule('X', replacement: 'Y', id: 'user.1'));
      await processor.restoreDefaults();
      expect(processor.rules.any((r) => r.id == 'builtin.triangle'), isTrue);
      expect(processor.rules.any((r) => r.id == 'user.1'), isTrue);
      expect(
        processor.rules.where((r) => !r.builtin).length,
        1,
        reason: '恢复默认不该重复添加自建规则',
      );
    });
  });

  group('规则生效', () {
    test('删除方括号内容 / 符号读成文字 / 去掉网址', () async {
      await processor.setRules(<TextRule>[
        rule(r'\[[^\]]*\]'),
        rule('△', replacement: '三角形'),
        rule(r'https?://\S+'),
      ]);
      expect(
        processor.apply('太平洋[1]最大，△ 表示三角形，见 https://a.com/b 完'),
        '太平洋最大，三角形 表示三角形，见  完',
      );
    });

    test('停用的规则不参与', () async {
      await processor.setRules(<TextRule>[
        rule('△', replacement: '三角形').copyWith(enabled: false),
      ]);
      expect(processor.apply('△'), '△');
      expect(processor.activeCount, 0);
      expect(processor.hasActiveRules, isFalse);
    });

    test('规则按顺序生效：前一条的输出是后一条的输入', () async {
      await processor.setRules(<TextRule>[
        rule('ab', replacement: 'cd'),
        rule('cd', replacement: 'ef'),
      ]);
      expect(processor.apply('ab'), 'ef');
    });

    test('非正则规则按字面量匹配，元字符不解释', () async {
      await processor.setRules(<TextRule>[rule(r'a.c', replacement: 'X', isRegex: false)]);
      expect(processor.apply(r'a.c a-c abc'), r'X a-c abc');
    });

    test(r'替换串支持分组回填：$1 / $& / $$ 字面量', () async {
      await processor.setRules(<TextRule>[
        rule(r'\((\d+)\)', replacement: r'[$1]'),
      ]);
      expect(processor.apply('见(12)页'), '见[12]页');

      await processor.setRules(<TextRule>[
        rule(r'第(\d+)章', replacement: r'<$&>'),
      ]);
      expect(processor.apply('第3章'), '<第3章>');

      await processor.setRules(<TextRule>[rule('钱', replacement: r'$$100')]);
      expect(processor.apply('钱'), r'$100');
    });

    test('规则把整段删空时返回空串（由朗读层决定跳过该单元）', () async {
      await processor.setRules(<TextRule>[rule(r'^.*$')]);
      expect(processor.apply('随便什么内容'), '');
    });
  });

  group('坏规则兜底', () {
    test('非法正则：validate 报错，apply 跳过它且不影响其它规则', () async {
      final broken = rule('[unclosed', replacement: 'X', id: 'broken');
      expect(TextProcessor.validate(broken), isNotNull);
      expect(TextProcessor.isUsable(broken), isFalse);

      await processor.setRules(<TextRule>[broken, rule('△', replacement: '三角形', id: 'ok')]);
      expect(processor.apply('△ [unclosed'), '三角形 [unclosed');
      // 启用了但不可用的规则不算「生效」
      expect(processor.activeCount, 1);
    });

    test('空 pattern 不报错也不改文本', () async {
      await processor.setRules(<TextRule>[rule('')]);
      expect(TextProcessor.validate(rule('')), '「查找」不能为空');
      expect(processor.apply('原文'), '原文');
    });

    test('规则把文本异常放大时丢弃这次替换（不读几分钟也读不完的内容）', () async {
      await processor.setRules(<TextRule>[rule('.', replacement: 'x' * 4000)]);
      final result = processor.apply('x' * 100);
      expect(result.length, 100, reason: '放大超过上限就该按原文处理');
    });

    test('损坏的持久化数据按「没配过」处理，不抛异常', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'text_process_rules': '{坏数据'});
      processor.resetForTest();
      await StorageService.instance.init();
      await processor.init();
      expect(processor.rules, isNotEmpty, reason: '解析失败应当退回内置预设而不是崩溃');
    });

    test('countMatches / applyOne 供编辑界面预览使用', () {
      final r = rule(r'\d');
      expect(TextProcessor.countMatches(r, 'a1b2c3'), 3);
      expect(TextProcessor.countMatches(rule('[bad'), 'a1'), 0);
      expect(TextProcessor.applyOne(r, 'a1b2'), 'ab');
    });
  });

  group('与朗读链路集成', () {
    test('送进引擎的文本是预处理之后的（文档朗读）', () async {
      final engine = _RecordingEngine();
      final tts = TtsManager.instance;
      tts.resetTimeouts();
      await tts.registerEngine(engine, makeActive: true);

      await processor.setRules(<TextRule>[
        rule(r'\[[^\]]*\]'),
        rule('△', replacement: '三角形'),
      ]);

      tts.loadDocument(
        StructuredDocument(
          chapters: <Chapter>[
            const Chapter(
              title: '第一章',
              paragraphs: <Paragraph>[
                Paragraph(sentences: <Sentence>[Sentence('这是第[1]句。')]),
                Paragraph(sentences: <Sentence>[Sentence('△ 是三角形。')]),
              ],
            ),
          ],
        ),
        title: '测试文档',
      );
      tts.speakFrom(0, 0, 0);
      await tts.whenSessionFinished().timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('朗读没有结束（疑似卡住）'),
      );

      expect(engine.spoken, <String>['这是第句。', '三角形 是三角形。']);
      expect(tts.error, isNull);
      expect(tts.speaking, isFalse);
    });

    test('被规则删空的句子直接跳过，不送空串给引擎、也不停住', () async {
      final engine = _RecordingEngine();
      final tts = TtsManager.instance;
      tts.resetTimeouts();
      await tts.registerEngine(engine, makeActive: true);

      await processor.setRules(<TextRule>[rule(r'\[[^\]]*\]')]);

      tts.loadDocument(
        StructuredDocument(
          chapters: <Chapter>[
            const Chapter(
              title: '第一章',
              paragraphs: <Paragraph>[
                Paragraph(sentences: <Sentence>[Sentence('[3]')]),
                Paragraph(sentences: <Sentence>[Sentence('正文。')]),
              ],
            ),
          ],
        ),
        title: '测试文档',
      );
      tts.speakFrom(0, 0, 0);
      await tts.whenSessionFinished().timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('朗读没有结束（疑似卡住）'),
      );

      expect(engine.spoken, <String>['正文。'], reason: '空串绝不能送去合成');
      expect(tts.cursor, (0, 1, 0), reason: '游标应当越过被删空的句子');
      expect(tts.error, isNull);
    });

    test('纯文本队列（网页 / 打字 / 分享朗读）同样走预处理', () async {
      final engine = _RecordingEngine();
      final tts = TtsManager.instance;
      tts.resetTimeouts();
      await tts.registerEngine(engine, makeActive: true);

      await processor.setRules(<TextRule>[
        rule(r'\[\d+\]'),
        rule('△', replacement: '三角形'),
      ]);

      tts.speakLines(<String>['第一条[1]', '[2]', '△ 第三条']);
      await tts.whenSessionFinished().timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('朗读没有结束（疑似卡住）'),
      );

      expect(engine.spoken, <String>['第一条', '三角形 第三条']);
      expect(tts.error, isNull);
    });
  });
}

/// 假引擎：立刻读完每一段并记录收到的文本
class _RecordingEngine with SyntheticTtsEngine implements TtsEngine {
  final List<String> spoken = <String>[];

  @override
  String get id => 'recording';

  @override
  String get displayName => '假引擎（记录文本）';

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
    await Future<void>.delayed(Duration.zero);
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

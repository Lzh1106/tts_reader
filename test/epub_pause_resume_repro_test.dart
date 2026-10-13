
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// EPUB 长会话：**中途暂停 → 继续**，必须能从原位置接着读，不能整章停住。
///
/// 背景（HANDOFF §4.107 之后的回归）：`pause()` 会 `_generation++` 作废当前循环，
/// 而 `resume()` 走的是「新会话」而不是复用老循环 —— 这条路径若被误伤，
/// 表现就是「暂停一下就再也读不动了」。
///
/// ⚠️ 本文件在一次批量脚本事故中**原内容丢失**，此版本是**按上述意图重建**的
/// （见 docs/v1.21.12-diag3-交接.md 的事故记录）。原始用例数/断言细节可能与旧版不同。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final tts = TtsManager.instance;

  /// 一份多句文档：句数足够多，暂停后仍有后续可读。
  StructuredDocument doc() => StructuredDocument(
        chapters: const <Chapter>[
          Chapter(
            title: 'C0',
            paragraphs: <Paragraph>[
              Paragraph(
                sentences: <Sentence>[
                  Sentence('第一句话，读一会儿之后会被暂停。'),
                  Sentence('第二句话，暂停期间不应该被跳过。'),
                  Sentence('第三句话，继续之后应当接着读。'),
                  Sentence('第四句话，用来确认真的一直在读。'),
                  Sentence('第五句话，本段最后一句。'),
                ],
              ),
            ],
          ),
        ],
      );

  /// 等条件成立（最多 [timeoutMs]），返回是否成立。
  Future<bool> waitFor(bool Function() cond, int timeoutMs) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      if (cond()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return cond();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    tts.resetTimeouts();
    tts.resetSessionForTest();
    await tts.registerEngine(_EpubFakeEngine(), makeActive: true);
  });

  tearDown(() async {
    await tts.stop();
    tts.resetTimeouts();
    tts.resetSessionForTest();
  });

  test('暂停 → 继续：必须从原位置接着读（不整章停住）', () async {
    tts.loadDocument(doc(), title: 'EPUB 暂停继续', documentId: 'epub-pause-resume');
    tts.speakFrom(0, 0, 0);

    // 前提：确实读起来了
    final bool started = await waitFor(() => tts.speaking, 3000);
    expect(started, isTrue, reason: '前提：会话必须真的起来（否则后面的断言没意义）');

    // 读一会儿再暂停
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await tts.pause();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(tts.paused, isTrue, reason: 'pause() 之后必须处于暂停态');
    final (int, int, int) pausedAt = tts.cursor;

    // 继续：必须恢复朗读状态
    tts.resume();
    final bool resumed = await waitFor(() => tts.speaking && !tts.paused, 3000);
    expect(resumed, isTrue, reason: 'resume() 之后必须回到「正在读」');

    // 关键断言：继续之后游标必须真的往前走（不是停在暂停处不动）
    final bool moved = await waitFor(() => tts.settledCursor != pausedAt, 8000);
    expect(moved, isTrue,
        reason: '暂停继续后位置必须继续推进（暂停点=$pausedAt，'
            '当前位置=${tts.settledCursor}）—— 停在原地就是「整章停住」那个回归');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('暂停期间不得吞掉后续句子：继续后读到的仍是暂停点之后的句子', () async {
    tts.loadDocument(doc(), title: 'EPUB 暂停继续', documentId: 'epub-pause-resume-2');
    tts.speakFrom(0, 0, 0);
    await waitFor(() => tts.speaking, 3000);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    await tts.pause();
    final (int, int, int) pausedAt = tts.cursor;
    tts.resume();
    await waitFor(() => tts.settledCursor != pausedAt, 8000);

    // 继续之后的位置只能「从暂停点往后」，不能倒退
    final (int, int, int) after = tts.settledCursor;
    expect(after.$1 == pausedAt.$1 && after.$2 >= pausedAt.$2, isTrue,
        reason: '继续后不能退回到暂停点之前（暂停点=$pausedAt 继续后=$after）');
  }, timeout: const Timeout(Duration(seconds: 30)));
}

/// EPUB 长会话用的假引擎：按「一句话读 300ms」的节奏回调完成。
///
/// 声明 `SyntheticTtsEngine`：它是合成语义的测试替身，不适用共享层的
/// 时长判据（判据本身对真引擎一律生效）。
class _EpubFakeEngine with SyntheticTtsEngine implements TtsEngine {
  void Function()? _onComplete;

  @override
  String get id => 'epub-fake';

  @override
  String get displayName => 'EPUB 假引擎';

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
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _onComplete?.call();
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) => _onComplete = handler;

  @override
  Future<void> dispose() async {}
}

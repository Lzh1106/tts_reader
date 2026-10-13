import 'dart:async';
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// **引擎失败时 PDF 位置不许推进**（v1.21.40 修）
///
/// ## 真机症状（v1.21.39 日志）
/// ```
/// 13:48:46.343  朗读失败：本地 TTS · multitts 超时（30000ms）
/// 13:48:47.859  位置[PDF写盘] page=17 sentence=32   ← 用户没听到，位置却前进
/// 13:48:51.931  位置[PDF写盘] page=17 sentence=34
/// 13:48:57.341  位置[PDF写盘] page=17 sentence=35
/// 13:48:58.927  位置[PDF写盘] page=17 sentence=36   ← 连跳 5 句
/// 13:49:01.395  之后 6 分钟静默，直到用户手动起读
/// ```
/// 用户一句都没听到，位置却往前跳了 5 句，然后朗读彻底停住。
///
/// ## 根因
/// `TtsManager._fail()`（超时 / 报错）**也会让 `whenSessionFinished()` 完成**，
/// 于是 `_readLoop` 里那个 `await done` 正常返回，代码照常走 `_advancePast` ——
/// **失败信号被当成了读完信号**。
///
/// 修法：`await` 之后检查 `TtsManager.error`，非空就只停会话、**不推进位置**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  PdfPageTextLayer makePage(int pageNumber, String text) {
    final chars = <PdfTextChar>[];
    for (var i = 0; i < text.length; i++) {
      chars.add(PdfTextChar(
        index: i,
        char: text[i],
        rect: Rect.fromLTWH(i * 10.0, 100, 10, 12),
      ));
    }
    return buildTextLayer(
      pageNumber: pageNumber,
      pageSize: const Size(400, 300),
      fullText: text,
      charRects: chars.map((c) => c.rect).toList(),
      segment: segmentIntoSentences,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    TtsManager.instance.resetSessionForTest();
    TtsManager.instance.resetTimeouts();
    // 超时设短一点：让"失败"来得快，用例不必等 30 秒
    TtsManager.instance.speakTimeout = const Duration(milliseconds: 300);
    PdfReadSession.instance.resetForTest();
    PdfReadSession.instance.audioBridge = RecordingAudioBridge();
  });

  tearDown(() async {
    await PdfReadSession.instance.clear();
    PdfReadSession.instance.resetForTest();
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.resetSessionForTest();
  });

  Future<void> waitFor(bool Function() cond, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('引擎一直不回调（超时）→ 位置停在原处，不推进', () async {
    final session = PdfReadSession.instance;
    await TtsManager.instance
        .registerEngine(_NeverCompletingEngine(), makeActive: true);

    final pages = <int, PdfPageTextLayer>{
      0: makePage(1, '第一句。第二句。第三句。第四句。'),
    };
    await session.open(
      documentId: 'engine-fail-doc',
      title: '引擎失败用例',
      pageCount: 1,
      layerLoader: (pageIndex) async => pages[pageIndex],
    );

    final layer = await session.ensureLayer(0);
    final start = sentenceRefAt(0, 0, layer)!;
    session.startAt(start);
    expect(session.current?.sentenceIndex, 0, reason: '起点是第 0 句');

    // 等引擎超时（speakTimeout = 300ms）→ `_fail()` → 会话被收尾
    await waitFor(
      () => TtsManager.instance.error != null,
      const Duration(seconds: 5),
    );
    // 再等一会儿：修前这里会继续推进好几句
    await Future<void>.delayed(const Duration(milliseconds: 400));

    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-engine-fail] 引擎错误=${TtsManager.instance.error} '
        '当前=${session.current?.pageIndex}:${session.current?.sentenceIndex} '
        'isPlaying=${session.isPlaying}');
    expect(TtsManager.instance.error, isNotNull,
        reason: '前置：引擎必须真的失败了（否则这条用例是空跑）');
    expect(session.current?.sentenceIndex, 0,
        reason: '用户一句都没听到 → 位置必须停在原处。'
            '修前这里会一路推进（真机日志连跳 5 句）');
    expect(session.isPlaying, isFalse, reason: '失败后不该还显示"正在朗读"');
  });

  test('正常读完之后仍然会推进（别把好路径一起挡掉）', () async {
    final session = PdfReadSession.instance;
    await TtsManager.instance
        .registerEngine(_CompletingEngine(), makeActive: true);

    final pages = <int, PdfPageTextLayer>{
      0: makePage(1, '第一句。第二句。第三句。'),
    };
    await session.open(
      documentId: 'engine-ok-doc',
      title: '正常用例',
      pageCount: 1,
      layerLoader: (pageIndex) async => pages[pageIndex],
    );

    final layer = await session.ensureLayer(0);
    session.startAt(sentenceRefAt(0, 0, layer)!);
    await waitFor(
      () => (session.current?.sentenceIndex ?? 0) >= 1,
      const Duration(seconds: 5),
    );
    // ignore: avoid_print
    print('DEVICE_VERIFY[pdf-engine-fail] 正常路径推进到='
        '${session.current?.sentenceIndex}');
    expect(session.current?.sentenceIndex, greaterThanOrEqualTo(1),
        reason: '正常读完必须照旧推进（这条守着"别修坏好路径"）');
  });
}

/// 引擎：`speak` **永不回调** → 必定走 `speakTimeout` 那条失败路
class _NeverCompletingEngine with SyntheticTtsEngine implements TtsEngine {
  @override
  String get id => 'never-completing';
  @override
  String get displayName => '假引擎（永不回调）';
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
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}

  @override
  Future<void> speak(String text) {
    // 关键：返回一个**永不完成**的 Future（模拟插件卡死）
    return Completer<void>().future;
  }

  @override
  void setCompletionHandler(void Function()? handler) {}
}

/// 引擎：正常读完（40ms 后回调）—— 守住"别把好路径一起挡掉"
class _CompletingEngine with SyntheticTtsEngine implements TtsEngine {
  void Function()? _onComplete;

  @override
  String get id => 'completing';
  @override
  String get displayName => '假引擎（正常读完）';
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
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}

  @override
  Future<void> speak(String text) async {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    _onComplete?.call();
  }

  @override
  void setCompletionHandler(void Function()? handler) {
    _onComplete = handler;
  }
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 「快进到下一句时**跳过该去的那句**」（用户真机反馈，v1.21.20）
///
/// ## 现象
/// 按「下一句」有概率直接落到**下一句的下一句**，中间那句永远没被读过。
///
/// ## 根因（本用例锁定的窗口）
/// 主循环的顺序是「读当前句 → await 出声 → 游标前进」。上一句 A 读完的瞬间，
/// 游标已经前进到 B，但 B 的**声音还没出来**（引擎起播有几百毫秒延迟）。
/// 用户此刻按「下一句」——他心里"当前"还是刚听完的 A，所以期望听到 B；
/// 而实现用的是**游标**（已经是 B）再 +1 = C → **B 被跳过**。
///
/// 判据：按「下一句」时要以**出声位置**（真正读到哪一句）为基准，
/// 而不是以"已经排队但还没出声"的游标为基准。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('上一句刚读完、下一句还没出声时按「下一句」，不能跳过没听到的那句', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    final TtsManager tts = TtsManager.instance;
    tts.resetSessionForTest();
    tts.resetTimeouts();
    tts.speakTimeout = const Duration(seconds: 5);

    final _ControlledEngine engine = _ControlledEngine();
    await tts.registerEngine(engine, makeActive: true);
    addTearDown(() async {
      await tts.stop();
      tts.resetSessionForTest();
    });

    // 三句话：A / B / C
    tts.loadDocument(
      StructuredDocument(chapters: <Chapter>[
        const Chapter(title: '第一章', paragraphs: <Paragraph>[
          Paragraph(sentences: <Sentence>[
            Sentence('甲句内容。'),
            Sentence('乙句内容。'),
            Sentence('丙句内容。'),
          ]),
        ]),
      ]),
      title: '快进竞态用例',
      documentId: 'skip-next-doc',
    );

    tts.speakFrom(0, 0, 0);
    await _waitFor(() => engine.spoken.length == 1); // A 已交给引擎

    // A 读完：主循环前进到 B 并把 B 交给引擎（B 的音频还没开始）
    engine.finishCurrent();
    await _waitFor(() => engine.spoken.length == 2);
    // ignore: avoid_print
    print('PROBE[快进] 出声序列=${engine.spoken} 游标=${tts.cursor}');

    // 用户此刻按「下一句」——他刚听完 A，期望听到 B
    tts.skipSentenceForward();
    await _waitFor(() => engine.spoken.length == 3);

    // ignore: avoid_print
    print('PROBE[快进] 按下后 出声序列=${engine.spoken} 游标=${tts.cursor}');
    expect(
      engine.spoken.last,
      '乙句内容。',
      reason: '用户刚听完甲句，按「下一句」应当去**乙句**；'
          '直接冲到丙句就是"跳过该去的那句"（实际出声=${engine.spoken}）',
    );
    expect(tts.cursor, (0, 0, 1), reason: '游标应停在乙句');
  });

  test('正在朗读中途按「下一句」：正常前进一句（不误回退）', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    final TtsManager tts = TtsManager.instance;
    tts.resetSessionForTest();
    tts.resetTimeouts();
    tts.speakTimeout = const Duration(seconds: 5);

    final _ControlledEngine engine = _ControlledEngine();
    await tts.registerEngine(engine, makeActive: true);
    addTearDown(() async {
      await tts.stop();
      tts.resetSessionForTest();
    });

    tts.loadDocument(
      StructuredDocument(chapters: <Chapter>[
        const Chapter(title: '第一章', paragraphs: <Paragraph>[
          Paragraph(sentences: <Sentence>[
            Sentence('第一句。'),
            Sentence('第二句。'),
            Sentence('第三句。'),
          ]),
        ]),
      ]),
      title: '中途快进用例',
      documentId: 'skip-next-doc-2',
    );

    tts.speakFrom(0, 0, 0);
    await _waitFor(() => engine.spoken.length == 1); // 第一句正在读
    // 让这一句"确实在读"（引擎已经出声一会儿了）
    await Future<void>.delayed(const Duration(milliseconds: 700));

    tts.skipSentenceForward();
    await _waitFor(() => engine.spoken.length == 2);
    // ignore: avoid_print
    print('PROBE[中途快进] 出声序列=${engine.spoken} 游标=${tts.cursor}');
    expect(engine.spoken.last, '第二句。', reason: '正在读第一句时快进 → 第二句');
    expect(tts.cursor, (0, 0, 1));
  });
}

/// 可控假引擎：每次 `speak()` 挂住，直到用例显式让它结束
class _ControlledEngine with SyntheticTtsEngine implements TtsEngine {
  final List<String> spoken = <String>[];
  final List<Completer<void>> _pending = <Completer<void>>[];

  @override
  String get id => 'controlled-engine';

  @override
  String get displayName => '可控假引擎';

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
  Future<void> speak(String text) {
    spoken.add(text);
    final Completer<void> c = Completer<void>();
    _pending.add(c);
    return c.future;
  }

  void finishCurrent() {
    if (_pending.isNotEmpty) _pending.removeAt(0).complete();
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {
    // 停声：把还挂着的都放行（真实引擎也是这个语义）
    for (final Completer<void> c in List<Completer<void>>.from(_pending)) {
      if (!c.isCompleted) c.complete();
    }
    _pending.clear();
  }

  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async {}
}

Future<void> _waitFor(bool Function() cond,
    [Duration timeout = const Duration(seconds: 3)]) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

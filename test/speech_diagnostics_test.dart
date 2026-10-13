import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/speech_diagnostics.dart';

/// 跳动检测判定器的自测：判不准 = 白做。
///
/// 事件用**直接构造**注入（`speakEvents` / `advanceEvents` / `turnEvents`
/// 是公开列表），这样时间戳、耗时、代次都完全可控 —— 不依赖真实时钟，
/// 也不会被 R5（耗时 < 100ms）之类的规则误伤。
void main() {
  final SpeechDiagnostics diag = SpeechDiagnostics.instance;

  DateTime at(int ms) => DateTime.fromMillisecondsSinceEpoch(1700000000000 + ms);

  setUp(diag.clear);

  /// 造一条「正常读完」的朗读事件。
  SpeakEvent speak({
    required int seq,
    required int epoch,
    required int issuedMs,
    required int durationMs,
    bool ok = true,
    String cursor = '0:0:0',
    String text = '这是第 N 句话，用来观察推进是否正常。',
  }) =>
      SpeakEvent(
        seq: seq,
        epoch: epoch,
        textPrefix: text.length <= 8 ? text : text.substring(0, 8),
        issuedAt: at(issuedMs),
        cursorBefore: cursor,
        doneAt: at(issuedMs + durationMs),
        durationMs: durationMs,
        ok: ok,
      );

  AdvanceEvent advance({
    required int seq,
    required int epoch,
    required int atMs,
    String before = '0:0:0',
    String after = '0:0:1',
    int delta = 1,
    String source = '自动',
  }) =>
      AdvanceEvent(
        seq: seq,
        cursorBefore: before,
        cursorAfter: after,
        delta: delta,
        source: source,
        epoch: epoch,
        at: at(atMs),
      );

  TurnEvent turn({
    required int seq,
    required int fromPage,
    required int toPage,
    required int atMs,
    required int elapsedMs,
    int sentences = 10,
    String trigger = '自动',
  }) =>
      TurnEvent(
        seq: seq,
        fromPage: fromPage,
        toPage: toPage,
        sentencesOnFromPage: sentences,
        elapsedSinceLastTurnMs: elapsedMs,
        trigger: trigger,
        at: at(atMs),
      );

  test('① 正常推进（代次一致、耗时合理、无人打断）→ 🟢', () {
    diag.speakEvents.add(speak(seq: 1, epoch: 5, issuedMs: 0, durationMs: 1200));
    diag.advanceEvents.add(advance(seq: 2, epoch: 5, atMs: 1210));

    final SpeechDiagReport report = diag.analyze();
    expect(report.level, SpeechDiagLevel.ok,
        reason: '正常序列必须判绿，命中=${report.hitsSummary}');
    expect(report.hits, isEmpty);
  });

  test('② 代次不匹配却推进 → 🔴 且必须命中 R2（本次 bug 的直接判据）', () {
    // 第 7 代发起朗读、读完；推进却发生在第 8 代（＝旧会话被掐掉后又推进了）
    diag.speakEvents.add(speak(seq: 1, epoch: 7, issuedMs: 0, durationMs: 1000));
    diag.advanceEvents.add(advance(seq: 2, epoch: 8, atMs: 1010));

    final SpeechDiagReport report = diag.analyze();
    expect(report.level, SpeechDiagLevel.abnormal);
    expect(report.rules, contains('R2'));
    expect(report.countOf('R2'), 1);
    expect(report.firstRedSeq, 2);
  });

  test('③ 翻页间隔 < 500ms 连续 3 次 → 🔴 且必须命中 R6', () {
    diag.turnEvents.add(turn(seq: 1, fromPage: 0, toPage: 1, atMs: 0, elapsedMs: -1));
    diag.turnEvents.add(turn(seq: 2, fromPage: 1, toPage: 2, atMs: 200, elapsedMs: 200));
    diag.turnEvents.add(turn(seq: 3, fromPage: 2, toPage: 3, atMs: 400, elapsedMs: 200));
    diag.turnEvents.add(turn(seq: 4, fromPage: 3, toPage: 4, atMs: 600, elapsedMs: 200));

    final SpeechDiagReport report = diag.analyze();
    expect(report.level, SpeechDiagLevel.abnormal);
    expect(report.rules, contains('R6'));
    expect(report.countOf('R6'), 1);
  });

  test('④ 导出文本可解析：首行 schema 版本 / 摘要命中数 / 默认体积 < 50KB', () {
    diag.speakEvents.add(speak(seq: 1, epoch: 7, issuedMs: 0, durationMs: 1000));
    diag.advanceEvents.add(advance(seq: 2, epoch: 8, atMs: 1010));
    // 再补一批正常事件，模拟「文件里不止一条」
    for (int i = 0; i < 30; i++) {
      diag.speakEvents.add(
        speak(seq: 3 + i * 2, epoch: 9, issuedMs: 2000 + i * 100, durationMs: 800),
      );
      diag.advanceEvents.add(
        advance(
          seq: 4 + i * 2,
          epoch: 9,
          atMs: 2810 + i * 100,
          before: '0:0:$i',
          after: '0:0:${i + 1}',
        ),
      );
    }

    final String text = diag.buildExportText(
      includeAllEvents: false,
      meta: const <String, String>{
        'app_version': '1.21.34+85',
        'device': 'test-device',
      },
    );

    expect(text.split('\n').first.trim(), 'speech_diag_v1');
    expect(text.contains('overall=red'), isTrue);
    expect(text.contains('hits=R2 x1'), isTrue,
        reason: '摘要段必须能对上判据命中数');
    expect(text.contains('[abnormal]'), isTrue);
    expect(text.contains('context:'), isTrue, reason: '异常窗口要带上下文');
    expect(text.contains('[events]'), isFalse,
        reason: '未勾选「包含全部事件」时不应出现全量事件段');
    expect(text.length, lessThan(50 * 1024), reason: '默认导出必须 < 50KB');
  });

  test('⑤ R2 边界：source=点句 + epoch 错位 → 必须判绿（用户点句不是异常）', () {
    // 用户点句会重建会话：推进发生在新代次上，但推进来源是「点句」。
    diag.speakEvents.add(speak(seq: 1, epoch: 7, issuedMs: 0, durationMs: 1000));
    diag.advanceEvents.add(
      advance(seq: 2, epoch: 8, atMs: 1010, source: '点句'),
    );

    final SpeechDiagReport report = diag.analyze();
    expect(report.level, SpeechDiagLevel.ok,
        reason: 'source=点句 的 epoch 错位是正常语义，不能报 R2；命中=');
    expect(report.rules, isNot(contains('R2')));
  });
}

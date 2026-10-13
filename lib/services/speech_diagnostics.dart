/// 朗读跳动检测：事件采样 + 判据判定 + 导出文本生成。
///
/// ## 定位
/// 这是**常驻的诊断系统**，不是临时探针：
/// - 采样层与判定层常驻（零 IO、零 print、零 await）；
/// - 呈现层与导出层由外部门控（`kDebugMode || StorageService.speechDiagEnabled`）；
/// - 本文件是**纯逻辑**：不引任何插件、不写文件、不打印。
///   落盘与分享在 `speech_diag_export.dart`，UI 在阅读页 / 设置页。
///
/// ## 为什么需要它
/// 「PDF 点句后位置多跳 5~10 句」「EPUB 暂停后整章停住」「EPUB 快速向后滚动」
/// 这三条都发生在**真机的时序**里，模拟器/单测复现不出来。
/// 把「该不该推进」变成可判定的事件，真机复现一次、导出一次就能自证。
library;

import 'dart:math' as math;

// ---------------------------------------------------------------------------
// 事件结构（字段固定，与任务书一致）
// ---------------------------------------------------------------------------

/// 一次朗读单元（`_speakUnit` → `_speakChunk`）的生命周期事件。
class SpeakEvent {
  SpeakEvent({
    required this.seq,
    required this.epoch,
    required this.textPrefix,
    required this.issuedAt,
    required this.cursorBefore,
    this.doneAt,
    this.durationMs,
    this.ok,
    this.cursorAfter = '',
    this.advanceDelta = 0,
    this.advanceSource,
  });

  /// 全局单调递增序号（三类事件共用一套序号，便于「第一条异常」定位）。
  final int seq;

  /// 发起这一刻的代次（当前实现里 = `TtsManager._generation` 会话令牌）。
  final int epoch;

  /// 文本前 8 字，供人工核对是哪一句。
  final String textPrefix;

  final DateTime issuedAt;

  /// 引擎返回时刻（null = 还没返回）。
  DateTime? doneAt;

  /// 引擎返回耗时（ms，null = 还没返回）。
  int? durationMs;

  /// 引擎是否正常返回（null = 还没返回）。
  bool? ok;

  /// 发起时的游标 "ch:p:s"。
  final String cursorBefore;

  /// 返回后这一拍结束时的游标 "ch:p:s"。
  String cursorAfter;

  /// 这一拍带来的游标推进量（0 = 没推进）。
  int advanceDelta;

  /// 推进来源（自动 / 点句 / 快进 / 恢复位置 / 目录 …）。
  String? advanceSource;
}

/// 一次游标推进。
class AdvanceEvent {
  const AdvanceEvent({
    required this.seq,
    required this.cursorBefore,
    required this.cursorAfter,
    required this.delta,
    required this.source,
    required this.epoch,
    required this.at,
  });

  final int seq;
  final String cursorBefore;
  final String cursorAfter;

  /// 跳跃量（句数）。
  final int delta;

  /// 来源：自动 / 点句 / 快进 / 恢复位置 / 目录 / 用户。
  final String source;

  /// 推进发生时的代次。
  final int epoch;

  final DateTime at;
}

/// 一次滚动。
class TurnEvent {
  const TurnEvent({
    required this.seq,
    required this.fromPage,
    required this.toPage,
    required this.sentencesOnFromPage,
    required this.elapsedSinceLastTurnMs,
    required this.trigger,
    required this.at,
  });

  final int seq;
  final int fromPage;
  final int toPage;

  /// 出发页上有多少句（用于 R8）。
  final int sentencesOnFromPage;

  /// 距上一次滚动的间隔（ms）。
  final int elapsedSinceLastTurnMs;

  /// 触发来源：用户 / 自动 / 目录 / 恢复位置 / 回到朗读位置。
  final String trigger;

  final DateTime at;
}

// ---------------------------------------------------------------------------
// 判定结果
// ---------------------------------------------------------------------------

/// 整体判定：🟢 正常 / 🟡 可疑 / 🔴 异常。
enum SpeechDiagLevel { ok, suspicious, abnormal }

/// 一条判据命中。
class SpeechDiagHit {
  const SpeechDiagHit({
    required this.rule,
    required this.level,
    required this.seq,
    required this.at,
    required this.detail,
  });

  /// 判据编号：R1 ~ R8。
  final String rule;

  final SpeechDiagLevel level;

  /// 命中的事件序号。
  final int seq;

  final DateTime at;

  /// 人类可读的细节（导出到异常窗口段）。
  final String detail;
}

/// 判定报告。
class SpeechDiagReport {
  const SpeechDiagReport({
    required this.level,
    required this.hits,
    required this.firstRedSeq,
    required this.firstRedAt,
  });

  final SpeechDiagLevel level;
  final List<SpeechDiagHit> hits;
  final int? firstRedSeq;
  final DateTime? firstRedAt;

  bool get hasRed => level == SpeechDiagLevel.abnormal;

  /// 某个判据命中的次数（导出摘要与自测都要用）。
  int countOf(String rule) => hits.where((SpeechDiagHit h) => h.rule == rule).length;

  /// 命中的判据编号（去重，便于测试断言）。
  List<String> get rules =>
      hits.map((SpeechDiagHit h) => h.rule).toSet().toList()..sort();

  /// 摘要行：`R2x3,R5x1`（按编号排序，无命中为空串）。
  String get hitsSummary {
    final Map<String, int> counts = <String, int>{};
    for (final SpeechDiagHit h in hits) {
      counts[h.rule] = (counts[h.rule] ?? 0) + 1;
    }
    final List<String> keys = counts.keys.toList()..sort();
    return keys.map((String k) => '$k x${counts[k]}').join(', ');
  }
}

// ---------------------------------------------------------------------------
// 采样 + 判定
// ---------------------------------------------------------------------------

/// 跳动检测的采样器与判定器（进程内单例）。
///
/// ⚠️ 所有 `record*` 方法都必须保持**零 IO、零 print、零 await**：
/// 它们跑在朗读主循环里，任何阻塞都会改变被测行为本身。
class SpeechDiagnostics {
  SpeechDiagnostics._();

  static final SpeechDiagnostics instance = SpeechDiagnostics._();

  /// 环形缓冲容量（任务书规定）。
  static const int speakCapacity = 200;
  static const int advanceCapacity = 200;
  static const int turnCapacity = 50;

  /// 判据阈值（与任务书一致）。
  static const int minRealSpeakMs = 100;
  static const int rapidAdvanceWindowMs = 1000;
  static const int rapidAdvanceLimit = 3;
  static const int rapidTurnWindowMs = 500;
  static const int rapidTurnStreak = 3;
  static const int bigJumpPages = 2;
  static const int shortPageSentences = 5;
  static const int contextWindow = 5;

  final List<SpeakEvent> speakEvents = <SpeakEvent>[];
  final List<AdvanceEvent> advanceEvents = <AdvanceEvent>[];
  final List<TurnEvent> turnEvents = <TurnEvent>[];

  /// 打断记录（内部辅助，不进导出结构）：R1 需要它区分「被打断所以没推进」。
  final List<({int epoch, DateTime at, bool paused})> interrupts =
      <({int epoch, DateTime at, bool paused})>[];

  DateTime? sessionStart;
  int _seq = 0;
  int _lastTurnAtMs = 0;

  // 用户显式操作标记：推进发生时若与它相邻，则来源算用户操作（不判 R3/R4）。
  String? _pendingSource;
  DateTime? _pendingSourceAt;

  int get eventCount =>
      speakEvents.length + advanceEvents.length + turnEvents.length;

  /// 已记录的滚动事件条数（**测试用**）
  ///
  /// 用途：验证「同一次显式定位只能记一笔」——
  /// v1.21.36+87 真机上出现过同一目标页在 2ms 内被记 5 次，
  /// 导致判据 R6「连续快速滚动」误判成红（见 [recordTurn] 的说明与
  /// `pdf_reading_page.dart` 的 `_revealToPageIndex` 去重）。
  int get turnEventCount => turnEvents.length;

  /// 记录一次用户显式操作（点句 / 快进 / 恢复位置 / 目录跳转）。
  ///
  /// 只影响后续 `recordAdvance` 的**来源标注**，不改变任何朗读逻辑。
  void markUserAction(String source) {
    _pendingSource = source;
    _pendingSourceAt = DateTime.now();
  }

  String _consumeSource([String fallback = '自动']) {
    final String? source = _pendingSource;
    final DateTime? at = _pendingSourceAt;
    _pendingSource = null;
    _pendingSourceAt = null;
    if (source == null || at == null) return fallback;
    // 用户操作与随之而来的推进之间允许 3 秒窗口，超过就当自动推进
    if (DateTime.now().difference(at).inMilliseconds > 3000) return fallback;
    return source;
  }

  void _trim<T>(List<T> list, int capacity) {
    while (list.length > capacity) {
      list.removeAt(0);
    }
  }

  /// 会话开始（用于导出里的 session_start）。
  void markSessionStart() {
    sessionStart ??= DateTime.now();
  }

  // ------------------------- 采样：三个写入点 -------------------------

  /// 埋点 1a：朗读单元发起。
  SpeakEvent recordSpeakIssued({
    required int epoch,
    required String text,
    required String cursor,
  }) {
    sessionStart ??= DateTime.now();
    final String prefix =
        text.length <= 8 ? text : text.substring(0, 8);
    final SpeakEvent event = SpeakEvent(
      seq: ++_seq,
      epoch: epoch,
      textPrefix: prefix,
      issuedAt: DateTime.now(),
      cursorBefore: cursor,
    );
    speakEvents.add(event);
    _trim<SpeakEvent>(speakEvents, speakCapacity);
    return event;
  }

  /// 埋点 1b：朗读单元返回（引擎给出结论）。
  void recordSpeakDone({required int epoch, required bool ok, String? cursorAfter}) {
    for (int i = speakEvents.length - 1; i >= 0; i--) {
      final SpeakEvent event = speakEvents[i];
      if (event.ok != null) continue;
      if (event.epoch != epoch) continue;
      final DateTime now = DateTime.now();
      event.doneAt = now;
      event.durationMs = now.difference(event.issuedAt).inMilliseconds;
      event.ok = ok;
      if (cursorAfter != null) event.cursorAfter = cursorAfter;
      return;
    }
  }

  /// 埋点 2：游标推进（在真正改写游标之前调用）。
  void recordAdvance({
    required String before,
    required String after,
    required int delta,
    required int epoch,
    String? source,
  }) {
    final String resolved = source ?? _consumeSource();
    // 把这次推进回填到「最近一次已返回、还没记推进」的朗读事件上
    for (int i = speakEvents.length - 1; i >= 0; i--) {
      final SpeakEvent event = speakEvents[i];
      if (event.ok == null) continue;
      if (event.cursorAfter.isNotEmpty) continue;
      event.cursorAfter = after;
      event.advanceDelta = delta;
      event.advanceSource = resolved;
      break;
    }
    advanceEvents.add(
      AdvanceEvent(
        seq: ++_seq,
        cursorBefore: before,
        cursorAfter: after,
        delta: delta,
        source: resolved,
        epoch: epoch,
        at: DateTime.now(),
      ),
    );
    _trim<AdvanceEvent>(advanceEvents, advanceCapacity);
  }

  /// 埋点 3：滚动。
  ///
  /// [sentencesOnFromPage] 传 -1 表示调用方不知道，此时由采样器按事件序列推算
  /// 「停留在出发页期间实际推进了多少句」——这正是 R8 要的口径。
  void recordTurn({
    required int fromPage,
    required int toPage,
    required int sentencesOnFromPage,
    required String trigger,
  }) {
    final DateTime now = DateTime.now();
    final int nowMs = now.millisecondsSinceEpoch;
    final int elapsed = _lastTurnAtMs == 0 ? -1 : nowMs - _lastTurnAtMs;
    _lastTurnAtMs = nowMs;
    final int sinceLastTurn = turnEvents.isEmpty
        ? advanceEvents.length
        : advanceEvents
            .where((AdvanceEvent e) => e.at.isAfter(turnEvents.last.at))
            .length;
    turnEvents.add(
      TurnEvent(
        seq: ++_seq,
        fromPage: fromPage,
        toPage: toPage,
        sentencesOnFromPage:
            sentencesOnFromPage >= 0 ? sentencesOnFromPage : sinceLastTurn,
        elapsedSinceLastTurnMs: elapsed,
        trigger: trigger,
        at: now,
      ),
    );
    _trim<TurnEvent>(turnEvents, turnCapacity);
  }

  /// 埋点 4：打断（stop / pause）。
  void recordInterrupt({required int epoch, required bool paused, required bool speaking}) {
    interrupts.add((epoch: epoch, at: DateTime.now(), paused: paused));
    while (interrupts.length > speakCapacity) {
      interrupts.removeAt(0);
    }
  }

  void clear() {
    speakEvents.clear();
    advanceEvents.clear();
    turnEvents.clear();
    interrupts.clear();
    sessionStart = null;
    _seq = 0;
    _lastTurnAtMs = 0;
    _pendingSource = null;
    _pendingSourceAt = null;
  }

  // ------------------------------ 判定 ------------------------------

  /// 判定 R1 ~ R8。纯函数式读取当前缓冲，不修改事件。
  SpeechDiagReport analyze() {
    final List<SpeechDiagHit> hits = <SpeechDiagHit>[];

    /// 用户显式操作：本身就会重建会话，epoch 变化是**预期**的。
    ///
    /// ⚠️ 声明在两条循环之前（v1.21.38）：R2 现在也用它（原来只硬编码排除「点句」），
    /// 而 R2 的循环在 R3/R4 之前 —— 放后面会"引用未声明"。
    const Set<String> explicitSources = <String>{
      '点句',
      '快进',
      '恢复位置',
      '目录',
      '书签',
      '用户',
    };

    // ---- 朗读事件：R1 / R2 / R5 ----
    for (int i = 0; i < speakEvents.length; i++) {
      final SpeakEvent event = speakEvents[i];
      final DateTime? doneAt = event.doneAt;
      final int? duration = event.durationMs;

      // R5：耗时 < 100ms 却报成功（典型「假完成」指纹）
      if (event.ok == true && duration != null && duration < minRealSpeakMs) {
        hits.add(
          SpeechDiagHit(
            rule: 'R5',
            level: SpeechDiagLevel.suspicious,
            seq: event.seq,
            at: doneAt ?? event.issuedAt,
            detail: 'speak 耗时 ${duration}ms 却 ok=true（低于 $minRealSpeakMs ms 合理下限）',
          ),
        );
      }

      // 这一拍之后、下一拍之前的推进与打断
      final DateTime windowEnd = i + 1 < speakEvents.length
          ? speakEvents[i + 1].issuedAt
          : DateTime(9999); // 哨兵：最后一拍一直看到底
      final DateTime windowStart = doneAt ?? event.issuedAt;
      final AdvanceEvent? follow = _firstAdvanceBetween(windowStart, windowEnd);
      final bool interrupted = interrupts.any(
        (({int epoch, DateTime at, bool paused}) mark) =>
            mark.epoch == event.epoch &&
            mark.at.isAfter(windowStart) &&
            mark.at.isBefore(windowEnd),
      );

      if (follow != null) {
        // R2：推进了，但推进时所属代次与这一拍的代次不一致 → 不该推进却推进了
        //
        // ⚠️ 只在**「引擎声称读完了」且非显式操作**时报（v1.21.38 收紧）：
        //
        // ① `event.ok == true` 是前提。`ok == false` 说明这一拍是**超时 / 取消 /
        //    失败** —— 它本就不该推进，后面出现的那次推进**一定来自新会话**
        //    （用户在这期间点句 / 快进，`_generation` 涨了一代，新循环正常读完一句
        //    才记的推进）。这是正常语义，不是异常。
        //    典型误报（真机 v1.21.37 日志）：单字符「”」送进引擎后**从不回调完成**，
        //    卡满 `speakTimeout`（ms=30001 ok=false）；用户在挂住期间点了句，
        //    新会话读完后按"自动"记了一笔推进 → 被判成 epoch 错位。
        //    ⚠️ 加这个条件**不会漏掉 §4.107 那类真 bug**：那里的场景是
        //    「取消被当成完成」—— 那种情况下 ok 恰好是 **true**，R2 照报。
        // ② 显式操作（点句 / 快进 / 恢复位置 / 目录 / 书签）本身就会重建会话，
        //    epoch 变化是预期的 —— 与 R3/R4 共用同一张表，不再只硬编码排除「点句」。
        final bool completedRead = event.ok == true;
        if (completedRead &&
            follow.epoch != event.epoch &&
            !explicitSources.contains(follow.source)) {
          hits.add(
            SpeechDiagHit(
              rule: 'R2',
              level: SpeechDiagLevel.abnormal,
              seq: follow.seq,
              at: follow.at,
              detail: '推进 ${follow.cursorBefore} → ${follow.cursorAfter}（delta=${follow.delta}）'
                  ' 发生在 epoch=${follow.epoch}，而这一拍出自 epoch=${event.epoch}'
                  '（文本「${event.textPrefix}」）',
            ),
          );
        }
      } else if (event.ok == true && interrupted) {
        // R1：引擎说完成了，但这一拍被 stop/pause 打断、最终没有推进
        hits.add(
          SpeechDiagHit(
            rule: 'R1',
            level: SpeechDiagLevel.suspicious,
            seq: event.seq,
            at: windowStart,
            detail: 'ok=true 但 epoch=${event.epoch} 期间被 stop/pause 打断，'
                '该推进没推进（文本「${event.textPrefix}」）',
          ),
        );
      }
    }

    // ---- 推进事件：R3 / R4 ----
    for (int i = 0; i < advanceEvents.length; i++) {
      final AdvanceEvent event = advanceEvents[i];
      final bool explicit = explicitSources.contains(event.source);

      // R3：一次跳多句，且不是用户显式操作
      if (event.delta > 1 && !explicit) {
        hits.add(
          SpeechDiagHit(
            rule: 'R3',
            level: SpeechDiagLevel.abnormal,
            seq: event.seq,
            at: event.at,
            detail: '单次推进 ${event.delta} 句（${event.cursorBefore} → ${event.cursorAfter}）'
                '来源=${event.source}，非用户显式操作',
          ),
        );
      }

      // R4：1 秒内推进超过 3 句
      if (i >= rapidAdvanceLimit - 1) {
        final AdvanceEvent first = advanceEvents[i - (rapidAdvanceLimit - 1)];
        final int span = event.at.difference(first.at).inMilliseconds;
        if (span >= 0 && span <= rapidAdvanceWindowMs && !explicit) {
          hits.add(
            SpeechDiagHit(
              rule: 'R4',
              level: SpeechDiagLevel.abnormal,
              seq: event.seq,
              at: event.at,
              detail: '${span}ms 内连续推进 $rapidAdvanceLimit 次'
                  '（${first.cursorBefore} → ${event.cursorAfter}）',
            ),
          );
        }
      }
    }

    // ---- 滚动事件：R6 / R7 / R8 ----
    int rapidStreak = 0;
    for (final TurnEvent event in turnEvents) {
      // R6：滚动间隔 < 500ms 且连续 ≥ 3 次
      if (event.elapsedSinceLastTurnMs >= 0 &&
          event.elapsedSinceLastTurnMs < rapidTurnWindowMs) {
        rapidStreak++;
        if (rapidStreak >= rapidTurnStreak) {
          hits.add(
            SpeechDiagHit(
              rule: 'R6',
              level: SpeechDiagLevel.abnormal,
              seq: event.seq,
              at: event.at,
              detail: '连续快速滚动（间隔 ${event.elapsedSinceLastTurnMs}ms < ${rapidTurnWindowMs}ms），'
                  '${event.fromPage} → ${event.toPage}，触发=${event.trigger}',
            ),
          );
        }
      } else {
        rapidStreak = 0;
      }

      // R7：向前跳超过 2 页，且不是目录 / 书签 / 恢复位置这类显式定位
      final bool jumpSource = event.trigger == '目录' ||
          event.trigger == '书签' ||
          event.trigger == '用户' ||
          event.trigger == '恢复位置';
      if (event.toPage > event.fromPage + bigJumpPages && !jumpSource) {
        hits.add(
          SpeechDiagHit(
            rule: 'R7',
            level: SpeechDiagLevel.suspicious,
            seq: event.seq,
            at: event.at,
            detail: '滚动跨度 ${event.fromPage} → ${event.toPage}（> +$bigJumpPages 页），'
                '触发=${event.trigger}',
          ),
        );
      }

      // R8：本页没读几句就被翻走
      if (event.trigger == '自动' &&
          event.sentencesOnFromPage >= 0 &&
          event.sentencesOnFromPage < shortPageSentences) {
        hits.add(
          SpeechDiagHit(
            rule: 'R8',
            level: SpeechDiagLevel.suspicious,
            seq: event.seq,
            at: event.at,
            detail: '第 ${event.fromPage} 页只推进了 ${event.sentencesOnFromPage} 句就被翻走'
                '（< $shortPageSentences）',
          ),
        );
      }
    }

    hits.sort((SpeechDiagHit a, SpeechDiagHit b) => a.seq.compareTo(b.seq));
    final Iterable<SpeechDiagHit> reds =
        hits.where((SpeechDiagHit h) => h.level == SpeechDiagLevel.abnormal);
    final SpeechDiagLevel level = reds.isNotEmpty
        ? SpeechDiagLevel.abnormal
        : (hits.isNotEmpty ? SpeechDiagLevel.suspicious : SpeechDiagLevel.ok);
    return SpeechDiagReport(
      level: level,
      hits: hits,
      firstRedSeq: reds.isEmpty ? null : reds.first.seq,
      firstRedAt: reds.isEmpty ? null : reds.first.at,
    );
  }

  AdvanceEvent? _firstAdvanceBetween(DateTime start, DateTime end) {
    for (final AdvanceEvent event in advanceEvents) {
      if (event.at.isBefore(start)) continue;
      if (!event.at.isBefore(end)) return null;
      return event;
    }
    return null;
  }

  // ------------------------------ 导出 ------------------------------

  /// 导出文本的**逐行迭代器**（v1.21.13 / B-P3）。
  ///
  /// 落盘层（`speech_diag_export.dart`）用它一条条写进 IOSink，**不先拼全文**：
  /// 事件多的时候「先 `StringBuffer` 拼完整串再 `writeAsString`」那一下就是内存尖峰
  /// （5 万条 ≈ 十几 MB），在低端机上是闪退的典型来源。
  ///
  /// 语义与 [buildExportText] 完全一致 —— 后者现在就是它的 `join`。
  Iterable<String> exportLines({
    required bool includeAllEvents,
    Map<String, String> meta = const <String, String>{},
  }) sync* {
    final SpeechDiagReport report = analyze();
    yield 'speech_diag_v1';
    yield '[meta]';
    for (final MapEntry<String, String> entry in meta.entries) {
      yield '${entry.key}=${entry.value}';
    }
    yield 'export_time=${DateTime.now().toIso8601String()}';
    yield 'session_start=${sessionStart?.toIso8601String() ?? "unknown"}';
    yield 'event_count.speak=${speakEvents.length}';
    yield 'event_count.advance=${advanceEvents.length}';
    yield 'event_count.turn=${turnEvents.length}';
    yield '[verdict]';
    yield 'overall=${_levelName(report.level)}';
    yield 'hits=${report.hitsSummary}';
    yield 'first_red_at=${report.firstRedSeq == null ? "none" : "seq=${report.firstRedSeq} time=${report.firstRedAt!.toIso8601String()}"}';

    yield '[abnormal]';
    final List<SpeechDiagHit> reds = report.hits
        .where((SpeechDiagHit h) => h.level == SpeechDiagLevel.abnormal)
        .toList();
    if (reds.isEmpty) {
      yield 'none';
    } else {
      for (final SpeechDiagHit hit in reds) {
        yield '--- ${hit.rule} seq=${hit.seq} at=${hit.at.toIso8601String()}';
        yield hit.detail;
        yield 'context:';
        yield* _contextLines(hit.seq);
      }
    }

    if (includeAllEvents) {
      yield '[events]';
      yield* _allEventLines();
    }
  }

  /// 导出**行数**估算（B-P3 的「大导出」确认框用）。
  ///
  /// 不拼字符串，只按与 [exportLines] 一一对应的写法累加；
  /// `speech_diag_export_test` 里有「估算 == 实际行数」的对拍用例。
  int estimateExportLines({
    required bool includeAllEvents,
    Map<String, String> meta = const <String, String>{},
  }) {
    // 头部固定 12 行（schema / [meta] / export_time / session_start /
    // 3 条计数 / [verdict] / overall / hits / first_red_at / [abnormal]）+ meta 条数
    int lines = 12 + meta.length;
    final SpeechDiagReport report = analyze();
    final List<SpeechDiagHit> reds = report.hits
        .where((SpeechDiagHit h) => h.level == SpeechDiagLevel.abnormal)
        .toList();
    if (reds.isEmpty) {
      lines += 1;
    } else {
      for (final SpeechDiagHit hit in reds) {
        // 两条头 + 'context:' + 窗口行
        lines += 3 + _contextLines(hit.seq).length;
      }
    }
    // 全量段：`[events]` 标题 1 行 + 每条事件 1 行
    if (includeAllEvents) lines += 1 + eventCount;
    return lines;
  }

  /// 导出文本。首行固定 schema 版本号。
  ///
  /// [includeAllEvents] 为假时只导「元信息 + 判定摘要 + 异常窗口」。
  String buildExportText({
    required bool includeAllEvents,
    Map<String, String> meta = const <String, String>{},
  }) =>
      exportLines(includeAllEvents: includeAllEvents, meta: meta)
          .map((String line) => '$line\n')
          .join();

  /// 当前缓冲的**脱离副本**（B-P3）：给隔离线程用。
  ///
  /// 为什么不能直接在隔离线程里读 `SpeechDiagnostics.instance`：单例是
  /// **进程内**的，隔离线程拿到的是另一份空实例（事件全丢）。所以必须在主线程
  /// 先取这份纯数据副本（列表 + 标量 + record），再当参数传进去。
  SpeechDiagnostics detachedCopy() {
    final SpeechDiagnostics copy = SpeechDiagnostics._();
    copy.speakEvents.addAll(speakEvents);
    copy.advanceEvents.addAll(advanceEvents);
    copy.turnEvents.addAll(turnEvents);
    copy.interrupts.addAll(interrupts);
    copy.sessionStart = sessionStart;
    copy._seq = _seq;
    copy._lastTurnAtMs = _lastTurnAtMs;
    copy._pendingSource = _pendingSource;
    copy._pendingSourceAt = _pendingSourceAt;
    return copy;
  }

  /// 命中事件前后各 5 条事件（三类事件按序号合并排序后取窗口）。
  List<String> _contextLines(int seq) {
    final List<({int seq, DateTime at, String line})> all =
        <({int seq, DateTime at, String line})>[
      for (final SpeakEvent e in speakEvents)
        (
          seq: e.seq,
          at: e.issuedAt,
          line: 'speak seq=${e.seq} epoch=${e.epoch} text=${e.textPrefix} '
              'issued=${e.issuedAt.toIso8601String()} '
              'done=${e.doneAt?.toIso8601String() ?? "-"} '
              'ms=${e.durationMs ?? -1} ok=${e.ok?.toString() ?? "-"} '
              'cursor=${e.cursorBefore}->${e.cursorAfter} '
              'delta=${e.advanceDelta} source=${e.advanceSource ?? "-"}'
        ),
      for (final AdvanceEvent e in advanceEvents)
        (
          seq: e.seq,
          at: e.at,
          line: 'advance seq=${e.seq} epoch=${e.epoch} '
              '${e.cursorBefore}->${e.cursorAfter} delta=${e.delta} '
              'source=${e.source} at=${e.at.toIso8601String()}'
        ),
      for (final TurnEvent e in turnEvents)
        (
          seq: e.seq,
          at: e.at,
          line: 'turn seq=${e.seq} ${e.fromPage}->${e.toPage} '
              'sentences=${e.sentencesOnFromPage} '
              'elapsed=${e.elapsedSinceLastTurnMs}ms trigger=${e.trigger} '
              'at=${e.at.toIso8601String()}'
        ),
    ]..sort((({int seq, DateTime at, String line}) a,
            ({int seq, DateTime at, String line}) b) =>
        a.seq.compareTo(b.seq));
    final int index = all.indexWhere((({int seq, DateTime at, String line}) e) => e.seq == seq);
    if (index < 0) return const <String>['(context unavailable)'];
    final int from = math.max(0, index - contextWindow);
    final int to = math.min(all.length, index + contextWindow + 1);
    return <String>[for (int i = from; i < to; i++) '  ${all[i].line}'];
  }

  /// 三类事件的单行文本（**惰性**：B-P3 之后导出路径逐条消费，不再先建整表）。
  Iterable<String> _allEventLines() sync* {
    for (final SpeakEvent e in speakEvents) {
      yield 'speak seq=${e.seq} epoch=${e.epoch} text=${e.textPrefix} '
          'issued=${e.issuedAt.toIso8601String()} '
          'done=${e.doneAt?.toIso8601String() ?? "-"} ms=${e.durationMs ?? -1} '
          'ok=${e.ok?.toString() ?? "-"} cursor=${e.cursorBefore}->${e.cursorAfter} '
          'delta=${e.advanceDelta} source=${e.advanceSource ?? "-"}';
    }
    for (final AdvanceEvent e in advanceEvents) {
      yield 'advance seq=${e.seq} epoch=${e.epoch} ${e.cursorBefore}->${e.cursorAfter} '
          'delta=${e.delta} source=${e.source} at=${e.at.toIso8601String()}';
    }
    for (final TurnEvent e in turnEvents) {
      yield 'turn seq=${e.seq} ${e.fromPage}->${e.toPage} '
          'sentences=${e.sentencesOnFromPage} elapsed=${e.elapsedSinceLastTurnMs}ms '
          'trigger=${e.trigger} at=${e.at.toIso8601String()}';
    }
  }

  static String _levelName(SpeechDiagLevel level) => switch (level) {
        SpeechDiagLevel.ok => 'green',
        SpeechDiagLevel.suspicious => 'yellow',
        SpeechDiagLevel.abnormal => 'red',
      };

  static String levelEmoji(SpeechDiagLevel level) => switch (level) {
        SpeechDiagLevel.ok => '🟢',
        SpeechDiagLevel.suspicious => '🟡',
        SpeechDiagLevel.abnormal => '🔴',
      };

  /// 供 UI 展示：最近 N 条事件的单行文本（新的在后）。
  List<String> recentLines(int limit) {
    final List<String> lines = _allEventLines().toList();
    if (lines.length <= limit) return lines;
    return lines.sublist(lines.length - limit);
  }
}

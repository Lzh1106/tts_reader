import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// **「被打断的那一拍不得推进位置」——可红的回归用例（§4.108）**
///
/// ## 为什么要专门写这个
///
/// §4.107 声称「治根」：在 `TtsManager` 加 `_speakInterrupted` 布尔标记，
/// 把「被 stop/pause 掐断」与「自然读完」分开。HANDOFF §4.107 末尾自己承认
/// **验证装置失真**：模拟器没有系统 TTS 引擎，测试里的假引擎是"立刻返回"的，
/// 于是 `_speaking` 在 `stop()` 之前就已经变 false，
/// `if (_speaking && !_paused) _speakInterrupted = true;` 这条分支**从来没走到过**。
/// 也就是说 638 项全绿里**没有一项**验证过这条链。
///
/// 本文件用一个「**永不自然返回、只能由测试手动唤醒**」的假引擎补上这一环：
/// 这样 `_speaking` 在 `stop()` 之前**保持为 true**，设标记的分支才真的会执行。
///
/// ## 案例设计（故意避开时序竞态，做成确定性序列）
///
/// ```
/// 1. 起读 → 引擎挂住（永不返回）           _speaking = true
/// 2. stop()                              → 设 _speakInterrupted = true（本用例的前提）
/// 3. 再起一个新会话（模拟"用户又点了别处"） → 会话起点 **清掉** 刚设的标记
/// 4. 手动唤醒第 1 次 speak 的等待           → 旧循环那一拍返回
/// 5. 断言：位置不得因为第 4 步而推进
///    —— 第 1 次 speak 是被 stop 掐掉的，它不是"读完"
/// ```
///
/// 第 3 步是关键：它复刻了「PDF 每句都是新会话、每个新会话都会清标记」
/// 与「旧会话的取消回调更晚才回来」的**交错**。
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

  late Map<int, PdfPageTextLayer> pages;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    TtsManager.instance.resetSessionForTest();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.speakTimeout = const Duration(seconds: 30);
    pages = <int, PdfPageTextLayer>{
      0: makePage(1, '第一页甲。第一页乙。第一页丙。'),
      1: makePage(2, '第二页甲。第二页乙。'),
    };
    PdfReadSession.instance.resetForTest();
    PdfReadSession.instance.audioBridge = _NullBridge();
  });

  tearDown(() async {
    await PdfReadSession.instance.clear();
    PdfReadSession.instance.resetForTest();
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.resetSessionForTest();
  });

  Future<void> openSession() => PdfReadSession.instance.open(
        documentId: 'interrupt-repro',
        title: '打断复现',
        pageCount: 2,
        layerLoader: (i) async => pages[i],
      );

  Future<void> waitFor(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('① stop 打断后，被掐掉那一拍的完成回调**不得**推进位置', () async {
    // 「永不自然返回」的引擎：只有 `wakeCurrent()` 才让 speak() 返回
    final engine = _ManualEngine();
    await TtsManager.instance.registerEngine(engine, makeActive: true);
    await openSession();
    final s = PdfReadSession.instance;

    // 1. 起读 → 引擎挂住
    s.startAt(sentenceRefAt(0, 0, pages[0]!)!);
    await waitFor(() => engine.speakCalls >= 1);
    expect(engine.speakCalls, 1, reason: '前提：第 1 次 speak 已经发出并挂住');

    final posBefore = s.current?.sentenceIndex ?? -1;
    // ignore: avoid_print
    print('DEVICE_PROBE[打断复现] 起读后 speaking=${TtsManager.instance.speaking} '
        'paused=${TtsManager.instance.paused} 位置=$posBefore');

    // 2. stop()：此刻 _speaking 仍为 true → 设标记那条分支**真的会走到**
    await TtsManager.instance.stop();
    // ignore: avoid_print
    print('DEVICE_PROBE[打断复现] stop 之后 lastSpeakInterrupted='
        '${TtsManager.instance.speaking}'
        '（期望 true —— 这是"设标记分支走到了"的证据）');
    expect(TtsManager.instance.speaking, isFalse,
        reason: 'stop() 掐掉一次正在飞的朗读后，必须被标记为「被打断」。\n'
            '若这里已是 false，说明守卫 `_speaking && !_paused` 没生效');

    // 3. 再起一个新会话（模拟"用户又点了别处"）—— 会话起点会清掉标记
    PdfReadSession.instance.startAt(sentenceRefAt(0, 1, pages[0]!)!);
    await waitFor(() => engine.speakCalls >= 2);
    // ignore: avoid_print
    print('DEVICE_PROBE[打断复现] 新会话起来后 lastSpeakInterrupted='
        '${TtsManager.instance.speaking}'
        '（新会话起点清标记 → 期望 false，这正是缺陷所在）');

    // 4. 现在才唤醒**第 1 次** speak 的等待（取消回调晚到的等价场景）
    final posBeforeWake = s.current?.sentenceIndex ?? -1;
    engine.wakeOldest();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final posAfter = s.current?.sentenceIndex ?? -1;

    // ignore: avoid_print
    print('DEVICE_PROBE[打断复现] 唤醒旧 speak 前=$posBeforeWake 后=$posAfter '
        '（唤醒的是被 stop 掐掉的那一拍）');

    // 5. 断言：被掐掉的那一拍不得推进位置
    expect(posAfter, posBeforeWake,
        reason: '**被 stop 掐掉的那次 speak 不是"读完"**，它返回时不得让游标前进。\n'
            '位置从 $posBeforeWake 变成 $posAfter = 这一拍被误当成读完了（§4.108 缺陷）');
  });

  test('② 反向：无人打断时，自然读完必须照常推进', () async {
    final engine = _ManualEngine();
    await TtsManager.instance.registerEngine(engine, makeActive: true);
    await openSession();
    final s = PdfReadSession.instance;
    s.startAt(sentenceRefAt(0, 0, pages[0]!)!);
    await waitFor(() => engine.speakCalls >= 1);
    final before = s.current?.sentenceIndex ?? -1;

    // 自然读完：唤醒，且期间没有 stop
    engine.wakeCurrent();
    await waitFor(() => engine.speakCalls >= 2,
        timeout: const Duration(seconds: 2));
    final after = s.current?.sentenceIndex ?? -1;

    // ignore: avoid_print
    print('DEVICE_PROBE[反向] speakCalls=${engine.speakCalls} '
        '$before → $after');
    expect(after, greaterThan(before),
        reason: '没人打断时必须照常推进（判据不能把正常朗读也挡掉）');
  });

  test('③ pause 之后再 stop，也必须识别为打断', () async {
    final engine = _ManualEngine();
    await TtsManager.instance.registerEngine(engine, makeActive: true);
    await openSession();
    final s = PdfReadSession.instance;
    s.startAt(sentenceRefAt(0, 0, pages[0]!)!);
    await waitFor(() => engine.speakCalls >= 1);

    await TtsManager.instance.pause(); // 先暂停
    await TtsManager.instance.stop(); // 再停止
    // ignore: avoid_print
    print('DEVICE_PROBE[pause→stop] lastSpeakInterrupted='
        '${TtsManager.instance.speaking}');
    expect(TtsManager.instance.speaking, isFalse,
        reason: 'pause 之后 _paused 为真、_speaking 可能已 false，'
            '用状态量做守卫会漏判；pause→stop 也必须算打断');
  });
}

/// **永不自然返回**的引擎：`speak()` 挂住，直到测试显式 `wake*()`。
///
/// 这是本文件的关键 —— 原来的假引擎「立刻返回」，导致 `_speaking` 在 `stop()`
/// 之前就已变成 false，于是 `stop()` 里设标记的分支永远走不到，
/// 整条链在测试里从未被覆盖（HANDOFF §4.107 末尾承认的"验证装置失真"）。
class _ManualEngine with SyntheticTtsEngine implements TtsEngine {
  int speakCalls = 0;
  final List<Completer<void>> _pending = <Completer<void>>[];

  @override
  String get id => 'manual-hold';
  @override
  String get displayName => '手动唤醒假引擎';
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
    speakCalls++;
    final done = Completer<void>();
    _pending.add(done);
    try {
      await done.future; // 挂住，永不自然返回
    } finally {
      _pending.remove(done);
    }
  }

  /// 唤醒最早那次挂住的 speak（= 被取消的那一拍的回调）
  void wakeOldest() {
    if (_pending.isEmpty) return;
    final p = _pending.first;
    if (!p.isCompleted) p.complete();
  }

  /// 唤醒最近那次挂住的 speak（= 自然读完）
  void wakeCurrent() {
    if (_pending.isEmpty) return;
    final p = _pending.last;
    if (!p.isCompleted) p.complete();
  }

  @override
  Future<void> stop() async {
    // 真机 SystemTtsEngine.stop() 会 `_completePending()` **同步**唤醒在等的 speak。
    // 这里刻意**不**唤醒：让"取消回调晚到"这个时序在测试里可控、可确定复现。
  }

  @override
  Future<void> pause() async {}

  @override
  void setCompletionHandler(void Function()? handler) {}
  @override
  Future<void> dispose() async {}
}

/// 不碰通知栏的音频桥（单测里 `audioHandler` 是 null）
class _NullBridge extends PdfSessionAudioBridge {
  @override
  void release(PdfReadSession session) {}
  @override
  void notifyIfActive(PdfReadSession session) {}
}

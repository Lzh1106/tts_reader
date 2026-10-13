import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// **短时间连点相邻句不丢目标（§4.102 意图游标）**
///
/// ## 用户症状
///
/// 「短时间内点击切换相邻的句子」时，屏幕滚到随机位置、从错误位置开始读；
/// TXT/EPUB 与 PDF **症状一致**，PDF 更频繁。
///
/// ## 根因
///
/// 点句 / 快进的取目标方式都是「**读游标 → 算相邻句**」：
///
/// ```dart
/// speakFrom(cursor.$1, cursor.$2, cursor.$3 + 1);   // 下一句
/// ```
///
/// 而 `speakFrom` 只是**发起**：真实游标 `_ch/_p/_s` 要等 `_runBody` 里
/// `await 停引擎` 之后才写（真机实测 **5–78ms**）。在这个窗口里读 `cursor`
/// 拿到的是**还没更新的旧值** —— 于是短间隔连点时：
///
/// 1. 第 1 次点 → 目标 (0,0,1)，游标仍是 (0,0,0)；
/// 2. 第 2 次点（<78ms）→ 读到的还是 (0,0,0) → **又算出 (0,0,1)**；
/// 3. 每次都把 `_generation` 加一 → 上一个 `_runBody` 判过期直接 return；
/// 4. 结果：**所有点击都算成同一句**，只有最后一次生效，且目标还是错的。
///
/// 真机实测（真实 EPUB《国家与革命》，间隔 80ms ×6）：六次点到的目标全是
/// 同一个 `(0,0,1)`，而游标自始至终停在 `(0,0,0)`。
///
/// ## 修法（意图游标）
///
/// `TtsManager` 增 `_pendingCursor`：`speakFrom` **同步**写入，
/// `cursor` getter 优先返回它，`_runBody` 真正落地后清空。
/// 于是窗口期内「读游标」读到的是**用户最后一次点的位置**。
///
/// 两条路（点屏 / 快进）都用同一个 getter，所以一次覆盖两条 ——
/// 这也正是为什么不在阅读页取目标那一步改（那只覆盖「点屏」）。
///
/// ⚠️ 管理层的 `skipSentence` / `_clampCursor` 也必须走「有效位置」，
/// 否则快进那条仍然基于旧游标算（本文件的快进用例就是守这条）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    TtsManager.instance.resetSessionForTest();
    // 兜底超时给短一点：用例用「挂住不停」的引擎把窗口拉开，
    // 收尾要靠这些超时到期把定时器清掉（§9.47「A Timer is still pending」）。
    TtsManager.instance
      ..speakTimeout = const Duration(milliseconds: 300)
      ..initTimeout = const Duration(milliseconds: 300)
      ..controlTimeout = const Duration(milliseconds: 300);
  });

  tearDown(() async {
    TtsManager.instance.resetTimeouts();
    await TtsManager.instance.stop();
    TtsManager.instance.resetSessionForTest();
  });

  /// 用例收尾：把挂住的引擎超时跑到期、把真实异步跑完
  /// （照抄 reader_jump_test 的 cleanup 思路）
  Future<void> drainTimers(WidgetTester tester) async {
    TtsManager.instance.resetTimeouts();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
    }
    await TtsManager.instance.stop();
    await tester.pump(const Duration(seconds: 2));
  }

  /// 两章、每章一段 6 句 —— 足够验证「相邻句」与「跨章」
  StructuredDocument doc6() => StructuredDocument(
        chapters: <Chapter>[
          for (var c = 0; c < 2; c++)
            Chapter(
              title: 'C$c',
              paragraphs: <Paragraph>[
                Paragraph(sentences: <Sentence>[
                  for (var i = 0; i < 6; i++) Sentence('C$c 第 $i 句。'),
                ]),
              ],
            ),
        ],
      );

  /// **`speak` 挂住、`stop` 正常返回**的引擎。
  ///
  /// 这是本文件的关键测试装置：
  /// - `stop()` 立刻返回 → `_runBody` 能走过「停引擎」那一步，把游标**落地**，
  ///   于是能验证「落地后清意图」；
  /// - `speak()` 永不返回 → `_speakLoop` 卡在那一句上，**自动推进不会跑**，
  ///   所以游标不会在断言之前自己往前走（这是第一版用例失败的原因：
  ///   用 `stop` 也挂住的引擎时，300ms 超时兜底一放开，整本书就被读完，
  ///   收尾游标成了 (1,0,5)）。
  Future<void> useHoldingEngine() async {
    await TtsManager.instance.registerEngine(_HoldingEngine(), makeActive: true);
  }

  // ============================================================ 点屏路径
  testWidgets('连点相邻句：最后生效的必须是最后点的那句（点屏路径）',
      (tester) async {
    await useHoldingEngine();
    final tts = TtsManager.instance;
    tts.loadDocument(doc6(), title: 'T', documentId: 'rapid-tap');
    expect(tts.cursor, (0, 0, 0));

    // 模拟用户短时间连点「相邻的下一句」三次：
    // 每次都是「读当前游标 → 点它的下一句」，间隔 25ms（远小于引擎往返）
    final seen = <(int, int, int)>[];
    for (var i = 0; i < 3; i++) {
      final c = tts.cursor;
      final target = (c.$1, c.$2, c.$3 + 1);
      seen.add(target);
      tts.speakFrom(target.$1, target.$2, target.$3);
      await tester.pump(const Duration(milliseconds: 25));
    }

    // ignore: avoid_print
    print('DBG rapid-tap：三次点到的目标 = $seen 最终 cursor=${tts.cursor}');

    // ① 三次点击必须**依次前进**，不能都算成同一句
    expect(seen, <(int, int, int)>[(0, 0, 1), (0, 0, 2), (0, 0, 3)],
        reason: '短时间连点相邻句时，每次都要基于**上一次的意图**前进，'
            '不能因为真实游标还没落地就反复算出同一句');
    // ② 最终生效的是**最后点的那句**
    expect(tts.cursor, (0, 0, 3), reason: '最后一次意图必须生效（不是 (0,0,1)）');

    // ③ 而且**真实游标也真的落到了那里** —— 否则就只是意图层在掩盖
    //    「真实游标一直没动」，下一次改动的基数仍然是错的。
    for (var i = 0; i < 40; i++) {
      if (tts.settledCursor == (0, 0, 3)) break;
      await tester.pump(const Duration(milliseconds: 25));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
    }
    // ignore: avoid_print
    print('DBG rapid-tap：真实游标 settled=${tts.settledCursor} '
        '（意图 cursor=${tts.cursor}）');
    expect(tts.settledCursor, (0, 0, 3),
        reason: '最后一次意图必须真的落地到真实游标，不能只停在意图层');
    await drainTimers(tester);
  });

  testWidgets('连点相邻句：每次读 cursor 都反映「最后一次意图」', (tester) async {
    await useHoldingEngine();
    final tts = TtsManager.instance;
    tts.loadDocument(doc6(), title: 'T', documentId: 'rapid-intent');

    tts.speakFrom(0, 0, 1);
    expect(tts.cursor, (0, 0, 1), reason: '发起后立刻读 cursor 应当看到意图');
    tts.speakFrom(0, 0, 2);
    expect(tts.cursor, (0, 0, 2), reason: '第二次意图要覆盖第一次');
    tts.speakFrom(0, 0, 3);
    expect(tts.cursor, (0, 0, 3), reason: '第三次意图要覆盖第二次');
    expect(tts.cursor, isNot((0, 0, 0)),
        reason: '窗口期内 cursor 不许返回还没更新的旧游标');
    await drainTimers(tester);
  });

  // ============================================================ 快进路径
  testWidgets('快进连点 3 次：游标要前进 3 句（快进路径）', (tester) async {
    await useHoldingEngine();
    final tts = TtsManager.instance;
    tts.loadDocument(doc6(), title: 'T', documentId: 'rapid-skip');
    expect(tts.cursor, (0, 0, 0));

    tts.skipSentenceForward();
    await tester.pump(const Duration(milliseconds: 25));
    tts.skipSentenceForward();
    await tester.pump(const Duration(milliseconds: 25));
    tts.skipSentenceForward();
    await tester.pump(const Duration(milliseconds: 25));

    // ignore: avoid_print
    print('DBG rapid-skip：连点 3 次后 cursor=${tts.cursor}');
    expect(tts.cursor, (0, 0, 3),
        reason: '快进连点 3 次必须前进 3 句；'
            '修复前会因为读旧游标而全部退化成「永远第 1 句」');
    await drainTimers(tester);
  });

  testWidgets('快进跨段/跨章也要基于意图前进', (tester) async {
    await useHoldingEngine();
    final tts = TtsManager.instance;
    tts.loadDocument(doc6(), title: 'T', documentId: 'rapid-skip2');

    // 从 (0,0,5) 起步，连点 2 次应当跨到下一章
    tts.speakFrom(0, 0, 5);
    tts.skipSentenceForward();
    await tester.pump(const Duration(milliseconds: 25));
    expect(tts.cursor, (1, 0, 0), reason: '第 1 次快进应当跨到第 2 章第 1 句');
    tts.skipSentenceForward();
    await tester.pump(const Duration(milliseconds: 25));
    expect(tts.cursor, (1, 0, 1), reason: '第 2 次快进再前进一句');
    await drainTimers(tester);
  });

  // ================================================== 落地后回归真实游标
  testWidgets('意图落地后 cursor 回归真实游标（清 null）', (tester) async {
    // 用「停得住、读不完」的引擎：游标会落地，但推进循环不会把整本书读完
    await useHoldingEngine();
    final tts = TtsManager.instance;
    tts.loadDocument(doc6(), title: 'T', documentId: 'landing');

    tts.speakFrom(0, 0, 2);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
    }
    // ignore: avoid_print
    print('DBG landing：speakFrom(0,0,2) 之后 cursor=${tts.cursor} '
        'speaking=${tts.speaking}');
    // 意图落地（清 null）+ 推进卡住 → 游标应当**正好**停在目标那一句
    expect(tts.cursor, (0, 0, 2),
        reason: '落地后 cursor 应当回归真实游标 (0,0,2)：'
            '既不该回到更早的位置，也不该自己乱走');
    await tts.stop();
    await drainTimers(tester);
  });

  // ============================================ 换书 / 清理不留跨文档意图
  testWidgets('意图不跨文档 / 不跨会话残留', (tester) async {
    await useHoldingEngine();
    final tts = TtsManager.instance;
    tts.loadDocument(doc6(), title: 'A', documentId: 'docA');
    tts.speakFrom(0, 0, 4);
    expect(tts.cursor, (0, 0, 4), reason: '前提：意图已记下');

    // 换到另一本文档：意图必须作废
    tts.loadDocument(doc6(), title: 'B', documentId: 'docB');
    expect(tts.cursor, (0, 0, 0), reason: '换书后不许把上一本的意图带过来');

    // 再起一个意图，然后 endSessionAndClear 清掉内容
    tts.speakFrom(1, 0, 3);
    expect(tts.cursor, (1, 0, 3));
    await tts.endSessionAndClear();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tts.cursor, (0, 0, 0), reason: 'endSessionAndClear 之后意图也必须清掉');
    await drainTimers(tester);
  });
}

/// `speak` 挂住、`stop` 正常返回 —— 让游标能落地但推进循环停住
class _HoldingEngine with SyntheticTtsEngine implements TtsEngine {
  @override
  String get id => 'rapid-hold';

  @override
  String get displayName => '假引擎（停得住、读不完）';

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

  /// 永不返回：推进循环卡在这一句，游标不会自己往前走
  @override
  Future<void> speak(String text) => Completer<void>().future;

  /// 正常返回：`_runBody` 能走过「停引擎」并落地游标
  @override
  Future<void> stop() async {}

  @override
  Future<void> pause() async {}

  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async {}
}


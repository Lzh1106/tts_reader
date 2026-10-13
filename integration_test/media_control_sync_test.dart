import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_audio_handler.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 通知栏 / 耳机 ↔ 阅读页 的**双向同步**设备验证（v1.21.14 任务 ②）。
///
/// 目的：把「谁是真相源、哪条链在哪一步断」变成可复现的运行时可观测事实。
/// 四条链：
///   A 阅读页 → 通知栏：`TtsManager.pause()/playFromCursor()` → handler 推状态
///   B 通知栏 → 阅读页：`TtsAudioHandler.pause()/play()` → `TtsManager` 状态变化
/// 对照组 `skipToNext/skipToPrevious`（用户报告「通」的那两条）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<TtsAudioHandler> handler() async =>
      (audioHandler ?? await TtsAudioHandler.init())!;

  Future<bool> waitFor(bool Function() cond, [int timeoutMs = 4000]) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      if (cond()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return cond();
  }

  StructuredDocument doc() => StructuredDocument(
        chapters: const <Chapter>[
          Chapter(
            title: '第一章',
            paragraphs: <Paragraph>[
              Paragraph(
                sentences: <Sentence>[
                  Sentence('同步用例的第一句话，用来把会话跑起来。'),
                  Sentence('第二句话，用来观察游标是否推进。'),
                  Sentence('第三句话，用来确认跳句链路仍然是通的。'),
                ],
              ),
            ],
          ),
        ],
      );

  void log(String s) {
    // ignore: avoid_print
    print('DEVICE_VERIFY[sync] $s');
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
  });

  tearDown(() async {
    await TtsManager.instance.stop();
  });

  testWidgets('方向 B：handler.pause() → TtsManager.paused 必须为 true', (tester) async {
    final h = await handler();
    final TtsManager tts = TtsManager.instance;
    tts.loadDocument(doc(), title: '同步用例B', documentId: 'sync-b');
    tts.speakFrom(0, 0, 0);
    final bool started = await waitFor(() => tts.playing);
    log('起读后 playing=${tts.playing} paused=${tts.paused} started=$started');
    expect(started, isTrue, reason: '会话必须真的跑起来');

    await h.pause();
    final bool paused = await waitFor(() => tts.paused && !tts.playing);
    log('handler.pause() 之后 playing=${tts.playing} paused=${tts.paused} '
        '→ 断言=${paused ? "通" : "断"}');
    expect(paused, isTrue,
        reason: '通知栏/耳机暂停必须让 TtsManager 进入暂停态（方向 B）');
  });

  testWidgets('方向 B：handler.play() → TtsManager.playing 必须回到 true', (tester) async {
    final h = await handler();
    final TtsManager tts = TtsManager.instance;
    tts.loadDocument(doc(), title: '同步用例B2', documentId: 'sync-b2');
    tts.speakFrom(0, 0, 0);
    await waitFor(() => tts.playing);
    await h.pause();
    await waitFor(() => tts.paused);

    await h.play();
    final bool resumed = await waitFor(() => tts.playing && !tts.paused);
    log('handler.play() 之后 playing=${tts.playing} paused=${tts.paused} '
        '→ 断言=${resumed ? "通" : "断"}');
    expect(resumed, isTrue, reason: '通知栏/耳机播放必须让朗读继续（方向 B）');
  });

  testWidgets('方向 A：TtsManager.pause() → 通知栏 playbackState.playing == false',
      (tester) async {
    final h = await handler();
    final TtsManager tts = TtsManager.instance;
    tts.loadDocument(doc(), title: '同步用例A', documentId: 'sync-a');
    tts.speakFrom(0, 0, 0);
    final bool pushed = await waitFor(() => h.playbackState.value.playing);
    log('起读后 通知栏 playing=${h.playbackState.value.playing} pushed=$pushed');
    expect(pushed, isTrue, reason: '开始朗读必须把 playing=true 推到通知栏');

    await tts.pause();
    final bool synced = await waitFor(() => h.playbackState.value.playing == false);
    log('TtsManager.pause() 之后 通知栏 playing=${h.playbackState.value.playing} '
        'state=${h.playbackState.value.processingState} → 断言=${synced ? "通" : "断"}');
    expect(synced, isTrue, reason: '阅读页暂停必须同步到通知栏（方向 A）');
  });

  testWidgets('平文模式：speakLines 起读后 pause → play 必须能恢复', (tester) async {
    final h = await handler();
    final TtsManager tts = TtsManager.instance;
    tts.speakLines(<String>['平文第一条，用来观察是否可以恢复。', '平文第二条，用来观察恢复后是否继续。']);
    final bool started = await waitFor(() => tts.playing);
    log('平文起读 playing=${tts.playing} started=$started');
    expect(started, isTrue);

    await h.pause();
    final bool paused = await waitFor(() => tts.paused && !tts.playing);
    log('平文暂停之后 playing=${tts.playing} paused=${tts.paused} '
        '_oneShot/行数/none 由下一行状态给出');
    expect(paused, isTrue, reason: '平文模式也必须能暂停');

    await h.play();
    final bool resumed = await waitFor(() => tts.playing && !tts.paused);
    log('平文 play() 之后 playing=${tts.playing} paused=${tts.paused} '
        '→ 断言=${resumed ? "通" : "断"}');
    expect(resumed, isTrue,
        reason: '平文模式（外部文本 / 网页朗读）暂停后必须能被播放键拉起来');
  });

  testWidgets('ColorOS ROM 兼容：正在播时 handler.play() 必须当暂停（设备侧）', (tester) async {
    final h = await handler();
    final TtsManager tts = TtsManager.instance;
    tts.loadDocument(doc(), title: 'ROM 兼容用例', documentId: 'rom-compat');
    tts.speakFrom(0, 0, 0);
    expect(await waitFor(() => tts.playing), isTrue, reason: '会话要先跑起来');

    // 模拟 ColorOS（一加/OPPO）：用户按"暂停"，系统发来的是 KEYCODE_MEDIA_PLAY
    await h.play();
    final bool paused = await waitFor(() => tts.paused && !tts.playing);
    log('ROM 兼容：正在播时 play() → playing=${tts.playing} paused=${tts.paused} '
        '→ 断言=${paused ? "通" : "断"}');
    expect(paused, isTrue,
        reason: 'ROM 把媒体键统一发成 MEDIA_PLAY，play() 必须承担"切换"职责'
            '（否则按暂停会走 playFromCursor → 重播当前句）');

    // 再按一次 → 应当恢复播放
    await h.play();
    final bool resumed = await waitFor(() => tts.playing && !tts.paused);
    log('ROM 兼容：暂停态 play() → playing=${tts.playing} '
        '→ 断言=${resumed ? "通" : "断"}');
    expect(resumed, isTrue, reason: '暂停态收到 play() 必须恢复');
  });

  testWidgets('对照组：skipToNext / skipToPrevious 仍然通', (tester) async {
    final h = await handler();
    final TtsManager tts = TtsManager.instance;
    tts.loadDocument(doc(), title: '同步用例C', documentId: 'sync-c');
    tts.speakFrom(0, 0, 0);
    await waitFor(() => tts.playing);

    final (int, int, int) before = tts.cursor;
    await h.skipToNext();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final (int, int, int) afterNext = tts.cursor;
    log('skipToNext: $before → $afterNext');
    expect(afterNext, isNot(before), reason: '耳机「下一首」必须动游标');

    await h.skipToPrevious();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    log('skipToPrevious: $afterNext → ${tts.cursor}');
  });
}

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_audio_handler.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// **通知栏最小语义（v1.21.13 简化需求）**
///
/// 新定义只有一句话：**对正在朗读的文档做媒体控制**。
///   · 有朗读会话 → 卡片显示当前文档（书名 + 播放/暂停）
///   · stop / clear → 卡片按 audio_service 默认行为消失（processingState = idle）
///   · **没有**「未在播放」这个中间态
///
/// 这里只断言这四件事。替代了被删除的 `library_bar_notification_test.dart`
/// （v1.21.9 为旧需求写的 4 项「卡片保留 / 未在播放」定义）
/// 与 `notification_spec_test.dart`（§4.105 的卡片完整定义）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// `AudioService.init` 一个进程只能成功一次（HANDOFF §9.42）：
  /// 已有全局实例就复用，没有才初始化。
  Future<TtsAudioHandler> handler() async =>
      (audioHandler ?? await TtsAudioHandler.init())!;

  /// 等条件成立（最多 [timeoutMs]），返回是否成立。
  Future<bool> waitFor(bool Function() cond, [int timeoutMs = 5000]) async {
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
                  Sentence('这是通知栏最小语义用例的第一句话。'),
                  Sentence('第二句话用来确认会话仍然活着。'),
                  Sentence('第三句话用来确认暂停与恢复。'),
                ],
              ),
            ],
          ),
        ],
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
  });

  tearDown(() async {
    await TtsManager.instance.stop();
  });

  testWidgets('① 播放中：通知栏媒体项 title = 正在朗读的书名', (tester) async {
    final h = await handler();
    TtsManager.instance
        .loadDocument(doc(), title: '通知栏书名用例', documentId: 'media-min-1');
    TtsManager.instance.speakFrom(0, 0, 0);

    final bool ok = await waitFor(
        () => h.mediaItem.value?.title == '通知栏书名用例');
    expect(ok, isTrue,
        reason: '有朗读会话时，卡片必须显示当前正在朗读的文档名'
            '（实际 title=${h.mediaItem.value?.title}）');
  });

  testWidgets('② 暂停：playbackState.playing == false', (tester) async {
    final h = await handler();
    TtsManager.instance
        .loadDocument(doc(), title: '通知栏暂停用例', documentId: 'media-min-2');
    TtsManager.instance.speakFrom(0, 0, 0);
    await waitFor(() => h.playbackState.value.playing);

    await h.pause();
    final bool paused = await waitFor(() => h.playbackState.value.playing == false);
    expect(paused, isTrue, reason: '暂停后 playing 必须为 false');
    // 暂停不销毁卡片：processingState 不应变成 idle
    expect(h.playbackState.value.processingState,
        isNot(AudioProcessingState.idle),
        reason: '暂停是「还在读这本」的中间态，卡片不能消失');
  });

  testWidgets('③ 恢复：playbackState.playing == true', (tester) async {
    final h = await handler();
    TtsManager.instance
        .loadDocument(doc(), title: '通知栏恢复用例', documentId: 'media-min-3');
    TtsManager.instance.speakFrom(0, 0, 0);
    await waitFor(() => h.playbackState.value.playing);
    await h.pause();
    await waitFor(() => h.playbackState.value.playing == false);

    await h.play();
    final bool resumed = await waitFor(() => h.playbackState.value.playing);
    expect(resumed, isTrue, reason: '恢复后 playing 必须回到 true');
  });

  testWidgets('④ stop：processingState == idle（卡片按默认行为消失）', (tester) async {
    final h = await handler();
    TtsManager.instance
        .loadDocument(doc(), title: '通知栏停止用例', documentId: 'media-min-4');
    TtsManager.instance.speakFrom(0, 0, 0);
    await waitFor(() => h.mediaItem.value?.title == '通知栏停止用例');

    await h.stop();
    final bool idle = await waitFor(
        () => h.playbackState.value.processingState == AudioProcessingState.idle);
    expect(idle, isTrue,
        reason: '会话结束后必须推 idle —— audio_service 见到 idle 才会收掉卡片；'
            '「未在播放」的卡片保留中间态已被 v1.21.13 撤销'
            '（实际=${h.playbackState.value.processingState}）');
  });
}

import 'dart:ui' show Rect, Size;

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/tts/tts_audio_handler.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 真机 / 模拟器验证：**后台朗读 + 通知栏**这条链路。
///
/// 这是 Android 14 上最容易「朗读时闪退」的地方：开始朗读 → 更新媒体通知 →
/// 启动 mediaPlayback 前台服务，任何一步类型/权限不对都会抛
/// MissingForegroundServiceTypeException / ForegroundServiceStartNotAllowedException
/// 这类平台异常，直接把进程带走。
///
/// 跑法：flutter test integration_test/audio_service_verify_test.dart -d emulator-5554
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('初始化 audio_service + 朗读：通知栏与前台服务不崩', (tester) async {
    // 1) 初始化音频服务（真实平台通道）
    final handler = await TtsAudioHandler.init();
    // ignore: avoid_print
    print('DEVICE_VERIFY[audio] handler=${handler != null}');

    final tts = TtsManager.instance;
    await tts.init();

    final clip = StructuredDocument(
      chapters: <Chapter>[
        for (var c = 0; c < 5; c++)
          Chapter(
            title: '第 ${c + 1} 页',
            paragraphs: <Paragraph>[
              Paragraph(sentences: <Sentence>[
                Sentence('Notification path page ${c + 1} sentence.'),
              ]),
            ],
          ),
      ],
      chapterIsPage: true,
    );

    tts.loadDocument(clip, title: '通知栏验证');
    await tts.setGranularity(ReadGranularity.sentence);

    // 2) 开始朗读：这一步会更新媒体通知并拉起前台服务
    tts.speakFrom(0, 0, 0);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1500)),
    );
    // ignore: avoid_print
    print('DEVICE_VERIFY[audio] after start: speaking=${tts.speaking} '
        'cursor=${tts.cursor} error=${tts.error} engine=${tts.activeEngineName}');

    // 3) 通知栏按钮走的路径：暂停 → 播放 → 下一章 → 进度拖动
    await tts.pause();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    // ignore: avoid_print
    print('DEVICE_VERIFY[audio] after pause: paused=${tts.paused} error=${tts.error}');

    tts.playFromCursor();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 600)),
    );

    tts.skipChapter(1);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 600)),
    );

    tts.seekToProgress(0.5);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 600)),
    );
    // ignore: avoid_print
    print('DEVICE_VERIFY[audio] after controls: cursor=${tts.cursor} '
        'progress=${tts.progress} error=${tts.error}');

    // 4) 空闲即断开
    await tts.stop();
    // ignore: avoid_print
    print('DEVICE_VERIFY[audio] after stop: speaking=${tts.speaking} error=${tts.error}');

    expect(tts.speaking, isFalse);
    // 游标始终有效
    expect(tts.cursor.$1, inInclusiveRange(0, clip.chapters.length - 1));
  });

  testWidgets('PDF 会话激活时的通知栏：书名 + 第 N/M 页、seek 禁用', (tester) async {
    // ⚠️ `AudioService.init` 一个进程只能成功一次（HANDOFF §9.42），
    // 所以第二个用例要**复用**上一个用例建好的全局 handler，
    // 不能再 init 一遍（再调一次返回 null）。
    final handler = audioHandler ?? await TtsAudioHandler.init();
    expect(handler, isNotNull, reason: '真实设备上应当能起 audio_service');

    final tts = TtsManager.instance;
    await tts.init();
    // 清掉上一个用例的 TXT 会话，确保通知栏来源是 PDF
    await tts.stop();

    final session = PdfReadSession.instance;
    session.resetForTest();

    // 造一份两页的假文本层（PDF 引擎跑不进这条用例，也不需要）
    PdfPageTextLayer page(int pageNumber, String text) {
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

    final pages = <int, PdfPageTextLayer>{
      0: page(1, 'First page sentence one. First page sentence two.'),
      1: page(2, 'Second page sentence.'),
    };
    await session.open(
      documentId: 'pdf-notify-doc',
      title: '通知栏 PDF 验证',
      pageCount: 2,
      layerLoader: (pageIndex) async => pages[pageIndex],
    );

    final layer0 = await session.ensureLayer(0);
    // ignore: avoid_print
    print('DEVICE_VERIFY[audio-pdf] 开读前 isActive=${session.isActive} '
        'layer0=${layer0 != null} pageCount=${session.pageCount} '
        'handler=${audioHandler != null}');
    session.startAt(sentenceRefAt(0, 0, layer0)!);
    // ignore: avoid_print
    print('DEVICE_VERIFY[audio-pdf] startAt 后 current=${session.current} '
        'isPlaying=${session.isPlaying} '
        'handlerSource=${audioHandler?.activeSource.sourceId}');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1500)),
    );

    // 1) 通知栏内容：书名 + 第 N/M 页
    final item = handler!.mediaItem.value;
    // ignore: avoid_print
    print('DEVICE_VERIFY[audio-pdf] 通知栏 title=${item?.title} '
        'artist=${item?.artist} playing=${handler.playbackState.value.playing} '
        'actions=${handler.playbackState.value.systemActions} '
        'label=${session.positionLabel}');
    expect(item?.title, '通知栏 PDF 验证', reason: '通知栏要显示 PDF 书名');
    expect(item?.artist, contains('第'), reason: '副标题要带页码');

    // 2) seek 必须不可用（PDF 不按比例跳）
    expect(
      handler.playbackState.value.systemActions.contains(MediaAction.seek),
      isFalse,
      reason: 'PDF 会话的 systemActions 里不该有 seek',
    );
    expect(session.canSeek, isFalse);

    // 3) 播放中 → 暂停键生效
    expect(handler.playbackState.value.playing, isTrue);
    await handler.pause();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    // ignore: avoid_print
    print('DEVICE_VERIFY[audio-pdf] 暂停后 paused=${session.isPaused} '
        'playing=${session.isPlaying}');
    expect(session.isPaused, isTrue, reason: '通知栏暂停键要能暂停 PDF 会话');

    // 4) 上/下一章 = 相邻页首句（PDF 一章即一页）
    session.skipChapter(1);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 900)),
    );
    // ignore: avoid_print
    print('DEVICE_VERIFY[audio-pdf] 下一章后 page=${session.current?.pageIndex} '
        'sentence=${session.current?.sentenceIndex} '
        'text=${session.current?.text}');
    expect(session.current?.pageIndex, 1, reason: '下一章要跳到第 2 页');
    expect(session.current?.sentenceIndex, 0, reason: '落在该页首句');

    // 收尾：自己停干净，否则报 A Timer is still pending（HANDOFF §4.60）
    await session.clear();
    await tts.stop();
    expect(session.isActive, isFalse);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/pages/home_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 「书A暂停 → 打开书B → 恢复却读书A」入口判据的回归（v1.21.54）
///
/// 文档库的「返回朗读页」先问 [HomePage.readingTargetDocumentId]「该跳哪本」。
/// 这里钉的是**它当时的答案**，并如实记录「暂停中的 PDF 仍算在播来源」这条
/// 既有设计（`isPlaybackActive` 含 `_paused`，见 §4.103）——它不是 bug，
/// 所以用例把它**记录**下来，而不是要求它变成 false。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    PdfReadSession.instance.resetForTest();
    TtsManager.instance.resetSessionForTest();
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetSessionForTest();
    PdfReadSession.instance.resetForTest();
  });

  test('没有任何会话时，返回朗读页没有目标', () {
    final id = HomePage.readingTargetDocumentId(
      pdf: PdfReadSession.instance,
      tts: TtsManager.instance,
    );
    expect(id, isNull, reason: '什么都没在读时不该指向任何文档');
  });

  test('PDF 在播时，返回朗读页指向它（正常语义）', () async {
    final session = PdfReadSession.instance;
    await session.open(
      documentId: 'pdfA',
      title: 'PDF-A',
      pageCount: 3,
      layerLoader: (pageIndex) async => null,
    );
    session.startAt(
        const PdfSentenceRef(pageIndex: 1, sentenceIndex: 0, text: 'A 的句子'));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(
      HomePage.readingTargetDocumentId(pdf: session, tts: TtsManager.instance),
      'pdfA',
      reason: 'PDF 在播时，"返回朗读页"应当回到它',
    );
  });

  test('★记录既有设计：暂停中的 PDF 仍算「在播来源」（不是 bug）', () async {
    final session = PdfReadSession.instance;
    await session.open(
      documentId: 'pdfA',
      title: 'PDF-A',
      pageCount: 3,
      layerLoader: (pageIndex) async => null,
    );
    session.startAt(
        const PdfSentenceRef(pageIndex: 1, sentenceIndex: 0, text: 'A 的句子'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await session.pause();
    expect(session.isPaused, isTrue, reason: '前置：用户按了暂停');

    // ⚠️ 这不是缺陷：`isPlaybackActive = isActive && (_playing || _paused)`，
    // 「暂停」按设计仍算这个来源在播（换歌要记住进度，§4.103）。
    // 用户报的「切书后读回旧书」若与它有关，修法**不能**是把这里改成 false
    // （那会让「暂停后再点播放」在很多正常路径上失效）。
    expect(session.isPlaybackActive, isTrue,
        reason: '既有设计：暂停仍算在播来源');
    expect(
      HomePage.readingTargetDocumentId(pdf: session, tts: TtsManager.instance),
      'pdfA',
      reason: '所以"返回朗读页"此时仍指向这本 PDF —— 这是**既有行为**，'
          '记录下来，供排查「切书后读回旧书」时对照',
    );
  });
}

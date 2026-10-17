import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/features/pdf_reading/pdf_read_session.dart';
import 'package:tts_reader/features/pdf_reading/pdf_text_layer.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/media_interruption.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 「所有方块键按下后是否都放开媒体焦点」（用户 2026-10-17 要求核对）
///
/// ## 为什么必须逐条挂号
///
/// 焦点只在两条路释放：
///   1. `TtsManager.stop()`（方块键 / 换书 / 结束会话都汇到这里）
///   2. `TtsAudioHandler.stop()`（通知栏 / 耳机那条）
///
/// PDF 页的方块键走的是 `PdfReadSession.stopSound()` —— **它原来一个都没调**。
/// 后果：停掉 PDF 朗读之后我们仍压着音频焦点，别的应用出不了声，
/// 媒体键路由也会异常（正是 v1.21.15 记下的那类症状）。
///
/// 本文件把「每个方块键入口都要释放」钉住，防止以后再各写一套。
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

  int focusCount() =>
      MediaInterruptionController.instance.debugReleaseFocusCount;

  test('★PDF 页方块键（stopSound）必须释放媒体焦点', () async {
    final session = PdfReadSession.instance;
    await session.open(
      documentId: 'pdfA',
      title: 'PDF-A',
      pageCount: 3,
      layerLoader: (pageIndex) async => null,
    );
    // ⚠️ **刻意不 startAt**：要的就是"PDF 没在借 TTS 的声音"这一形态 ——
    // 那种情况下 `stopSound()` 里那句 `TtsManager.stop()` 不会执行，
    // 于是本用例只能由 `stopSound()` 自己的 releaseFocus 满足。
    // 若改成"正在读"的形态，`TtsManager.stop()` 也会释放焦点，
    // 用例就会绿得没有意义（负向自检抓过这个假测试）。
    session.startAt(
        const PdfSentenceRef(pageIndex: 0, sentenceIndex: 0, text: 'A 的句子'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // 把借声状态结束掉：停声一次，然后再测方块键
    await session.stopSound();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final before = focusCount();
    // 方块键：`PdfReadingPage._stopAndCollapse()` 走的正是这一条
    await session.stopSound();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // ignore: avoid_print
    print('DEVICE_VERIFY[focus] PDF 方块键 释放次数 '
        'before=$before after=${focusCount()}');
    expect(focusCount(), greaterThan(before),
        reason: '★停掉 PDF 朗读后必须放开音频焦点，'
            '否则别的应用会一直被我们压着、媒体键路由也会异常');
  });

  test('★TTS 方块键（stop）必须释放媒体焦点', () async {
    TtsManager.instance.resetSessionForTest();
    final before = focusCount();
    await TtsManager.instance.stop();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // ignore: avoid_print
    print('DEVICE_VERIFY[focus] TTS stop 释放次数 '
        'before=$before after=${focusCount()}');
    expect(focusCount(), greaterThan(before),
        reason: '★文字档方块键（stop / endSessionAndClear）必须放开焦点');
  });

  test('★对照：暂停**不许**释放焦点（v1.21.15 定的行为）', () async {
    TtsManager.instance.resetSessionForTest();
    // `PdfReadSession.pause()` 是最容易"顺手"加上释放的地方，拿它做对照
    final session = PdfReadSession.instance;
    await session.open(
      documentId: 'pdfA',
      title: 'PDF-A',
      pageCount: 3,
      layerLoader: (pageIndex) async => null,
    );
    session.startAt(
        const PdfSentenceRef(pageIndex: 0, sentenceIndex: 0, text: 'A 的句子'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // ⚠️ 基线必须取在 `open()` **之后**：`open()` 内部换书会
    // `terminateForDocumentSwitch` → 释放一次焦点（那是正确的）。
    // 取早了会把那次算到暂停头上（本文件第一版就这么误判过）。
    final before = focusCount();
    await session.pause();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // ignore: avoid_print
    print('DEVICE_VERIFY[focus] 暂停 释放次数 '
        'before=$before after=${focusCount()}');
    expect(focusCount(), before,
        reason: '★暂停**不能**释放焦点 —— '
            'ColorOS 上暂停就交出焦点会导致"再按播放毫无反应"（v1.21.15 实测）');
  });
}

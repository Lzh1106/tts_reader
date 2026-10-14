import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/features/pdf_reading/pdf_reading_page.dart';
import 'package:tts_reader/pages/reader_page.dart';

/// 扫描件提示文案
///
/// ## 措辞演变（两轮用户决定，用例跟着钉死）
///
/// 1. 最早是含糊的"**可能是**扫描件" —— 用户反馈听着像"换个模式就能读"；
/// 2. 中间一版改成"要读它需要先做 OCR，转换成带文字的 PDF"；
/// 3. **2026-10-14 用户拍板：应用内不做 OCR**（OCR 识别准确率没保证，
///    以后可能走 AI 接口做识别 + 翻译），所以提示**不再提 OCR**，
///    只说清「**能正常翻阅**」+「**朗读不了**」。
///
/// 两处入口（阅读页顶部横幅、PDF 原版式页内提示）必须同一套说法。
void main() {
  group('扫描件提示（只保证能读，不承诺 OCR）', () {
    test('阅读页横幅：说明能翻阅、朗读用不了', () {
      expect(ReaderPage.scannedPdfHint, contains('扫描件'));
      expect(ReaderPage.scannedPdfHint, contains('无法朗读'),
          reason: '得让用户马上明白"读不出声"不是坏了');
      expect(ReaderPage.scannedPdfHint, contains('可以正常翻页阅读'),
          reason: '★用户要求：暂时只保证可以阅读（翻阅）即可');
      expect(ReaderPage.scannedPdfHint, isNot(contains('可能是扫描件')),
          reason: '含糊的说法早就废掉了');
    });

    test('★不再把 OCR 当解决方案挂在提示里（应用内不做 OCR）', () {
      expect(ReaderPage.scannedPdfHint, isNot(contains('OCR')),
          reason: '★2026-10-14 用户拍板：OCR 识别准确率没保证，'
              '暂时不做；以后可能走 AI 接口做识别 + 翻译');
      expect(PdfReadingPage.scannedPdfHint, isNot(contains('OCR')));
      expect(ReaderPage.scannedPdfHint, isNot(contains('转换')),
          reason: '不该让用户以为"转一下就能读"');
    });

    test('PDF 原版式页内提示：同样是"能看不能读"', () {
      expect(PdfReadingPage.scannedPdfHint, contains('无法朗读'));
      expect(PdfReadingPage.scannedPdfHint, contains('可以正常翻页阅读'));
      expect(PdfReadingPage.scannedPdfHint, isNot(contains('OCR')));
    });

    test('两处文案必须一致（同一件事不能两种说法）', () {
      expect(PdfReadingPage.scannedPdfHint, ReaderPage.scannedPdfHint,
          reason: '★同一个"扫描件读不了"的提示，两处入口说法必须一样');
    });
  });
}

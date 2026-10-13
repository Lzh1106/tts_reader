import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/features/pdf_reading/pdf_reading_page.dart';

/// **负向验证**：`AF[居中]` 里的 `✅一致 / ⚠️不一致` 判据**真的会变红吗**？
///
/// ## 为什么要专门写这一条（用户要求，且理由很硬）
///
/// S2a 的成败判据是「`refPage == 视口页`」。如果这个判据**永远显示"一致"**，
/// 它就是个**摆设** —— 看起来一切正常，实际上什么都没验证。
///
/// 所以必须证明：**存在输入让它显示"不一致"**。
///
/// ## 判据为什么有可能是循环的（这个风险是真实的）
///
/// 如果 `viewportPage` 也是从"朗读位置"算出来的，那两边永远相等 ——
/// 判据恒真、永远绿。这里要钉死的是：
/// * `viewportPage` 来自**滚动位置**（`_pageAtOffset`：只读 `_pageExtents` + offset）；
/// * `refPage` 来自**朗读会话**的当前句。
///
/// 两者独立 → 滑动页面就能让它们错开 → 判据**能变红**。
void main() {
  group('★判据能变红（负向验证）', () {
    test('视口比朗读位置**靠后** → 不一致（用户往下滑走）', () {
      expect(
        PdfReadingPage.isViewportSyncedWithReading(viewportPage: 9, refPage: 8),
        isFalse,
        reason: '★朗读在 8、视口在 9 → 必须判"不一致"',
      );
    });

    test('视口比朗读位置**靠前** → 不一致（用户往回滑）', () {
      expect(
        PdfReadingPage.isViewportSyncedWithReading(viewportPage: 7, refPage: 8),
        isFalse,
        reason: '★朗读在 8、视口在 7 → 必须判"不一致"',
      );
    });

    test('差很多页 → 不一致（大跨度滑走）', () {
      expect(
        PdfReadingPage.isViewportSyncedWithReading(viewportPage: 300, refPage: 8),
        isFalse,
      );
    });

    test('相等 → 一致（正常跟读时应当是这个）', () {
      expect(
        PdfReadingPage.isViewportSyncedWithReading(viewportPage: 8, refPage: 8),
        isTrue,
      );
    });

    test('★判据不是恒真也不是恒假（两种输出都可达）', () {
      // 这一条是整个负向验证的核心：两个分支都被真实打到过。
      final results = <bool>{
        PdfReadingPage.isViewportSyncedWithReading(viewportPage: 8, refPage: 8),
        PdfReadingPage.isViewportSyncedWithReading(viewportPage: 9, refPage: 8),
      };
      expect(results, <bool>{true, false},
          reason: '★若这里只有 {true}，判据就是摆设 —— 正是本次要排除的情形');
    });
  });
}

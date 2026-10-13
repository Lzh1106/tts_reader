import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/features/pdf_reading/pdf_reading_page.dart';

/// **PDF「进书定位 / 回到朗读位置」定位不准 + 滚动让位污染**（2026-10-13 真机日志）
///
/// 三个独立缺陷，各自的纯逻辑抽成了公开可测的函数（同一个文件里）：
///
/// 1. `_revealToPageIndex` 的页高累加**遇到空缺就 break** → 进书定位停在开头几页
///    （真机：`位置[PDF恢复] 落定=18/10` 之后 `AF[真落位] page=11`，收敛链消失）；
/// 2. `_isPageIndexVisible` 把 ListView **预建区**当成"可见"（1 像素重叠即为真）
///    → 收敛链提前 `onRevealFinished` 并结束；
/// 3. `_lastUserScrollEndAt` 被**程序自己的 `animateTo` 结束**污染
///    → 程序滚一次就白送 4 秒"让位"，跟读看起来变迟钝。
///
/// 这里测的就是这三条判据 —— 不依赖真机、不依赖 PDF 渲染。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('缺陷 1：按页高估算目标页偏移（空缺用估算顶替，不中断）', () {
    // 真机量级：一页 ~522 逻辑像素；进书那一刻只有前 11 页报过页高
    final List<double> extents = <double>[
      ...List<double>.filled(11, 522.0), // 第 0~10 页：实测
      ...List<double>.filled(20, 0.0), // 第 11~30 页：还没进过视野
    ];

    test('★空缺不中断：目标第 19 页（index 18）算出 18 页的高度', () {
      final r = PdfReadingPage.estimateOffsetToPage(
        pageExtents: extents,
        pageIndex: 18,
        estimatedExtent: 522,
      );
      expect(r, isNotNull);
      expect(r!.offset, 18 * 522.0,
          reason: '前 11 页实测 + 后 7 页按估算顶替 = 18 页的总高');
      expect(r.estimated, 7, reason: '要如实报出"其中 7 页是估算的"');
    });

    test('★对照"修前"的算法：它只会累到第 11 页 —— 这就是"停在 11"的来源', () {
      // 复现旧写法（遇到第一个 e <= 0 就 break），证实用例真的能抓到那个 bug
      double legacy(List<double> e, int pageIndex) {
        var sum = 0.0;
        for (var i = 0; i < pageIndex && i < e.length; i++) {
          if (e[i] <= 0) break;
          sum += e[i];
        }
        return sum;
      }

      final double buggy = legacy(extents, 18);
      expect(buggy, 11 * 522.0,
          reason: '旧算法停在"最后一个连续量到的页"= 第 11 页');
      final r = PdfReadingPage.estimateOffsetToPage(
        pageExtents: extents,
        pageIndex: 18,
        estimatedExtent: 522,
      );
      expect(r!.offset, isNot(buggy),
          reason: '★修完之后必须与旧值不同 —— 否则这条用例抓不到 bug');
      expect(r.offset, greaterThan(buggy),
          reason: '缺口补上后目标偏移只会更大（更接近真实位置）');
    });

    test('一页都没量到（全 0）时，等价于老的 est × pageIndex 兜底', () {
      final r = PdfReadingPage.estimateOffsetToPage(
        pageExtents: List<double>.filled(40, 0),
        pageIndex: 18,
        estimatedExtent: 522,
      );
      expect(r!.offset, 522 * 18);
      expect(r.estimated, 18, reason: '一页实测都没有 → 全是估算');
    });

    test('第 0 页：偏移 0（没有"前面的页"要累加）', () {
      final r = PdfReadingPage.estimateOffsetToPage(
        pageExtents: extents,
        pageIndex: 0,
        estimatedExtent: 522,
      );
      expect(r!.offset, 0.0);
      expect(r.estimated, 0);
    });

    test('连估算都给不出（文档没打开完）→ null，这一拍不算、下一帧再试', () {
      expect(
        PdfReadingPage.estimateOffsetToPage(
          pageExtents: List<double>.filled(20, 0),
          pageIndex: 5,
          estimatedExtent: 0,
        ),
        isNull,
      );
    });

    test('全部实测时不报"估算页数"（日志不该谎报误差）', () {
      final r = PdfReadingPage.estimateOffsetToPage(
        pageExtents: List<double>.filled(20, 500),
        pageIndex: 4,
        estimatedExtent: 999, // 不该被用上
      );
      expect(r!.offset, 4 * 500.0);
      expect(r.estimated, 0);
    });
  });

  group('缺陷 2：实质可见 = 至少一半落在视口内（预建区不算）', () {
    // 视口：0 ~ 600；页高 500
    test('整页在视口内 → 可见', () {
      expect(
        PdfReadingPage.isPageSubstantiallyVisible(
          pageTop: 100,
          pageBottom: 600,
          viewportTop: 0,
          viewportBottom: 600,
        ),
        isTrue,
      );
    });

    test('正好一半在视口内 → 可见（边界取 ≥）', () {
      expect(
        PdfReadingPage.isPageSubstantiallyVisible(
          pageTop: 300,
          pageBottom: 800, // 重叠 300 = 500 × 0.6 → 可见
          viewportTop: 0,
          viewportBottom: 600,
        ),
        isTrue,
      );
      expect(
        PdfReadingPage.isPageSubstantiallyVisible(
          pageTop: 350,
          pageBottom: 850, // 重叠 250 = 500 × 0.5 → 恰好一半
          viewportTop: 0,
          viewportBottom: 600,
        ),
        isTrue,
      );
    });

    test('★只探进视口一点点（ListView 预建区）→ **不可见**', () {
      // 重叠 50px = 10%：老判据（有重叠即真）会说"到了"，于是收敛链提前收工
      expect(
        PdfReadingPage.isPageSubstantiallyVisible(
          pageTop: 550,
          pageBottom: 1050,
          viewportTop: 0,
          viewportBottom: 600,
        ),
        isFalse,
        reason: '★这就是"进书定位停在开头几页"的机制：预建区里的页冒充"到位"',
      );
      expect(
        PdfReadingPage.isPageSubstantiallyVisible(
          pageTop: -450,
          pageBottom: 50, // 上方预建区，重叠 50px
          viewportTop: 0,
          viewportBottom: 600,
        ),
        isFalse,
      );
    });

    test('47% 也不够（门槛是 50%）', () {
      expect(
        PdfReadingPage.isPageSubstantiallyVisible(
          pageTop: 365,
          pageBottom: 865, // 重叠 235 / 500 = 47%
          viewportTop: 0,
          viewportBottom: 600,
        ),
        isFalse,
      );
    });

    test('完全在视口外 / 页高为 0 → 不可见（不抛异常）', () {
      expect(
        PdfReadingPage.isPageSubstantiallyVisible(
          pageTop: 5000,
          pageBottom: 5500,
          viewportTop: 0,
          viewportBottom: 600,
        ),
        isFalse,
      );
      expect(
        PdfReadingPage.isPageSubstantiallyVisible(
          pageTop: 100,
          pageBottom: 100,
          viewportTop: 0,
          viewportBottom: 600,
        ),
        isFalse,
      );
    });
  });

  group('缺陷 3：程序滚动不许冒充"用户停手"', () {
    test('★程序自己的 animateTo 结束 → **不记**停手时刻', () {
      final t = UserScrollStopTracker();
      // 程序滚动：ScrollStartNotification 没有 dragDetails
      t.onScrollStart(isUserDrag: false);
      final recorded = t.onScrollEnd(now: DateTime(2026, 10, 13, 14, 52, 38, 738));
      expect(recorded, isFalse,
          reason: '★否则"程序滚完一次"就重置 4 秒计时 → 跟读白让位 4 秒');
      expect(t.lastUserStopAt, isNull,
          reason: '★真机 14:52:38.738 那条 `AF[滚动到位]` 就是这么污染计时的');
    });

    test('用户真实拖动结束 → 记停手时刻（开关 B 的 4 秒从这一刻起算）', () {
      final t = UserScrollStopTracker();
      t.onScrollStart(isUserDrag: true);
      final at = DateTime(2026, 10, 13, 15, 0, 0);
      expect(t.onScrollEnd(now: at), isTrue);
      expect(t.lastUserStopAt, at);
    });

    test('用户拖动之后紧跟一个程序滚动结束 → 不会重复记', () {
      final t = UserScrollStopTracker();
      t.onScrollStart(isUserDrag: true);
      t.onScrollEnd(now: DateTime(2026, 10, 13, 15, 0, 0));
      // 收敛链随后自己 animateTo 一次
      t.onScrollStart(isUserDrag: false);
      final recorded = t.onScrollEnd(now: DateTime(2026, 10, 13, 15, 0, 1));
      expect(recorded, isFalse);
      expect(t.lastUserStopAt, DateTime(2026, 10, 13, 15, 0, 0),
          reason: '停手时刻不该被程序滚动刷新');
    });

    test('标志不留脏：程序滚动结束后不会让下一次"结束"误判成用户停手', () {
      final t = UserScrollStopTracker();
      t.onScrollStart(isUserDrag: false);
      t.onScrollEnd(now: DateTime(2026, 10, 13, 15, 0, 0));
      expect(t.dragging, isFalse);
      expect(t.onScrollEnd(now: DateTime(2026, 10, 13, 15, 0, 1)), isFalse);
    });

    testWidgets('通知类型判据：拖动开始为真，程序滚动开始 / 任何结束为假', (tester) async {
      // 这两个通知类要求一个真实 BuildContext（Flutter 3.24 的签名），
      // 所以这条用 testWidgets 拿 context，判据本身仍然是纯函数。
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (BuildContext c) {
            ctx = c;
            return const SizedBox.shrink();
          }),
        ),
      );
      final FixedScrollMetrics metrics = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 10000,
        pixels: 100,
        viewportDimension: 600,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1.0,
      );
      expect(
        PdfReadingPage.isUserDragScrollStart(
          ScrollStartNotification(
            metrics: metrics,
            context: ctx,
            dragDetails: DragStartDetails(),
          ),
        ),
        isTrue,
      );
      expect(
        PdfReadingPage.isUserDragScrollStart(
          ScrollStartNotification(metrics: metrics, context: ctx),
        ),
        isFalse,
        reason: '程序 animateTo 的 start 没有 dragDetails',
      );
      expect(
        PdfReadingPage.isUserDragScrollStart(
          ScrollEndNotification(metrics: metrics, context: ctx),
        ),
        isFalse,
      );
    });
  });
}

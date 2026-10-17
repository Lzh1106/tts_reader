import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/pages/reader_page.dart';

/// 回归测试：**自动（程序）滚动不得被判定为用户滚动**，以及外推定位的限幅。
///
/// 真机（2026-10-17）症状：自动翻页后跟随停摆，日志里出现
/// `用户滚动=true` / `朗读跟随[跳过] 用户正在滚动`，而用户并没有碰屏幕。
///
/// 根因：`UserScrollNotification` 不是「用户碰了屏幕」——任何滚动**结束时**
/// `goIdle()` 都会补发一条 `direction == idle` 的它，我们自己的跟随
/// `animateTo` 也一样。原判据不看 direction，于是程序滚动把自己判成了人工操作，
/// `_userScrolling` 被置真 2.5 秒，期间跟随全部让位。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 造一条滚动通知（只需要 metrics 的非空即可，判据只看类型与字段）
  ScrollNotification userScroll(ScrollDirection direction) {
    final metrics = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 1000,
      pixels: 100,
      viewportDimension: 600,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    );
    return UserScrollNotification(
      metrics: metrics,
      context: _FakeContext(),
      direction: direction,
    );
  }

  ScrollUpdateNotification update({DragUpdateDetails? dragDetails}) {
    final metrics = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 1000,
      pixels: 100,
      viewportDimension: 600,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    );
    return ScrollUpdateNotification(
      metrics: metrics,
      context: _FakeContext(),
      scrollDelta: 10,
      dragDetails: dragDetails,
    );
  }

  group('程序滚动 vs 用户手势', () {
    test('★滚动结束发的 UserScrollNotification(idle) 不算用户滚动', () {
      expect(isUserScrollNotification(userScroll(ScrollDirection.idle)), isFalse,
          reason: '★程序滚动（animateTo）一结束就会发这一条；'
              '判成用户滚动 → 跟随被自己关掉 2.5 秒（真机「自动翻页后脱节」）');
    });

    test('反向：用户在拖（direction=forward）仍然算用户滚动', () {
      expect(isUserScrollNotification(userScroll(ScrollDirection.forward)), isTrue);
      expect(isUserScrollNotification(userScroll(ScrollDirection.reverse)), isTrue);
    });

    test('无 dragDetails 的 ScrollUpdateNotification（动画帧）不算用户滚动', () {
      expect(isUserScrollNotification(update()), isFalse);
    });

    test('反向：带 dragDetails 的 ScrollUpdateNotification 算用户滚动', () {
      final details = DragUpdateDetails(
        globalPosition: const Offset(0, 100),
        delta: const Offset(0, -10),
      );
      expect(isUserScrollNotification(update(dragDetails: details)), isTrue);
    });
  });

  group('外推定位单轮限幅（真机 偏移 43.4 → 11396）', () {
    test('★目标很远时只走 3 个视口高，不再一步跳上万像素', () {
      final clamped = clampExtrapolateStep(
        want: 11396,
        from: 43.4,
        viewport: 600,
        maxViewports: 3,
      );
      expect(clamped, closeTo(43.4 + 1800, 0.01),
          reason: '★不限幅的话 jumpTo 会把画面甩到 11396，随后又被重试拉回来 —— '
              '用户看到「先闪错、再跳回」');
    });

    test('反向：目标就在附近时不做任何限幅（不误伤精确落位）', () {
      final clamped = clampExtrapolateStep(
        want: 500,
        from: 43.4,
        viewport: 600,
        maxViewports: 3,
      );
      expect(clamped, 500);
    });

    test('反向：往回滚也要限幅（方向不能丢）', () {
      final clamped = clampExtrapolateStep(
        want: 0,
        from: 9000,
        viewport: 600,
        maxViewports: 3,
      );
      expect(clamped, closeTo(7200, 0.01));
    });
  });
}

/// 滚动通知要求一个 BuildContext；判据不看它，给个空实现即可。
class _FakeContext extends StatelessWidget implements BuildContext {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

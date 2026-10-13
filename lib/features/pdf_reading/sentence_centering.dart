import 'dart:math' as math;

/// **让当前朗读句待在屏幕对齐位置**的纯计算（v1.21.43）
///
/// ## 术语（先纠正一个长期误解）
///
/// **PDF 朗读从头到尾只有一件事：让当前朗读句上下滑动到可见 / 对齐的位置。**
///
/// 我们（实现方）曾经把它想成"翻页"（`PageView` 那种一页一页翻），
/// 于是造了一整套**并不存在的东西**：翻页闸门 / `turnTo` / 落位回调 /
/// `jumpTo`-`animateTo` 分派 / `pageCount<=0` 吞请求 / 硬上限。
/// 而底层**一直是连续滚动的 `ListView`**（见 `pdf_reading_page._pagesView`）。
///
/// ⛔ **本项目里禁止再用"翻页"描述 PDF 朗读**。统一口径：
/// | 不要写 | 要写 |
/// | --- | --- |
/// | 翻页、翻到第 N 页 | 上下滑动 / 滚动、滑动到朗读句位置 |
/// | 跨页句 | 一句跨两页（高亮两页都画） |
/// | 落位、到没到位 | 滚动到了没有 |
/// | 翻页闸门 | **没有这个概念**（已废除） |
///
/// ⚠️ **例外**：`pages/reader_page.dart`（EPUB/TXT）是**真的分页**模型
/// （见 `models/reader_paging.dart`：按章切页），那边的"翻页"用词是**正确**的，
/// 不要去改它 —— 这也是产品要求「PDF 与文字档分开」的一部分。
///
/// ## 为什么把这些算术单独抽出来
///
/// 它们是"新做法"的全部核心，而且**不依赖 Widget** → 能直接单测，
/// 跑得快、不 flaky。这正是本做法比旧的"翻页闸门"好验证的地方。
class SentenceCentering {
  const SentenceCentering._();

  /// **死区比例**：对齐位置上下各 30% 视口高以内不滚（用户拍板选"死区居中"）
  ///
  /// 为什么不追求精确对齐：用户原话是「保持在可见范围中心**附近**」——
  /// 精确对齐会让**同页内相邻句每次滚一点点**（每句 y 都不同），
  /// 看起来是"页面在轻轻抖"。死区吃掉这种微动。
  static const double deadZoneFraction = 0.30;

  /// **死区下限**（像素）：死区再窄也不窄于它
  ///
  /// ⚠️ 它**不是**第二个独立判据，而是**死区本身的宽度下限** ——
  /// 这一点踩过自相矛盾的坑：早先写成"出死区 → 要滚"+"偏差 < 15px 不滚"
  /// 两个独立条件，就会出现
  /// 「死区外 16px 就滚、死区内 100px 不滚」这种说不通的组合。
  ///
  /// 现在只有**一个**判据：`|句 y − 对齐位置| ≤ deadZonePx` → 不滚。
  /// `deadZonePx = max(视口高 × 30%, 15px)`，所以：
  /// · 大屏（视口高 800）→ 死区 240px，下限不生效；
  /// · 极小视口（视口高 40）→ 死区 15px，下限**保证死区不会窄到等于没有**。
  static const double minDeadZonePx = 15.0;

  /// 死区的实际半径（像素，单边）
  static double deadZonePx(double viewportHeight) {
    final double byFraction = viewportHeight * deadZoneFraction;
    return byFraction > minDeadZonePx ? byFraction : minDeadZonePx;
  }

  /// 算出「让句心落在 `alignment` 处」需要的滚动偏移
  ///
  /// * [pageTopOffset] —— 句所在页在滚动内容里的顶部偏移（**实测**，
  ///   来自 `RenderAbstractViewport.getOffsetToReveal`）
  /// * [sentenceCenterY] —— 句心在**该页内**的 y（**实测**，来自句的
  ///   `bounds.center.dy`）
  /// * [viewportHeight] —— 视口高
  /// * [alignment] —— 0 = 贴顶、0.5 = 居中、1 = 贴底
  ///
  /// ⚠️ 这两个输入都是**实测值**，与页高数组（`_pageExtents`）无关 ——
  /// 这是句级对齐比"按页计算"稳的根本原因：按页算必须先知道页高，
  /// 而 812 页的文档里页高**大部分还没量到**。
  static double targetOffset({
    required double pageTopOffset,
    required double sentenceCenterY,
    required double viewportHeight,
    required double alignment,
  }) =>
      pageTopOffset + sentenceCenterY - viewportHeight * alignment;

  /// **死区判定**：句当前 y 落在"对齐位置 ± 30% 视口高"内就不滚
  ///
  /// ⚠️ **必须夹取到视口内**（[viewportHeight]）：
  /// 极端档位下 `targetY ± 0.3V` 会越出视口 —— 例如
  /// `alignment = 0.2`、`V = 1000` → 区间 `[-100, 500]`（下界为负），
  /// 于是一个**已经在屏幕上方外面的句**会被判成"在死区内、不用滚"，
  /// 那就**违反了"保持在可见范围内"这个原始要求**。
  ///
  /// 夹取在 0.35 / 0.5 / 0.65 三档下**不生效**（区间本来就在视口内），
  /// 它是给将来加档位留的安全网。
  static bool isInsideDeadZone({
    required double sentenceY,
    required double viewportHeight,
    required double alignment,
    double? deadZonePxOverride,
  }) {
    final double targetY = viewportHeight * alignment;
    final double radius = deadZonePxOverride ?? deadZonePx(viewportHeight);
    final double deadTop = math.max(0.0, targetY - radius);
    final double deadBottom = math.min(viewportHeight, targetY + radius);
    return sentenceY >= deadTop && sentenceY <= deadBottom;
  }

  /// **该不该发滚动**（唯一判据 = 死区）
  ///
  /// 两个参数各自独立，语义如下（用户拍板，比三档命名清楚也好测）：
  ///
  /// | 场景 | [force] | [forceCenter] | 效果 |
  /// | --- | --- | --- | --- |
  /// | 日常跟读 | `false` | `false` | 走死区；滑动中 / 停手未满 4 秒则让位 |
  /// | 一句跨两页翻到续页 / 首次进入 | `false` | `true` | **突破死区**；但仍让位 |
  /// | 回到朗读位置 / 点句朗读 / 目录跳转 | `true` | `true` | 两者都突破，无条件对齐 |
  ///
  /// * [force] —— 突破**让位**：用户正在滑动、或停手未满 4 秒时**仍可**滚动
  /// * [forceCenter] —— 突破**死区**：即便句已经在死区内也重新对齐
  ///
  /// 返回 `false` 只有一种原因：**句落在死区内且没有被要求强制对齐**。
  static bool shouldScroll({
    required double sentenceY,
    required double viewportHeight,
    required double alignment,
    required double targetOffsetValue,
    required double currentScrollOffset,
    bool force = false,
    bool forceCenter = false,
    double? deadZonePxOverride,
  }) {
    // 强制对齐：纯看"是否需要移动"（0.5px 以内视为已经在位，省一次无意义滚动）
    if (forceCenter) {
      return (targetOffsetValue - currentScrollOffset).abs() >= 0.5;
    }
    // 日常跟读：**唯一判据是死区**（15px 已作为死区下限，不再单独判一次）
    return !isInsideDeadZone(
      sentenceY: sentenceY,
      viewportHeight: viewportHeight,
      alignment: alignment,
      deadZonePxOverride: deadZonePxOverride,
    );
  }

  /// 把目标偏移夹进可滚动范围（避免"撞墙"时反复发无效滚动）
  static double clampOffset(double offset, double min, double max) =>
      offset < min ? min : (offset > max ? max : offset);
}

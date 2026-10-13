import 'package:flutter/material.dart';

/// 目录里「当前所在章节」那一行的统一装饰。
///
/// ## 为什么单独抽出来
///
/// 文字档（TXT/EPUB）与 PDF 的目录**数据结构不同** —— 前者是
/// `StructuredDocument` 的章节列表，后者是 `DocumentOutlineEntry`（PDF 书签）
/// 或纯页码列表；两边的页面各自渲染。但「当前读到哪一章」的视觉呈现必须
/// 一致（用户要求「效果和图标要一致」），所以把这层装饰抽出来共用，
/// 避免各写一套之后慢慢漂移。
///
/// ## 视觉参考
///
/// 音乐播放器的「正在播放」行：
///   · 淡色圆角背景
///   · 标题加粗 + 主题色
///   · 右侧一枚 `graphic_eq`（三条竖线）表示「正在这里」
///
/// 只保留「当前章节」这一种状态 —— 用户明确要求**不要**「已读完」的绿勾。
class TocCurrentItem extends StatelessWidget {
  const TocCurrentItem({
    super.key,
    required this.active,
    required this.child,
    this.borderRadius = 12,
  });

  /// 是不是「当前所在章节」。false 时原样返回 [child]（不加任何装饰）。
  final bool active;

  final Widget child;

  /// 圆角半径。三处目录（PDF 页码列表 / 原书目录 / 文字档章节列表）
  /// 用同一个值，保持外观一致。
  final double borderRadius;

  /// 当前章节右侧的图标。
  ///
  /// 选 `graphic_eq`（三条竖线）是照音乐播放器的「正在播放」观感来的；
  /// 三处目录**必须共用这一个常量**，不允许各选一个 —— 那就是漂移的开始。
  static const IconData currentIcon = Icons.graphic_eq;

  /// 当前章节背景色的透明度（相对 `primaryContainer`）。
  ///
  /// 太高会喧宾夺主、盖过正文，太低又看不出来；0.55 在亮 / 暗两种主题下
  /// 都能看出高亮、又不刺眼。**跟随主题**（含动态取色），不是写死的颜色。
  static const double fillOpacity = 0.55;

  /// 计算当前章节的背景色（三处共用）。
  static Color? fillColor(BuildContext context, bool active) {
    if (!active) return null;
    return Theme.of(context)
        .colorScheme
        .primaryContainer
        .withOpacity(fillOpacity);
  }

  /// 给 `ExpansionTile` 用的圆角形状。
  ///
  /// ⚠️ `ExpansionTile` **没法用 [DecoratedBox] 包裹** —— 包了它展开后的
  /// 子项（那一章的页列表）会被一起染上背景色，看起来像"整个展开块都选中"。
  /// 所以那一处只能走 `backgroundColor` / `shape` 这两个参数，
  /// 圆角在这里单独给一个 ShapeBorder。
  static ShapeBorder? expansionShape(bool active, double borderRadius) {
    if (!active) return null;
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(borderRadius),
      side: BorderSide.none,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!active) return child;
    return Padding(
      // 外留一点空隙，让高亮块不贴着列表左右边缘（观感更接近音乐软件那行）
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fillColor(context, true),
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: child,
      ),
    );
  }
}

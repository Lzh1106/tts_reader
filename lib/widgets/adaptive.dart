import 'package:flutter/material.dart';

/// 平板横屏 / 桌面的断点（Material 3 的 compact / medium 分界）
///
/// 达到这个宽度就换成「侧边导航栏 + 更宽的内容区」的布局：
/// 手机竖屏用底部导航，横屏拿在手里底部栏会离拇指很远。
const double kWideBreakpoint = 720;

/// 更宽的断点：内容区可以再分栏（例如文档库双列）
const double kExtraWideBreakpoint = 1000;

/// 当前是不是宽屏（平板横屏 / 桌面）
bool isWideLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kWideBreakpoint;

/// 当前是不是超宽屏
bool isExtraWideLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kExtraWideBreakpoint;

/// 当前是不是平板（按最短边判断，横竖屏都成立）
///
/// 为什么要单独判：PDF 原版式在平板上**竖屏**时视口也很宽（800dp 上下），
/// 但 `isWideLayout` 只看宽不看高，竖屏平板是 800×1280 会被判成宽屏，
/// 而横屏手机（900×400）又不该按平板处理。用最短边更接近「这是不是大屏设备」。
bool isTabletLayout(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.shortestSide >= 600;
}

/// 当前是不是平板或更大的屏幕
bool isLargeScreen(BuildContext context) =>
    isTabletLayout(context) || isWideLayout(context);

/// 文档库网格列数：手机 1 列，平板 2 列，大平板 / 桌面 3 列
int libraryColumns(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width >= 1280) return 3;
  if (width >= kWideBreakpoint) return 2;
  return 1;
}

/// 内容居中并限制最大宽度
///
/// 平板上最容易忽略的问题不是「显示不下」，而是**一行太长**：
/// 正文铺满 1200dp 时眼睛很难换行，所以正文 / 设置这类纵向内容统一限宽居中。
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth = 760});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

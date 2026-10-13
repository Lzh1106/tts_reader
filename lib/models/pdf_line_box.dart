import 'dart:ui' show Offset, Rect, Size;

/// 视口坐标 → (页下标, 页内坐标)；算不出来返回 null
///
/// 依据（用真实点击在设备上校对过）：`PdfViewerController.scrollOffset` 是
/// **逻辑像素**，在 `zoomLevel == 1` 时满足
///
/// ```
/// 页内 = 视口 + scrollOffset
/// ```
///
/// 校对记录（同一份文档、缩放 1）：
/// - 视口 y=386.2 → 插件报页内 591.1 → 差 204.9
/// - 视口 y=214.7 → 插件报页内 550.4 → 差 335.7（期间用户往下滚了）
///
/// 两次差值都恰好等于当时的 `scrollOffset.dy`，所以这套换算是可靠的。
/// 连续滚动版式里视口可能同时露出两页，因此按 `页高 * zoomLevel` 逐页定位；
/// 算出越界返回 null（调用方按「点空了」处理）。
(int, Offset)? viewportToPagePosition({
  required Offset viewportPosition,
  required Offset scrollOffset,
  required Size pageSize,
  required double zoomLevel,
  required int pageCount,
}) {
  if (pageCount <= 0) return null;
  if (pageSize.width <= 0 || pageSize.height <= 0) return null;
  final zoom = zoomLevel <= 0 ? 1.0 : zoomLevel;
  // scrollOffset 是视口逻辑像素；乘 zoom 换到「页内坐标 × zoom」的空间
  final contentY = viewportPosition.dy + scrollOffset.dy * zoom;
  final pageHeight = pageSize.height * zoom;
  if (pageHeight <= 0) return null;
  var index = (contentY / pageHeight).floor();
  if (index < 0) index = 0;
  if (index > pageCount - 1) index = pageCount - 1;
  final localX = (viewportPosition.dx + scrollOffset.dx * zoom) / zoom;
  final localY = (contentY - index * pageHeight) / zoom;
  if (localX < 0 || localY < 0) return null;
  return (index, Offset(localX, localY));
}

/// PDF 页面上的一行文字及其位置
///
/// 坐标系：PDF 页面坐标（单位与 `SfPdfViewer` 的 `PdfGestureDetails.pagePosition`
/// 一致——原点在页面左上角），因此可以直接拿点击位置来命中某一行。
///
/// 用途：原版式下点页面上的任意一行 → 从那一行所在的句子开始朗读。
class PdfLineBox {
  const PdfLineBox({required this.text, required this.bounds});

  /// 这一行的文字
  final String text;

  /// 这一行在页面上的外框
  final Rect bounds;

  /// 是否落在这一行的纵向容差带内
  ///
  /// PDF 的文字外框往往只包住字身（行距比字高大），行与行之间的空隙直接
  /// `contains` 是点不中的；容差取一个行高，超出行高就不算这一行。
  static bool hits(Rect bounds, Offset point) {
    final tolerance = (bounds.height > 10 ? bounds.height : 10.0) * 1.2;
    final dy = _verticalGap(bounds, point);
    return dy <= tolerance;
  }

  static double _verticalGap(Rect bounds, Offset point) {
    if (point.dy < bounds.top) return bounds.top - point.dy;
    if (point.dy > bounds.bottom) return point.dy - bounds.bottom;
    return 0;
  }

  static double _horizontalGap(Rect bounds, Offset point) {
    if (point.dx < bounds.left) return bounds.left - point.dx;
    if (point.dx > bounds.right) return point.dx - bounds.right;
    return 0;
  }

  /// 命中代价：纵向距离权重远高于横向
  ///
  /// 同一行左右留白（点在字的左边/右边）仍应算这一行，
  /// 而点在两行之间时应当归给纵向更近的那一行。
  static double cost(Rect bounds, Offset point) =>
      _verticalGap(bounds, point) * 100 + _horizontalGap(bounds, point);

  /// 在一页的行里找出被点中的那一行；都不合适返回 null
  static PdfLineBox? find(List<PdfLineBox> lines, Offset point) {
    PdfLineBox? best;
    var bestCost = double.infinity;
    for (final line in lines) {
      if (!hits(line.bounds, point)) continue;
      final value = cost(line.bounds, point);
      if (value < bestCost) {
        bestCost = value;
        best = line;
      }
    }
    return best;
  }

  @override
  String toString() => 'PdfLineBox(${bounds.left.toStringAsFixed(0)},'
      '${bounds.top.toStringAsFixed(0)} ${bounds.width.toStringAsFixed(0)}x'
      '${bounds.height.toStringAsFixed(0)} "$text")';
}

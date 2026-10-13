import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/pdf_line_box.dart';

/// 视口坐标 → 页内坐标的换算。
///
/// 这是「点 PDF 文本层」的**核心数学**：算错了就命不中文字行，
/// 而设备上又很难自动验（合成触摸不一定驱动得了插件的手势链），
/// 所以把它抽成纯函数在这里精确断言。
///
/// 校对依据（设备实测，见 [viewportToPagePosition] 的文档）：
/// 视口 y=386.2 + scrollOffset 204.9 = 插件报的页内 y=591.1。
void main() {
  const pageSize = Size(392.1, 567.78);
  const count = 319;

  test('未滚动：页内坐标等于视口坐标', () {
    final hit = viewportToPagePosition(
      viewportPosition: const Offset(200, 300),
      scrollOffset: Offset.zero,
      pageSize: pageSize,
      zoomLevel: 1,
      pageCount: count,
    );
    expect(hit, isNotNull);
    expect(hit!.$1, 0);
    expect(hit.$2.dx, closeTo(200, 0.001));
    expect(hit.$2.dy, closeTo(300, 0.001));
  });

  test('用设备实测数据校对：视口 386.2 + 滚动 204.9 = 页内 591.1', () {
    final hit = viewportToPagePosition(
      viewportPosition: const Offset(100, 386.2),
      scrollOffset: const Offset(0, 204.9),
      pageSize: pageSize,
      zoomLevel: 1,
      pageCount: count,
    );
    expect(hit, isNotNull);
    expect(hit!.$1, 1, reason: '591.1 > 页高 567.78，落在第 2 页');
    expect(hit.$2.dy, closeTo(591.1 - 567.78, 0.01));
  });

  test('用设备实测数据校对：视口 214.7 + 滚动 335.7 = 页内 550.4', () {
    final hit = viewportToPagePosition(
      viewportPosition: const Offset(80, 214.7),
      scrollOffset: const Offset(0, 335.7),
      pageSize: pageSize,
      zoomLevel: 1,
      pageCount: count,
    );
    expect(hit, isNotNull);
    expect(hit!.$1, 0, reason: '550.4 仍在第 1 页内');
    expect(hit.$2.dy, closeTo(550.4, 0.01));
    expect(hit.$2.dx, closeTo(80, 0.01));
  });

  test('滚动过一页多：页码按页高推进', () {
    // 滚到第 3 页中部
    final scroll = pageSize.height * 2 + 200;
    final hit = viewportToPagePosition(
      viewportPosition: const Offset(50, 100),
      scrollOffset: Offset(0, scroll),
      pageSize: pageSize,
      zoomLevel: 1,
      pageCount: count,
    );
    expect(hit, isNotNull);
    expect(hit!.$1, 2);
    expect(hit.$2.dy, closeTo(300, 0.01));
  });

  test('放大 2 倍：滚动偏移与页高都按缩放计入', () {
    final hit = viewportToPagePosition(
      viewportPosition: const Offset(100, 200),
      scrollOffset: const Offset(0, 400),
      pageSize: pageSize,
      zoomLevel: 2,
      pageCount: count,
    );
    expect(hit, isNotNull);
    // contentY = 200 + 400*2 = 1000；页高 = 1135.56 → 仍在第 1 页
    expect(hit!.$1, 0);
    expect(hit.$2.dy, closeTo(500, 0.01), reason: '(1000 - 0) / 2');
    expect(hit.$2.dx, closeTo(50, 0.01), reason: '100 / 2（scrollOffset.dx=0）');
  });

  test('越界：滚过头也夹到最后一页，不返回负数页', () {
    final hit = viewportToPagePosition(
      viewportPosition: const Offset(10, 10),
      scrollOffset: Offset(0, pageSize.height * (count + 5)),
      pageSize: pageSize,
      zoomLevel: 1,
      pageCount: count,
    );
    expect(hit, isNotNull);
    expect(hit!.$1, count - 1, reason: '夹到最后一页');
    expect(hit.$2.dy, greaterThanOrEqualTo(0));
  });

  test('越界：负滚动（回弹中）夹到第 1 页且不返回负坐标', () {
    final hit = viewportToPagePosition(
      viewportPosition: const Offset(10, 300),
      scrollOffset: const Offset(0, -200),
      pageSize: pageSize,
      zoomLevel: 1,
      pageCount: count,
    );
    expect(hit, isNotNull);
    expect(hit!.$1, 0);
    expect(hit.$2.dy, closeTo(100, 0.01));
  });

  test('视口在页外（负坐标）返回 null，调用方按「点空了」处理', () {
    final hit = viewportToPagePosition(
      viewportPosition: const Offset(-10, 300),
      scrollOffset: Offset.zero,
      pageSize: pageSize,
      zoomLevel: 1,
      pageCount: count,
    );
    expect(hit, isNull);
  });

  test('坏输入不抛异常，一律返回 null', () {
    expect(
      viewportToPagePosition(
        viewportPosition: Offset.zero,
        scrollOffset: Offset.zero,
        pageSize: Size.zero,
        zoomLevel: 1,
        pageCount: count,
      ),
      isNull,
      reason: '页尺寸为 0（解析还没拿到）时不该算',
    );
    expect(
      viewportToPagePosition(
        viewportPosition: Offset.zero,
        scrollOffset: Offset.zero,
        pageSize: pageSize,
        zoomLevel: 1,
        pageCount: 0,
      ),
      isNull,
      reason: '还没加载完页数时不该算',
    );
    // zoomLevel 为 0（插件未就绪）：按 1 处理而不是除零
    final fallback = viewportToPagePosition(
      viewportPosition: const Offset(10, 10),
      scrollOffset: Offset.zero,
      pageSize: pageSize,
      zoomLevel: 0,
      pageCount: count,
    );
    expect(fallback, isNotNull);
    expect(fallback!.$2.dy, closeTo(10, 0.01));
  });
}

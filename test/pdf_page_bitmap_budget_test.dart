import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/features/pdf_reading/pdf_page_layer.dart';

/// 位图**像素预算**的纯逻辑测试。
///
/// 「清晰 vs 内存」这件事只有一个取舍点：单页位图能有多大。
/// 位图字节数按尺寸的**平方**增长，所以一旦页面逻辑尺寸变大
/// （以后加捏合缩放、或平板大屏），不设上限就会把 `imageCache`
/// 的默认预算（100 MB）挤爆。
///
/// 这里把边界钉死：**没超上限要原样返回**（不能误伤清晰度），
/// **超了要等比缩小**（不能改宽高比 —— 改了显示就会变形）。
void main() {
  group('位图像素预算 capPagePixels', () {
    test('没超上限：原样返回（不能误伤清晰度）', () {
      // 当前真机实测值：逻辑 376.7×534.6、dpr 2.75 → 位图 1036×1470
      const actual = Size(1036, 1470);
      final result = PdfPageLayer.capPagePixels(actual);
      expect(result, actual, reason: '约 152 万像素，远低于 400 万上限，必须原样');
      expect(result.width * result.height, lessThan(PdfPageLayer.maxPagePixels));
    });

    test('恰好等于上限：原样返回（边界不能提前缩）', () {
      const side = 2000.0; // 2000×2000 = 400 万 = maxPagePixels
      const exact = Size(side, side);
      expect(exact.width * exact.height, PdfPageLayer.maxPagePixels);
      expect(PdfPageLayer.capPagePixels(exact), exact);
    });

    test('超过上限：等比缩小到上限（面积正好压到上限）', () {
      // 模拟「加了 200% 缩放的大页面」：4000×3000 = 1200 万像素
      const huge = Size(4000, 3000);
      final result = PdfPageLayer.capPagePixels(huge);
      final pixels = result.width * result.height;
      expect(pixels, lessThanOrEqualTo(PdfPageLayer.maxPagePixels + 1),
          reason: '压到上限以内');
      expect(pixels, greaterThan(PdfPageLayer.maxPagePixels * 0.99),
          reason: '要用满预算，不能缩过头（缩过头就是白白糊掉）');
    });

    test('等比：宽高比必须保持（否则显示会变形）', () {
      const huge = Size(4000, 3000);
      final result = PdfPageLayer.capPagePixels(huge);
      final before = huge.width / huge.height;
      final after = result.width / result.height;
      expect(after, closeTo(before, 1e-9),
          reason: '只降分辨率、不改宽高比；命中测试用的是逻辑尺寸，与这里无关');
    });

    test('极端超限也等比（1 亿像素不能变形成条状）', () {
      const extreme = Size(10000, 10000);
      final result = PdfPageLayer.capPagePixels(extreme);
      expect(result.width, closeTo(result.height, 1e-6));
      expect(result.width * result.height,
          lessThanOrEqualTo(PdfPageLayer.maxPagePixels + 1));
    });

    test('空尺寸不炸（除以 0 的防护）', () {
      expect(PdfPageLayer.capPagePixels(Size.zero), Size.zero);
      expect(PdfPageLayer.capPagePixels(const Size(0, 100)),
          const Size(0, 100));
    });

    test('上限值本身要足够放得下当前真机需求（留有余量）', () {
      // 真机实测 152 万像素；上限至少要留 2 倍余量，否则以后稍加缩放就被压
      const measured = 1036.0 * 1470.0;
      expect(PdfPageLayer.maxPagePixels, greaterThan(measured * 2),
          reason: '当前实测 ${measured.toInt()} 像素，上限 '
              '${PdfPageLayer.maxPagePixels.toInt()} 应当留足 2 倍以上余量');
      // 同时不能大到失去意义：解码后（4 字节/像素）不该超过 imageCache 的 1/4
      const decodedMb = PdfPageLayer.maxPagePixels * 4 / 1024 / 1024;
      expect(decodedMb, lessThan(100 / 4),
          reason: '单页解码 ${decodedMb.toStringAsFixed(1)}MB，'
              '要保证 imageCache（默认 100MB）至少能放 4 页');
    });
  });
}

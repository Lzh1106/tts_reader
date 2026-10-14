import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/features/pdf_reading/pdf_page_layer.dart';

/// T2S 三条借鉴里的**几何异常检测**（★v1.21.45 改动 3）
///
/// 判据（施工单）：
/// * 字符盒落在「页面 + 5% 容忍带」之外；
/// * 越界比例 **> 20%** 才算异常；
/// * 零面积占位盒不算（它们是 fragment 之间被引擎丢掉的字符）。
///
/// 用**纯函数**单测：`analyzeTextLayerGeometry` 不碰 PDF、不碰 IO，
/// 所以边界可以钉死（19% / 21% / 容忍带内）。
void main() {
  const Size page = Size(600, 800);

  /// 造 n 个"在页面内"的盒 + m 个"跑到页面外"的盒
  List<Rect> boxes(int inside, int outside) => <Rect>[
        for (var i = 0; i < inside; i++)
          Rect.fromLTWH(20 + (i % 10) * 10, 30 + (i ~/ 10) * 12, 8, 10),
        for (var i = 0; i < outside; i++)
          Rect.fromLTWH(page.width + 50, page.height + 60, 8, 10),
      ];

  PdfTextLayerGeometry analyze(List<Rect> rects) => analyzeTextLayerGeometry(
        pageNumber: 3,
        charRects: rects,
        pageSize: page,
        lines: 5,
        sentences: 2,
      );

  group('几何异常检测', () {
    test('全部在页面内 → 不判异常', () {
      final g = analyze(boxes(100, 0));
      expect(g.charBoxes, 100);
      expect(g.outsideBoxes, 0);
      expect(g.anomalous, isFalse);
      expect(g.outsideRatio, 0);
    });

    test('★21% 越界 → 判异常（门槛是 > 20%）', () {
      final g = analyze(boxes(79, 21));
      expect(g.charBoxes, 100);
      expect(g.outsideBoxes, 21);
      expect(g.outsideRatio, closeTo(0.21, 1e-9));
      expect(g.anomalous, isTrue, reason: '21% > 20% → 这份 PDF 的文字位置有问题');
    });

    test('★19% 越界 → 不判异常（差一点点不该误报）', () {
      final g = analyze(boxes(81, 19));
      expect(g.outsideRatio, closeTo(0.19, 1e-9));
      expect(g.anomalous, isFalse);
    });

    test('★外扩 5% 容忍带内的轻微越界 → 不算越界', () {
      // 页面 600x800 → 容忍带各 30 / 40；盒中心落在带内就不算
      final g = analyze(<Rect>[
        // 右边超出 10px（< 30）：不算
        Rect.fromLTWH(page.width + 6, 100, 8, 10),
        // 左边超出 10px：不算
        const Rect.fromLTWH(-14, 100, 8, 10),
        // 下边超出 20px（< 40）：不算
        Rect.fromLTWH(100, page.height + 15, 8, 10),
      ]);
      expect(g.charBoxes, 3);
      expect(g.outsideBoxes, 0, reason: '5% 容忍带内的溢出属正常（页码 / 页眉 / 末字微溢）');
      expect(g.anomalous, isFalse);
    });

    test('超出容忍带才算越界（带外一点点就记）', () {
      final g = analyze(<Rect>[
        Rect.fromLTWH(page.width + 40, 100, 8, 10), // 中心超出 30 → 越界
        const Rect.fromLTWH(100, 100, 8, 10),
      ]);
      expect(g.outsideBoxes, 1);
      expect(g.outsideRatio, closeTo(0.5, 1e-9));
      expect(g.anomalous, isTrue);
    });

    test('零面积占位盒不计入分母（否则正常 PDF 会被误判）', () {
      // 10 个有效盒 + 90 个零面积占位盒：越界 3 个 → 3/10 = 30% > 20% → 异常
      final g = analyze(<Rect>[
        ...boxes(7, 3),
        for (var i = 0; i < 90; i++) Rect.zero,
      ]);
      expect(g.charBoxes, 10, reason: '零面积盒是"没有字符盒的位置"，不是真的错位');
      expect(g.outsideRatio, closeTo(0.3, 1e-9));
      expect(g.anomalous, isTrue);
    });

    test('一个有效盒都没有 → 不判异常（无从判断，不误报）', () {
      final g = analyze(<Rect>[Rect.zero, Rect.zero]);
      expect(g.charBoxes, 0);
      expect(g.outsideRatio, 0);
      expect(g.anomalous, isFalse);
      expect(g.logLine, contains('字符盒=0'));
    });
  });

  group('诊断探针那一行（改动 2）', () {
    test('格式固定：字符盒 / 行 / 句 / 页面尺寸', () {
      final g = analyze(boxes(42, 0));
      expect(
        g.logLine,
        'PDF 文字层[第 3 页] 字符盒=42 行=5 句=2 页面=600x800',
        reason: '★施工单钉的格式；真机排查就靠这一行',
      );
    });

    test('异常时另有说明（含比例与阈值，便于拿日志判案）', () {
      final g = analyze(boxes(70, 30));
      expect(g.anomalyNote, contains('几何异常'));
      expect(g.anomalyNote, contains('30/100'));
      expect(g.anomalyNote, contains('30.0%'));
      expect(g.anomalyNote, contains('20%'));
    });

    test('阈值可覆盖（测试 / 以后调参不用改实现）', () {
      final g = analyzeTextLayerGeometry(
        pageNumber: 1,
        charRects: boxes(95, 5),
        pageSize: page,
        lines: 1,
        sentences: 1,
        anomalyRatio: 0.01,
      );
      expect(g.anomalous, isTrue, reason: '阈值降到 1% 时 5% 就该判异常');
      expect(g.anomalyRatio, 0.01);
      expect(g.tolerance, 0.05);
    });
  });
}

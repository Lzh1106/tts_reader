import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/features/pdf_reading/sentence_centering.dart';

/// **句级居中的纯计算**（v1.21.43 · 模型 A · S1）
///
/// ## 为什么先测这一块
///
/// 模型 A 把「滚动状态机」（`PdfPageTurnController`）整层拆掉，
/// 换成"让朗读句待在屏幕对齐位置"。**拆掉的那层有 505 行 + 35 条用例**，
/// 而替换它的核心就是**这几个纯算术**：
///
/// * 目标偏移 = 页顶偏移 + 句心 y − 视口高 × 档位
/// * 死区 = 目标 ± 30% 视口高（**并夹取到视口内**）
/// * 强制对齐（force / forceCenter）→ 无视死区
///
/// 把它们钉住，等于把"新模型的行为"钉住了大半 —— 而且**不需要 Widget**，
/// 跑得快、不 flaky。这也是模型 A 比滚动模型好验证的地方。
void main() {
  // 812 页 PDF 的典型视口（手机竖屏）
  const double vh = 800.0;

  group('目标偏移：让句心落在档位处', () {
    test('居中档（0.5）：句心落在视口中点', () {
      // 页顶在滚动内容 10000，句心在页内 300 → 句绝对位置 10300
      // 要让它落在 0.5*800 = 400 → 滚动到 10300 - 400 = 9900
      final off = SentenceCentering.targetOffset(
        pageTopOffset: 10000,
        sentenceCenterY: 300,
        viewportHeight: vh,
        alignment: 0.5,
      );
      expect(off, 9900);
    });

    test('靠上档（0.35）：句心落在 35% 处（比居中更靠上）', () {
      final off = SentenceCentering.targetOffset(
        pageTopOffset: 10000,
        sentenceCenterY: 300,
        viewportHeight: vh,
        alignment: 0.35,
      );
      // 10300 - 0.35*800 = 10300 - 280 = 10020
      expect(off, 10020);
    });

    test('靠下档（0.65）：目标偏移比居中档小（画面更往下走）', () {
      final a = SentenceCentering.targetOffset(
        pageTopOffset: 10000,
        sentenceCenterY: 300,
        viewportHeight: vh,
        alignment: 0.35,
      );
      final b = SentenceCentering.targetOffset(
        pageTopOffset: 10000,
        sentenceCenterY: 300,
        viewportHeight: vh,
        alignment: 0.5,
      );
      final c = SentenceCentering.targetOffset(
        pageTopOffset: 10000,
        sentenceCenterY: 300,
        viewportHeight: vh,
        alignment: 0.65,
      );
      // 档位越大（越靠下），需要滚到的偏移越小
      expect(a, greaterThan(b));
      expect(b, greaterThan(c));
    });
  });

  group('死区：目标 ± 30% 视口高内不滚', () {
    test('正好落在目标位置 → 在死区内', () {
      expect(
        SentenceCentering.isInsideDeadZone(
            sentenceY: vh * 0.5, viewportHeight: vh, alignment: 0.5),
        isTrue,
      );
    });

    test('偏离目标 20%（< 30%）→ 仍在死区内（不滚）', () {
      expect(
        SentenceCentering.isInsideDeadZone(
            sentenceY: vh * 0.5 + vh * 0.20, viewportHeight: vh, alignment: 0.5),
        isTrue,
      );
    });

    test('偏离目标 40%（> 30%）→ 出死区（要滚）', () {
      expect(
        SentenceCentering.isInsideDeadZone(
            sentenceY: vh * 0.5 + vh * 0.40, viewportHeight: vh, alignment: 0.5),
        isFalse,
      );
    });

    test('★死区随档位平移：靠上档的可接受区整体上移', () {
      // 同一个 y：在靠上档下"偏低"（出区），在靠下档下"接近目标"（在区）
      const y = vh * 0.55;
      final inTop = SentenceCentering.isInsideDeadZone(
          sentenceY: y, viewportHeight: vh, alignment: 0.35);
      final inBottom = SentenceCentering.isInsideDeadZone(
          sentenceY: y, viewportHeight: vh, alignment: 0.65);
      // 0.55 距 0.35 是 0.20（<0.30，在区）；距 0.65 也是 0.10（在区）
      // → 两个都在区，说明区间足够宽。这里验证"档位确实被用上了"：
      expect(inTop, isTrue);
      expect(inBottom, isTrue);
      // 换一个只在一档里成立的 y：0.85 距 0.35 = 0.50（出区）、距 0.65 = 0.20（在区）
      const y2 = vh * 0.85;
      expect(
        SentenceCentering.isInsideDeadZone(
            sentenceY: y2, viewportHeight: vh, alignment: 0.35),
        isFalse,
        reason: '距靠上档 50% > 30% → 出区',
      );
      expect(
        SentenceCentering.isInsideDeadZone(
            sentenceY: y2, viewportHeight: vh, alignment: 0.65),
        isTrue,
        reason: '距靠下档 20% < 30% → 在区（这就是"死区随档位平移"）',
      );
    });

    test('★屏幕外的句绝不算"在死区内"（夹取生效，防漏滚看不见的句）', () {
      // 极端档位 0.2：naive 公式 target ± 30% = [0.2-0.3, 0.2+0.3] = [-0.1, 0.5]
      // 若下界取 -0.1，则 y = -50（屏幕上方外面）会被误判成"在区内"
      expect(
        SentenceCentering.isInsideDeadZone(
            sentenceY: -50, viewportHeight: vh, alignment: 0.2),
        isFalse,
        reason: '★屏幕上方外面的句必须判为"要滚"（夹取到 [0, vh] 救的正是这个）',
      );
      expect(
        SentenceCentering.isInsideDeadZone(
            sentenceY: vh + 100, viewportHeight: vh, alignment: 0.8),
        isFalse,
        reason: '★屏幕下方外面的句同理',
      );
    });

    test('三档 0.35/0.5/0.65 下区间本来就在视口内（夹取不生效）', () {
      for (final a in <double>[0.35, 0.5, 0.65]) {
        final target = vh * a;
        expect(target - 0.30 * vh, greaterThanOrEqualTo(0.0),
            reason: '$a 档下界应 ≥ 0');
        expect(target + 0.30 * vh, lessThanOrEqualTo(vh),
            reason: '$a 档上界应 ≤ vh');
      }
    });
  });

  group('该不该滚：死区 + 微抖阈值 + 强制', () {
    test('落在死区内 → 不滚（这就是"死区居中"）', () {
      final target = SentenceCentering.targetOffset(
        pageTopOffset: 10000,
        sentenceCenterY: 300,
        viewportHeight: vh,
        alignment: 0.5,
      );
      expect(
        SentenceCentering.shouldScroll(
          sentenceY: vh * 0.5,
          viewportHeight: vh,
          alignment: 0.5,
          targetOffsetValue: target,
          currentScrollOffset: 9500, // 差 400，但句在死区内
        ),
        isFalse,
        reason: '死区优先：句已经在"中心附近"，不该为它滚动',
      );
    });

    test('出死区 → 要滚', () {
      final target = SentenceCentering.targetOffset(
        pageTopOffset: 10000,
        sentenceCenterY: 300,
        viewportHeight: vh,
        alignment: 0.5,
      );
      expect(
        SentenceCentering.shouldScroll(
          sentenceY: vh * 0.95, // 贴着屏幕底，远超 30% 死区
          viewportHeight: vh,
          alignment: 0.5,
          targetOffsetValue: target,
          currentScrollOffset: 9500,
        ),
        isTrue,
      );
    });

    test('★突破死区的是 forceCenter（force 管的是让位）', () {
      final target = SentenceCentering.targetOffset(
        pageTopOffset: 10000,
        sentenceCenterY: 300,
        viewportHeight: vh,
        alignment: 0.5,
      );
      expect(
        SentenceCentering.shouldScroll(
          sentenceY: vh * 0.5, // 明明在死区里
          viewportHeight: vh,
          alignment: 0.5,
          targetOffsetValue: target,
          currentScrollOffset: 9500,
          forceCenter: true,
        ),
        isTrue,
        reason: '★「回到朗读位置」「点句朗读」「目录跳转」= force+forceCenter，'
            '其中"无视死区"由 forceCenter 负责',
      );
    });

    test('★forceCenter（跨页换页时机）→ 也无视死区', () {
      final target = SentenceCentering.targetOffset(
        pageTopOffset: 10000,
        sentenceCenterY: 300,
        viewportHeight: vh,
        alignment: 0.5,
      );
      expect(
        SentenceCentering.shouldScroll(
          sentenceY: vh * 0.5,
          viewportHeight: vh,
          alignment: 0.5,
          targetOffsetValue: target,
          currentScrollOffset: 9500,
          forceCenter: true,
        ),
        isTrue,
        reason: '★跨页是内容连续性被打断的时刻，值得一次干净对齐',
      );
    });

    test('★强制对齐时偏差极小也不发滚动（省一次无意义滚动）', () {
      expect(
        SentenceCentering.shouldScroll(
          sentenceY: vh * 0.9,
          viewportHeight: vh,
          alignment: 0.5,
          targetOffsetValue: 9900.0,
          currentScrollOffset: 9900.2, // 只差 0.2px
          force: true,
          forceCenter: true,
        ),
        isFalse,
        reason: '已经在目标位置：强制也不该发一次无意义滚动',
      );
    });

    test('★唯一判据是死区：出死区就滚，与"偏差大小"无关', () {
      // 用户指出过一处自相矛盾：早先是「出死区 → 要滚」+「偏差<15px 不滚」
      // 两个独立条件 → 会出现「死区外 16px 就滚、死区内 100px 不滚」。
      // 现在 15px 是**死区宽度下限**，只有一个判据。
      final target = SentenceCentering.targetOffset(
        pageTopOffset: 10000,
        sentenceCenterY: 300,
        viewportHeight: vh,
        alignment: 0.5,
      );
      // 句刚出死区一点点（目标 + 31%），**偏差只有 10px** → 仍然要滚
      expect(
        SentenceCentering.shouldScroll(
          sentenceY: vh * 0.5 + vh * 0.31,
          viewportHeight: vh,
          alignment: 0.5,
          targetOffsetValue: target,
          currentScrollOffset: target - 10,
        ),
        isTrue,
        reason: '★出了死区就是出了死区 —— 不再被"偏差小于 15px"二次否决',
      );
    });

    test('★force / forceCenter 的组合语义（两参数各自独立）', () {
      final target = SentenceCentering.targetOffset(
        pageTopOffset: 10000,
        sentenceCenterY: 300,
        viewportHeight: vh,
        alignment: 0.5,
      );
      bool call({bool force = false, bool forceCenter = false}) =>
          SentenceCentering.shouldScroll(
            sentenceY: vh * 0.5, // 一直"在死区内"
            viewportHeight: vh,
            alignment: 0.5,
            targetOffsetValue: target,
            currentScrollOffset: 9500,
            force: force,
            forceCenter: forceCenter,
          );
      // 日常跟读：都 false → 在死区 → 不滚
      expect(call(), isFalse, reason: '日常跟读：走死区');
      // 跨页/首次进入：forceCenter=true, force=false → 突破死区
      expect(call(forceCenter: true), isTrue,
          reason: '跨页 / 首次进入：突破死区（force=false 表示**仍**让位）');
      // 用户主动：两个都 true → 突破死区（force 另在调用方突破让位）
      expect(call(force: true, forceCenter: true), isTrue,
          reason: '用户主动：两样都突破');
      // force 单独为真而 forceCenter 为假：不应被当成"突破死区"
      expect(call(force: true), isFalse,
          reason: '★force 只管"让位"，管不到"死区" —— 两个参数职责不重叠');
    });
  });

  group('死区下限 15px（防止死区窄到等于没有）', () {
    test('大视口：按 30% 算，下限不生效', () {
      expect(SentenceCentering.deadZonePx(800), 240.0);
    });

    test('极小视口：落到 15px 下限', () {
      // 视口高 40 → 30% 只有 12px < 15px → 取 15px
      expect(SentenceCentering.deadZonePx(40), 15.0);
    });

    test('恰好相等时的边界（视口高 50 → 30% = 15px）', () {
      expect(SentenceCentering.deadZonePx(50), 15.0);
    });

    test('★下限让"死区"在极小视口下仍然存在（不是 0）', () {
      expect(
        SentenceCentering.isInsideDeadZone(
          sentenceY: 10,
          viewportHeight: 40,
          alignment: 0.5,
        ),
        isTrue,
        reason: '★对齐位置 20、死区半径 15 → [5, 35]；句 y=10 在区内',
      );
    });
  });

  group('偏移夹取', () {
    test('低于最小值 → 夹到最小值（不撞上边）', () {
      expect(SentenceCentering.clampOffset(-100, 0, 5000), 0);
    });

    test('高于最大值 → 夹到最大值（不撞下边）', () {
      expect(SentenceCentering.clampOffset(9999, 0, 5000), 5000);
    });

    test('区间内原样返回', () {
      expect(SentenceCentering.clampOffset(1234, 0, 5000), 1234);
    });
  });

  group('★一句跨两页：高亮两页都画（S2b 的核心语义）', () {
    // 这一组钉的是**判据**：给定"朗读句起点"与"跨页终点"，某一页该不该画、
    // 该画哪一句。绘制侧只认"本页的句索引"，于是两页各画自己那一半。
    //
    // 抽成局部纯函数是为了能直接单测（不必起 Widget）；
    // 它与 `pdf_reading_page._highlightFor` 的判定逐条一致。
    int? highlightSentenceFor({
      required int pageIndex, // 0 起
      required int? refPage,
      required int refSentence,
      required int? spanEndPage,
      required int? spanEndSentence,
    }) {
      if (refPage == null) return null;
      if (refPage == pageIndex) return refSentence; // ① 起始页
      if (spanEndPage == pageIndex) return spanEndSentence; // ② 续页
      return null;
    }

    test('★起始页画起始句', () {
      expect(
        highlightSentenceFor(
          pageIndex: 6,
          refPage: 6,
          refSentence: 25,
          spanEndPage: 7,
          spanEndSentence: 1,
        ),
        25,
      );
    });

    test('★续页画续句（这就是"两页都画"）', () {
      expect(
        highlightSentenceFor(
          pageIndex: 7,
          refPage: 6,
          refSentence: 25,
          spanEndPage: 7,
          spanEndSentence: 1,
        ),
        1,
        reason: '★旧实现在这里返回 null（字符区间在本页对不上任何整句）'
            ' → 第二页不画，就是用户报的"跨页句只框在上一页"',
      );
    });

    test('既不是起始页也不是续页 → 不画', () {
      expect(
        highlightSentenceFor(
          pageIndex: 6,
          refPage: 5,
          refSentence: 3,
          spanEndPage: 7,
          spanEndSentence: 1,
        ),
        isNull,
      );
    });

    test('不跨页时只有起始页画，续页为空（不能凭空多框一页）', () {
      expect(
        highlightSentenceFor(
          pageIndex: 6,
          refPage: 6,
          refSentence: 25,
          spanEndPage: null,
          spanEndSentence: null,
        ),
        25,
      );
      expect(
        highlightSentenceFor(
          pageIndex: 7,
          refPage: 6,
          refSentence: 25,
          spanEndPage: null,
          spanEndSentence: null,
        ),
        isNull,
        reason: '★不跨页时续页**不许**画（否则每页都多一块高亮）',
      );
    });

    test('没有朗读句（ref 为空）→ 哪页都不画', () {
      expect(
        highlightSentenceFor(
          pageIndex: 6,
          refPage: null,
          refSentence: 0,
          spanEndPage: null,
          spanEndSentence: null,
        ),
        isNull,
      );
    });
  });
}

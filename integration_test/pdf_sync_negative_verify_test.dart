import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tts_reader/features/pdf_reading/pdf_reading_page.dart';
import 'package:tts_reader/services/crash_log.dart';

/// **负向验证（设备侧）**：`AF[居中]` 的 `✅一致 / ⚠️不一致` 判据**接线**对不对。
///
/// ## 为什么要这条
///
/// S2a 的成败判据是「`refPage == 视口页`」。两个风险：
/// 1. **判据恒真**（摆设）—— 已由 `test/pdf_sync_judgement_test.dart` 证明
///    两种输出都可达（纯逻辑层）；
/// 2. **接线错了**（例如视口页其实也读了朗读位置）—— **只有真机能验**，
///    因为 `_pageAtOffset` 依赖真实渲染出来的页高。
///
/// 这条用例在真实 PDF 上把**视口滑到很远的一页**，然后断言：
/// **从滚动位置反推的页号 ≠ 朗读句所在页**。
///
/// * 若判据接线正确 → 反推出的页号会跟着滚动变（第 300 页左右），
/// * 若接线错误（反推也读朗读位置）→ 它会**一直等于**朗读页 → 本用例红。
///
/// 需要 `/data/local/tmp/abc.pdf`（319 页《共产主义ABC》）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<File?> adopt(String name) async {
    for (final dir in <String>['/data/local/tmp', '/sdcard/Download']) {
      final src = File('$dir/$name');
      if (!src.existsSync()) continue;
      final base = await getApplicationDocumentsDirectory();
      final dst = File('${base.path}/books/$name');
      await dst.parent.create(recursive: true);
      if (src.absolute.path == dst.absolute.path) return dst;
      await src.copy(dst.path);
      return dst;
    }
    return null;
  }

  testWidgets('★负向验证：视口滑走后，「视口页」必须与朗读页不同', (tester) async {
    final file = await adopt('abc.pdf');
    expect(file, isNotNull, reason: '需要 /data/local/tmp/abc.pdf');

    await tester.pumpWidget(MaterialApp(
      home: PdfReadingPage(
        filePath: file!.path,
        title: '同步判据负向验证',
        documentId: 'neg-sync-test',
      ),
    ));
    // 等文档打开 + 首页渲染（页高报回来才能反推页号）
    await tester.pumpAndSettle(const Duration(seconds: 5));

    final state = tester.state<PdfReadingPageState>(
      find.byType(PdfReadingPage),
    );

    // ① 起始（没滚动）：视口页应当能算出来
    //
    // ⚠️ 用的是**估算补齐版**（`viewportPageForJudgement`）—— 判据用的就是它。
    // 精确版在"远页页高还没量到"时会返回 null，实测滑到 offset=72583 时就红过。
    final startPage = state.viewportPageForJudgement(0);
    expect(startPage, isNotNull,
        reason: '★页高没报回来 → 页号反推不可用，判据无从谈起（先修这个）');
    // ignore: avoid_print
    print('NEG_SYNC 起点：offset=0 → 视口页=$startPage');

    // ② 把视口滑到很远处（用真实的滚动控制器，等价于用户大幅滑动）
    final scrollable = find.byType(Scrollable).first;
    final pos = tester.widget<Scrollable>(scrollable).controller!.position;
    final far = (pos.maxScrollExtent * 0.4).clamp(0.0, pos.maxScrollExtent);
    pos.jumpTo(far);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final farPage = state.viewportPageForJudgement(far);
    // ignore: avoid_print
    print('NEG_SYNC 滑到 offset=${far.toStringAsFixed(0)} → 视口页=$farPage '
        '（max=${pos.maxScrollExtent.toStringAsFixed(0)}）');

    expect(farPage, isNotNull, reason: '页高应已量到');
    expect(farPage, isNot(startPage),
        reason: '★滑到 40% 位置后，反推页号**必须变** —— '
            '若它纹丝不动，说明这个值不是从滚动位置算的，判据无效');

    // ③ 判据本体：视口页 ≠ 朗读页 → 必须判"不一致"
    final refPage = state.debugReadingPage ?? 0;
    final synced = PdfReadingPage.isViewportSyncedWithReading(
      viewportPage: farPage!,
      refPage: refPage + 1,
    );
    // ignore: avoid_print
    print('NEG_SYNC 朗读页=${refPage + 1} 视口页=$farPage '
        '→ ${synced ? "✅一致" : "⚠️不一致"}（期望 ⚠️不一致）');
    expect(synced, isFalse,
        reason: '★这条就是"判据能变红"的设备侧证明：'
            '朗读还在第 ${refPage + 1} 页、视口已经在第 $farPage 页');

    // 顺带留一条日志，便于真机上按 logcat 核对
    CrashLog.mark('NEG_SYNC 设备侧负向验证通过：朗读=${refPage + 1} '
        '视口=$farPage → ⚠️不一致');
  });
}

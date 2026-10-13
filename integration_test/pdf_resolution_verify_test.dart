import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tts_reader/features/pdf_reading/pdf_page_layer.dart';
import 'package:tts_reader/features/pdf_reading/pdf_reading_page.dart';

/// 设备侧：**PDF 位图分辨率**的数值断言。
///
/// ## 为什么要有这条
///
/// 用户反馈「手机解析 PDF 显示不够清晰」。真机上「清晰」与否没法用截图对比
/// 来守（CI 里不可靠），所以这里断言**三个尺寸的关系**：
///
/// ```
/// 位图尺寸  ≥  显示尺寸 × devicePixelRatio
/// ```
///
/// 达不到就是「位图小于物理像素、被拉伸放大」→ 必然发虚。
///
/// 这条用例守着的是 `PdfPageLayer` 交给 pdfrx 的渲染尺寸 ——
/// pdfrx 的 `_updateImage` 里，**给了 `pageSizeCallback` 就完全按它的返回值
/// 渲染**（不再乘 dpr），所以返回逻辑尺寸就会糊 dpr 倍。
///
/// 跑法：
///   flutter test integration_test/pdf_resolution_verify_test.dart -d emulator-5554
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 把测试资产拷到应用可读目录
  Future<File?> adopt(String name) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final target = File('${dir.path}/$name');
      if (!await target.exists()) {
        final candidates = <String>[
          'test_assets/$name',
          '/data/local/tmp/$name',
        ];
        for (final path in candidates) {
          final source = File(path);
          if (await source.exists()) {
            await source.copy(target.path);
            break;
          }
        }
      }
      return await target.exists() ? target : null;
    } catch (_) {
      return null;
    }
  }

  testWidgets('真实 PDF：位图分辨率要达到物理像素（否则就是糊的）', (tester) async {
    final file = await adopt('abc.pdf');
    expect(file, isNotNull, reason: '需要 test_assets/abc.pdf 或 /data/local/tmp/abc.pdf');
    // ignore: avoid_print
    print('DEVICE_VERIFY[resolution] 文件=${file!.path} '
        '大小=${(await file.length() / 1024 / 1024).toStringAsFixed(2)}MB');

    final samples = <PdfRenderDiagnostics>[];
    PdfPageLayer.renderDiagnosticsListener = samples.add;
    addTearDown(() => PdfPageLayer.renderDiagnosticsListener = null);

    await tester.pumpWidget(MaterialApp(
      home: PdfReadingPage(filePath: file.path, title: '分辨率验证'),
    ));

    // 等第一页渲染出诊断数据
    for (var i = 0; i < 120; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      if (samples.isNotEmpty) break;
    }

    expect(samples, isNotEmpty, reason: '应当至少渲染一页并报出诊断数据');
    final info = samples.first;
    // ignore: avoid_print
    print('DEVICE_VERIFY[resolution] $info');
    // ignore: avoid_print
    print('DEVICE_VERIFY[resolution] 位图/显示='
        '${info.bitmapPerDisplayPixel.toStringAsFixed(3)} '
        'dpr=${info.devicePixelRatio} '
        '页面点尺寸=${info.pageSize} '
        '达到物理像素=${info.isPhysicalResolution}');

    // 1) 位图不能小于显示尺寸（小于就是被放大，必然糊）
    expect(
      info.bitmapPerDisplayPixel,
      greaterThanOrEqualTo(1.0),
      reason: '位图（${info.bitmap.width.toStringAsFixed(1)}px）不该小于'
          '显示宽度（${info.display.width.toStringAsFixed(1)}），否则被放大→糊',
    );

    // 2) 这是本次修复的核心断言：位图要达到物理像素
    expect(
      info.isPhysicalResolution,
      isTrue,
      reason: '位图应当达到显示尺寸 × dpr（'
          '${(info.display.width * info.devicePixelRatio).toStringAsFixed(1)}px），'
          '实际只有 ${info.bitmap.width.toStringAsFixed(1)}px → 会被拉伸 dpr 倍、发虚',
    );

    // 3) 同时不能超过像素预算（清晰不能以内存失控为代价）
    //
    // 位图字节数按尺寸的平方增长：这一条守住「以后加缩放 / 平板大屏」
    // 时不会把 imageCache（默认 100MB）挤爆。
    final bitmapPixels = info.bitmap.width * info.bitmap.height;
    // ignore: avoid_print
    print('DEVICE_VERIFY[resolution] 位图像素=${bitmapPixels.toInt()} '
        '上限=${PdfPageLayer.maxPagePixels.toInt()} '
        '解码约=${(bitmapPixels * 4 / 1024 / 1024).toStringAsFixed(1)}MB');
    expect(
      bitmapPixels,
      lessThanOrEqualTo(PdfPageLayer.maxPagePixels + 1),
      reason: '单页位图不该超过 ${PdfPageLayer.maxPagePixels.toInt()} 像素',
    );
    expect(bitmapPixels, greaterThan(0), reason: '位图尺寸必须有效');

    // 收尾：别把朗读会话留给下一个用例
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}

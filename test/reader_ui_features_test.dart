import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/services/web_theme_script.dart';
import 'package:tts_reader/tts/tts_manager.dart';
import 'package:tts_reader/widgets/adaptive.dart';

/// v1.16 阅读页 / 浏览器新特性验证：
/// 1. 底部控制中心可折叠（按钮真的在两种形态之间切换）；
/// 2. 平板端按屏幕大小放大 PDF 页面的换算（纯算术，含手机不放大）；
/// 3. 平板 / 大屏断点判定（横竖屏都算平板，横屏手机按宽度算宽屏）；
/// 4. 浏览器主题注入脚本的产出（暗色压暗、亮色不动、脚本转义）。
void main() {
  final previousOnError = FlutterError.onError;
  setUpAll(() {
    FlutterError.onError = (FlutterErrorDetails details) {
      final text = details.exception.toString();
      if (text.contains('MissingPluginException') ||
          text.contains('syncfusion_flutter_pdfviewer')) {
        return;
      }
      previousOnError?.call(details);
    };
  });
  tearDownAll(() {
    FlutterError.onError = previousOnError;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    final tts = TtsManager.instance;
    tts
      ..speakTimeout = const Duration(milliseconds: 250)
      ..initTimeout = const Duration(milliseconds: 250)
      ..voiceTimeout = const Duration(milliseconds: 250)
      ..controlTimeout = const Duration(milliseconds: 250);
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
  });

  Future<(Directory, Document)> makeTxt(WidgetTester tester, String tag) async {
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('tts_$tag'));
    final file = File('${dir!.path}/$tag.txt')
      ..writeAsStringSync(
        List<String>.generate(60, (i) => '第 $i 段第一句。第 $i 段第二句！').join('\n\n'),
      );
    return (
      dir,
      Document(
        id: tag,
        title: tag,
        path: file.path,
        type: DocumentType.txt,
        importedAt: DateTime(2024),
      ),
    );
  }

  Future<void> cleanup(WidgetTester tester, Directory dir) async {
    unawaited(TtsManager.instance.stop());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.runAsync(() async {
      try {
        if (dir.existsSync()) await dir.delete(recursive: true);
      } catch (_) {
        // Windows 上句柄占用时忽略
      }
    });
  }

  /// 打开阅读页并等解析完成（底部控制栏出现即视为完成）
  Future<void> openReader(WidgetTester tester, Document document) async {
    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      if (find.byKey(ReaderPage.controlCenterKey).evaluate().isNotEmpty ||
          find.byKey(ReaderPage.collapsedControlKey).evaluate().isNotEmpty) {
        return;
      }
    }
  }

  group('底部控制中心折叠', () {
    testWidgets('默认展开，点收起变折叠态，点展开恢复', (tester) async {
      final (dir, document) = await makeTxt(tester, 'fold');
      try {
        await openReader(tester, document);
        // 折叠状态是跨页面记住的静态量，先确保起点是展开态
        if (find.byKey(ReaderPage.collapsedControlKey).evaluate().isNotEmpty) {
          await tester.tap(find.byKey(ReaderPage.expandControlKey));
          await tester.pump();
        }
        expect(find.byKey(ReaderPage.controlCenterKey), findsOneWidget);
        expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

        // 收起
        await tester.tap(find.byKey(ReaderPage.collapseControlKey));
        await tester.pump();
        expect(find.byKey(ReaderPage.collapsedControlKey), findsOneWidget);
        expect(find.byKey(ReaderPage.controlCenterKey), findsNothing);
        expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);

        // 再展开
        await tester.tap(find.byKey(ReaderPage.expandControlKey));
        await tester.pump();
        expect(find.byKey(ReaderPage.controlCenterKey), findsOneWidget);
        expect(find.byKey(ReaderPage.collapsedControlKey), findsNothing);
      } finally {
        await cleanup(tester, dir);
      }
    });

    testWidgets('折叠态仍然有播放按钮（折起来不能连暂停都点不到）', (tester) async {
      final (dir, document) = await makeTxt(tester, 'foldplay');
      try {
        await openReader(tester, document);
        await tester.tap(find.byKey(ReaderPage.collapseControlKey));
        await tester.pump();
        expect(find.byKey(ReaderPage.collapsedControlKey), findsOneWidget);
        expect(find.byIcon(Icons.play_arrow), findsWidgets);
        // 点它不该抛异常（测试环境没有 TTS 插件，只会走超时分支）
        await tester.tap(find.byIcon(Icons.play_arrow).first);
        await tester.pump();
        expect(tester.takeException(), isNull);
      } finally {
        await cleanup(tester, dir);
      }
    });
  });

  group('平板放大 PDF 页面（换算）', () {
    // A4 的 PDF 点尺寸约 595×842
    const a4 = Size(595, 842);

    test('手机竖屏（视口 400 宽）不放大', () {
      final zoom = pdfInitialZoom(
        viewport: const Size(400, 800),
        pageSize: a4,
        wide: false,
      );
      expect(zoom, 1.0);
    });

    test('平板竖屏（视口 800 宽）也停在适应宽度', () {
      final zoom = pdfInitialZoom(
        viewport: const Size(800, 1200),
        pageSize: a4,
        wide: false,
      );
      expect(zoom, 1.0);
    });

    test('平板横屏（1280x740，用户参考图的设备）：停在适应宽度，不放大', () {
      // 真机实测结论：zoomLevel=1.0 已经是适应宽度（页面铺满视口宽）。
      // 再加倍率会让页面溢出视口，点页面上的行会被判成「页面外」——
      // 实测 2.4 倍时 pageNumber = -1，点句起读直接失效。
      final zoom = pdfInitialZoom(
        viewport: const Size(1280, 740),
        pageSize: a4,
        wide: true,
      );
      // ignore: avoid_print
      print('DEVICE_VERIFY[tablet-zoom] wide 1280x740 zoom=$zoom');
      expect(zoom, 1.0,
          reason: '横屏平板停在适应宽度；放大到溢出会破坏点句');
    });

    test('任何大屏都不放大（把「再放大」留给用户捏合）', () {
      for (final viewport in <Size>[
        const Size(1280, 740), // 横屏平板
        const Size(800, 1200), // 竖屏平板
        const Size(2400, 1800), // 超大屏
        const Size(400, 800), // 手机
      ]) {
        for (final wide in <bool>[true, false]) {
          final zoom = pdfInitialZoom(
            viewport: viewport,
            pageSize: a4,
            wide: wide,
          );
          expect(zoom, 1.0, reason: '$viewport wide=$wide 应当停在适应宽度');
        }
      }
    });

    test('任何参数组合都不放大（zoomLevel=1.0 已是适应宽度）', () {
      // 这条是「别再想当然调大」的护栏：真机实测证明放大到溢出会让
      // 点句起读失效（pageNumber = -1），所以初始缩放恒定 1.0。
      for (final viewport in <Size>[
        const Size(2400, 1800),
        const Size(800, 1200),
        const Size(1280, 740),
      ]) {
        for (final page in <Size>[
          a4,
          const Size(595, 842),
          const Size(1400, 2000), // 大幅面扫描页
          const Size(300, 400), // 很小的页面
        ]) {
          expect(
            pdfInitialZoom(viewport: viewport, pageSize: page, wide: true),
            1.0,
            reason: '$viewport / $page 不该被放大',
          );
          expect(
            pdfInitialZoom(viewport: viewport, pageSize: page, wide: false),
            1.0,
            reason: '$viewport / $page 不该被放大',
          );
        }
      }
    });

    test('视口或页面尺寸无效时返回 1（不让界面算出 NaN / 除零）', () {
      expect(
        pdfInitialZoom(viewport: const Size(48, 48), pageSize: a4, wide: false),
        1.0,
      );
      expect(
        pdfInitialZoom(viewport: const Size(0, 0), pageSize: a4, wide: true),
        1.0,
      );
      expect(
        pdfInitialZoom(
          viewport: const Size(800, 1200),
          pageSize: Size.zero,
          wide: false,
        ),
        1.0,
      );
      expect(
        pdfInitialZoom(
          viewport: const Size(double.nan, double.nan),
          pageSize: a4,
          wide: true,
        ),
        1.0,
      );
    });
  });

  group('大屏断点', () {
    testWidgets('平板竖屏（800×1280）与横屏手机（900×400）分得开', (tester) async {
      Future<void> pump(Size size) => tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(size: size),
                child: Builder(
                  builder: (context) => Text(
                    '${isTabletLayout(context)}/${isWideLayout(context)}/'
                    '${isLargeScreen(context)}',
                  ),
                ),
              ),
            ),
          );

      await pump(const Size(800, 1280));
      expect(find.text('true/true/true'), findsOneWidget, reason: '平板竖屏也是大屏');

      await pump(const Size(900, 400));
      // 横屏手机：宽度够（isWideLayout 为真，导航栏用得上），但最短边只有 400
      expect(find.text('false/true/true'), findsOneWidget);

      await pump(const Size(400, 800));
      expect(find.text('false/false/false'), findsOneWidget, reason: '手机竖屏不是大屏');
    });
  });

  group('浏览器主题注入脚本', () {
    test('暗色主题压暗底色并声明 color-scheme', () {
      final css = WebThemeScript.css(dark: true);
      expect(css, contains('color-scheme: dark'));
      expect(css, contains(WebThemeScript.darkSurface));
      expect(css, contains('::-webkit-scrollbar'));
      expect(css, contains('!important'));
    });

    test('亮色主题不压暗页面（网页原本的白底就是对的）', () {
      final css = WebThemeScript.css(dark: false);
      expect(css, isNot(contains('color-scheme: dark')));
      expect(css, isNot(contains('!important')));
      expect(css, contains('::-webkit-scrollbar'));
    });

    test('注入脚本带 id（重复注入替换旧的），并把样式转义成单行字面量', () {
      final js = WebThemeScript.inject(dark: true);
      expect(js, contains(WebThemeScript.styleElementId));
      expect(js, contains('document.getElementById'));
      expect(js, contains('createElement'));

      // 样式必须是**单行**：JS 字符串里出现真实换行会直接语法错误。
      // 取 createTextNode(' 与 ' 之间的那段，应当只剩转义后的 \n
      const start = "createTextNode('";
      final from = js.indexOf(start);
      expect(from, greaterThan(0), reason: '注入脚本要把 CSS 写进文本节点');
      final body = js.substring(from + start.length, js.indexOf("')", from));
      expect(body, isNot(contains('\n')), reason: '真实换行会截断 JS 字符串');
      expect(body, contains(r'\n'), reason: '换行应当被转义');
    });
  });
}

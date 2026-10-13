import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/reader_style.dart';
import 'package:tts_reader/pages/reader_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 阅读排版（T2S 的 ThemeSettings / 字号设置）验证：
/// 取值的夹取与持久化、配色在自定义底色下的可读性，以及「改完阅读页真的变了」。
void main() {
  final storage = StorageService.instance;

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
    storage.resetForTest();
    await storage.init();
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
  });

  group('取值与夹取', () {
    test('默认值就是出厂设置', () {
      const style = ReaderStyle.defaults;
      expect(style.isDefault, isTrue);
      expect(style.theme, ReadingTheme.follow);
      expect(style.fontFamily, '');
      expect(style.summary, contains('字号 17'));
    });

    test('越界值全部夹取到合法区间', () {
      final big = const ReaderStyle().copyWith(
        fontSize: 999,
        lineHeight: 9,
        letterSpacing: 99,
        pageMargin: 999,
        paragraphSpacing: 999,
      );
      expect(big.fontSize, ReaderStyle.maxFontSize);
      expect(big.lineHeight, ReaderStyle.maxLineHeight);
      expect(big.letterSpacing, ReaderStyle.maxLetterSpacing);
      expect(big.pageMargin, ReaderStyle.maxPageMargin);
      expect(big.paragraphSpacing, ReaderStyle.maxParagraphSpacing);

      final small = const ReaderStyle().copyWith(
        fontSize: -5,
        lineHeight: 0,
        letterSpacing: -3,
        pageMargin: -1,
        paragraphSpacing: -1,
      );
      expect(small.fontSize, ReaderStyle.minFontSize);
      expect(small.lineHeight, ReaderStyle.minLineHeight);
      expect(small.letterSpacing, 0);
      expect(small.pageMargin, 0);
      expect(small.paragraphSpacing, 0);
    });

    test('序列化往返不丢字段', () {
      final style = const ReaderStyle().copyWith(
        fontSize: 22,
        lineHeight: 2.0,
        letterSpacing: 1.0,
        pageMargin: 24,
        paragraphSpacing: 12,
        fontFamily: 'serif',
        theme: ReadingTheme.sepia,
      );
      final restored = ReaderStyle.fromJson(style.toJson());
      expect(restored.fontSize, 22);
      expect(restored.lineHeight, 2.0);
      expect(restored.letterSpacing, 1.0);
      expect(restored.pageMargin, 24);
      expect(restored.paragraphSpacing, 12);
      expect(restored.fontFamily, 'serif');
      expect(restored.theme, ReadingTheme.sepia);
      expect(restored.isDefault, isFalse);
    });

    test('坏数据不会造出非法排版', () {
      final restored = ReaderStyle.fromJson(<String, dynamic>{
        'fontSize': '很大',
        'lineHeight': 100,
        'pageMargin': -20,
        'fontFamily': 42,
        'theme': '不存在的主题',
      });
      expect(restored.fontSize, ReaderStyle.defaults.fontSize);
      expect(restored.lineHeight, ReaderStyle.maxLineHeight);
      expect(restored.pageMargin, 0);
      expect(restored.fontFamily, '');
      expect(restored.theme, ReadingTheme.follow);
    });
  });

  group('样式与配色', () {
    test('apply 把排版参数套到主题基础样式上', () {
      const base = TextStyle(fontSize: 14, height: 1.2, color: Colors.red);
      final style = const ReaderStyle().copyWith(
        fontSize: 20,
        lineHeight: 2.0,
        letterSpacing: 0.5,
        fontFamily: 'serif',
      );
      final result = style.apply(base);
      expect(result.fontSize, 20);
      expect(result.height, 2.0);
      expect(result.letterSpacing, 0.5);
      expect(result.fontFamily, 'serif');
    });

    test('浅底高亮派生自主题 primaryContainer（跟随主题 / 动态取色）', () {
      final light = ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4));
      final (bg, fg) = const ReaderStyle().highlightColors(light);
      expect(bg, light.primaryContainer);
      expect(fg, light.onPrimaryContainer);
      // 不再是写死的 T2S 浅蓝
      expect(bg, isNot(const Color(0xFFB5D8FE)));

      // 换强调色（模拟动态取色取到不同壁纸色），高亮底色真的变
      final other = ColorScheme.fromSeed(seedColor: const Color(0xFFB00020));
      final (bg2, _) = const ReaderStyle().highlightColors(other);
      expect(bg2, isNot(bg), reason: '改主题色后高亮底色必须跟着变');
      expect(bg2, other.primaryContainer);
    });

    test('两套主题的高亮实际颜色不同（改主题真的生效）', () {
      final a = ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4));
      final b = ColorScheme.fromSeed(seedColor: const Color(0xFF00696D));
      final ha = const ReaderStyle().highlightColors(a);
      final hb = const ReaderStyle().highlightColors(b);
      expect(ha.$1, isNot(hb.$1), reason: '两套主题的高亮底色必须不同');
    });

    test('暗底 / 暗色模式：高亮从暗色派生且文字可读（亮度差 > 0.3）', () {
      final light = ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4));
      // 1) 阅读底色本身是暗的（夜间）——浅底主题下的反向派生：底暗字亮
      final night = const ReaderStyle().copyWith(theme: ReadingTheme.night);
      final (nightBg, nightFg) = night.highlightColors(light);
      expect(nightFg.computeLuminance(), greaterThan(nightBg.computeLuminance()),
          reason: '夜间高亮应当底暗字亮');
      expect(nightBg, isNot(const Color(0xFFB5D8FE)), reason: '夜间不能用浅蓝底');

      // 2) 跟随主题但系统在暗色模式
      final dark = ColorScheme.fromSeed(
        seedColor: const Color(0xFF6750A4),
        brightness: Brightness.dark,
      );
      final followDark = const ReaderStyle().highlightColors(dark);
      expect(followDark.$1, isNot(const Color(0xFFB5D8FE)),
          reason: '暗色模式下不能用浅蓝底');

      // 3) 关键：底色与字色对比得开
      for (final pair in <(Color, Color)>[(nightBg, nightFg), followDark]) {
        final contrast =
            (pair.$1.computeLuminance() - pair.$2.computeLuminance()).abs();
        expect(contrast, greaterThan(0.3),
            reason: '高亮底 $pair 与文字色的亮度差太小，看不清');
      }

      // 暗底也随主题变（从暗色 ColorScheme 派生，不是写死深蓝）
      final darkOther = ColorScheme.fromSeed(
        seedColor: const Color(0xFFB00020),
        brightness: Brightness.dark,
      );
      expect(
        const ReaderStyle().highlightColors(darkOther).$1,
        isNot(followDark.$1),
        reason: '改主题色后暗色高亮底色也必须跟着变',
      );
      expect(night.headerColor(light), isNot(light.surfaceContainerHighest));
    });

    test('排版设置能存下来并在重启后读回', () async {
      await storage.setReaderStyle(
        const ReaderStyle().copyWith(fontSize: 24, theme: ReadingTheme.eyeCare),
      );
      expect(storage.readerStyle.value.fontSize, 24);

      // 模拟重启：丢掉缓存后重新 init
      storage.resetForTest();
      await storage.init();
      expect(storage.readerStyle.value.fontSize, 24);
      expect(storage.readerStyle.value.theme, ReadingTheme.eyeCare);
    });

    test('存储损坏时退回默认排版而不是崩溃', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'reader_style': '{不是 JSON'});
      storage.resetForTest();
      await storage.init();
      expect(storage.readerStyle.value.isDefault, isTrue);
    });
  });

  group('阅读页真的按设置渲染', () {
    testWidgets('改字号 / 换底色后正文立即变化', (tester) async {
      final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('tts_style'));
      final file = File('${dir!.path}/style.txt')
        ..writeAsStringSync('第一段第一句。第一段第二句。\n\n第二段第一句。');
      final document = Document(
        id: 'style',
        title: 'style',
        path: file.path,
        type: DocumentType.txt,
        importedAt: DateTime(2024),
      );

      /// 正文段落的字号（`Text.rich` 建出来的 Text 带 textSpan）
      double? bodyFontSize() {
        for (final text in tester.widgetList<Text>(find.byType(Text))) {
          if (text.textSpan != null && text.style?.fontSize != null) {
            return text.style!.fontSize;
          }
        }
        return null;
      }

      /// 阅读底色：正文外层应当出现对应颜色的 ColoredBox
      bool hasReadingBackground(Color color) => tester
          .widgetList<ColoredBox>(find.byType(ColoredBox))
          .any((box) => box.color == color);

      try {
        await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1200)));
        await tester.pump();
        await tester.pump();

        expect(find.textContaining('第一段第一句。'), findsWidgets);
        expect(bodyFontSize(), ReaderStyle.defaults.fontSize);
        expect(hasReadingBackground(ReadingTheme.sepia.background!), isFalse);

        await storage.setReaderStyle(
          const ReaderStyle().copyWith(fontSize: 26, theme: ReadingTheme.sepia),
        );
        await tester.pump();
        expect(bodyFontSize(), 26, reason: '字号改了正文就该跟着变');
        expect(
          hasReadingBackground(ReadingTheme.sepia.background!),
          isTrue,
          reason: '选了羊皮纸底色，阅读区应当铺上这个颜色',
        );
        expect(find.textContaining('第一段第一句。'), findsWidgets, reason: '换排版不该丢正文');
      } finally {
        unawaited(TtsManager.instance.stop());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.runAsync(() async {
          try {
            if (dir.existsSync()) await dir.delete(recursive: true);
          } catch (_) {
            // Windows 句柄占用时忽略
          }
        });
      }
    });
  });
}

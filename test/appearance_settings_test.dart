import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/pages/settings_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 外观设置的持久化与默认值：
/// 1. 手机动态取色（开关落盘）；
/// 2. 自定义背景图 + 透明度（路径与透明度落盘、透明度夹取）。
///
/// 说明：「启动图标切换」已按要求删除（ROM 上表现不可靠），相关用例一并移除。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
  });

  group('动态取色', () {
    test('默认关闭；开启后落盘，重开仍是开启', () async {
      final storage = StorageService.instance;
      expect(storage.useDynamicColor, isFalse, reason: '默认用内置种子色');

      await storage.setUseDynamicColor(true);
      expect(storage.useDynamicColor, isTrue);

      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      expect(StorageService.instance.useDynamicColor, isTrue,
          reason: '动态取色开关要落盘');
    });

    test('关闭后也落盘', () async {
      await StorageService.instance.setUseDynamicColor(true);
      await StorageService.instance.setUseDynamicColor(false);
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      expect(StorageService.instance.useDynamicColor, isFalse);
    });
  });

  group('自定义背景图', () {
    test('默认没有背景图；设置后落盘', () async {
      final storage = StorageService.instance;
      expect(storage.hasBackgroundImage, isFalse);

      await storage.setBackgroundImage('/tmp/bg.png');
      expect(storage.hasBackgroundImage, isTrue);
      expect(storage.backgroundImage, '/tmp/bg.png');

      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      expect(StorageService.instance.backgroundImage, '/tmp/bg.png');
    });

    test('清除后回到没有背景图', () async {
      final storage = StorageService.instance;
      await storage.setBackgroundImage('/tmp/bg.png');
      await storage.setBackgroundImage('');
      expect(storage.hasBackgroundImage, isFalse);
      // 只有空白的路径也算没设，避免拼出无效 File
      await storage.setBackgroundImage('   ');
      expect(storage.hasBackgroundImage, isFalse);
    });

    test('透明度默认 0.35，且会被夹到 0~1', () async {
      final storage = StorageService.instance;
      expect(storage.backgroundImageOpacity, closeTo(0.35, 0.001));

      await storage.setBackgroundImageOpacity(0.8);
      expect(storage.backgroundImageOpacity, closeTo(0.8, 0.001));
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      expect(StorageService.instance.backgroundImageOpacity, closeTo(0.8, 0.001),
          reason: '透明度要落盘');

      await storage.setBackgroundImageOpacity(5);
      expect(storage.backgroundImageOpacity, 1.0, reason: '超过 1 要夹到 1');
      await storage.setBackgroundImageOpacity(-3);
      expect(storage.backgroundImageOpacity, 0.0, reason: '小于 0 要夹到 0');
      await storage.setBackgroundImageOpacity(double.nan);
      expect(storage.backgroundImageOpacity, closeTo(0.35, 0.001),
          reason: 'NaN 要退回默认值，不能让渲染层拿到 NaN');
    });
  });

  group('设置页控件', () {
    testWidgets('外观控件都在，且动态取色开关能切换', (tester) async {
      // 设置页要读 TtsManager（引擎信息），必须给它 Provider
      await tester.pumpWidget(
        ChangeNotifierProvider<TtsManager>.value(
          value: TtsManager.instance,
          child: const MaterialApp(home: Scaffold(body: SettingsPage())),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      // 外观卡片是列表第一项，滚动前就可见
      expect(find.byKey(SettingsPage.dynamicColorKey), findsOneWidget);
      expect(find.byKey(SettingsPage.pickBackgroundKey), findsOneWidget);
      // 没设背景图时不该出现「清除背景」
      expect(find.byKey(SettingsPage.clearBackgroundKey), findsNothing);

      // 打开动态取色
      await tester.tap(find.byKey(SettingsPage.dynamicColorKey));
      await tester.pump(const Duration(milliseconds: 200));
      expect(StorageService.instance.useDynamicColor, isTrue);
    });
  });
}

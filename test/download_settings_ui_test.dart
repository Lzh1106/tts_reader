import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/pages/settings_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// **下载设置页的文案与判据**（v1.21.40 真机截图暴露的 5 个 UI bug）
///
/// 截图现象（用户给的）：
/// ```
/// 保存位置
/// Directory: '/data/user/0/com.example.tts_reader/        ← 前缀 + 引号 + 丢子目录
/// 所以现在只能自定义**应用私有目录**里的文件夹。          ← 星号原样显示
/// 点「好」后仍按默认位置保存（系统「下载」目录）           ← 与副标题矛盾
/// ```
///
/// 分工：
/// - 「纯路径字符串」由 `test/browser_download_test.dart` 守（那条最容易回归）；
/// - 这里守**纯文本文案不许带 Markdown 星号**，以及**根目录判据**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
  });

  group('存储根判据（决定提示语说哪一句）', () {
    test('存储根 / 公共存储根都算"没进具体文件夹"', () {
      for (final root in <String>[
        '/',
        '/storage',
        '/storage/emulated',
        '/storage/emulated/0',
        '/sdcard',
        '/mnt/sdcard',
        '',
        '   ',
        '/storage/emulated/0/', // 末尾斜杠也要归一到根
      ]) {
        expect(SettingsPage.isPublicStorageRoot(root), isTrue,
            reason: '"$root" 应当判为"请先进入具体文件夹"');
      }
    });

    test('进了具体文件夹就不算根', () {
      for (final dir in <String>[
        '/storage/emulated/0/Download',
        '/storage/emulated/0/Download/Books',
        '/storage/emulated/0/Android',
        '/sdcard/Books',
      ]) {
        expect(SettingsPage.isPublicStorageRoot(dir), isFalse,
            reason: '"$dir" 已经进了文件夹，不该说"请先进入具体文件夹"');
      }
    });
  });

  group('⚠️ 纯文本文案里不许出现 Markdown 星号', () {
    // Flutter 的 `Text` 不渲染 Markdown，星号会**原样显示给用户**。
    // §4.87 教程弹窗踩过同一个坑（`tutorial_dialog_test` 有断言守着那边），
    // 但没管到设置页这个对话框 —— v1.21.40 就栽在这里。
    testWidgets('设置页里所有文本都不含 ** 强调标记', (tester) async {
      // 设置页要读 TtsManager（引擎信息），必须给它 Provider
      await tester.pumpWidget(
        ChangeNotifierProvider<TtsManager>.value(
          value: TtsManager.instance,
          child: const MaterialApp(home: Scaffold(body: SettingsPage())),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      final List<String> offenders = <String>[];
      for (final widget in tester.widgetList<Text>(find.byType(Text))) {
        final String? data = widget.data;
        if (data != null && data.contains('**')) offenders.add(data);
      }
      // ignore: avoid_print
      print('DEVICE_VERIFY[settings-copy] 含星号的文本数=${offenders.length}');
      expect(offenders, isEmpty,
          reason: '这些文本会把星号原样显示给用户：\n${offenders.join('\n---\n')}');
    });
  });

  // ── v1.21.44：保存位置那一行要**跟随生效路径** ────────────────────────
  group('保存位置跟随自定义路径', () {
    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 20000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<TtsManager>.value(
          value: TtsManager.instance,
          child: const MaterialApp(home: Scaffold(body: SettingsPage())),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('默认（没设自定义）显示系统路径', (tester) async {
      final String inbox = StorageService.instance.downloadInboxPath;
      await pump(tester);
      expect(find.textContaining(inbox), findsWidgets,
          reason: '默认状态显示的应当是公共「下载」+ 专属子文件夹');
      expect(find.textContaining('不再收纳到软件专属子文件夹'), findsNothing);
    });

    testWidgets('★已设自定义 → 进页面就显示自定义路径 + 方案 B 的说明文案',
        (tester) async {
      final storage = StorageService.instance;
      // 先设好再进页面（真机上等价于"上次设过、这次重新进设置页"）
      await storage.setCustomDownloadPath('/data/user/0/com.example.tts_reader/files/Books');
      addTearDown(storage.resetDownloadPath);

      await pump(tester);
      expect(
          find.textContaining('/data/user/0/com.example.tts_reader/files/Books'),
          findsWidgets,
          reason: '★自定义生效后，保存位置那一行必须显示自定义路径');
      expect(find.textContaining(storage.downloadInboxPath), findsNothing,
          reason: '★不能"显示自定义、下面还写着 inbox"');
      expect(find.textContaining('不再收纳到软件专属子文件夹'), findsOneWidget,
          reason: '★自定义生效时说明文案必须换成方案 B 那套');
    });

    testWidgets('★点「恢复默认」按钮：显示与说明文案都立刻刷回系统路径',
        (tester) async {
      final storage = StorageService.instance;
      final String inbox = storage.downloadInboxPath;
      await storage.setCustomDownloadPath('/data/user/0/com.example.tts_reader/files/Books');

      await pump(tester);
      expect(
          find.textContaining('/data/user/0/com.example.tts_reader/files/Books'),
          findsWidgets);

      await tester.tap(find.byKey(const ValueKey<String>('download-path-reset')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining(inbox), findsWidgets,
          reason: '★按钮路径也要刷新（_loadDownloadPath 的加载短路不能挡住这次刷新）');
      expect(find.textContaining('不再收纳到软件专属子文件夹'), findsNothing);
      expect(find.textContaining('下完再挪'), findsOneWidget,
          reason: '回到默认后，"下完再挪进子文件夹"那套说明要回来');
    });
  });

  // ── v1.21.44：设置页底部「项目主页（GitHub）」 ────────────────────────
  group('项目主页入口', () {
    testWidgets('★位置：在「诊断日志」下方，且水平居中', (tester) async {
      tester.view.physicalSize = const Size(1200, 20000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<TtsManager>.value(
          value: TtsManager.instance,
          child: const MaterialApp(home: Scaffold(body: SettingsPage())),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      final Finder entry = find.byKey(const ValueKey<String>('project-home'));
      expect(entry, findsOneWidget);

      // ① 在「诊断日志」那张卡下方
      final double cardBottom =
          tester.getBottomLeft(find.text('诊断日志')).dy;
      expect(tester.getTopLeft(entry).dy, greaterThan(cardBottom),
          reason: '★用户要求：入口放在诊断日志提示的下方');

      // ② 水平居中（与本页可用宽度的中心对齐，容差 1px）
      final double centerX = tester.getCenter(entry).dx;
      final double pageCenterX =
          tester.getSize(find.byType(SettingsPage)).width / 2;
      expect((centerX - pageCenterX).abs(), lessThanOrEqualTo(1.0),
          reason: '★用户要求：这个按钮居中（实测 $centerX vs 中心 $pageCenterX）');
    });

    testWidgets('点一下会把 GitHub 地址交给外部打开入口', (tester) async {
      String? opened;
      tester.view.physicalSize = const Size(1200, 20000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<TtsManager>.value(
          value: TtsManager.instance,
          child: MaterialApp(
            home: Scaffold(body: SettingsPage(onOpenUrl: (String url) => opened = url)),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('项目主页（GitHub）'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('project-home')));
      await tester.pump();
      expect(opened, SettingsPage.projectHomeUrl,
          reason: '★按钮必须把项目主页地址交出去（由 HomePage 切到浏览器 Tab 打开）');
      expect(opened, 'https://github.com/lzhtt23/tts_reader',
          reason: '★账号改名后地址要跟着换（旧地址会 301，但显示/打开的都该是新地址）');
    });

    testWidgets('没有注入打开入口时：至少把地址显示出来（不能点了没反应）',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 20000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<TtsManager>.value(
          value: TtsManager.instance,
          child: const MaterialApp(home: Scaffold(body: SettingsPage())),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byKey(const ValueKey<String>('project-home')));
      await tester.pump();
      expect(find.textContaining(SettingsPage.projectHomeUrl), findsWidgets);
    });

    testWidgets('★按钮下面那行短地址与按钮目标同源（不许各写一份）', (tester) async {
      tester.view.physicalSize = const Size(1200, 20000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<TtsManager>.value(
          value: TtsManager.instance,
          child: const MaterialApp(home: Scaffold(body: SettingsPage())),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(SettingsPage.projectHomeShortUrl, 'github.com/lzhtt23/tts_reader');
      expect(find.text(SettingsPage.projectHomeShortUrl), findsOneWidget,
          reason: '★界面上显示的那行必须由 projectHomeUrl 推导，避免改名后只改一半');
      expect(SettingsPage.projectHomeUrl,
          'https://${SettingsPage.projectHomeShortUrl}');
    });
  });
}

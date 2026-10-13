import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tts_reader/pages/browser_page.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 真机 / 模拟器上验证浏览器主界面的两条要求：
///
/// 1. **地址栏默认为空白**（不再预填默认首页网址）；
/// 2. **首页键回浏览器主界面** —— 没设过自定义首页时也一样，
///    而不是去加载默认网址；设过自定义首页后主界面会多一个入口。
///
/// 为什么必须真机跑：`InAppWebView` 在纯 widget 测试里没有平台实现
/// （`InAppWebViewPlatform.instance` 为空会直接断言失败），
/// 只有设备上才构造得出来。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('主界面：地址栏空白 + 首页键回主界面', (tester) async {
    await StorageService.instance.init();

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: BrowserPage())));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1500)),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 1) 主界面在
    expect(find.byKey(BrowserPage.startPageKey), findsOneWidget);

    // 2) 地址栏默认为空白
    final field = tester.widget<TextField>(
      find.byKey(BrowserPage.addressFieldKey),
    );
    final addressText = field.controller?.text ?? '';
    // ignore: avoid_print
    print('DEVICE_VERIFY[browser-start] address="$addressText" '
        'homeUrl=${StorageService.instance.homeUrl}');
    expect(addressText, isEmpty, reason: '自定义首页的地址栏默认为空白');

    // 3) 已经在主界面 → 首页键禁用（点了也是回这里，无事可做）
    final homeButton = find.ancestor(
      of: find.byIcon(Icons.home_outlined),
      matching: find.byType(IconButton),
    );
    expect(homeButton, findsOneWidget, reason: '地址栏那一行应有首页按钮');
    expect(
      tester.widget<IconButton>(homeButton).onPressed,
      isNull,
      reason: '已经在浏览器主界面时首页键应当禁用',
    );

    // 4) 没设过自定义首页 → 主界面上没有「自定义首页」入口
    expect(
      find.byKey(BrowserPage.customHomeKey),
      findsNothing,
      reason: '没设过自定义首页时不该出现这个入口',
    );

    // 5) 菜单里的入口叫「回到浏览器主页」
    final titles = <String>[];
    for (final entry in tester
        .state<BrowserPageState>(find.byType(BrowserPage))
        .browserMenuEntries()) {
      if (entry is! PopupMenuItem<String>) continue;
      final child = entry.child;
      if (child is! ListTile) continue;
      final title = child.title;
      if (title is Text && title.data != null) titles.add(title.data!);
    }
    // ignore: avoid_print
    print('DEVICE_VERIFY[browser-start] menu=$titles');
    expect(titles, contains(BrowserPage.homeEntryTitle));
    expect(titles, isNot(contains('打开首页')));
    // v1.21.36：**扩展商店入口已按用户决定撤掉**（实测商店在 WebView 里
    // 必然把用户引去装 Edge，留着只会让人以为功能坏了）。这里守"别再回来"。
    expect(titles, isNot(contains('浏览器扩展商店')),
        reason: '扩展商店入口已移除，不该再出现在菜单里');
    // v1.21.37：翻译那项的标签**必须跟着实际引擎走**。
    // 原来是「翻译本页（Edge 翻译）」—— 那是微软 Translator 时代的说法；
    // v1.21.36 起引擎已换成谷歌优先 + 百度兜底，标签再写 Edge 就是骗用户。
    expect(titles, contains('翻译本页（谷歌／百度）'),
        reason: '菜单标签要写明实际用的引擎');
    expect(
      titles.any((String t) => t.contains('Edge 翻译')),
      isFalse,
      reason: '引擎已不是微软，标签不该再出现「Edge 翻译」',
    );

    // 6) 设一个自定义首页 → 主界面出现入口，且地址栏仍然空白
    await StorageService.instance.setHomeUrl('https://example.com/start');
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.shrink())));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: BrowserPage())));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1200)),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final afterField = tester.widget<TextField>(
      find.byKey(BrowserPage.addressFieldKey),
    );
    // ignore: avoid_print
    print('DEVICE_VERIFY[browser-start] customHome='
        '${find.byKey(BrowserPage.customHomeKey).evaluate().length} '
        'address="${afterField.controller?.text ?? ''}"');
    expect(
      afterField.controller?.text ?? '',
      isEmpty,
      reason: '设过自定义首页后地址栏依然默认空白',
    );
    expect(
      find.byKey(BrowserPage.customHomeKey),
      findsOneWidget,
      reason: '设过自定义首页后主界面应出现打开它的入口',
    );

    // 收尾：把自定义首页清回去，别污染后面的用例
    await StorageService.instance.setHomeUrl(StorageService.defaultHomeUrl);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.shrink())));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  /// **外部 App 链接不再落成错误页**（v1.21.36）
  ///
  /// 实测来源：Edge 扩展商店在 WebView 里最终会跳到
  /// `intent://play.google.com/store/apps/details?id=com.microsoft.emmx…`，
  /// 而 `shouldOverrideUrlLoading` 原来是"一律放行"，于是 WebView 停在
  /// `ERR_UNKNOWN_URL_SCHEME / Webpage not available` 错误页上。
  /// 现在这类"唤起别的 App"的链接会被拦下 + 提示。
  ///
  /// ⚠️ 判据不依赖网络：只验证"点了之后没落成不支持协议的错误页"。
  testWidgets('intent:// 链接被拦下：不落成 ERR_UNKNOWN_URL_SCHEME 错误页', (tester) async {
    await StorageService.instance.init();

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: BrowserPage())));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1500)),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final BrowserPageState state =
        tester.state<BrowserPageState>(find.byType(BrowserPage));
    state.debugLastLoadError = '';
    state.submitAddress(
        'intent://play.google.com/store/apps/details?id=com.microsoft.emmx'
        '#Intent;scheme=https;action=android.intent.action.VIEW;end');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    // ignore: avoid_print
    print('DEVICE_VERIFY[browser-intent] err="${state.debugLastLoadError}" '
        'realUrl="${await tester.runAsync(state.currentUrlForTest) ?? ''}"');

    expect(state.debugLastLoadError, isNot(contains('UNSUPPORTED_SCHEME')),
        reason: 'intent 链接必须被拦掉，不能落成"不支持的协议"错误页');

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.shrink())));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

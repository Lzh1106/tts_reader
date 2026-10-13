import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tts_reader/pages/browser_page.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 设备侧验证：**标签页切走再切回，页面状态保留**（v1.21.39 任务 4）
///
/// 这是「多 WebView 保活」（`IndexedStack`）方案的全部价值所在。
/// 如果这条不成立，方案 A 就退化成"切回来重新加载"，那和书签没区别。
///
/// 为什么必须上设备：`InAppWebView` 在纯 widget 测试里没有平台实现
/// （`InAppWebViewPlatform.instance` 为空会直接断言失败），
/// 只有真机 / 模拟器才构造得出来。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 造一个「可滚动 + 能读到 scrollY」的页面内容
  ///
  /// 用 about:blank + 注入，而不是 `data:` URL —— `submitAddress` 的
  /// 输入解析会把 `data:` 当搜索词，绕开它反而更干净。
  const String seedScript = '''
    document.body.innerHTML =
      '<div style="height:4000px;background:linear-gradient(#fff,#333)">tall</div>';
    document.body.style.margin = '0';
    window.__tabProbe = Math.random().toString(36);
    true;
  ''';

  Future<void> settle(WidgetTester tester, {int rounds = 40}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
  }

  testWidgets('标签页：切走再切回，滚动位置与 JS 变量都不丢', (tester) async {
    // 关掉首启教程：它是模态弹窗，屏障会吃掉 tap（§4.99 的教训）
    await StorageService.instance.setTutorialDone(true);
    await StorageService.instance.init();

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BrowserPage())),
    );
    await settle(tester, rounds: 40);

    final BrowserPageState state =
        tester.state<BrowserPageState>(find.byType(BrowserPage));
    expect(state.debugTabCount, 1, reason: '初始应当有 1 个标签');

    // ---- 标签 0：注入可滚动内容，滚到中间，记下现场 ----
    final InAppWebViewController? tab0 = state.activeControllerForTest;
    expect(tab0, isNotNull, reason: '第一个标签的 controller 应当已挂上');
    await tab0!.loadUrl(urlRequest: URLRequest(url: WebUri('about:blank')));
    await settle(tester, rounds: 20);
    await tab0.evaluateJavascript(source: seedScript);
    await settle(tester, rounds: 10);
    await tab0.evaluateJavascript(source: 'window.scrollTo(0, 1500)');
    await settle(tester, rounds: 10);

    final Object? probeBefore =
        await tab0.evaluateJavascript(source: 'window.__tabProbe');
    final Object? scrollBefore =
        await tab0.evaluateJavascript(source: 'window.scrollY');
    // ignore: avoid_print
    print('DEVICE_VERIFY[tabs] tab0 现场：probe=$probeBefore '
        'scrollY=$scrollBefore');
    expect(probeBefore, isNotNull);
    expect(scrollBefore, isA<num>());
    expect((scrollBefore! as num).toDouble(), greaterThan(1000),
        reason: '前置条件：tab0 必须真的滚动过，否则这条用例是空跑');

    // ---- 新建标签 1，切走 ----
    state.debugNewTab();
    await settle(tester, rounds: 20);
    expect(state.debugTabCount, 2);
    expect(identical(state.activeControllerForTest, tab0), isFalse,
        reason: '新标签必须是**另一个** WebView（各有各的 controller）');

    // 在 tab1 里改点东西，确认两个标签互不干扰
    final InAppWebViewController? tab1 = state.activeControllerForTest;
    await tab1!.evaluateJavascript(source: 'window.__tab1Mark = "mine"');
    await settle(tester, rounds: 5);

    // ---- 切回标签 0 ----
    state.debugSelectTab(0);
    await settle(tester, rounds: 20);
    expect(identical(state.activeControllerForTest, tab0), isTrue,
        reason: '切回后拿到的必须还是原来那个 controller');

    // ★ 核心断言：滚动位置与 JS 变量都没丢
    final Object? probeAfter =
        await tab0.evaluateJavascript(source: 'window.__tabProbe');
    final Object? scrollAfter =
        await tab0.evaluateJavascript(source: 'window.scrollY');
    final Object? tab1Leak =
        await tab0.evaluateJavascript(source: 'window.__tab1Mark ?? null');
    // ignore: avoid_print
    print('DEVICE_VERIFY[tabs] 切回 tab0：probe=$probeAfter '
        'scrollY=$scrollAfter tab1痕迹=$tab1Leak');

    expect(probeAfter, probeBefore,
        reason: 'JS 变量不同 = 页面被重新加载了（IndexedStack 保活失效）');
    expect(scrollAfter, scrollBefore,
        reason: '滚动位置不同 = WebView 被重建了。'
            '这正是「切走再切回不丢位置」要守住的东西');
    expect(tab1Leak, isNull,
        reason: 'tab1 的 JS 变量不该出现在 tab0 里（两个标签必须相互隔离）');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('标签页：关闭当前标签后落到右边一个（没有就左边），且不会关到零个',
      (tester) async {
    await StorageService.instance.setTutorialDone(true);
    await StorageService.instance.init();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BrowserPage())),
    );
    await settle(tester, rounds: 30);

    final BrowserPageState state =
        tester.state<BrowserPageState>(find.byType(BrowserPage));
    state.debugNewTab();
    await settle(tester, rounds: 10);
    state.debugNewTab();
    await settle(tester, rounds: 10);
    expect(state.debugTabCount, 3, reason: '应当有 3 个标签');

    // 切到中间那个（索引 1），关掉它 → 按 Chrome 习惯落到"右边一个"（新的索引 1）
    state.debugSelectTab(1);
    await settle(tester, rounds: 5);
    final activeBefore = state.activeControllerForTest;
    state.debugCloseTab(1);
    await settle(tester, rounds: 10);
    expect(state.debugTabCount, 2, reason: '关掉一个应当剩 2 个');
    expect(identical(state.activeControllerForTest, activeBefore), isFalse,
        reason: '关掉当前标签后必须切到别的标签，不能留在已销毁的那个上');
    expect(state.activeControllerForTest, isNotNull,
        reason: '新激活标签必须有可用的 controller');
    // ignore: avoid_print
    print('DEVICE_VERIFY[tabs] 关闭中间标签：剩=${state.debugTabCount} '
        '新激活 controller=${state.activeControllerForTest != null}');

    // ⚠️ 只剩一个时再关：**必须不动**（全关掉就没有浏览界面了）
    state.debugCloseTab(0);
    await settle(tester, rounds: 5);
    state.debugCloseTab(0);
    await settle(tester, rounds: 5);
    expect(state.debugTabCount, greaterThanOrEqualTo(1),
        reason: '标签数量必须始终 ≥ 1（全关掉就没有页面可显示）');
    // ignore: avoid_print
    print('DEVICE_VERIFY[tabs] 关到最后一个：剩=${state.debugTabCount}');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

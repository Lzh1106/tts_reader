import 'package:flutter/material.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/pages/browser_page.dart';

/// **下载列表面板（Chrome 式）的组件级验证**（本轮 · 需求二）
///
/// ## 这条守什么
///
/// 分组与按钮的**判据**在 `DownloadListModel`（`test/download_list_model_test.dart`
/// 已经钉死），这里守的是**界面真的把它们画出来了**：
/// · 三个分组标题按"正在下载 → 已完成 → 失败"出现；
/// · 每一项带着**进度条**与**来源站点 + 状态 + 百分比**那一行；
/// · 每一项的按钮与状态对得上（进行中给暂停/取消，完成给打开/移除，失败给重试/移除）。
///
/// ## 为什么直接 pump `DownloadsSheet` 而不是 `BrowserPage`
///
/// `BrowserPage` 一 build 就要 `InAppWebViewPlatform.instance`（平台通道），
/// 组件测试里直接抛断言 —— 所以面板被单独做成公开组件，
/// 用例只 pump 它（`debugTasks` 喂一份任务表，插件的那次 `loadTasks()` 就绕开了）。
///
/// ## 为什么还要管"关掉面板"
///
/// 面板要每秒轮询一次任务表（插件没有变更推送）。定时器挂在 State 上，
/// **`dispose` 必须取消** —— 这条用例最后把面板从树上摘掉：只要漏了取消，
/// 测试框架会直接报"still pending a Timer"，比人肉点一百遍都可靠。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DownloadTask task({
    required String id,
    required DownloadTaskStatus status,
    required int progress,
    required String url,
    required String name,
    required int created,
  }) =>
      DownloadTask(
        taskId: id,
        status: status,
        progress: progress,
        url: url,
        filename: name,
        savedDir: '/storage/emulated/0/Download',
        timeCreated: created,
        allowCellular: true,
      );

  /// 把面板挂到一棵最小可用的树上（MaterialApp + Scaffold 就够：
  /// 它要用 `ScaffoldMessenger` 报错、用 `Theme` 取色）
  Future<void> pumpSheet(WidgetTester tester, List<DownloadTask> tasks) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DownloadsSheet(
            onOpenFolder: () async {},
            onOpenTask: (DownloadTask _) async {},
            debugTasks: tasks,
          ),
        ),
      ),
    );
    // 首帧 + 让 `_refresh()` 那一次异步落地
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('★分组 + 进度条 + 按状态给的按钮', (tester) async {
    await pumpSheet(tester, <DownloadTask>[
      task(
        id: 'run1',
        status: DownloadTaskStatus.running,
        progress: 40,
        url: 'https://z-lib.sk/book/1',
        name: '正在下的书.pdf',
        created: 300,
      ),
      task(
        id: 'done1',
        status: DownloadTaskStatus.complete,
        progress: 100,
        url: 'https://libgen.is/book/2',
        name: '下好的书.epub',
        created: 200,
      ),
      task(
        id: 'fail1',
        status: DownloadTaskStatus.failed,
        progress: 6,
        url: 'https://example.com/book/3',
        name: '失败的书.pdf',
        created: 100,
      ),
    ]);

    // ── 标题与分组 ──────────────────────────────────────────────
    expect(find.text('下载列表'), findsOneWidget);
    expect(find.text('正在下载（1）'), findsOneWidget);
    expect(find.text('已完成（1）'), findsOneWidget);
    expect(find.text('失败（1）'), findsOneWidget);

    // ── 每项一行信息：来源站点 · 状态 · 百分比 ──────────────────
    expect(find.text('Z-Library · 下载中 · 40%'), findsOneWidget,
        reason: '来源域名映射表要真的用在界面上');
    expect(find.text('Library Genesis · 已完成 · 100%'), findsOneWidget);
    expect(find.text('example.com · 失败 · 6%'), findsOneWidget,
        reason: '认不出来的站点回落主机名');

    // ── 进度条：三项各一条 ─────────────────────────────────────
    expect(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.byType(LinearProgressIndicator),
      ),
      findsNWidgets(3),
      reason: '每个任务都要有进度条',
    );
    // 进度条取值 = 百分比 / 100（40% 那条就是 0.4）
    final List<LinearProgressIndicator> bars = tester
        .widgetList<LinearProgressIndicator>(find.descendant(
          of: find.byType(ListTile),
          matching: find.byType(LinearProgressIndicator),
        ))
        .toList();
    expect(bars.map((b) => b.value).toList()..sort(), <double>[0.06, 0.4, 1.0]);

    // ── 按钮按状态分派 ─────────────────────────────────────────
    expect(find.byTooltip('暂停'), findsOneWidget, reason: '下载中 → 暂停');
    expect(find.byTooltip('取消下载'), findsOneWidget, reason: '下载中 → 取消');
    expect(find.byTooltip('打开'), findsOneWidget, reason: '已完成 → 打开');
    expect(find.byTooltip('重试'), findsOneWidget, reason: '失败 → 重试');
    expect(find.byTooltip('从列表移除'), findsNWidgets(2),
        reason: '已完成与失败各有一个"移除"');
    // 不该出现的死按钮
    expect(find.byTooltip('继续'), findsNothing,
        reason: '没有暂停中的任务，就不该有"继续"');
    expect(find.byTooltip('暂停'), findsOneWidget,
        reason: '已完成 / 失败那两项不该有暂停按钮');

    // ignore: avoid_print
    print('DEVICE_VERIFY[download-sheet] 分组=3 进度条=3 '
        '按钮=暂停/取消/打开/移除×2/重试');

    // ── 摘掉面板：定时器必须被取消（漏了就报 pending timer） ────
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('已暂停的任务：给"继续"，不给"暂停"', (tester) async {
    await pumpSheet(tester, <DownloadTask>[
      task(
        id: 'pause1',
        status: DownloadTaskStatus.paused,
        progress: 20,
        url: 'https://1lib.sk/book/9',
        name: '暂停的书.pdf',
        created: 10,
      ),
    ]);

    expect(find.text('正在下载（1）'), findsOneWidget,
        reason: '暂停中的任务仍归"正在下载"——它还能继续');
    expect(find.byTooltip('继续'), findsOneWidget);
    expect(find.byTooltip('暂停'), findsNothing);
    expect(find.byTooltip('取消下载'), findsOneWidget);
    expect(find.text('Z-Library · 已暂停 · 20%'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('没有任务时给一句人话，而不是空白面板', (tester) async {
    await pumpSheet(tester, const <DownloadTask>[]);

    expect(find.text('暂无下载任务'), findsOneWidget);
    expect(find.textContaining('（'), findsNothing,
        reason: '一个任务都没有时不该出现任何空分组标题');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}

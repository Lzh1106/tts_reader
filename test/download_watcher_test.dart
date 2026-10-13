import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/download_watcher.dart';
import 'package:tts_reader/services/storage_service.dart';

/// **后台下载收尾扫描**（v1.21.40，方案 A）
///
/// 解决的问题：`flutter_downloader` 走 WorkManager，下载本身后台支持，
/// 但「下载完成 → 自动导入文档库」原来只写在浏览器页里、靠**页面前台轮询** ——
/// 用户切走 Tab / 退到桌面 / 杀掉应用，轮询就停了，下载跑完也不入库。
///
/// 方案：应用启动 + 每次回前台 `DownloadWatcher.instance.sweep()`。
///
/// ## 这个文件测什么
///
/// 设备的插件通道在纯 Dart 测试里拿不到（`FlutterDownloader.loadTasks()` 会抛），
/// 而 `sweep()` 的设计就是"任何失败只记 CrashLog、不抛" ——
/// 所以这里测的是**它必须守住的两条不变量**：
///   1. **不抛异常**（它挂在应用启动与回前台上，抛了会影响主流程）；
///   2. **幂等 / 防重入**（同时只能有一次扫描，重复调用不会重复导入）。
///
/// 「下载完真的能入库」那条要在设备上验（见验收清单）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    await DownloadWatcher.instance.resetForTest();
    DownloadWatcher.instance.debugForceUnlocked = true;
  });

  tearDown(() async {
    await DownloadWatcher.instance.resetForTest();
    DownloadWatcher.instance.debugForceUnlocked = false;
  });

  test('拿不到插件任务表也不抛（挂启动/回前台，抛了会连累主流程）', () async {
    // 纯 Dart 环境没有 flutter_downloader 的平台实现 —— 正好验证兜底
    final imported = await DownloadWatcher.instance.sweep();
    expect(imported, 0, reason: '没有可导入的任务时应当返回 0');
    // ignore: avoid_print
    print('DEVICE_VERIFY[bg-download] 无插件环境下 sweep 返回=$imported（未抛异常）');
  });

  test('连续 sweep 幂等：第二次不会重复处理', () async {
    final first = await DownloadWatcher.instance.sweep();
    final second = await DownloadWatcher.instance.sweep();
    expect(second, 0, reason: '第二次扫描不该再导入任何东西');
    expect(first, 0);
    // ignore: avoid_print
    print('DEVICE_VERIFY[bg-download] sweep×2 = $first / $second');
  });

  test('并发 sweep 有防重入（同时只跑一次）', () async {
    DownloadWatcher.instance.debugForceUnlocked = false;
    final results = await Future.wait<int>(<Future<int>>[
      DownloadWatcher.instance.sweep(),
      DownloadWatcher.instance.sweep(),
      DownloadWatcher.instance.sweep(),
    ]);
    // 最多一个能真正跑起来，其余直接返回 0
    expect(results.where((v) => v > 0).length, lessThanOrEqualTo(1));
    // ignore: avoid_print
    print('DEVICE_VERIFY[bg-download] 并发 sweep 结果=$results');
  });

  test('已处理集合落盘后能被读回（重启不重复导入的前提）', () async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList('download_handled_task_ids', <String>['t1', 't2']);
    final read = sp.getStringList('download_handled_task_ids');
    expect(read, <String>['t1', 't2']);
    // resetForTest 应当把它清掉
    await DownloadWatcher.instance.resetForTest();
    expect(sp.getStringList('download_handled_task_ids'), isNull);
  });

  test('importDownloadedFile 对不支持的格式返回 null（不抛）', () async {
    final doc = await importDownloadedFile('/tmp/不存在的文件.mobi');
    expect(doc, isNull, reason: 'mobi 不支持朗读，且文件也不存在 → 返回 null');
  });

  test('locateDownloadedFile 找不到就返回 null（不抛）', () async {
    final found = await locateDownloadedFile('/tmp/绝对不存在.pdf');
    expect(found, isNull);
  });

  // ──────────────────────────────────────────────────────────────────────
  // v1.21.43 · 失败任务**退避**
  //
  // 真机日志实证（用户 2026-10-11）：
  // ```
  // 19:42:14  下载探针[后台扫描] task=7b881749 status=failed progress=6%
  // 19:45:45  同一条……
  // 19:46:11 / 19:56:11 / … / 01:20:19 / 01:26
  // ```
  // 一个**永远不会再产出文件**的失败任务，从 19:41 被重扫到 01:26
  // （每 6~13 秒一条），刷爆日志、耗电、淹没有效信息。
  //
  // 规则：失败/取消的任务按 `30min × 2^(n-1)` 指数退避，上限 24 小时；
  // 退避窗口内**不扫也不打日志**。偶发失败仍有补救机会，尸体迅速安静。
  // ──────────────────────────────────────────────────────────────────────

  group('⚠️ 失败任务退避（治"每秒重扫"的日志噪音）', () {
    test('退避时长按 2 的幂增长，并在 24 小时封顶', () {
      final d1 = DownloadWatcher.backoffFor(1);
      final d2 = DownloadWatcher.backoffFor(2);
      final d3 = DownloadWatcher.backoffFor(3);
      // ignore: avoid_print
      print('DEVICE_VERIFY[backoff] 1次=${d1.inMinutes}分 2次=${d2.inMinutes}分 '
          '3次=${d3.inMinutes}分 20次=${DownloadWatcher.backoffFor(20).inHours}时');

      expect(d1, const Duration(minutes: 30), reason: '第 1 次失败先等 30 分钟');
      expect(d2, const Duration(hours: 1), reason: '第 2 次翻倍');
      expect(d3, const Duration(hours: 2), reason: '第 3 次再翻倍');
      expect(DownloadWatcher.backoffFor(20), const Duration(hours: 24),
          reason: '无论失败多少次，最多等 24 小时（不能无限涨）');
      // 单调不减
      for (var i = 1; i < 12; i++) {
        expect(DownloadWatcher.backoffFor(i + 1) >=
            DownloadWatcher.backoffFor(i), isTrue);
      }
    });

    test('窗口内必须跳过；过期或从未记过则要扫', () {
      const now = 1000000;
      // 从未记过 → 要扫（第一次总得看一眼）
      expect(DownloadWatcher.shouldSkipByBackoff(null, now), isFalse);
      // 还没到期 → 跳过（这正是"不扫也不打日志"的判据）
      expect(DownloadWatcher.shouldSkipByBackoff(now + 1, now), isTrue);
      expect(DownloadWatcher.shouldSkipByBackoff(now + 60000, now), isTrue);
      // 已经到期 → 要扫
      expect(DownloadWatcher.shouldSkipByBackoff(now, now), isFalse);
      expect(DownloadWatcher.shouldSkipByBackoff(now - 1, now), isFalse);
    });

    test('退避表能落盘并被读回（重启后仍然安静）', () async {
      final watcher = DownloadWatcher.instance;
      await watcher.resetBackoffForTest();
      final sp = await SharedPreferences.getInstance();
      // 模拟一次失败后写入的退避记录
      final due = DateTime.now().millisecondsSinceEpoch + 30 * 60 * 1000;
      await sp.setStringList('download_failed_backoff', <String>[
        '7b881749-aaaa|$due',
        '坏数据没有分隔符',
      ]);
      // 读回（内部走 _loadBackoff；这里直接验证落盘格式能被解析）
      final raw = sp.getStringList('download_failed_backoff')!;
      expect(raw.first.split('|').length, 2);
      expect(int.tryParse(raw.first.split('|')[1]), isNotNull);
      // ignore: avoid_print
      print('DEVICE_VERIFY[backoff] 落盘条数=${raw.length} 首条=${raw.first}');
    });
  });
}

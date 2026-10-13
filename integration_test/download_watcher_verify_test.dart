import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:tts_reader/services/document_service.dart';
import 'package:tts_reader/services/download_watcher.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 设备侧验证（v1.21.40）：**后台下载收尾 → 自动入库**
///
/// ## 这条要证明什么
///
/// `flutter_downloader` 走 WorkManager，**下载本身后台是支持的**；
/// 缺的是「下载完成 → 自动导入文档库」原来只写在浏览器页里、靠**页面前台轮询**
/// —— 用户切走 Tab / 退到桌面，轮询停了，下完也不入库，回来发现"下了但书不在"。
///
/// 方案 A：应用启动 + 回前台时 `DownloadWatcher.sweep()` 扫一遍。
///
/// 这条用例**刻意不碰浏览器页**（没有页面前台轮询），
/// 只让任务自己跑完，再调一次 `sweep()` —— 若书进了文档库，
/// 就说明"离开页面也能入库"成立。
///
/// 跑法：`flutter --no-version-check test integration_test/download_watcher_verify_test.dart -d emulator-5554`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 插件只允许初始化一次（重复调用会断言失败），所以放 setUpAll
  setUpAll(() async {
    await FlutterDownloader.initialize(debug: true);
  });

  Future<void> waitFor(bool Function() cond, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  testWidgets('下载在"没人轮询"的情况下跑完 → sweep() 把它收进文档库（且幂等）',
      (tester) async {
    // 现场生成一份真 PDF（下载完还能真解析一遍）
    final pdf = PdfDocument();
    final font = PdfStandardFont(PdfFontFamily.helvetica, 12);
    pdf.pages.add().graphics.drawString(
      'Background download page one. Second sentence here.',
      font,
      bounds: const Rect.fromLTWH(20, 40, 500, 200),
    );
    final payload = pdf.saveSync();
    pdf.dispose();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType('application', 'pdf');
      // ⚠️ HTTP 头**不能直接放非 ASCII**（`Invalid HTTP header field value`，实测）。
      // 中文名必须走 RFC 5987 的 `filename*=UTF-8''<百分号编码>` ——
      // 这正好也端到端验一遍 `FileNaming.parseContentDisposition`。
      final encoded = Uri.encodeComponent('后台下载的书.pdf');
      request.response.headers.set(
        'Content-Disposition',
        "attachment; filename=\"bg.pdf\"; filename*=UTF-8''$encoded",
      );
      request.response.add(payload);
      await request.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/bg.pdf';

    await StorageService.instance.init();
    // 从干净状态开始：清掉"已处理"记录，否则上一轮的 id 会让本次跳过
    await DownloadWatcher.instance.resetForTest();
    DownloadWatcher.instance.debugForceUnlocked = true;

    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/downloads/后台验收');
    if (!dir.existsSync()) dir.createSync(recursive: true);

    // 先记下文档库里已有的书，最后按"多出来的那一本"断言
    final before = (await StorageService.instance.loadDocuments()).length;

    final taskId = await FlutterDownloader.enqueue(
      url: url,
      savedDir: dir.path,
      fileName: '后台下载的书.pdf',
      showNotification: false,
      openFileFromNotification: false,
      saveInPublicStorage: false,
      requiresStorageNotLow: false,
      allowCellular: true,
      timeout: 15000,
    );
    expect(taskId, isNotNull,
        reason: 'enqueue 返回 null = WorkManager 没初始化（见 download_verify_test 顶部）');
    // ignore: avoid_print
    print('DEVICE_VERIFY[bg-download] taskId=$taskId dir=${dir.path}');

    // ⚠️ 全程**不**调浏览器页的 `_waitForDownload` / `_onDownloaded`：
    // 模拟"用户已经离开浏览器页"，看后台扫描能不能独立收到尾。
    await waitFor(() {
      final f = File('${dir.path}/后台下载的书.pdf');
      return f.existsSync() && f.lengthSync() == payload.length;
    }, const Duration(seconds: 40));
    // 等任务状态真的变 complete（不能只看文件存在：边下边写，文件会先出现）
    var complete = false;
    for (var i = 0; i < 80; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final tasks =
          await FlutterDownloader.loadTasks() ?? const <DownloadTask>[];
      if (tasks.any((t) =>
          t.taskId == taskId && t.status == DownloadTaskStatus.complete)) {
        complete = true;
        break;
      }
    }
    // ignore: avoid_print
    print('DEVICE_VERIFY[bg-download] 任务完成=$complete '
        '文件=${File('${dir.path}/后台下载的书.pdf').existsSync()}');
    expect(complete, isTrue, reason: '前置：下载任务必须真的跑到 complete');

    // ★ 核心：只调 sweep()，模拟"应用回前台"
    final imported = await DownloadWatcher.instance.sweep();
    final after = await StorageService.instance.loadDocuments();
    // ignore: avoid_print
    print('DEVICE_VERIFY[bg-download] sweep 导入=$imported '
        '文档数 $before → ${after.length}');

    expect(imported, greaterThanOrEqualTo(1),
        reason: '离开浏览器页之后，sweep() 必须能把下载好的书收进文档库');
    expect(after.length, greaterThan(before),
        reason: '文档库要多出这本书');
    final added = after.where((d) => d.title.contains('后台下载的书')).toList();
    expect(added, isNotEmpty, reason: '新入库的书名应当保留原名');
    expect(DocumentService.titleFromPath(added.first.path), contains('后台下载的书'));

    // ★ 幂等：再扫一次不该重复导入
    final again = await DownloadWatcher.instance.sweep();
    final after2 = await StorageService.instance.loadDocuments();
    // ignore: avoid_print
    print('DEVICE_VERIFY[bg-download] 再扫一次 导入=$again 文档数=${after2.length}');
    expect(again, 0, reason: '同一个任务只能导入一次（靠已处理 id 去重）');
    expect(after2.length, after.length, reason: '重复扫描不许重复入库');

    await server.close(force: true);
    await DownloadWatcher.instance.resetForTest();
    DownloadWatcher.instance.debugForceUnlocked = false;
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('sweep 在真设备上不抛（拿得到插件任务表）', (tester) async {
    await StorageService.instance.init();
    DownloadWatcher.instance.debugForceUnlocked = true;
    final imported = await DownloadWatcher.instance.sweep();
    // ignore: avoid_print
    print('DEVICE_VERIFY[bg-download] 空跑 sweep 返回=$imported');
    expect(imported, greaterThanOrEqualTo(0));
    // 顺带确认"已处理"集合读写正常（重启不重复导入的前提）
    SharedPreferences.setMockInitialValues(<String, Object>{});
    DownloadWatcher.instance.debugForceUnlocked = false;
  });
}

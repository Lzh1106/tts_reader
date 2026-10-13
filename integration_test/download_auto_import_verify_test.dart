import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/services/download_watcher.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 设备侧验证（v1.21.41）：**下载 → 收纳进软件专属文件夹 → 自动导入文档库**
///
/// ## 这条串起了用户要的整条链
///
/// 用户原话：「下载到根目录时新建一个软件专属文件夹，用于存储文件」，
/// 以及「要测试自动导入功能」。所以这条用例必须证明：
///
/// 1. 下载**真的落到公共「下载」目录**（公共目录 = 卸载不删）；
/// 2. 下完**立刻被挪进** `下载/桃花源阅读器/`（同卷改名，不是第二份数据）；
/// 3. 文件**自动进了文档库**（不需要用户手动点任何东西）；
/// 4. 重复扫描**不重复导入**。
///
/// ## 为什么要上设备
///
/// ① `flutter_downloader` 只能真机上跑（WorkManager + 平台通道）；
/// ② "同一存储卷内 rename" 这个前提只有真机文件系统能验 ——
///    它决定了收纳是"瞬间改名"还是"复制+删"。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await FlutterDownloader.initialize(debug: true);
  });

  testWidgets('下载 → 收纳进软件专属子文件夹 → 自动入库（且重复扫描不重复导入）',
      (tester) async {
    // ⚠️ 文件名带时间戳：公共目录**跨运行残留**（"卸载不删"应有的样子），
    // 固定名字会撞上上一轮留下的文件。**服务端返回的与 enqueue 传的必须是同一个**
    // —— 走 `saveInPublicStorage` 时文件名以**服务端**为准（MediaStore 会忽略
    // 我们传的 fileName），两边不一致会让"按名字找文件"的断言全部落空。
    final fileName = '自动导入测试书_${DateTime.now().millisecondsSinceEpoch}.pdf';
    final encoded = Uri.encodeComponent(fileName);

    // ---- 现场造一份真 PDF，用本机 HTTP 服务提供（不依赖外网） ----
    final pdf = PdfDocument();
    final font = PdfStandardFont(PdfFontFamily.helvetica, 12);
    pdf.pages.add().graphics.drawString(
      'Auto import page one. Second sentence of this book.',
      font,
      bounds: const Rect.fromLTWH(20, 40, 500, 200),
    );
    final payload = pdf.saveSync();
    pdf.dispose();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType('application', 'pdf');
      // 中文名必须走 RFC 5987（HTTP 头不能直接放非 ASCII）
      request.response.headers.set(
        'Content-Disposition',
        "attachment; filename=\"auto.pdf\"; filename*=UTF-8''$encoded",
      );
      request.response.add(payload);
      await request.response.close();
    });

    await StorageService.instance.init();
    await DownloadWatcher.instance.resetForTest();
    DownloadWatcher.instance.debugForceUnlocked = true;

    const root = StorageService.publicDownloadPath;
    const inbox = '$root/${StorageService.downloadInboxFolder}';
    // 清场：根目录与收纳目录里可能留着上次的
    //
    // ⚠️ 必须"存在才删"：这条用例要验的正是"文件落在**公共**目录里"，
    // 而公共目录**不会被卸载清掉** —— `flutter test` 每次会重装应用，
    // 上一轮留下的书会跨运行残留（这正是"卸载不删"应有的样子）。
    // 直接用 `delete()` 会在文件不存在时抛 `PathNotFoundException`（实测踩到）。
    for (final p in <String>['$root/$fileName', '$inbox/$fileName']) {
      final f = File(p);
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {
        // 删不掉不算失败：下面的断言会用"精确文件名"来判定
      }
    }

    final before = (await StorageService.instance.loadDocuments()).length;

    // ---- 下载到**公共「下载」根目录**（就是默认那条路） ----
    final taskId = await FlutterDownloader.enqueue(
      url: 'http://127.0.0.1:${server.port}/auto.pdf',
      savedDir: root,
      fileName: fileName,
      showNotification: false,
      openFileFromNotification: false,
      // true = 走系统媒体库落公共「下载」（savedDir 会被忽略，正是要验的那条路）
      saveInPublicStorage: true,
      requiresStorageNotLow: false,
      allowCellular: true,
      timeout: 15000,
    );
    expect(taskId, isNotNull, reason: 'enqueue 返回 null = WorkManager 没初始化');
    // ignore: avoid_print
    print('DEVICE_VERIFY[auto-import] taskId=$taskId root=$root');

    // 等下载完成
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
    expect(complete, isTrue, reason: '前置：下载必须真的跑到 complete');

    // ---- ② 走"后台扫描"那条路（用户切走/回前台时就是这个） ----
    //    它会做两件事：收纳进子文件夹 + 导入文档库
    final imported = await DownloadWatcher.instance.sweep();
    final after = await StorageService.instance.loadDocuments();

    final inRoot = await File('$root/$fileName').exists();
    final inInbox = await File('$inbox/$fileName').exists();
    final inboxDir = Directory(inbox);
    // ignore: avoid_print
    print('DEVICE_VERIFY[auto-import] 根目录=$inRoot 收纳目录=$inInbox '
        'sweep导入=$imported 文档数 $before → ${after.length}');
    if (await inboxDir.exists()) {
      final names = (await inboxDir.list().toList())
          .map((e) => e.path.split('/').last)
          .where((n) => n.contains('自动导入'))
          .toList();
      // ignore: avoid_print
      print('DEVICE_VERIFY[auto-import] 收纳目录内容(过滤)=$names');
    }

    // ★ ① 文件必须**离开根目录、进了软件专属子文件夹**
    expect(inRoot, isFalse,
        reason: '收纳之后根目录不该还留着一份（否则就是两份数据）');
    expect(inInbox, isTrue,
        reason: '文件必须被挪进 ${StorageService.downloadInboxFolder}/ 子文件夹'
            '（用户要的"软件专属文件夹"）');

    // ★ ② 必须自动进了文档库
    expect(after.length, greaterThan(before), reason: '文档库要多出这本书');
    final added =
        after.where((d) => d.title.contains('自动导入测试书')).toList();
    expect(added, isNotEmpty, reason: '书名应当保留原名');
    final doc = added.first;
    // ignore: avoid_print
    print('DEVICE_VERIFY[auto-import] 入库：${doc.title} type=${doc.type} '
        'path=${doc.path}');
    expect(doc.type, DocumentType.pdf);
    // 入库后会在应用私有目录留一份副本（LibraryStorage.adopt 的行为），
    // 公共目录那份**仍在**（给用户留的、卸载不删）
    expect(await File('$inbox/$fileName').exists(), isTrue,
        reason: '公共目录那份必须保留：它是"卸载不删"的那一份');

    // ★ ③ 幂等：再扫一次不重复导入
    final again = await DownloadWatcher.instance.sweep();
    final after2 = await StorageService.instance.loadDocuments();
    // ignore: avoid_print
    print('DEVICE_VERIFY[auto-import] 再扫一次 导入=$again '
        '文档数=${after2.length}');
    expect(again, 0, reason: '同一个任务只能导入一次');
    expect(after2.length, after.length, reason: '不许重复入库');

    // 清场
    await server.close(force: true);
    await DownloadWatcher.instance.resetForTest();
    DownloadWatcher.instance.debugForceUnlocked = false;
  }, timeout: const Timeout(Duration(minutes: 6)));

  testWidgets('收纳对"不在公共下载根目录"的文件不动手（私有目录的不搬）',
      (tester) async {
    await StorageService.instance.init();
    final docs = await getApplicationDocumentsDirectory();
    final probe = File('${docs.path}/inbox_probe.txt');
    await probe.writeAsString('x');

    final result = await inboxDownloadedFile(probe.path);
    // ignore: avoid_print
    print('DEVICE_VERIFY[auto-import] 私有目录文件 inbox 后=$result');
    expect(result, probe.path,
        reason: '只收公共「下载」根目录里的文件，私有目录的不该被搬走');
    expect(await probe.exists(), isTrue);
    await probe.delete();
  });
}

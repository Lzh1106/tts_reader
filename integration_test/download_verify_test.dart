import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/services/document_service.dart';
import 'package:tts_reader/services/file_naming.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 设备层验证：**下载真的能创建任务、落到磁盘，并且能被导入文档库朗读**。
///
/// 这是那个「下载任务创建失败」bug 的回归测试。根因在 Android 清单里：
/// 我们曾经按插件文档的「可选配置」把 androidx.startup 里的 WorkManagerInitializer 移除了，
/// 却没有补上插件自己的 `FlutterDownloaderInitializer`（真正初始化 WorkManager 的那个
/// ContentProvider）。结果 `WorkManager.getInstance()` 直接抛异常，
/// `enqueue` 返回 null —— 表现就是**每个下载都失败**，而且错误信息只有一句
/// 「下载任务创建失败」，完全看不出原因。
///
/// 用本机 HTTP 服务当下载源：不依赖外网，结果确定。
///
/// 跑法：flutter test integration_test/download_verify_test.dart -d emulator-5554
///
/// 排障提示：如果任务一直停在 enqueued，先看模拟器的网络是不是「部分连通」
/// （`adb shell dumpsys connectivity | grep PARTIAL`）——WorkManager 的「需要联网」
/// 约束不满足时任务会一直排队且不给任何提示。模拟器上关掉强制门户探测即可：
/// `adb shell settings put global captive_portal_mode 0` + 飞行模式来回一次。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 插件只允许初始化一次（重复调用会断言失败），所以放在 setUpAll
  setUpAll(() async {
    await FlutterDownloader.initialize(debug: true);
  });

  testWidgets('下载：任务创建成功 → 落盘 → 能导入文档库并解析', (tester) async {
    // 现场生成一份真实的小 PDF，这样下载完还能真的解析一遍
    final pdf = PdfDocument();
    final font = PdfStandardFont(PdfFontFamily.helvetica, 12);
    pdf.pages.add().graphics.drawString(
      'Downloaded book page one. Second sentence of the book.',
      font,
      bounds: const Rect.fromLTWH(20, 40, 500, 200),
    );
    final payload = pdf.saveSync();
    pdf.dispose();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType('application', 'pdf');
      request.response.headers.set('Content-Disposition', 'attachment; filename="verify.pdf"');
      request.response.add(payload);
      await request.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/verify.pdf';

    await StorageService.instance.init();

    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/downloads/验收');
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final taskId = await FlutterDownloader.enqueue(
      url: url,
      savedDir: dir.path,
      fileName: 'verify.pdf',
      showNotification: false,
      openFileFromNotification: false,
      saveInPublicStorage: false,
      requiresStorageNotLow: false,
      allowCellular: true,
      timeout: 15000,
    );
    // ignore: avoid_print
    print('DEVICE_VERIFY[download] taskId=$taskId savedDir=${dir.path}');
    expect(
      taskId,
      isNotNull,
      reason: 'enqueue 返回 null 就是 WorkManager 没初始化（见本文件顶部说明）',
    );

    // 等任务跑到 complete（不能只看文件存在：边下边写，文件会先出现）
    String? status;
    final file = File('${dir.path}/verify.pdf');
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final tasks = await FlutterDownloader.loadTasks() ?? const <DownloadTask>[];
      for (final task in tasks) {
        if (task.taskId == taskId) {
          status = task.status.name;
          break;
        }
      }
      if (status == 'complete' || status == 'failed' || status == 'canceled') break;
    }
    final exists = file.existsSync();
    final length = exists ? file.lengthSync() : 0;
    // ignore: avoid_print
    print('DEVICE_VERIFY[download] status=$status exists=$exists bytes=$length');

    expect(status, isNotNull, reason: '任务应当能在下载列表里查到');
    expect(status, 'complete', reason: '任务应当跑完（一直排队说明 WorkManager 的约束没满足）');
    expect(exists, isTrue, reason: '文件应当落到 savedDir 下');
    expect(length, payload.length, reason: '落盘内容长度要与服务端一致');

    // 下载完成后浏览器会自动导入：这里验证同一个判定与入库 + 解析链路
    expect(DocumentType.isReadable(file.path), isTrue, reason: 'PDF 应当被判为可朗读');
    final document = Document(
      id: 'downloaded',
      title: DocumentService.titleFromPath(file.path),
      path: file.path,
      type: DocumentType.fromExtension(file.path),
      importedAt: DateTime.now(),
    );
    await StorageService.instance.upsertDocument(document);
    final saved = await StorageService.instance.loadDocuments();
    expect(saved.any((item) => item.id == 'downloaded'), isTrue, reason: '应当进文档库');

    final parsed = await DocumentService.parse(document);
    // ignore: avoid_print
    print('DEVICE_VERIFY[download] parsed chapters=${parsed.document.chapters.length} '
        'sentences=${parsed.document.sentenceCount} textLayer=${parsed.hasTextLayer}');
    expect(parsed.document.chapters, isNotEmpty, reason: '下载来的 PDF 要能解析出内容');
    expect(parsed.document.sentenceCount, greaterThan(0), reason: '解析出句子才谈得上朗读');

    await StorageService.instance.removeDocument('downloaded');
    await server.close(force: true);
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {
      // 句柄占用时忽略
    }
  });

  testWidgets('下载：原名带空格 / 中文 / 括号也照原样落盘，重名加 (1)', (tester) async {
    final pdf = PdfDocument();
    pdf.pages.add().graphics.drawString(
      'Original file name verification.',
      PdfStandardFont(PdfFontFamily.helvetica, 12),
      bounds: const Rect.fromLTWH(20, 40, 500, 200),
    );
    final payload = pdf.saveSync();
    pdf.dispose();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType('application', 'pdf');
      // 真实站点就是这么给的：名字里带空格、中文、括号
      request.response.headers.set(
        'Content-Disposition',
        "attachment; filename*=UTF-8''%E7%BA%A2%E6%A5%BC%E6%A2%A6%20(%E6%9B%B9%E9%9B%AA%E8%8A%B9)%20%E7%AC%AC%E4%B8%80%E5%9B%9E.pdf",
      );
      request.response.add(payload);
      await request.response.close();
    });

    await StorageService.instance.init();

    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/downloads/原名验收');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    String pathOf(String name) => '${dir.path}${Platform.pathSeparator}$name';
    bool exists(String name) => File(pathOf(name)).existsSync();

    // 与浏览器下载用的是同一套命名规则（服务端建议名 → 只清洗非法字符）
    const suggested = '红楼梦 (曹雪芹) 第一回.pdf';
    final first = FileNaming.uniqueName(
      FileNaming.downloadName(suggested: suggested, urlPath: '/dl', mimeType: 'application/pdf'),
      exists,
    );
    // ignore: avoid_print
    print('DEVICE_VERIFY[filename] 服务端名字=$suggested → 实际用=$first');
    expect(first, suggested, reason: '空格 / 中文 / 括号必须原样保留');

    Future<String?> download(String name) async {
      final id = await FlutterDownloader.enqueue(
        url: 'http://127.0.0.1:${server.port}/dl',
        savedDir: dir.path,
        fileName: name,
        showNotification: false,
        openFileFromNotification: false,
        saveInPublicStorage: false,
        requiresStorageNotLow: false,
        allowCellular: true,
        timeout: 15000,
      );
      if (id == null) return null;
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final tasks = await FlutterDownloader.loadTasks() ?? const <DownloadTask>[];
        for (final task in tasks) {
          if (task.taskId != id) continue;
          if (task.status == DownloadTaskStatus.complete) return name;
          if (task.status == DownloadTaskStatus.failed || task.status == DownloadTaskStatus.canceled) {
            return null;
          }
        }
      }
      return null;
    }

    expect(await download(first), isNotNull, reason: '第一次下载应当成功');
    expect(exists(suggested), isTrue, reason: '落盘文件名要与原名一字不差');
    expect(File(pathOf(suggested)).lengthSync(), payload.length);

    // 再下一次同名文件：不覆盖、不改名，按 Android 下载器的习惯加 (1)
    final second = FileNaming.uniqueName(
      FileNaming.downloadName(suggested: suggested, urlPath: '/dl', mimeType: 'application/pdf'),
      exists,
    );
    // ignore: avoid_print
    print('DEVICE_VERIFY[filename] 重名时第二个文件=$second');
    expect(second, '红楼梦 (曹雪芹) 第一回 (1).pdf');
    expect(await download(second), isNotNull, reason: '第二次下载应当成功');
    expect(exists(second), isTrue);
    expect(exists(suggested), isTrue, reason: '原文件不能被覆盖掉');

    // 导入文档库后的书名 = 原名去掉扩展名
    expect(DocumentService.titleFromPath(pathOf(suggested)), '红楼梦 (曹雪芹) 第一回');
    final document = Document(
      id: 'original_name',
      title: DocumentService.titleFromPath(pathOf(suggested)),
      path: pathOf(suggested),
      type: DocumentType.pdf,
      importedAt: DateTime.now(),
    );
    await StorageService.instance.upsertDocument(document);
    final saved = await StorageService.instance.loadDocuments();
    expect(
      saved.firstWhere((item) => item.id == 'original_name').title,
      '红楼梦 (曹雪芹) 第一回',
      reason: '文档库里的名字也要是原名',
    );
    await StorageService.instance.removeDocument('original_name');

    await server.close(force: true);
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {
      // 句柄占用时忽略
    }
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/web_link.dart';
import 'package:tts_reader/pages/browser_page.dart';
import 'package:tts_reader/services/book_source_directory.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 浏览器下载相关的纯逻辑验证：可朗读格式判定、下载位置与文件夹名、书源列表。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final storage = StorageService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    storage.resetForTest();
    await storage.init();
  });

  group('可朗读格式判定', () {
    test('PDF / EPUB / TXT 都算，大小写不敏感', () {
      expect(DocumentType.isReadable('/tmp/a.pdf'), isTrue);
      expect(DocumentType.isReadable('/tmp/a.PDF'), isTrue);
      expect(DocumentType.isReadable('a.epub'), isTrue);
      expect(DocumentType.isReadable('a.TXT'), isTrue);
    });

    test('其它格式不算（不能像 fromExtension 那样一律当 txt）', () {
      expect(DocumentType.isReadable('a.mobi'), isFalse);
      expect(DocumentType.isReadable('a.azw3'), isFalse);
      expect(DocumentType.isReadable('a.zip'), isFalse);
      expect(DocumentType.isReadable('没有扩展名'), isFalse);
      expect(DocumentType.isReadable('a.'), isFalse);
      expect(DocumentType.isReadable(''), isFalse);
      // 对照：fromExtension 会把 mobi 当成 txt，所以下载导入不能直接用它
      expect(DocumentType.fromExtension('a.mobi'), DocumentType.txt);
    });
  });

  group('下载位置', () {
    // v1.21.43：**下载超时必须显式给，且不能吃插件的 15 秒默认**
    //
    // 真机症状（用户报「**下载还是无法下全**」，日志为证）：
    // ```
    // 19:41:57  progress=0%      19:42:12  progress=6%
    // 19:42:13  status=failed progress=6%     ← 入队到失败只有 16 秒
    // ```
    // 插件源码：`timeout` 同时用于 `connectTimeout` 与 **`readTimeout`**
    // （相邻数据包的最大间隔），默认 **15000ms**。几十 MB 的书从慢速 CDN
    // （`dln1.ncdn.ec`）下，15 秒的包间隔是常态 → 必然"下到百分之几就 failed"。
    test('★下载超时必须显式给，且明显长于插件默认的 15 秒', () {
      const ms = BrowserPage.downloadTimeoutMs;
      // ignore: avoid_print
      print('DEVICE_VERIFY[dl-timeout] downloadTimeoutMs=$ms（${ms ~/ 1000} 秒）');
      expect(ms, greaterThan(15000),
          reason: '★不能等于插件的 15 秒默认；那正是"下到 6% 就失败"的原因');
      expect(ms, greaterThanOrEqualTo(60000), reason: '慢速 CDN 的大文件至少给 1 分钟');
      expect(ms, lessThanOrEqualTo(600000),
          reason: '也不能太长：真断线时用户不该干等太久');
    });

    // v1.21.39：默认值从「应用私有目录」改成「系统下载目录」
    // —— 用户要求默认落在文件管理器能看到的公共「下载」里。
    test('默认是系统下载目录，且没有自定义路径', () {
      expect(storage.downloadTarget, DownloadTarget.publicDownloads);
      expect(storage.downloadFolder, StorageService.defaultDownloadFolder);
      expect(storage.hasCustomDownloadPath, isFalse);
      expect(DownloadTarget.publicDownloads.label, contains('下载'));
    });

    test('默认路径常量就是系统「下载」目录', () {
      expect(StorageService.publicDownloadPath, '/storage/emulated/0/Download');
    });

    test('未解析真实路径时，downloadPath 给出可读的近似值（不为空）', () {
      expect(storage.downloadPath, isNotEmpty);
      expect(storage.downloadPath, contains('Download'));
    });

    // v1.21.40：路径必须是**纯路径字符串**
    //
    // 真机截图里显示成 `Directory: '/data/user/0/com.example.tts_reader/`
    // —— 根因是 `'$base/downloads/...'` 里 `$base` 是 `Directory` 对象，
    // 插值走 `toString()` 得到 `Directory: '...'`（带前缀 + 单引号），
    // 而且后面的子目录也丢了。这条把"不许把对象拿去插值"钉死。
    test('⚠️ downloadPath 不许带 Directory: 前缀、不许带引号', () async {
      final resolved = await storage.refreshDownloadPath();
      for (final candidate in <String>[storage.downloadPath, resolved]) {
        expect(candidate.contains('Directory:'), isFalse,
            reason: '这是 Directory 对象插值的指纹（"$candidate"）');
        expect(candidate.contains("'"), isFalse,
            reason: 'toString() 会带单引号（"$candidate"）');
        expect(candidate.contains('"'), isFalse);
        expect(candidate.startsWith('/'), isTrue,
            reason: '必须是绝对路径（"$candidate"）');
      }
    });

    test('默认（系统下载目录）显示的就是公共下载路径常量', () async {
      expect(storage.downloadTarget, DownloadTarget.publicDownloads);
      await storage.refreshDownloadPath();
      expect(storage.downloadPath, StorageService.publicDownloadPath,
          reason: '副标题说"系统下载目录"，显示的就该是它，不能是私有目录');
    });

    test('选应用私有目录后能持久化并在重启后读回', () async {
      await storage.setDownloadTarget(DownloadTarget.appPrivate);
      expect(storage.downloadTarget, DownloadTarget.appPrivate);

      storage.resetForTest();
      await storage.init();
      expect(storage.downloadTarget, DownloadTarget.appPrivate);
    });

    test('坏数据退回系统下载目录', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'download_target': '不存在的位置'});
      storage.resetForTest();
      await storage.init();
      expect(storage.downloadTarget, DownloadTarget.publicDownloads);
    });

    // ── v1.21.44：第三项 custom（自定义文件夹） ────────────────────────────
    group('DownloadTarget.custom（自定义文件夹）', () {
      test('加了 custom 之后 fromName 仍兼容旧数据，且兜底不变', () {
        expect(DownloadTarget.fromName('appPrivate'), DownloadTarget.appPrivate);
        expect(DownloadTarget.fromName('publicDownloads'),
            DownloadTarget.publicDownloads);
        // ★新增项必须认得出来，否则用户选完自定义、重启就被兜底吃成"系统下载目录"
        expect(DownloadTarget.fromName('custom'), DownloadTarget.custom);
        // ★兜底维持现状（publicDownloads）：改成 appPrivate 是行为变更，不是本任务
        expect(DownloadTarget.fromName('nonsense'), DownloadTarget.publicDownloads);
        expect(DownloadTarget.fromName(null), DownloadTarget.publicDownloads);
        expect(DownloadTarget.fromName(42), DownloadTarget.publicDownloads);
      });

      test('custom 排在最后（老数据按 name 存，但 index 判据不能被挪位）', () {
        expect(DownloadTarget.values.indexOf(DownloadTarget.custom),
            DownloadTarget.values.length - 1);
        expect(DownloadTarget.values.length, 3);
      });

      test('选了自定义文件夹 → 来源标记变成 custom，并能持久化', () async {
        expect(storage.downloadTarget, DownloadTarget.publicDownloads);

        await storage.setCustomDownloadPath('/storage/emulated/0/MyBooks');
        expect(storage.customDownloadPath, '/storage/emulated/0/MyBooks');
        expect(storage.downloadTarget, DownloadTarget.custom,
            reason: '路径与来源标记必须一起变（设置页靠它显示"当前来源"）');
        expect(storage.downloadPath, '/storage/emulated/0/MyBooks',
            reason: '自定义路径优先于任何默认落点');

        storage.resetForTest();
        await storage.init();
        expect(storage.customDownloadPath, '/storage/emulated/0/MyBooks');
        expect(storage.downloadTarget, DownloadTarget.custom,
            reason: '★重启后必须还是 custom（这条就是"选完就丢"的回归防线）');
      });

      test('恢复默认 → 路径清掉、来源标记回到 publicDownloads', () async {
        await storage.setCustomDownloadPath('/storage/emulated/0/MyBooks');
        await storage.resetDownloadPath();
        expect(storage.customDownloadPath, isEmpty);
        expect(storage.hasCustomDownloadPath, isFalse);
        expect(storage.downloadTarget, DownloadTarget.publicDownloads,
            reason: '不能留下"标记说自定义、路径却已清掉"的半态');
        expect(storage.downloadPath, isNot('/storage/emulated/0/MyBooks'));
      });

      test('isFilesystemPath：只认以 / 开头的真实路径，拒掉 content:// 与空白', () {
        expect(StorageService.isFilesystemPath('/storage/emulated/0/Books'), isTrue);
        expect(StorageService.isFilesystemPath('  /sdcard/Books  '), isTrue);
        // SAF 的"云盘 / 快捷方式"就是这种 URI —— flutter_downloader 写不进去
        expect(
            StorageService.isFilesystemPath(
                'content://com.android.externalstorage.documents/tree/primary'),
            isFalse);
        expect(StorageService.isFilesystemPath(''), isFalse);
        expect(StorageService.isFilesystemPath('/'), isFalse,
            reason: '光一个根斜杠不是有效目录');
        expect(StorageService.isFilesystemPath('relative/path'), isFalse);
        // Windows 盘符也算文件系统路径（宿主机跑测试要用；Android 上见不到）
        expect(StorageService.isFilesystemPath(r'C:\Temp\Books'), isTrue);
      });

      test('isWritableDir：临时目录能写；content:// 直接判否', () async {
        final Directory tmp = Directory.systemTemp.createTempSync('tts_writable_');
        addTearDown(() {
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        });
        expect(await StorageService.isWritableDir(tmp.path), isTrue);
        // 不存在的深层目录会被建出来（recursive）
        final String deeper = '${tmp.path}/a/b/c';
        expect(await StorageService.isWritableDir(deeper), isTrue);
        expect(Directory(deeper).existsSync(), isTrue);
        expect(await StorageService.isWritableDir('content://x/y'), isFalse);
      });

      test('isUsableCustomDir（放开后的唯一判据）：基准内直接过，外部路径真测', () async {
        // ① 基准目录之内 → 通过（纯字符串比对，不碰磁盘）
        final List<String> bases = await StorageService.writableBaseDirs();
        if (bases.isNotEmpty) {
          expect(await StorageService.isUsableCustomDir('${bases.first}/Books'), isTrue);
        }
        // ② 普通可写目录 → 通过（靠探针实测）
        final Directory tmp = Directory.systemTemp.createTempSync('tts_usable_');
        addTearDown(() {
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        });
        expect(await StorageService.isUsableCustomDir(tmp.path), isTrue);
        // ③ content://（系统文件选择器给出的 URI）→ 直接否，连探针都不试
        expect(
            await StorageService.isUsableCustomDir(
                'content://com.android.externalstorage.documents/tree/primary'),
            isFalse);
        // ④ 父级是**文件**的路径 → 建不出来 → 否（真机上对应"目录被删/SD 卡拔出"）
        final File blocker = File('${tmp.path}/blocker');
        blocker.writeAsStringSync('x');
        expect(await StorageService.isUsableCustomDir('${blocker.path}/sub'), isFalse);
      });
      test('hasAllFilesAccess：非 Android 恒为 true，测试开关能强制', () async {
        // 测试环境（桌面/CI）不该误报"没有权限"，否则设置页流程根本走不到选择器
        if (!Platform.isAndroid) {
          expect(await StorageService.hasAllFilesAccess(), isTrue);
        }
        // 测试开关（只给测试用）：能强制成"已授权 / 未授权"
        StorageService.debugAllFilesAccessOverride = false;
        addTearDown(() => StorageService.debugAllFilesAccessOverride = null);
        expect(await StorageService.hasAllFilesAccess(), isFalse);
        StorageService.debugAllFilesAccessOverride = true;
        expect(await StorageService.hasAllFilesAccess(), isTrue);
        // 强制模式下 requestAllFilesAccess 只返回、不真跳系统页
        await StorageService.requestAllFilesAccess();
        expect(StorageService.debugAllFilesAccessOverride, isTrue);
      });
    });
    test('自定义下载路径：设置 / 读回 / 恢复默认', () async {
      expect(storage.hasCustomDownloadPath, isFalse);
      await storage.setCustomDownloadPath('/data/user/0/com.example.tts_reader/files/Books');
      expect(storage.hasCustomDownloadPath, isTrue);
      expect(storage.downloadPath, '/data/user/0/com.example.tts_reader/files/Books');

      // 重启后仍在
      storage.resetForTest();
      await storage.init();
      expect(storage.hasCustomDownloadPath, isTrue);

      await storage.resetDownloadPath();
      expect(storage.hasCustomDownloadPath, isFalse);
      expect(storage.customDownloadPath, isEmpty);
      // 恢复默认后回到公共「下载」目录的近似值
      expect(storage.downloadPath, contains('Download'));
    });

    test('resetForTest 清掉自定义路径与解析缓存', () {
      storage.resetForTest();
      expect(storage.hasCustomDownloadPath, isFalse);
      expect(storage.downloadPath, isNotEmpty);
    });

    test('文件夹名会被清洗：分隔符与非法字符变下划线', () async {
      await storage.setDownloadFolder('我的/书籍:2024');
      expect(storage.downloadFolder, '我的_书籍_2024');
      expect(storage.downloadFolder.contains('/'), isFalse);
      expect(storage.downloadFolder.contains(':'), isFalse);
    });

    test('空文件夹名 / 纯符号回退到默认', () {
      expect(StorageService.sanitizeFolderName('   '), StorageService.defaultDownloadFolder);
      expect(StorageService.sanitizeFolderName('...'), StorageService.defaultDownloadFolder);
      expect(StorageService.sanitizeFolderName(''), StorageService.defaultDownloadFolder);
    });

    test('过长的文件夹名被截断', () {
      final long = StorageService.sanitizeFolderName('书' * 200);
      expect(long.length, 40);
    });

    test('文件夹名能持久化', () async {
      await storage.setDownloadFolder('小说');
      storage.resetForTest();
      await storage.init();
      expect(storage.downloadFolder, '小说');
    });
  });

  group('私有目录判据（isUnderAnyBase）', () {
    // ⚠️ 这条判据决定「自定义下载路径能不能用」，写错的后果是「设置页说能用、
    // 下载时却写不进去」。
    const appBase = '/data/user/0/com.example.tts_reader/app_flutter';
    const extBase =
        '/storage/emulated/0/Android/data/com.example.tts_reader/files';
    const bases = <String>[appBase, extBase];

    test('落在基准目录之内 → 可写', () {
      expect(StorageService.isUnderAnyBase('$appBase/Books', bases), isTrue);
      expect(StorageService.isUnderAnyBase(extBase, bases), isTrue);
      expect(StorageService.isUnderAnyBase('$extBase/a/b/c', bases), isTrue);
    });

    test('⚠️ 设备存储根不会被误判为私有', () {
      // 设备根路径本身就含 /Android/data/，所以不能拿子串判断
      expect(
        StorageService.isUnderAnyBase('/storage/emulated/0/Android/data', bases),
        isFalse,
        reason: '这是 Android/data 根，不是本应用的目录',
      );
      expect(
        StorageService.isUnderAnyBase(
            '/storage/emulated/0/Android/data/com.other.app/files', bases),
        isFalse,
        reason: '别的应用的目录不能写',
      );
      expect(
        StorageService.isUnderAnyBase('/storage/emulated/0/Download/Turrit/Books', bases),
        isFalse,
        reason: '公共下载目录里的子路径写不进去（MediaStore 会忽略 savedDir）',
      );
      expect(StorageService.isUnderAnyBase(StorageService.publicDownloadPath, bases),
          isFalse);
    });

    test('前缀相同但不同目录不算（/app_flutterX ≠ /app_flutter）', () {
      expect(StorageService.isUnderAnyBase('${appBase}X', bases), isFalse);
      expect(StorageService.isUnderAnyBase('${appBase}2/a', bases), isFalse);
    });

    test('末尾斜杠 / 反斜杠 / 空串都归一化处理', () {
      expect(StorageService.isUnderAnyBase('$appBase/Books/', bases), isTrue);
      expect(StorageService.isUnderAnyBase('$appBase\\Books', bases), isTrue);
      expect(StorageService.isUnderAnyBase('   ', bases), isFalse);
      expect(StorageService.isUnderAnyBase('/tmp/x', const <String>[]), isFalse);
      expect(StorageService.isUnderAnyBase('/tmp/x', const <String>['']), isFalse);
    });
  });

  group('书源', () {
    test('v1.21.24：默认书源是一组"入口"，且不写死镜像域名', () async {
      final sources = await storage.loadBookSources();
      // ignore: avoid_print
      print('PROBE[书源] ${sources.map((e) => e.title).toList()}');
      expect(sources, isNotEmpty, reason: '空列表按「没配过」处理，回默认入口');
      expect(
        sources.any((source) => source.url.startsWith(BookSourceDirectory.directoryUrl)),
        isTrue,
        reason: '默认要给「查当前可用域名」的入口，而不是写死某个镜像（域名换得太快）',
      );
      expect(
        StorageService.defaultBookSources.any((item) =>
            item.$2.contains('z-lib.') || item.$2.contains('z-library.')),
        isFalse,
        reason: '不再内置具体镜像域名',
      );
      for (final source in sources) {
        expect(source.title, isNotEmpty);
        final uri = Uri.tryParse(source.url);
        expect(uri, isNotNull);
        expect(uri!.scheme, anyOf('http', 'https'));
      }
    });

    test('换源：改完之后读到的就是新的', () async {
      final DateTime now = DateTime(2026, 10, 10);
      await storage.saveBookSources(<WebLink>[
        WebLink(title: '我的镜像', url: 'https://my-mirror.example/', createdAt: now),
      ]);
      storage.resetForTest();
      await storage.init();
      final reloaded = await storage.loadBookSources();
      expect(reloaded.length, 1);
      expect(reloaded.first.title, '我的镜像');
      expect(reloaded.first.url, 'https://my-mirror.example/');

      // 再改一次：读到的同样要是新的
      await storage.saveBookSources(<WebLink>[
        WebLink(title: '换一个', url: 'https://another.example/', createdAt: now),
      ]);
      storage.resetForTest();
      await storage.init();
      final again = await storage.loadBookSources();
      expect(again.single.title, '换一个');
      expect(again.single.url, 'https://another.example/');
    });

    test('删空之后回默认入口（避免菜单变成空的）', () async {
      await storage.saveBookSources(const <WebLink>[]);
      final sources = await storage.loadBookSources();
      expect(sources.length, StorageService.defaultBookSources.length,
          reason: '空列表按「没配过」处理，回默认书源入口');
    });
  });
}

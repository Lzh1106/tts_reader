import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/storage_service.dart';

/// **软件专属文件夹路径**（v1.21.43 重写版 · 块3）
///
/// ## 治什么
///
/// 用户拍板：「下载到根目录时新建一个软件专属文件夹，用于存储文件」+
/// 「下载文件夹的导航也导航到这个位置」。
///
/// 于是需要两个语义清晰的路径：
/// - [StorageService.downloadPath] —— 下载器**直写**的位置（公共「下载」根目录，
///   因为插件源码里 `RELATIVE_PATH` 写死成 `DIRECTORY_DOWNLOADS`，子路径会被忽略）；
/// - [StorageService.downloadInboxPath] —— 文件**最终待的地方**
///   （公共「下载」+ 软件专属子文件夹），设置页显示它、📂 导航到它。
///
/// 两者**必须都是公共目录**下的路径 —— 那是"卸载软件不删"的唯一位置
/// （应用私有目录卸载必删，已实测）。
///
/// ⚠️ 本文件是 v1.21.42 丢失版本的**重写**，不是"恢复"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    storage = StorageService.instance;
    storage.resetForTest();
    await storage.init();
  });

  group('downloadInboxPath（软件专属文件夹）', () {
    test('固定为「公共下载目录 + 软件专属子文件夹」', () {
      expect(StorageService.publicDownloadPath, '/storage/emulated/0/Download');
      expect(StorageService.downloadInboxFolder, '桃花源阅读器');
      expect(storage.downloadInboxPath,
          '/storage/emulated/0/Download/${StorageService.downloadInboxFolder}');
      // ignore: avoid_print
      print('DEVICE_VERIFY[inbox] downloadInboxPath=${storage.downloadInboxPath}');
    });

    test('下载器直写路径是公共「下载」根目录（不含子文件夹）', () {
      expect(storage.downloadPath, StorageService.publicDownloadPath);
      expect(storage.downloadPath.endsWith('/桃花源阅读器'), isFalse,
          reason: '下载器只能直写根目录（插件 RELATIVE_PATH 写死），'
              '子文件夹靠"下完再挪"');
    });

    test('两条路径都在公共目录下（这是"卸载不删"的前提）', () {
      for (final p in <String>[storage.downloadPath, storage.downloadInboxPath]) {
        expect(p.startsWith('/storage/emulated/0/'), isTrue,
            reason: '$p 必须在公共存储下，否则卸载会被删掉');
        expect(p.contains('/Android/data/'), isFalse,
            reason: '$p 不能是应用私有目录（那种卸载必删）');
        expect(p.contains('/data/user/'), isFalse,
            reason: '$p 不能是应用内部私有目录');
      }
    });

    test('子文件夹名不含路径分隔符（否则会拼出意外路径）', () {
      expect(StorageService.downloadInboxFolder.contains('/'), isFalse);
      expect(StorageService.downloadInboxFolder.contains('\\'), isFalse);
    });

    test('resetForTest 之后两条路径仍是固定值（不受偏好影响）', () {
      storage.resetForTest();
      expect(storage.downloadPath, StorageService.publicDownloadPath);
      expect(storage.downloadInboxPath,
          contains(StorageService.downloadInboxFolder));
    });
  });
}

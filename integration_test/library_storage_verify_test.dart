import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/services/document_service.dart';
import 'package:tts_reader/services/library_storage.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 设备层验证：**导入时把文件复制进应用目录**，之后源文件没了书也能读。
///
/// 场景就是 Android 上的真实情况：file_picker 把用户选的文件复制到
/// `cache/file_picker/<时间戳>/<名字>` 再交给应用，系统随时可能清掉这个缓存。
/// 这里直接用应用自己的 cache 目录模拟那份「临时副本」。
///
/// 跑法：flutter test integration_test/library_storage_verify_test.dart -d emulator-5554
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const content = '第一章 风起\n'
      '天还没亮他就出门了，路上一个人也没有。\n'
      '第二章 雨落\n'
      '雨下了整夜，他站在门口没动。\n';

  testWidgets('导入副本：复制进应用目录并保持原名，源文件删掉后仍能解析', (tester) async {
    await StorageService.instance.init();

    final cache = await getTemporaryDirectory();
    final docs = await getApplicationDocumentsDirectory();
    String join(String a, String b) => '$a${Platform.pathSeparator}$b';
    const name = '红楼梦 (曹雪芹) 第一回.txt';
    // 模拟 picker 交给应用的缓存副本
    final source = File(join(join(cache.path, 'picker_cache'), name));
    source.parent.createSync(recursive: true);
    source.writeAsStringSync(content);

    final adopted = await LibraryStorage.adopt(source.path, name: name);
    // ignore: avoid_print
    print('DEVICE_VERIFY[adopt] 应用目录=${docs.path}');
    // ignore: avoid_print
    print('DEVICE_VERIFY[adopt] 缓存副本=${source.path}');
    // ignore: avoid_print
    print('DEVICE_VERIFY[adopt] → ${adopted.path} copied=${adopted.copied} err=${adopted.error}');

    expect(adopted.ok, isTrue, reason: '复制不该失败');
    expect(adopted.copied, isTrue, reason: '缓存副本应当被复制进应用目录');
    expect(adopted.path, join(join(docs.path, LibraryStorage.dirName), name),
        reason: '保持原文件名，落在书库目录里');
    expect(File(adopted.path).readAsStringSync(), content, reason: '内容一字不差');
    expect(await LibraryStorage.isInAppDir(adopted.path), isTrue);
    expect(await LibraryStorage.isLibraryCopy(adopted.path), isTrue);
    expect(await LibraryStorage.isInAppDir(source.path), isFalse, reason: '缓存目录不算应用目录');

    // 关键场景：源文件消失（系统清缓存 / 用户删了原文件）
    source.deleteSync();
    expect(source.existsSync(), isFalse);

    final parsed = await DocumentService.parseAsync(
      Document(
        id: 'adopted',
        title: DocumentService.titleFromPath(adopted.path),
        path: adopted.path,
        type: DocumentType.txt,
        importedAt: DateTime.now(),
      ),
    ).result;
    // ignore: avoid_print
    print('DEVICE_VERIFY[adopt] 源文件删除后解析：书名=${DocumentService.titleFromPath(adopted.path)} '
        '章=${parsed.document.chapters.length} 编码=${parsed.encoding} '
        '首段=${parsed.document.chapters.first.paragraphs.first.text}');

    expect(parsed.document.chapters.length, 2, reason: '副本要能正常解析');
    expect(parsed.document.chapters.first.title, '第一章 风起');
    expect(parsed.document.chapters.first.paragraphs.first.text, '天还没亮他就出门了，路上一个人也没有。');

    // 移除文档时把书库副本删掉（下载目录 / 外部文件不动）
    expect(await LibraryStorage.release(adopted.path), isTrue);
    expect(File(adopted.path).existsSync(), isFalse);
    try {
      if (source.parent.existsSync()) source.parent.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('已经在应用目录里的文件不会被再复制一份', (tester) async {
    final docs = await getApplicationDocumentsDirectory();
    String join(String a, String b) => '$a${Platform.pathSeparator}$b';
    // 「下载到应用私有目录」的落点就是这个 downloads 子目录
    final dir = Directory(join(join(docs.path, 'downloads'), '验收'));
    dir.createSync(recursive: true);
    final file = File(join(dir.path, '已下载的书.txt'))..writeAsStringSync('正文');

    final adopted = await LibraryStorage.adopt(file.path);
    // ignore: avoid_print
    print('DEVICE_VERIFY[adopt] 应用目录内的文件 → ${adopted.path} copied=${adopted.copied}');
    expect(adopted.copied, isFalse, reason: '已经在应用目录里，不必再存一份');
    expect(adopted.path, file.path);
    expect(await LibraryStorage.isLibraryCopy(file.path), isFalse, reason: '下载目录不是书库副本');
    expect(await LibraryStorage.release(file.path), isFalse, reason: '不该删下载目录里的文件');
    expect(file.existsSync(), isTrue);

    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
}

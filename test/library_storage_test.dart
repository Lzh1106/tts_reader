import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/library_storage.dart';

/// 书库存储（导入时把文件复制进应用目录）的验证。
///
/// 动机：Android 上 file_picker 交给应用的是**缓存副本**
/// （`cache/file_picker/<时间戳>/<名字>`），缓存被系统清掉后文档库里的书就打不开了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory appDocs;
  late Directory outside;

  setUp(() {
    appDocs = Directory.systemTemp.createTempSync('lib_appdocs_');
    outside = Directory.systemTemp.createTempSync('lib_outside_');
    // 测试环境不跑 dart_plugin_registrant，path_provider 默认走方法通道，mock 它即可
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProvider,
      (call) async =>
          call.method == 'getApplicationDocumentsDirectory' ? appDocs.path : null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    for (final dir in <Directory>[appDocs, outside]) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  File makeFile(String name, String content) =>
      File('${outside.path}${Platform.pathSeparator}$name')..writeAsStringSync(content);

  String booksPath(String name) =>
      '${appDocs.path}${Platform.pathSeparator}${LibraryStorage.dirName}${Platform.pathSeparator}$name';

  test('外部文件被复制进书库目录，并保持原名', () async {
    final source = makeFile('红楼梦 (曹雪芹) 第一回.txt', '正文');

    final result = await LibraryStorage.adopt(source.path, name: '红楼梦 (曹雪芹) 第一回.txt');

    expect(result.ok, isTrue);
    expect(result.copied, isTrue);
    expect(result.path, booksPath('红楼梦 (曹雪芹) 第一回.txt'));
    expect(File(result.path).readAsStringSync(), '正文');
    expect(source.existsSync(), isTrue, reason: '原文件不动');
  });

  test('名字里的非法字符被清洗（用 list 场景：选择器给了个带冒号的名字）', () async {
    final source = makeFile('source.txt', 'x');
    // 注意不能真去创建 `a:b*c.txt`：Windows 上建不出来，所以用 name 参数模拟
    final result = await LibraryStorage.adopt(source.path, name: 'a:b*c?.txt');
    expect(result.path, booksPath('a_b_c_.txt'));
  });

  test('重复导入同一本书：复用副本，不存两份', () async {
    final source = makeFile('三体.txt', '一样的内容');
    final first = await LibraryStorage.adopt(source.path);
    final second = await LibraryStorage.adopt(source.path);

    expect(first.copied, isTrue);
    expect(second.copied, isFalse);
    expect(second.reused, isTrue);
    expect(second.path, first.path);
    final files = Directory('${appDocs.path}${Platform.pathSeparator}${LibraryStorage.dirName}')
        .listSync()
        .whereType<File>()
        .toList();
    expect(files.length, 1, reason: '书库里只有一份');
  });

  test('同名但内容不同（大小不同）：加 (1)，不覆盖', () async {
    final a = makeFile('书.txt', '短');
    final b = File('${outside.path}${Platform.pathSeparator}other${Platform.pathSeparator}书.txt');
    b.parent.createSync(recursive: true);
    b.writeAsStringSync('长很多的内容');

    final first = await LibraryStorage.adopt(a.path);
    final second = await LibraryStorage.adopt(b.path);

    expect(first.path, booksPath('书.txt'));
    expect(second.path, booksPath('书 (1).txt'));
    expect(File(first.path).readAsStringSync(), '短');
    expect(File(second.path).readAsStringSync(), '长很多的内容');
  });

  test('已经在应用私有目录里的文件不再复制（下载目录就是这种情况）', () async {
    final downloaded = Directory('${appDocs.path}${Platform.pathSeparator}downloads')
      ..createSync(recursive: true);
    final file = File('${downloaded.path}${Platform.pathSeparator}下好的书.pdf')
      ..writeAsStringSync('pdf');

    final result = await LibraryStorage.adopt(file.path);

    expect(result.copied, isFalse);
    expect(result.path, file.path);
    expect(Directory('${appDocs.path}${Platform.pathSeparator}${LibraryStorage.dirName}').existsSync(),
        isFalse,
        reason: '不该为了它建书库目录');

    expect(await LibraryStorage.isInAppDir(file.path), isTrue);
    expect(await LibraryStorage.isLibraryCopy(file.path), isFalse, reason: '下载目录不是书库副本');
  });

  test('文件不存在：报错但不抛异常，路径保持原样', () async {
    final result = await LibraryStorage.adopt('${outside.path}${Platform.pathSeparator}没有这个文件.txt');
    expect(result.ok, isFalse);
    expect(result.copied, isFalse);
    expect(result.path, contains('没有这个文件.txt'));
    expect(result.error, isNotNull);
  });

  test('path_provider 不可用时也不抛异常（导入不该因此失败）', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    final source = makeFile('兜底.txt', 'x');
    final result = await LibraryStorage.adopt(source.path);
    expect(result.copied, isFalse);
    expect(result.ok, isFalse);
    expect(result.path, source.path, reason: '退回原路径，功能照常');
  });

  test('release 只删书库副本，外部文件与下载目录都不动', () async {
    final source = makeFile('移除我.txt', '正文');
    final adopted = await LibraryStorage.adopt(source.path);
    final downloaded = Directory('${appDocs.path}${Platform.pathSeparator}downloads')
      ..createSync(recursive: true);
    final download = File('${downloaded.path}${Platform.pathSeparator}下载的书.txt')
      ..writeAsStringSync('x');

    expect(await LibraryStorage.release(adopted.path), isTrue);
    expect(File(adopted.path).existsSync(), isFalse);
    expect(await LibraryStorage.release(download.path), isFalse);
    expect(download.existsSync(), isTrue);
    expect(await LibraryStorage.release(source.path), isFalse);
    expect(source.existsSync(), isTrue);
  });

  test('bookmarks / 文档记录用的路径能被识别为书库副本', () async {
    final source = makeFile('识别.txt', 'x');
    final adopted = await LibraryStorage.adopt(source.path);
    expect(await LibraryStorage.isLibraryCopy(adopted.path), isTrue);
    expect(await LibraryStorage.isInAppDir(adopted.path), isTrue);
  });

  test('书库里已有同名同大小文件时也算复用（大小一致视为同一本）', () async {
    final source = makeFile('同名.txt', '四个字符');
    await LibraryStorage.adopt(source.path);
    // 换一个路径、内容长度相同
    final other = File('${outside.path}${Platform.pathSeparator}sub${Platform.pathSeparator}同名.txt');
    other.parent.createSync(recursive: true);
    other.writeAsStringSync('一样长度');
    expect(utf8.encode('四个字符').length, utf8.encode('一样长度').length);

    final second = await LibraryStorage.adopt(other.path);
    expect(second.reused, isTrue);
    expect(second.copied, isFalse);
  });
}

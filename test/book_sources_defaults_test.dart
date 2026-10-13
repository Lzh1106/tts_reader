import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/web_link.dart';
import 'package:tts_reader/services/book_source_directory.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 默认书源（v1.21.24 重建）
///
/// 演变：v1.21.23 按用户要求把内置的 5 条清空 → 本轮重建为 7 条**入口**，
/// 其中三条是 Z-Library 入口（open-slum 状态板 / Awesome-Zlibrary 的 Markdown /
/// getzlib 指引页），由运行时「检索可用域名」决定具体镜像。
///
/// 铁律：**不写死具体镜像域名**（域名几周就换，写死等于埋雷）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
  });

  test('默认书源：7 条入口，含三个 Z-Library 入口与两个状态源', () async {
    final List<WebLink> sources = await StorageService.instance.loadBookSources();
    // ignore: avoid_print
    print('PROBE[默认书源] ${sources.map((e) => e.title).toList()}');

    expect(StorageService.defaultBookSources.length, 7);
    expect(sources.length, 7);

    final List<String> urls = sources.map((WebLink e) => e.url).toList();
    expect(urls, contains(BookSourceDirectory.directoryUrl),
        reason: '主入口：应用内「检索可用域名」从它拉列表');
    expect(
      urls,
      contains(
          'https://raw.githubusercontent.com/dongyubin/Awesome-Zlibrary/main/README.md'),
      reason: '社区维护的镜像列表（Markdown）',
    );
    expect(urls, contains('https://getzlib.com/'), reason: 'getzlib 域名指引页');
    expect(urls.any((String u) => u.endsWith('annas.html')), isTrue);
    expect(urls.any((String u) => u.endsWith('libgen.html')), isTrue);
    expect(urls, contains('https://www.gutenberg.org/'));
    expect(urls, contains('https://zh.wikisource.org/'));

    // 每个都是合法 http(s) 绝对地址
    for (final WebLink source in sources) {
      expect(source.title, isNotEmpty);
      final Uri? uri = Uri.tryParse(source.url);
      expect(uri, isNotNull);
      expect(uri!.host, isNotEmpty);
      expect(uri.scheme, anyOf('http', 'https'));
    }
  });

  test('不写死具体镜像域名（只放"入口"）', () async {
    for (final (String, String) item in StorageService.defaultBookSources) {
      final String host = Uri.parse(item.$2).host.toLowerCase();
      // ignore: avoid_print
      print('PROBE[入口] ${item.$1} → $host');
      expect(
        host.contains('z-lib.') || host.contains('z-library.') || host.contains('zlibrary.'),
        isFalse,
        reason: '镜像域名换得太快，不能写死（${item.$2}）',
      );
    }
  });

  test('老设备存量：v1.21.23 之前内置的那几条会被清掉，之后回落到新默认', () async {
    final DateTime now = DateTime(2026, 10, 10);
    await StorageService.instance.saveBookSources(<WebLink>[
      WebLink(
          title: 'Z-Library 可用域名（open-slum.org）',
          url: 'https://open-slum.org/',
          createdAt: now),
      WebLink(
          title: '维基文库', url: 'https://zh.wikisource.org/', createdAt: now),
      WebLink(title: '我自己的书源', url: 'https://example.com/books', createdAt: now),
    ]);

    final List<WebLink> after = await StorageService.instance.loadBookSources();
    // ignore: avoid_print
    print('PROBE[清理存量] 剩下=${after.map((e) => e.title).toList()}');

    expect(after.map((WebLink e) => e.title), contains('我自己的书源'),
        reason: '用户自己加的那条必须留着');
    expect(after.length, 1,
        reason: '同地址同标题的两条内置条目被清掉后只剩用户自己那条（不自动补默认）');
  });

  test('列表空时回落到默认入口（避免书源页彻底空白）', () async {
    await StorageService.instance.loadBookSources(); // 触发一次性清理标记
    await StorageService.instance.saveBookSources(const <WebLink>[]);
    final List<WebLink> sources = await StorageService.instance.loadBookSources();
    expect(sources.length, StorageService.defaultBookSources.length,
        reason: '空列表按"没配过"处理 → 回默认入口');
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/web_link.dart';
import 'package:tts_reader/pages/browser_page.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 浏览器起始页与搜索引擎验证。
///
/// 覆盖三件事：
/// 1. 地址栏/搜索框的输入判定（网址 vs 搜索词）—— 纯函数，最容易写错；
/// 2. 搜索引擎默认值、URL 拼接与持久化；
/// 3. 存储层对「存了怪值」的容错。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
  });

  group('地址栏输入判定', () {
    const bing = SearchEngine(name: '必应', urlTemplate: 'https://www.bing.com/search?q=%s');

    test('完整 URL 原样打开', () {
      expect(resolveBrowserInput('https://example.com/a', bing),
          'https://example.com/a');
      expect(resolveBrowserInput('http://example.com', bing),
          'http://example.com');
      expect(resolveBrowserInput('  https://example.com  ', bing),
          'https://example.com');
    });

    test('像域名的补上 https', () {
      expect(resolveBrowserInput('example.com', bing), 'https://example.com');
      expect(resolveBrowserInput('www.bing.com/search', bing),
          'https://www.bing.com/search');
    });

    test('其余按搜索词处理：用当前引擎而不是写死百度', () {
      expect(resolveBrowserInput('桃花源记', bing),
          'https://www.bing.com/search?q=%E6%A1%83%E8%8A%B1%E6%BA%90%E8%AE%B0');
      // 带空格的也走搜索（不可能是域名）
      expect(resolveBrowserInput('flutter webview', bing),
          'https://www.bing.com/search?q=flutter%20webview');
    });

    test('换搜索引擎后同一段文字拼出不同 URL', () {
      const baidu = SearchEngine(name: '百度', urlTemplate: 'https://www.baidu.com/s?wd=%s');
      final withBing = resolveBrowserInput('测试', bing);
      final withBaidu = resolveBrowserInput('测试', baidu);
      expect(withBing, contains('bing.com'));
      expect(withBaidu, contains('baidu.com'));
      expect(withBing, isNot(withBaidu));
    });

    test('空输入返回空串（不跳转）', () {
      expect(resolveBrowserInput('   ', bing), '');
      expect(resolveBrowserInput('', bing), '');
    });
  });

  group('快捷方式：搜索页识别与去重', () {
    WebLink link(String url, {String title = '', bool shortcut = true}) => WebLink(
          title: title,
          url: url,
          createdAt: DateTime(2024),
          isShortcut: shortcut,
        );

    test('识别各家的搜索结果页', () {
      for (final url in <String>[
        'https://www.bing.com/search?q=flutter',
        'https://cn.bing.com/search?q=%E6%B5%8B%E8%AF%95&form=QBLH',
        'https://www.baidu.com/s?wd=flutter',
        'https://www.google.com/search?q=flutter',
        'https://duckduckgo.com/?q=flutter',
        'https://www.sogou.com/web?query=flutter',
        'https://www.so.com/s?q=flutter',
      ]) {
        expect(link(url).isSearchResult, isTrue, reason: url);
      }
    });

    test('普通页面不算搜索页', () {
      for (final url in <String>[
        'https://flutter.dev/docs',
        'https://www.bing.com/',
        'https://cn.bing.com/',
        'https://www.baidu.com/',
        'https://zh.wikipedia.org/wiki/Flutter',
        'https://example.com/search-not-really',
      ]) {
        expect(link(url).isSearchResult, isFalse, reason: url);
      }
    });

    test('按主机名去重：同一站点只留一条（保留靠前的那条）', () {
      final deduped = StorageService.dedupeByHost(<WebLink>[
        link('https://www.bing.com/search?q=a', title: 'Search - A'),
        link('https://cn.bing.com/search?q=b', title: 'Search - B'),
        link('https://flutter.dev/', title: 'Flutter'),
        link('https://flutter.dev/docs', title: 'Flutter Docs'),
      ]);
      // bing.com 与 cn.bing.com 去掉 www. 后是不同主机，所以各留一条；
      // flutter.dev 的两条合并成一条
      expect(deduped.length, 3);
      expect(deduped.where((l) => l.bareHost == 'flutter.dev').length, 1);
      expect(deduped.firstWhere((l) => l.bareHost == 'flutter.dev').title, 'Flutter');
    });

    test('同主机不同前缀（www.）视为同一站点', () {
      final deduped = StorageService.dedupeByHost(<WebLink>[
        link('https://www.example.com/a'),
        link('https://example.com/b'),
      ]);
      expect(deduped.length, 1);
    });

    test('loadShortcuts 会把搜索页与重复站点过滤掉', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'browser_bookmarks': jsonEncode(<Map<String, dynamic>>[
          link('https://www.bing.com/search?q=a', title: 'Search - Microsoft Bing').toJson(),
          link('https://www.bing.com/search?q=b', title: 'Search - Microsoft Bing').toJson(),
          link('https://www.bing.com/search?q=c', title: '搜索 - 设置').toJson(),
          link('https://flutter.dev/', title: 'Flutter').toJson(),
          link('https://flutter.dev/docs', title: 'Flutter Docs').toJson(),
          link('https://dart.dev/', title: 'Dart').toJson(),
        ]),
      });
      StorageService.instance.resetForTest();
      await StorageService.instance.init();

      final shortcuts = await StorageService.instance.loadShortcuts();
      final titles = shortcuts.map((s) => s.displayTitle).toList();
      // 三条 bing 搜索页全被滤掉，flutter.dev 合并成一条
      expect(titles, <String>['Flutter', 'Dart']);
    });

    test('非快捷方式的普通收藏，在旧数据里也照常显示（兼容旧版本）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'browser_bookmarks': jsonEncode(<Map<String, dynamic>>[
          link('https://flutter.dev/', title: '老收藏', shortcut: false).toJson(),
        ]),
      });
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      final shortcuts = await StorageService.instance.loadShortcuts();
      expect(shortcuts.length, 1, reason: '旧数据没有 shortcut 标记，仍要当快捷方式显示');
    });

    test('新增 / 删除 / 清空快捷方式', () async {
      final storage = StorageService.instance;
      await storage.addShortcut(link('https://a.test/', title: 'A'));
      await storage.addShortcut(link('https://b.test/', title: 'B'));
      expect((await storage.loadShortcuts()).length, 2);

      await storage.removeShortcut('https://a.test/');
      final left = await storage.loadShortcuts();
      expect(left.length, 1);
      expect(left.first.url, 'https://b.test/');

      await storage.clearShortcuts();
      expect(await storage.loadShortcuts(), isEmpty);
    });

    test('addShortcut 对同一网址是幂等的（只把标记补上，不重复添加）', () async {
      final storage = StorageService.instance;
      await storage.addShortcut(link('https://a.test/', title: 'A'));
      await storage.addShortcut(link('https://a.test/', title: 'A 再来一次'));
      final shortcuts = await storage.loadShortcuts();
      expect(shortcuts.length, 1);
      expect(shortcuts.first.title, 'A 再来一次', reason: '后写的标题生效');
    });

    test('isShortcut 标记会持久化（重启后快捷方式还在）', () async {
      await StorageService.instance.addShortcut(link('https://a.test/', title: 'A'));
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      final shortcuts = await StorageService.instance.loadShortcuts();
      expect(shortcuts.length, 1);
      expect(shortcuts.first.url, 'https://a.test/');
    });
  });

  group('自定义首页与「回到浏览器主页」', () {
    test('默认（没设过）时：没有自定义首页，默认首页仍是内置的必应', () {
      final storage = StorageService.instance;
      expect(storage.homeUrl, StorageService.defaultHomeUrl);
      // 「有没有自定义过」由这个判据决定：与内置默认值不同才算设过
      expect(storage.homeUrl == StorageService.defaultHomeUrl, isTrue);
    });

    test('设为自定义首页后能持久化，且与内置默认值不再相同', () async {
      final storage = StorageService.instance;
      await storage.setHomeUrl('https://example.com/start');
      expect(storage.homeUrl, 'https://example.com/start');
      expect(storage.homeUrl == StorageService.defaultHomeUrl, isFalse);

      // 重开仍是自定义的
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      expect(StorageService.instance.homeUrl, 'https://example.com/start');
    });

    test('地址栏输入判定：主界面留空时不跳转', () {
      // 地址栏默认为空白（用户要求）——空输入必须返回空串，
      // 否则一进主界面就会被当成搜索词跳走
      for (final engine in StorageService.searchEngines) {
        expect(resolveBrowserInput('', engine), isEmpty);
        expect(resolveBrowserInput('   ', engine), isEmpty);
      }
    });

    test('菜单元数据：首页入口叫「回到浏览器主页」', () {
      // 菜单项文案与行为必须一致（首页键与菜单项现在都回主界面，
      // 不再去加载默认网址）。这里只校验文案表，
      // 真机行为由 integration_test/browser_home_test.dart 验证。
      expect(BrowserPage.homeEntryTitle, '回到浏览器主页');
    });
  });

  group('搜索引擎', () {
    test('默认是必应', () {
      expect(StorageService.defaultSearchEngine.name, '必应');
      expect(StorageService.instance.searchEngine.name, '必应');
      expect(StorageService.defaultSearchEngine.urlTemplate, contains('bing.com'));
    });

    test('预设里必应排第一，且都在列表里', () {
      expect(StorageService.searchEngines.first.name, '必应');
      final names = StorageService.searchEngines.map((e) => e.name).toList();
      expect(names, containsAll(<String>['必应', '百度', 'Google', 'DuckDuckGo', '搜狗']));
      // 每个模板都要有 %s 占位符，否则拼不出搜索 URL
      for (final engine in StorageService.searchEngines) {
        expect(engine.urlTemplate, contains('%s'), reason: engine.name);
      }
    });

    test('urlFor 会做 URL 编码并去掉首尾空白', () {
      const engine = SearchEngine(name: '必应', urlTemplate: 'https://x.test/s?q=%s');
      expect(engine.urlFor('  a b&c=d  '), 'https://x.test/s?q=a%20b%26c%3Dd');
    });

    test('切换后能持久化，重开仍是新的引擎', () async {
      const baidu = SearchEngine(name: '百度', urlTemplate: 'https://www.baidu.com/s?wd=%s');
      await StorageService.instance.setSearchEngine(baidu);
      expect(StorageService.instance.searchEngine.name, '百度');

      // 模拟「重开应用」：丢掉内存状态后重新 init
      StorageService.instance.resetForTest();
      expect(StorageService.instance.searchEngine.name, '必应', reason: 'reset 回默认');
      await StorageService.instance.init();
      expect(StorageService.instance.searchEngine.name, '百度', reason: '从存储里读回来');
    });

    test('存储里是怪值时退回默认，不崩', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'browser_search_engine': 'https://evil.example/?q=%s',
      });
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      expect(StorageService.instance.searchEngine.name, '必应');
    });

    test('相同模板的 SearchEngine 相等（列表里做单选判断要用）', () {
      const a = SearchEngine(name: '必应', urlTemplate: 'https://www.bing.com/search?q=%s');
      expect(a, StorageService.defaultSearchEngine);
      expect(a.hashCode, StorageService.defaultSearchEngine.hashCode);
    });
  });
}

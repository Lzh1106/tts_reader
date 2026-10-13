import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/book_source_directory.dart';

/// 书源域名发现：多源聚合 + 本地缓存（v1.21.22）
///
/// 背景：原来只依赖 `open-slum.org` 一个源，它挂了整个「检索可用域名」就废了。
/// 用例里的 HTML 片段**抄自 2026-10-10 实抓的页面**（见交付物附录），
/// 不是凭空编的结构。
const String _openSlumHtml = '''
<div class="site-grid">
  <div class="site-card">
    <div class="site-card-header">
      <a href="zlibrary.html" class="site-card-title">zlibrary</a>
      <span class="status-badge up">UP</span>
    </div>
    <ul class="domain-list-dense">
      <li class="domain-item-dense">
        <a class="domain-link" href="https://z-lib.sk/">z-lib.sk</a>
        <span class="status-badge up" title="UP">UP</span>
      </li>
      <li class="domain-item-dense">
        <a class="domain-link" href="https://z-lib.fm/">z-lib.fm</a>
        <span class="status-badge down" title="DOWN">DOWN</span>
      </li>
    </ul>
  </div>
</div>
''';

/// 抄自实抓的 getzlib.com（Tailwind 类名原样保留）
const String _getZlibHtml = '''
<div class="animate-fade-up delay-3 mx-auto mt-8 w-full max-w-2xl sm:mt-12">
  <span class="mb-2 block text-left text-xs font-medium text-muted-foreground">Listed domain</span>
  <div class="flex flex-col gap-3 rounded-2xl border border-primary/30 bg-primary/5 p-3 sm:flex-row sm:items-center">
    <a href="https://z-lib.sk/" target="_blank" rel="noopener noreferrer" aria-label="Visit https://z-lib.sk/"
       class="flex-1 truncate rounded-xl bg-background px-4 py-3 text-left font-mono text-sm">https://z-lib.sk/</a>
  </div>
</div>
<div class="space-y-3">
  <div class="flex flex-wrap items-center gap-4 rounded-xl border border-primary/20 bg-secondary/30 p-4">
    <div class="min-w-0 flex-1 space-y-1">
      <p class="break-words text-base font-medium text-foreground">https://z-lib.sk/</p>
      <p class="text-xs text-muted-foreground">Link #1 · Wikipedia source checked 2026-10-10T08:27:48.701Z</p>
    </div>
  </div>
</div>
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    BookSourceDirectory.clearCacheForTest();
    now = DateTime(2026, 10, 10, 12);
    BookSourceDirectory.clock = () => now;
  });

  tearDown(() {
    BookSourceDirectory.clock = DateTime.now;
    BookSourceDirectory.clearCacheForTest();
  });

  test('多源聚合：主源挂了，备用源照常给出结果', () async {
    final List<String> hit = <String>[];
    final http.Client client = MockClient((http.Request request) async {
      final String url = request.url.toString();
      hit.add(url);
      if (url.contains('open-slum')) {
        return http.Response('service unavailable', 503); // 主源挂了
      }
      if (url.contains('getzlib')) {
        return http.Response(_getZlibHtml, 200,
            headers: <String, String>{'content-type': 'text/html; charset=utf-8'});
      }
      return http.Response('', 404);
    });

    final DirectoryResult result =
        await BookSourceDirectory.fetch(client: client, forceRefresh: true, probe: false);
    // ignore: avoid_print
    print('PROBE[多源] source=${result.sourceUrl} entries=${result.entries} hit=$hit');

    expect(result.entries, isNotEmpty, reason: '主源 503 时备用源必须顶上');
    expect(result.sourceUrl, contains('getzlib'), reason: '结果应标注来自备用源');
    expect(result.entries.first.host, 'z-lib.sk');
    expect(result.entries.first.usable, isTrue);
    expect(hit.length, greaterThanOrEqualTo(2), reason: '两个源都要被并行请求到');
  });

  test('主源正常时：用主源的完整解析（含状态徽章）', () async {
    // 备用源这次不返回内容，确保走的是主源那条解析
    final http.Client client = MockClient((http.Request request) async {
      if (request.url.toString().contains('open-slum')) {
        return http.Response(_openSlumHtml, 200);
      }
      return http.Response('', 500);
    });
    final DirectoryResult result =
        await BookSourceDirectory.fetch(client: client, forceRefresh: true, probe: false);
    // ignore: avoid_print
    print('PROBE[主源] source=${result.sourceUrl} entries=${result.entries}');
    expect(result.sourceUrl, contains('open-slum'));
    expect(result.entries.length, 2);
    expect(result.entries.first.host, 'z-lib.sk');
    expect(result.entries.first.status, 'UP');
    // 可用的排前面
    expect(result.entries.last.status, 'DOWN');
  });

  test('两个源都可用时：先返回的那个胜出（并行赛跑，任一个成功即可）', () async {
    final http.Client client = MockClient((http.Request request) async {
      final String url = request.url.toString();
      if (url.contains('open-slum')) {
        // 让主源慢一拍，验证备用源能独立顶上
        await Future<void>.delayed(const Duration(milliseconds: 80));
        return http.Response(_openSlumHtml, 200);
      }
      if (url.contains('getzlib')) {
        return http.Response(_getZlibHtml, 200,
            headers: <String, String>{'content-type': 'text/html; charset=utf-8'});
      }
      return http.Response('', 404); // 第三个源（Markdown）这轮不参与
    });
    final DirectoryResult result =
        await BookSourceDirectory.fetch(client: client, forceRefresh: true, probe: false);
    // ignore: avoid_print
    print('PROBE[赛跑] source=${result.sourceUrl} entries=${result.entries}');
    expect(result.entries, isNotEmpty);
    expect(result.sourceUrl, contains('getzlib'),
        reason: '快的那一个先给出结果就用它（不必等慢的主源）');
  });

  test('本地缓存：2 小时内不再打网络，过期后重新请求', () async {
    var calls = 0;
    final http.Client client = MockClient((http.Request request) async {
      calls++;
      if (request.url.toString().contains('getzlib')) {
        return http.Response(_getZlibHtml, 200,
            headers: <String, String>{'content-type': 'text/html; charset=utf-8'});
      }
      return http.Response('', 404);
    });

    final DirectoryResult first =
        await BookSourceDirectory.fetch(client: client, forceRefresh: true, probe: false);
    expect(first.fromCache, isFalse);
    final int afterFirst = calls;
    expect(afterFirst, greaterThan(0));

    // 第二次（同一进程）：命中缓存，不再请求
    final DirectoryResult second = await BookSourceDirectory.fetch(client: client);
    // ignore: avoid_print
    print('PROBE[缓存] first=${first.fromCache} second=${second.fromCache} calls=$calls');
    expect(second.fromCache, isTrue);
    expect(second.entries.length, first.entries.length);
    expect(calls, afterFirst, reason: '缓存命中时不该再打网络');

    // 拨到 2 小时之后：缓存过期 → 重新请求
    now = now.add(const Duration(hours: 2, minutes: 1));
    final DirectoryResult third = await BookSourceDirectory.fetch(client: client);
    // ignore: avoid_print
    print('PROBE[缓存过期] third=${third.fromCache} calls=$calls');
    expect(third.fromCache, isFalse);
    expect(calls, greaterThan(afterFirst), reason: '过期后必须重新请求');
  });

  test('缓存跨进程有效（新进程只靠落盘缓存也不打网络）', () async {
    var calls = 0;
    final http.Client client = MockClient((http.Request request) async {
      calls++;
      if (request.url.toString().contains('getzlib')) {
        return http.Response(_getZlibHtml, 200,
            headers: <String, String>{'content-type': 'text/html; charset=utf-8'});
      }
      return http.Response('', 404);
    });
    await BookSourceDirectory.fetch(client: client, forceRefresh: true, probe: false);
    final int afterFirst = calls;

    // 模拟"重开应用"：清掉进程内缓存，保留 SharedPreferences
    BookSourceDirectory.clearCacheForTest();
    final DirectoryResult result = await BookSourceDirectory.fetch(client: client);
    // ignore: avoid_print
    print('PROBE[落盘缓存] fromCache=${result.fromCache} calls=$calls');
    expect(result.fromCache, isTrue, reason: '落盘缓存要能命中');
    expect(result.entries, isNotEmpty);
    expect(calls, afterFirst, reason: '不该再打网络');
  });

  test('全部源失败：明确报告失败源（界面据此提示手动书源）', () async {
    final http.Client client = MockClient((http.Request request) async {
      return http.Response('nope', 500);
    });
    final DirectoryResult result =
        await BookSourceDirectory.fetch(client: client, forceRefresh: true, probe: false);
    // ignore: avoid_print
    print('PROBE[全失败] entries=${result.entries.length} failed=${result.failedSources}');
    expect(result.entries, isEmpty);
    expect(result.allFailed, isTrue);
    expect(result.failedSources.length, BookSourceDirectory.directoryUrls.length,
        reason: '每个候选源都要被记进失败列表');
  });

  test('zlib.wwkejishe.top 实测连不上 → 不进候选列表', () {
    // ignore: avoid_print
    print('PROBE[候选源] ${BookSourceDirectory.directoryUrls}');
    expect(BookSourceDirectory.directoryUrls.length, greaterThanOrEqualTo(2));
    expect(
      BookSourceDirectory.directoryUrls.any((String u) => u.contains('wwkejishe')),
      isFalse,
      reason: '2026-10-10 实测 20s 连接超时，收进来只会拖慢检索',
    );
    // 主源常量保持兼容（storage_service 里的默认书签靠它拼 annas.html / libgen.html）
    expect(BookSourceDirectory.directoryUrl, 'https://open-slum.org/');
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/book_source_directory.dart';

/// v1.21.24 新增的两层：**本机连通性实测** + **自定义状态源**
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    BookSourceDirectory.clearCacheForTest();
  });

  const String zlibHtml = '''
<div class="site-grid">
  <div class="site-card">
    <div class="site-card-header">
      <a href="zlibrary.html" class="site-card-title">zlibrary</a>
    </div>
    <ul class="domain-list-dense">
      <li class="domain-item-dense">
        <a class="domain-link" href="https://ok.example/">ok</a>
        <span class="status-badge up" title="UP">UP</span>
      </li>
      <li class="domain-item-dense">
        <a class="domain-link" href="https://blocked.example/">blocked</a>
        <span class="status-badge up" title="UP">UP</span>
      </li>
      <li class="domain-item-dense">
        <a class="domain-link" href="https://dead.example/">dead</a>
        <span class="status-badge up" title="UP">UP</span>
      </li>
    </ul>
  </div>
</div>
''';

  group('本机连通性实测', () {
    test('2xx 可达 / 403 不可达 / 连不上不可达（用户口径）', () async {
      final List<MirrorEntry> entries = <MirrorEntry>[
        const MirrorEntry(url: 'https://ok.example/', host: 'ok.example', status: 'UP'),
        const MirrorEntry(
            url: 'https://blocked.example/', host: 'blocked.example', status: 'DEGRADED'),
        const MirrorEntry(
            url: 'https://dead.example/', host: 'dead.example', status: 'UP'),
      ];
      final http.Client client = MockClient((http.Request request) async {
        switch (request.url.host) {
          case 'ok.example':
            return http.Response('ok', 200);
          case 'blocked.example':
            return http.Response('forbidden', 403);
          default:
            throw Exception('timeout-ish'); // 连接失败
        }
      });

      final List<MirrorEntry> probed =
          await BookSourceDirectory.probeAll(entries, client: client);
      final Map<String, String> byHost = <String, String>{
        for (final MirrorEntry e in probed) e.host: e.status,
      };
      // ignore: avoid_print
      print('PROBE[本机实测] $byHost');

      expect(byHost['ok.example'], 'UP');
      expect(byHost['blocked.example'], 'DOWN', reason: '用户口径：403 被档 = 不可达');
      expect(byHost['dead.example'], 'DOWN', reason: '连不上就不是可用');
      expect(probed.where((MirrorEntry e) => e.usable).length, 1,
          reason: '只有 200 的那条算可用；403 与连不上都不算');
      expect(probed.first.host, 'ok.example', reason: '可用的排最前');
    });

    test('探测结果会写进 fetch 的返回值（本机实测生效）', () async {
      final http.Client client = MockClient((http.Request request) async {
        final String url = request.url.toString();
        if (url.contains('open-slum')) {
          return http.Response.bytes(utf8.encode(zlibHtml), 200,
              headers: <String, String>{'content-type': 'text/html; charset=utf-8'});
        }
        if (url.contains('ok.example')) return http.Response('ok', 200);
        if (url.contains('blocked.example')) return http.Response('no', 403);
        return http.Response('', 404); // 其它源 + dead.example
      });

      final DirectoryResult result =
          await BookSourceDirectory.fetch(client: client, forceRefresh: true);
      final Map<String, String> byHost = <String, String>{
        for (final MirrorEntry e in result.entries) e.host: e.status,
      };
      // ignore: avoid_print
      print('PROBE[实测+检索] probed=${result.probed} $byHost '
          'reachable=${result.reachableCount}');
      expect(result.probed, isTrue);
      expect(byHost['ok.example'], 'UP');
      expect(byHost['blocked.example'], 'DOWN', reason: '403 = 不可达');
      expect(byHost['dead.example'], isNot('UP'));
      expect(result.reachableCount, 1);
    });

    test('probe=false 时不动状态（给"只看列表"的场景留口子）', () async {
      final http.Client client = MockClient((http.Request request) async {
        final String url = request.url.toString();
        if (url.contains('open-slum')) {
          return http.Response.bytes(utf8.encode(zlibHtml), 200,
              headers: <String, String>{'content-type': 'text/html; charset=utf-8'});
        }
        return http.Response('', 404);
      });
      final DirectoryResult result = await BookSourceDirectory.fetch(
          client: client, forceRefresh: true, probe: false);
      expect(result.probed, isFalse);
      expect(result.entries.length, 3, reason: '不做实测 → 保留状态站给的 3 条');
    });
  });

  group('自定义状态源', () {
    test('追加、去重、与内置合并', () async {
      // 空的时候只有内置
      List<String> all = await BookSourceDirectory.allSources();
      expect(all.length, BookSourceDirectory.directoryUrls.length);
      // ignore: avoid_print
      print('PROBE[源清单-初始] $all');

      // 追加一个：自动补 https://
      await BookSourceDirectory.addCustomSource('my-mirror.example/list.md');
      all = await BookSourceDirectory.allSources();
      // ignore: avoid_print
      print('PROBE[源清单-追加后] $all');
      expect(all.length, BookSourceDirectory.directoryUrls.length + 1);
      expect(all.last, 'https://my-mirror.example/list.md');

      // 重复追加（带尾部斜杠 / 换协议）→ 不重复
      await BookSourceDirectory.addCustomSource('https://my-mirror.example/list.md/');
      await BookSourceDirectory.addCustomSource('http://my-mirror.example/list.md');
      all = await BookSourceDirectory.allSources();
      // ignore: avoid_print
      print('PROBE[源清单-去重后] $all');
      expect(all.length, BookSourceDirectory.directoryUrls.length + 1);

      // 与内置重复（同一个地址）→ 也不重复
      await BookSourceDirectory.addCustomSource('https://getzlib.com/');
      all = await BookSourceDirectory.allSources();
      expect(all.length, BookSourceDirectory.directoryUrls.length + 1,
          reason: '自定义里内置已存在的地址要被去重掉');

      // 删除
      final List<String> after =
          await BookSourceDirectory.removeCustomSource('my-mirror.example/list.md');
      expect(after, isEmpty);
      all = await BookSourceDirectory.allSources();
      expect(all.length, BookSourceDirectory.directoryUrls.length);
    });

    test('非法地址被拒绝（不写进去）', () async {
      for (final String bad in <String>['', '   ', 'ftp://x.example/', '不是地址']) {
        final List<String> after = await BookSourceDirectory.addCustomSource(bad);
        // ignore: avoid_print
        print('PROBE[非法源] "$bad" → $after');
        expect(after, isEmpty, reason: '非法地址不能进列表：$bad');
      }
      expect(BookSourceDirectory.normalizeSourceUrl('ftp://x.example/'), isNull);
      expect(BookSourceDirectory.normalizeSourceUrl(''), isNull);
      expect(BookSourceDirectory.normalizeSourceUrl('example.com'),
          'https://example.com');
    });

    test('自定义源会真的被并行检索（作为兜底）', () async {
      await BookSourceDirectory.addCustomSource('https://custom.example/mirrors.md');
      final List<String> hit = <String>[];
      final http.Client client = MockClient((http.Request request) async {
        final String url = request.url.toString();
        hit.add(url);
        if (url.contains('custom.example')) {
          return http.Response.bytes(
            utf8.encode('| 镜像 | 状态 |\n| --- | --- |\n'
                '| [https://fromcustom.example/](https://fromcustom.example/) | ✅ |\n'),
            200,
            headers: <String, String>{'content-type': 'text/plain; charset=utf-8'},
          );
        }
        return http.Response('', 500); // 内置两个都挂
      });

      final DirectoryResult result =
          await BookSourceDirectory.fetch(client: client, forceRefresh: true);
      // ignore: avoid_print
      print('PROBE[自定义源兜底] source=${result.sourceUrl} '
          'entries=${result.entries.map((e) => "${e.host}(${e.status})").toList()} hit=$hit');

      expect(result.entries.any((MirrorEntry e) => e.host == 'fromcustom.example'),
          isTrue,
          reason: '内置源全挂时，自定义源要能顶上');
      expect(hit.any((String u) => u.contains('custom.example')), isTrue);
    });
  });
}

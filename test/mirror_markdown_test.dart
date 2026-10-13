import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/book_source_directory.dart';

/// Awesome-Zlibrary Markdown 镜像表（v1.21.24）
///
/// 片段**抄自实抓的 README**（2026-10-10 抓
/// `raw.githubusercontent.com/dongyubin/Awesome-Zlibrary/main/README.md`，13,302 字节）：
/// - 镜像表是**两列**：`| [url](url) | ✅ |`
/// - 状态列可能带后缀：`✅（2026年6月13日）`
/// - 第 1 行是 `http://`（不是 https）
/// - ⚠️ README 里还有一张 6 列的"访问方案对比表"也带 ✅/❌ —— 必须靠**列数**排除
const String _readmeSnippet = '''
| 访问方案 | 需要代理 | 能否下载 | 次数限制 | 稳定性 | 适合人群 |
| ------------------------------------------------------------ | ------------ | ------------ | ---------------------------- | ------ | -------- |
| 国内可直连镜像域名（下表 ✅ 项） | ❌ 不需要 | ✅ 可以 | 游客 5 次/日 | 高（域名会轮换） | 绝大多数国内用户，首选 |
| [plainproxies](https://plainproxies.com/resources/free-web-proxy) 网页代理 | ❌ 不需要 | ✅ 可以（站内跳转需复制链接） | 同上 | 中 | 临时应急查书 |
| 第三方客户端 [O-lib](#zlibrary-第三方客户端) | ❌ 不需要（免梯高速下载） | ✅ 需要填写当前可用域名 | 无限制 | 中 | 高级用户 |

## Zlibrary官方最新网址合集

| 镜像域名 | 国内直连 |
| ------------------------------------------------------------ | ------------------ |
| [http://z-lib.sk/](http://z-lib.sk/)                         | ✅                  |
| [https://z-lib.fm/](https://z-lib.fm/)                       | ✅                  |
| [https://zh.z-lib.gd/](https://zh.z-lib.gd/)                 | ✅                  |
| [https://zh.zlib.li/](https://zh.zlib.li/)                   | ✅（2026年6月13日） |
| [https://zh.intcn.online/](https://zh.intcn.online/)（官方地址） | ✅                  |
| [https://dead.example/](https://dead.example/)               | ❌                  |
| [https://slow.example/](https://slow.example/)               | ⚠️                  |
| https://bare.example/                                        | ✅                  |
| [相对路径](/mirror)                                          | ✅                  |
| [锚点](#top)                                                 | ✅                  |
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    BookSourceDirectory.clearCacheForTest();
  });

  group('parseMirrorMarkdown 正常输入', () {
    test('两列表格行：带链接 / 裸 URL 都提取，✅⚠❌ 映射到 UP/DEGRADED/DOWN', () {
      final List<MirrorEntry> entries = BookSourceDirectory.parseMirrorMarkdown(_readmeSnippet);
      final Map<String, String> byHost = <String, String>{
        for (final MirrorEntry e in entries) e.host: e.status,
      };
      // ignore: avoid_print
      print('PROBE[Markdown] ${entries.map((e) => "${e.host}(${e.status})").toList()}');

      expect(byHost['z-lib.sk'], 'UP', reason: 'http:// 也要收（README 第 1 行就是 http）');
      expect(byHost['z-lib.fm'], 'UP');
      expect(byHost['zh.zlib.li'], 'UP', reason: '✅（2026年6月13日）这种带后缀也要认');
      expect(byHost['zh.intcn.online'], 'UP', reason: '链接后面还有「（官方地址）」也要认');
      expect(byHost['dead.example'], 'DOWN');
      expect(byHost['slow.example'], 'DEGRADED');
      expect(byHost['bare.example'], 'UP', reason: '没有链接格式的裸 URL 也要收');
    });

    test('6 列的"访问方案对比表"不能被当成镜像（列数是判据）', () {
      final List<MirrorEntry> entries = BookSourceDirectory.parseMirrorMarkdown(_readmeSnippet);
      final List<String> hosts = entries.map((MirrorEntry e) => e.host).toList();
      expect(hosts, isNot(contains('plainproxies.com')),
          reason: '对比表里的链接不是镜像域名');
      expect(hosts.length, greaterThanOrEqualTo(7));
    });

    test('相对路径 / 锚点 被跳过', () {
      final List<MirrorEntry> entries = BookSourceDirectory.parseMirrorMarkdown(_readmeSnippet);
      expect(entries.any((MirrorEntry e) => e.url.contains('/mirror')), isFalse);
      expect(entries.any((MirrorEntry e) => e.url.contains('#top')), isFalse);
    });

    test('同一 host 出现多次：保留状态最好的那条（UP > DEGRADED > UNKNOWN > DOWN）', () {
      const String md = '''
| 镜像域名 | 状态 |
| --- | --- |
| [https://dup.example/](https://dup.example/) | ❌ |
| [https://dup.example/](https://dup.example/) | ✅ |
| [https://dup2.example/](https://dup2.example/) | ⚠️ |
| [https://dup2.example/](https://dup2.example/) | ✅ |
''';
      final List<MirrorEntry> entries = BookSourceDirectory.parseMirrorMarkdown(md);
      final Map<String, String> byHost = <String, String>{
        for (final MirrorEntry e in entries) e.host: e.status,
      };
      // ignore: avoid_print
      print('PROBE[去重] $byHost');
      expect(byHost['dup.example'], 'UP');
      expect(byHost['dup2.example'], 'UP');
      expect(entries.length, 2, reason: '同一 host 只留一条');
    });

    test('文本状态列（UP / DOWN / PROTECTED）也认', () {
      const String md = '''
| 镜像域名 | 状态 |
| --- | --- |
| [https://a.example/](https://a.example/) | UP |
| [https://b.example/](https://b.example/) | PROTECTED |
| [https://c.example/](https://c.example/) | DOWN |
''';
      final Map<String, String> byHost = <String, String>{
        for (final MirrorEntry e in BookSourceDirectory.parseMirrorMarkdown(md))
          e.host: e.status,
      };
      expect(byHost['a.example'], 'UP');
      expect(byHost['b.example'], 'PROTECTED');
      expect(byHost['c.example'], 'DOWN');
    });
  });

  group('parseMirrorMarkdown 异常输入（一律返回空，不抛）', () {
    test('空串 / 纯文本 / 只有竖线但结构不对', () {
      for (final String bad in <String>[
        '',
        '   ',
        '这是一段普通说明文字，没有任何表格。',
        '|',
        '||',
        '| 只有一列 |',
        '| 两列但第一列不是网址 | ✅ |',
      ]) {
        final List<MirrorEntry> entries = BookSourceDirectory.parseMirrorMarkdown(bad);
        // ignore: avoid_print
        print('PROBE[坏输入] "${bad.replaceAll("\n", " ")}" → ${entries.length} 条');
        expect(entries, isEmpty, reason: '坏输入要优雅降级：$bad');
      }
    });

    test('parse() 喂 Markdown：安全返回空（不误判、不抛）', () {
      expect(BookSourceDirectory.parse(_readmeSnippet), isEmpty);
      expect(() => BookSourceDirectory.parse(_readmeSnippet), returnsNormally);
    });
  });

  group('端到端：Markdown 源顶上', () {
    test('open-slum 与 getzlib 都挂时，从 raw.githubusercontent 拿到域名', () async {
      final List<String> hit = <String>[];
      final http.Client client = MockClient((http.Request request) async {
        final String url = request.url.toString();
        hit.add(url);
        if (url.contains('raw.githubusercontent.com')) {
          // ⚠️ http 包把请求头名统一成小写
          expect(request.headers['accept'], 'text/plain',
              reason: '抓 Markdown 时应当发 text/plain');
          // ⚠️ 必须给**字节**：`http.Response(String)` 默认按 latin1 编码，
          // 中文与 ✅ 会被编坏（真实 GitHub raw 返回的就是 UTF-8 字节）
          return http.Response.bytes(
            utf8.encode(_readmeSnippet),
            200,
            headers: <String, String>{'content-type': 'text/plain; charset=utf-8'},
          );
        }
        return http.Response('boom', 502); // 两个状态站都挂
      });

      final DirectoryResult result =
          await BookSourceDirectory.fetch(client: client, forceRefresh: true, probe: false);
      // ignore: avoid_print
      print('PROBE[端到端] source=${result.sourceUrl} '
          '条数=${result.entries.length} 前几个=${result.entries.take(4).map((e) => "${e.host}(${e.status})").toList()}');

      expect(result.entries, isNotEmpty, reason: '两个状态站都挂时，Markdown 源要顶上');
      expect(result.sourceUrl, contains('raw.githubusercontent.com'));
      expect(result.entries.any((MirrorEntry e) => e.usable), isTrue);
      expect(hit.length, greaterThanOrEqualTo(3), reason: '三个源都要被请求到');
    });
  });
}

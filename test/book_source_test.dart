import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/book_source_directory.dart';

/// 镜像状态站（open-slum.org）解析验证。
///
/// 内置固定域名很快就会失效（这类站点换域名很频繁），所以改成「现查现用」：
/// 解析必须稳、改版时不能崩，这是这组测试要守的东西。
void main() {
  /// 与状态站真实结构一致的一小段标记（.site-card / .domain-item-dense / .status-badge）
  String page() => '''
<!DOCTYPE html><html><body>
  <div class="site-card">
    <div class="site-card-header">
      <a href="libgen.html" class="site-card-title">libgen</a>
      <span class="status-badge up">UP</span>
    </div>
    <ul class="domain-list-dense">
      <li class="domain-item-dense">
        <div class="domain-left-group">
          <a href="https://libgen.bz" class="domain-link" target="_blank" rel="noopener noreferrer" title="https://libgen.bz">
            libgen.bz
          </a>
        </div>
        <div class="status-col">
          <a href="libgen.html#libgen.bz" class="status-badge compact up" title="UP - Click for details">UP</a>
        </div>
      </li>
    </ul>
  </div>
  <div class="site-card">
    <div class="site-card-header">
      <a href="zlibrary.html" class="site-card-title">zlibrary</a>
      <span class="status-badge up">UP</span>
    </div>
    <div class="site-mini-summary">
      <span>6 domains</span>
      <span class="count" style="color: #3fb950;">6 PROTECTED</span>
    </div>
    <ul class="domain-list-dense">
      <li class="domain-item-dense">
        <div class="domain-left-group">
          <a href="https://z-library.sk" class="domain-link" target="_blank" rel="noopener noreferrer" title="https://z-library.sk">
            z-library.sk
          </a>
        </div>
        <div class="status-col">
          <a href="zlibrary.html#zlibrary.sk" class="status-badge compact protected" title="PROTECTED - Click for details">PROTECTED</a>
        </div>
      </li>
      <li class="domain-item-dense">
        <div class="domain-left-group">
          <a href="https://z-lib.gl" class="domain-link" target="_blank" rel="noopener noreferrer" title="https://z-lib.gl">
            z-lib.gl
          </a>
        </div>
        <div class="status-col">
          <a href="zlibrary.html#zlibrary.gl" class="status-badge compact down" title="DOWN - Click for details">DOWN</a>
        </div>
      </li>
      <li class="domain-item-dense">
        <div class="domain-left-group">
          <a href="https://1lib.sk" class="domain-link" target="_blank" rel="noopener noreferrer" title="https://1lib.sk">
            1lib.sk
          </a>
        </div>
        <div class="status-col">
          <a href="zlibrary.html#zlibrary.1lib" class="status-badge compact up" title="UP - Click for details">UP</a>
        </div>
      </li>
    </ul>
  </div>
</body></html>
''';

  group('解析可用域名', () {
    test('只取指定服务的域名，不混入别的服务', () {
      final entries = BookSourceDirectory.parse(page(), service: 'zlibrary');
      expect(entries.map((entry) => entry.host), containsAll(<String>['z-library.sk', 'z-lib.gl', '1lib.sk']));
      expect(
        entries.any((entry) => entry.host == 'libgen.bz'),
        isFalse,
        reason: 'libgen 那一节不该被算进来',
      );
    });

    test('读得出状态，并且可用的排在前面', () {
      final entries = BookSourceDirectory.parse(page(), service: 'zlibrary');
      expect(entries.length, 3);
      expect(entries.last.host, 'z-lib.gl', reason: 'DOWN 的排最后');
      expect(entries.last.usable, isFalse);
      expect(entries.take(2).every((entry) => entry.usable), isTrue);
      expect(entries.firstWhere((entry) => entry.host == 'z-library.sk').status, 'PROTECTED');
      expect(entries.firstWhere((entry) => entry.host == '1lib.sk').status, 'UP');
    });

    test('换服务也一样能解析', () {
      final entries = BookSourceDirectory.parse(page(), service: 'libgen');
      expect(entries.length, 1);
      expect(entries.single.host, 'libgen.bz');
      expect(entries.single.usable, isTrue);
    });

    test('找不到的服务 / 空页面 / 垃圾内容都返回空，不抛异常', () {
      expect(BookSourceDirectory.parse(page(), service: 'scihub'), isEmpty);
      expect(BookSourceDirectory.parse(''), isEmpty);
      expect(BookSourceDirectory.parse('这不是网页'), isEmpty);
      expect(BookSourceDirectory.parse('<html><body>改版了</body></html>'), isEmpty);
    });

    test('状态站改版（类名没了）时退化成扫链接，仍能拿到域名', () {
      // 去掉所有 class，只留结构：DOM 解析拿不到，应当走兜底
      final stripped = page()
          .replaceAll(RegExp(r'class="[^"]*"'), '')
          .replaceAll('domain-link', 'x')
          .replaceAll('site-card-title', 'y');
      final entries = BookSourceDirectory.parse(stripped, service: 'zlibrary');
      expect(entries.map((entry) => entry.host), contains('z-library.sk'));
      expect(entries.any((entry) => entry.host == 'libgen.bz'), isFalse);
    });

    test('状态文案与可用性判定', () {
      const up = MirrorEntry(url: 'https://a.com', host: 'a.com', status: 'UP');
      const protectedEntry = MirrorEntry(url: 'https://b.com', host: 'b.com', status: 'PROTECTED');
      const down = MirrorEntry(url: 'https://c.com', host: 'c.com', status: 'DOWN');
      expect(up.usable, isTrue);
      expect(protectedEntry.usable, isTrue, reason: 'PROTECTED 只是挡了探测，浏览器里能打开');
      expect(down.usable, isFalse);
      expect(up.statusLabel, '可用');
      expect(protectedEntry.statusLabel, contains('可用'));
      expect(down.statusLabel, '不可用');
    });

    test('可选服务里带上了 zlibrary', () {
      expect(
        BookSourceDirectory.services.any((item) => item.$1 == 'zlibrary'),
        isTrue,
      );
      expect(BookSourceDirectory.directoryUrl, startsWith('https://'));
    });
  });
}

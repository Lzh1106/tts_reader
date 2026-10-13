import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 一个镜像域名及其可用状态
class MirrorEntry {
  const MirrorEntry({required this.url, required this.host, required this.status});

  /// 完整网址（带 https://）
  final String url;

  /// 域名（展示用）
  final String host;

  /// 站点状态：UP / PROTECTED / DEGRADED / DOWN / TIMEOUT / UNKNOWN
  ///
  /// 「PROTECTED」表示站点活着、只是挡了探测请求（这类站点在浏览器里能正常打开），
  /// 所以 UP 与 PROTECTED 都算可用。
  final String status;

  /// 能不能用
  bool get usable => status == 'UP' || status == 'PROTECTED';

  /// 状态的中文说明
  String get statusLabel => switch (status) {
    'UP' => '可用',
    'PROTECTED' => '可用（有防护）',
    'DEGRADED' => '不稳定',
    'DOWN' => '不可用',
    'TIMEOUT' => '超时',
    _ => '未知',
  };

  Map<String, String> toJson() => <String, String>{
        'url': url,
        'host': host,
        'status': status,
      };

  static MirrorEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url'];
    final host = raw['host'];
    final status = raw['status'];
    if (url is! String || host is! String || status is! String) return null;
    return MirrorEntry(url: url, host: host, status: status);
  }

  @override
  String toString() => '$host($status)';
}

/// 一次「检索可用域名」的结果
///
/// v1.21.22：从 `List<MirrorEntry>` 升级成对象 —— 界面需要知道
/// **数据来自哪个源**、**是不是缓存**、**是不是所有源都挂了**，
/// 才能在全部失败时给出「去手动书源」的明确提示（而不是空列表干瞪眼）。
class DirectoryResult {
  const DirectoryResult({
    required this.entries,
    this.sourceUrl,
    this.fromCache = false,
    this.failedSources = const <String>[],
    this.probed = false,
    this.sourceCount = 0,
  });

  final List<MirrorEntry> entries;

  /// 这份数据来自哪个源（缓存命中时是当初写缓存的那个源）
  final String? sourceUrl;

  /// 是否来自本地缓存（界面可标注"缓存于 …"）
  final bool fromCache;

  /// 这次没成功的源（全部失败时用它给提示）
  final List<String> failedSources;

  /// 一条都没有
  bool get isEmpty => entries.isEmpty;

  /// 所有候选源都没给出结果
  bool get allFailed => entries.isEmpty;

  /// 这份结果里**本机实测可达**的条数（探测过才有意义）
  int get reachableCount => entries.where((MirrorEntry e) => e.usable).length;

  /// 是否做过本机连通性实测
  final bool probed;

  /// 这次一共问了几个源（内置 + 自定义）
  final int sourceCount;
}

/// 从公开的镜像状态站检索可用域名（多源聚合 + 本地缓存）
///
/// 为什么这样做而不是内置一份域名表：Z-Library 这类站点换域名非常频繁，
/// 写死在应用里的地址过几周就会失效。
///
/// v1.21.22 两处加固（用户反馈「经常连不上」）：
/// 1. **多源聚合**：[directoryUrls] 里的源**并行**请求，谁先给出非空结果就用谁；
/// 2. **本地缓存**：[cacheTtl] 内直接用上次结果，不再打网络。
class BookSourceDirectory {
  BookSourceDirectory._();

  /// 主源（状态板，结构最全）。
  ///
  /// ⚠️ 保留这个常量：`storage_service` 里的默认书签（`annas.html` /
  /// `libgen.html` 等页面路径）与界面文案都按它拼 URL，别改成列表。
  static const String directoryUrl = 'https://open-slum.org/';

  /// 候选源列表：**并行**请求，任意一个先成功就用。
  ///
  /// 2026-10-10 实测（抓取环境：本机直连）：
  /// - `open-slum.org` ✅ 200 / 99 KB 正常；
  /// - `getzlib.com` ✅ 200 / 133 KB（首包偶发慢，20s 会超时、90s 能抓全）；
  /// - `zlib.wwkejishe.top` ❌ 连接超时（20s 无响应）→ **未收录**。
  static const List<String> directoryUrls = <String>[
    'https://open-slum.org/',
    'https://getzlib.com/',
    // v1.21.24 新增：GitHub 上的社区维护镜像列表（人工验证，更新较慢但结构稳定）
    'https://raw.githubusercontent.com/dongyubin/Awesome-Zlibrary/main/README.md',
  ];

  /// 默认检索的服务
  static const String defaultService = 'zlibrary';

  /// 可选的服务（对应状态站上的分节）
  static const List<(String, String)> services = <(String, String)>[
    ('zlibrary', 'Z-Library'),
    ('annas', "Anna's Archive"),
    ('libgen', 'Library Genesis'),
    ('scihub', 'Sci-Hub'),
  ];

  static const Duration timeout = Duration(seconds: 20);

  /// 缓存有效期：2 小时内不再请求网络
  static const Duration cacheTtl = Duration(hours: 2);

  /// 缓存键前缀
  static const String _cachePrefix = 'book_source_cache_';

  /// 进程内缓存（同一进程里连开两次不读盘）
  static final Map<String, DirectoryResult> _memory = <String, DirectoryResult>{};
  static final Map<String, DateTime> _memoryAt = <String, DateTime>{};

  /// 取当前时间（测试可替换）
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// 检索某个服务的镜像列表
  ///
  /// 流程：多源并行取列表 → **本机连通性实测** → 命中缓存。
  /// [forceRefresh] 为真时跳过缓存（界面上的"刷新"按钮用）。
  static Future<DirectoryResult> fetch({
    String service = defaultService,
    http.Client? client,
    bool forceRefresh = false,
    bool probe = true,
  }) async {
    if (!forceRefresh) {
      final cached = await _readCache(service);
      if (cached != null) return cached;
    }
    final own = client == null;
    final http.Client httpClient = client ?? http.Client();
    try {
      final List<String> sources = await allSources();
      final DirectoryResult raw = await _fetchAll(httpClient, service, sources);
      if (raw.entries.isEmpty) return raw;
      // 本机实测：状态站说 UP 不等于**本机**连得上（探测点在国外/也在轮换）
      final List<MirrorEntry> probed =
          probe ? await probeAll(raw.entries, client: httpClient) : raw.entries;
      final DirectoryResult result = DirectoryResult(
        entries: probed,
        sourceUrl: raw.sourceUrl,
        failedSources: raw.failedSources,
        probed: probe,
        sourceCount: sources.length,
      );
      await _writeCache(service, result);
      return result;
    } finally {
      if (own) httpClient.close();
    }
  }

  // ---------------- 本机连通性实测（v1.21.24 新增） ----------------

  /// 探测单个域名的本机可达性（默认 6 秒超时）
  static const Duration probeTimeout = Duration(seconds: 6);

  /// 并发上限：一次别把手机网络打满
  static const int probeConcurrency = 6;

  /// 并发探测「本机能不能连上」，把结果写回 [MirrorEntry.status]
  ///
  /// 口径：
  /// - **2xx/3xx → 保留原状态**（本来标 UP/PROTECTED 就仍是"可用"；标 DOWN 的升为 UP，
  ///   因为本机确实连上了 —— 这正是"状态站说不可用、其实能用"的情形）；
  /// - **401/403/407 → `DOWN`（不可达）**：⚠️ 这条按用户口径改过 ——
  ///   档了探测请求（Cloudflare 挑战页等）在**本机就是打不开**，算可用会让用户白点一次；
  /// - 其它 4xx/5xx → `DEGRADED`；
  /// - 超时 → `TIMEOUT`；其它网络错误 → `DOWN`；
  /// - 一条都失败不影响别的（每个都是独立 try）。
  ///
  /// 失败不影响功能：探测本身抛错时返回原始列表。
  static Future<List<MirrorEntry>> probeAll(
    List<MirrorEntry> entries, {
    http.Client? client,
    Duration? timeout,
    int concurrency = probeConcurrency,
  }) async {
    if (entries.isEmpty) return entries;
    final own = client == null;
    final http.Client httpClient = client ?? http.Client();
    final Duration limit = timeout ?? probeTimeout;
    final List<MirrorEntry?> out = List<MirrorEntry?>.filled(entries.length, null);
    var next = 0;
    try {
      Future<void> worker() async {
        while (true) {
          final int index = next++;
          if (index >= entries.length) return;
          out[index] = await _probeOne(httpClient, entries[index], limit);
        }
      }

      final int workers =
          concurrency < 1 ? 1 : (concurrency > entries.length ? entries.length : concurrency);
      await Future.wait(<Future<void>>[for (var i = 0; i < workers; i++) worker()]);
      return _sorted(<MirrorEntry>[
        for (var i = 0; i < out.length; i++) out[i] ?? entries[i],
      ]);
    } catch (_) {
      return entries; // 探测整体失败：原样返回，不影响"检索"这件事本身
    } finally {
      if (own) httpClient.close();
    }
  }

  static Future<MirrorEntry> _probeOne(
    http.Client client,
    MirrorEntry entry,
    Duration limit,
  ) async {
    final Uri? uri = Uri.tryParse(entry.url);
    if (uri == null || uri.host.isEmpty) {
      return MirrorEntry(url: entry.url, host: entry.host, status: 'DOWN');
    }
    try {
      // 用 send 只取状态码，不把整页拉下来（镜像站首页可能很大）
      final http.StreamedResponse response = await client
          .send(http.Request('GET', uri)
            ..headers['Accept'] = 'text/html'
            ..headers['User-Agent'] = 'Mozilla/5.0 (tts_reader)')
          .timeout(limit);
      // 状态码到手就断开，不读 body
      unawaited(response.stream.listen(null).cancel());
      final int code = response.statusCode;
      final String status;
      if (code >= 200 && code < 400) {
        status = entry.usable ? entry.status : 'UP';
      } else if (code == 401 || code == 403 || code == 407) {
        status = 'DOWN'; // 被档 = 本机打不开（用户口径：算不可达）
      } else {
        status = 'DEGRADED';
      }
      return MirrorEntry(url: entry.url, host: entry.host, status: status);
    } on TimeoutException {
      return MirrorEntry(url: entry.url, host: entry.host, status: 'TIMEOUT');
    } catch (_) {
      return MirrorEntry(url: entry.url, host: entry.host, status: 'DOWN');
    }
  }

  // ---------------- 自定义状态源（v1.21.24 新增） ----------------

  static const String _customKey = 'book_source_custom_directories';

  /// 用户自定义状态源（持久化）
  ///
  /// 为什么要留这个口子：内置源哪天全挂了（站点改版 / 换域名），用户还能自己
  /// 贴一个状态页或 Markdown 列表地址救急 —— 这是最后兜底。
  static Future<List<String>> loadCustomSources() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final List<String>? raw = sp.getStringList(_customKey);
      return raw ?? const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  /// 追加一个自定义源；返回最新列表（**去重**：见 [_dedupeKey]）
  ///
  /// ⚠️ 去重必须按"忽略协议 + 忽略尾部斜杠"的键来比：
  /// 用户很可能把 `https://a.com/x.md` 和 `http://a.com/x.md/` 都贴一遍；
  /// 只比字符串会重复加（测试里实测过）。**内置源也要一起比**，
  /// 否则用户贴一个内置已有的地址会在列表里多出一条。
  static Future<List<String>> addCustomSource(String url) async {
    final String? normalized = normalizeSourceUrl(url);
    final List<String> current = await loadCustomSources();
    if (normalized == null) return current;
    final String key = _dedupeKey(normalized);
    final Set<String> existing = <String>{
      ...directoryUrls.map(_dedupeKey),
      ...current.map(_dedupeKey),
    };
    if (existing.contains(key)) return current; // 已存在（含内置）：不重复
    final List<String> next = <String>[...current, normalized];
    await _saveCustomSources(next);
    return next;
  }

  /// 删掉一个自定义源；返回最新列表
  static Future<List<String>> removeCustomSource(String url) async {
    final String? normalized = normalizeSourceUrl(url);
    final String? key = normalized == null ? null : _dedupeKey(normalized);
    final List<String> current = await loadCustomSources();
    final List<String> next = current
        .where((String item) => key == null || _dedupeKey(item) != key)
        .toList();
    if (next.length != current.length) await _saveCustomSources(next);
    return next;
  }

  static Future<void> _saveCustomSources(List<String> urls) async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setStringList(_customKey, urls);
    } catch (_) {
      // 存不下就只影响下次启动，不影响这次
    }
  }

  /// 规范化用户输入的地址：补协议、去尾部斜杠、去 query/fragment
  ///
  /// 返回 null = 不是合法的 http(s) 地址（调用方据此提示用户）。
  ///
  /// ⚠️ host 必须是**纯 ASCII 且带点**：否则 `不是地址` 这种输入会被
  /// `Uri.tryParse` 当成 IDN 主机收下（实测：变成 `https://%E4%B8%8D...`），
  /// 用户会看到一个永远查不出东西的源。
  static String? normalizeSourceUrl(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'https://$text';
    final Uri? uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    final String host = uri.host;
    if (!RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(host) || !host.contains('.')) {
      return null;
    }
    final String path = uri.path == '/' ? '' : uri.path;
    final String normalized = '${uri.scheme}://$host$path';
    return normalized.endsWith('/') && normalized.length > 8
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
  }

  /// 内置 + 自定义（去重、保持顺序：内置在前）
  static Future<List<String>> allSources() async {
    final List<String> custom = await loadCustomSources();
    final List<String> out = <String>[...directoryUrls];
    final Set<String> seen = out.map((String u) => _dedupeKey(u)).toSet();
    for (final String item in custom) {
      final String? normalized = normalizeSourceUrl(item);
      if (normalized == null) continue;
      if (seen.add(_dedupeKey(normalized))) out.add(normalized);
    }
    return out;
  }

  /// 去重键：忽略协议与尾部斜杠差异（`http://a.com/` 与 `https://a.com` 视为同一个）
  static String _dedupeKey(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return url;
    final String path = uri.path == '/' ? '' : uri.path;
    return '${uri.host}$path'.toLowerCase();
  }

  /// 并行打所有候选源，第一个给出非空结果的胜出
  static Future<DirectoryResult> _fetchAll(
    http.Client client,
    String service,
    List<String> sources,
  ) async {
    final Completer<DirectoryResult> done = Completer<DirectoryResult>();
    final List<String> failed = <String>[];
    var remaining = sources.length;

    void finish() {
      if (remaining > 0 || done.isCompleted) return;
      // 全部打完还是没有结果：明确告知失败，界面据此提示手动书源
      done.complete(DirectoryResult(
        entries: const <MirrorEntry>[],
        failedSources: List<String>.of(failed),
        sourceCount: sources.length,
      ));
    }

    for (final String url in sources) {
      unawaited(() async {
        List<MirrorEntry> entries = const <MirrorEntry>[];
        try {
          entries = await fetchFrom(url, service: service, client: client);
        } catch (_) {
          entries = const <MirrorEntry>[];
        }
        if (entries.isNotEmpty) {
          if (!done.isCompleted) {
            // 只交付原始结果；**缓存留给 fetch 写**（那里写的是本机实测之后的状态）
            done.complete(DirectoryResult(
              entries: entries,
              sourceUrl: url,
              failedSources: List<String>.of(failed),
              sourceCount: sources.length,
            ));
          }
        } else {
          failed.add(url);
        }
        remaining--;
        finish();
      }());
    }
    return done.future;
  }

  /// 从**指定**源抓一页并解析（给测试与调试用）
  ///
  /// 三档解析（按源的结构分派，取到就返回）：
  /// 1. 状态板结构（open-slum 的 `.site-card`）；拿不到再退化成扫链接；
  /// 2. **Markdown 镜像表**（Awesome-Zlibrary 这类社区维护的 README）；
  /// 3. getzlib 的域名指引页。
  static Future<List<MirrorEntry>> fetchFrom(
    String url, {
    String service = defaultService,
    http.Client? client,
  }) async {
    final own = client == null;
    final http.Client httpClient = client ?? http.Client();
    try {
      final http.Response response = await httpClient
          .get(Uri.parse(url), headers: <String, String>{'Accept': _acceptFor(url)})
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw StateError('$url 返回 ${response.statusCode}');
      }
      // 页面是 UTF-8：用 bodyBytes 自己解码，别依赖响应头里的 charset
      final String html = utf8.decode(response.bodyBytes, allowMalformed: true);
      return parseAny(html, service: service, sourceUrl: url);
    } finally {
      if (own) httpClient.close();
    }
  }

  /// 请求头：抓 Markdown 时发 `text/plain`（GitHub raw 不挑，但更干净）
  static String _acceptFor(String url) {
    final String lower = url.toLowerCase();
    if (lower.endsWith('.md') || lower.contains('raw.githubusercontent.com')) {
      return 'text/plain';
    }
    return 'text/html';
  }

  /// 按源的特征分派解析器（纯函数，便于单测）
  ///
  /// ⚠️ Markdown 那一档的判据故意宽松（有 `|` 且有 ✅ / 提到 Z-Library / 是那个仓库），
  /// 但**解析器本身**足够严（只认两列行），认不出来就返回空 → 不会污染结果。
  static List<MirrorEntry> parseAny(
    String text, {
    String service = defaultService,
    String sourceUrl = '',
  }) {
    // ① 状态板结构
    final List<MirrorEntry> byService = parse(text, service: service);
    if (byService.isNotEmpty) return byService;

    // ② Markdown 镜像表（Awesome-Zlibrary）
    if (text.contains('|') &&
        (text.contains('✅') ||
            text.contains('Z-Library') ||
            sourceUrl.contains('Awesome-Zlibrary'))) {
      final List<MirrorEntry> marked = parseMirrorMarkdown(text);
      if (marked.isNotEmpty) return marked;
    }

    // ③ getzlib 域名指引页
    if (sourceUrl.contains('getzlib') || text.contains('Listed domain')) {
      return parseGetZlib(text);
    }
    return const <MirrorEntry>[];
  }

  // ---------------- 缓存 ----------------

  static String _cacheKey(String service) => '$_cachePrefix$service';

  static Future<DirectoryResult?> _readCache(String service) async {
    final DateTime now = clock();
    // ① 进程内
    final DirectoryResult? mem = _memory[service];
    final DateTime? memAt = _memoryAt[service];
    // ⚠️ 时间戳在"未来"（时钟被改过 / 时区调整）一律当过期：
    // 否则 difference 为负数，永远 `< cacheTtl`，缓存就再也不失效了。
    if (mem != null &&
        memAt != null &&
        !now.isBefore(memAt) &&
        now.difference(memAt) < cacheTtl) {
      return DirectoryResult(
        entries: mem.entries,
        sourceUrl: mem.sourceUrl,
        fromCache: true,
        failedSources: mem.failedSources,
      );
    }
    // ② 落盘
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final String? raw = sp.getString(_cacheKey(service));
      if (raw == null || raw.isEmpty) return null;
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final int at = (decoded['at'] as num?)?.toInt() ?? 0;
      final DateTime cachedAt = DateTime.fromMillisecondsSinceEpoch(at);
      if (now.isBefore(cachedAt)) return null; // 未来时间戳：当过期
      if (now.difference(cachedAt) >= cacheTtl) return null; // 过期
      final List<MirrorEntry> entries = <MirrorEntry>[];
      final Object? list = decoded['entries'];
      if (list is List) {
        for (final Object? item in list) {
          final MirrorEntry? entry = MirrorEntry.fromJson(item);
          if (entry != null) entries.add(entry);
        }
      }
      if (entries.isEmpty) return null;
      final DirectoryResult result = DirectoryResult(
        entries: entries,
        sourceUrl: decoded['source'] as String?,
        fromCache: true,
      );
      _memory[service] = result;
      _memoryAt[service] = cachedAt;
      return result;
    } catch (_) {
      return null; // 缓存坏了就当没有，不影响功能
    }
  }

  static Future<void> _writeCache(String service, DirectoryResult result) async {
    _memory[service] = result;
    _memoryAt[service] = clock();
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setString(
        _cacheKey(service),
        jsonEncode(<String, Object?>{
          'at': clock().millisecondsSinceEpoch,
          'source': result.sourceUrl,
          'entries': result.entries.map((MirrorEntry e) => e.toJson()).toList(),
        }),
      );
    } catch (_) {
      // 写缓存失败不影响这次结果
    }
  }

  /// 测试用：清掉两级缓存
  @visibleForTesting
  static void clearCacheForTest() {
    _memory.clear();
    _memoryAt.clear();
  }

  // ---------------- open-slum.org 解析 ----------------

  /// 解析状态站页面（纯函数，便于单测）
  ///
  /// 只认页面上的结构：每个服务是一张 `.site-card`，域名在 `.domain-item-dense` 里，
  /// 状态在 `.status-badge` 上。站点改版时返回空列表（调用方给提示），不会崩。
  ///
  /// 实测结构（2026-10-10 抓取，见交付物附录）：
  /// ```html
  /// <div class="site-card">
  ///   <div class="site-card-header">
  ///     <a href="annas.html" class="site-card-title">annas</a>
  ///     <span class="status-badge up">UP</span>
  ///   </div>
  ///   <ul class="domain-list-dense">
  ///     <li class="domain-item-dense">…<a class="domain-link" href="https://…">…</a>
  ///       <span class="status-badge up">UP</span>…</li>
  /// ```
  static List<MirrorEntry> parse(String htmlText, {String service = defaultService}) {
    if (htmlText.trim().isEmpty) return const <MirrorEntry>[];
    final List<MirrorEntry> entries;
    try {
      final document = html_parser.parse(htmlText);
      entries = _parseWithDom(document, service);
    } catch (_) {
      return const <MirrorEntry>[];
    }
    if (entries.isNotEmpty) return _sorted(entries);
    // 结构变了就退化成扫链接（至少还能拿到域名）
    return _sorted(_parseWithRegex(htmlText, service));
  }

  static List<MirrorEntry> _parseWithDom(dom.Document document, String service) {
    for (final card in document.querySelectorAll('.site-card')) {
      final title = card.querySelector('.site-card-title')?.text.trim().toLowerCase();
      if (title != service.toLowerCase()) continue;
      final entries = <MirrorEntry>[];
      for (final item in card.querySelectorAll('.domain-item-dense')) {
        final href = item.querySelector('a.domain-link')?.attributes['href'];
        if (href == null) continue;
        final status = item.querySelector('.status-badge')?.text.trim().toUpperCase() ?? 'UNKNOWN';
        entries.add(_entry(href, status));
      }
      return entries;
    }
    return const <MirrorEntry>[];
  }

  /// 兜底：按服务名切段，段内所有绝对链接都当域名，状态取链接之后最近的徽章文本
  static List<MirrorEntry> _parseWithRegex(String htmlText, String service) {
    final marker = RegExp('href="$service\\.html"', caseSensitive: false).firstMatch(htmlText);
    if (marker == null) return const <MirrorEntry>[];
    var section = htmlText.substring(marker.end);
    // 截到下一个服务分节为止
    final next = RegExp(r'href="[a-z0-9_-]+\.html"').firstMatch(section);
    if (next != null) section = section.substring(0, next.start);

    final entries = <MirrorEntry>[];
    final linkPattern = RegExp(r'href="(https?://[^"]+)"');
    for (final match in linkPattern.allMatches(section)) {
      final url = match.group(1)!;
      final window = section.substring(match.end, (match.end + 1200).clamp(0, section.length));
      final badge = RegExp(
        r'title="(UP|PROTECTED|DEGRADED|DOWN|TIMEOUT|UNKNOWN)',
        caseSensitive: false,
      ).firstMatch(window);
      entries.add(_entry(url, badge?.group(1)?.toUpperCase() ?? 'UNKNOWN'));
    }
    return entries;
  }

  // ---------------- Awesome-Zlibrary 风格 Markdown 解析（v1.21.24 新增） ----------------

  /// 解析 Awesome-Zlibrary 风格的 Markdown 镜像表格
  ///
  /// 认两种行：`| [url](url) | ✅ |` 与 `| url | ✅ |`（带不带链接都行）。
  /// 状态列支持 ✅ / ⚠️ / ❌ / UP / DOWN / PROTECTED。
  /// 解析不出来时返回空列表（不抛异常）。
  ///
  /// ## 实抓校准（2026-10-10 抓 `raw.githubusercontent.com/dongyubin/Awesome-Zlibrary/main/README.md`）
  ///
  /// 1. **只认"恰好两列"的行**（`| a | b |`）。README 里另有一张"访问方案对比表"，
  ///    同样带 ✅/❌，但它是 6 列：
  ///    `| [plainproxies](https://plainproxies.com/...) 网页代理 | ❌ 不需要 | ✅ 可以 | … |`
  ///    —— 只按"含 ✅"扫会把 plainproxies、`#锚点` 之类全收进来。列数是天然的分隔判据。
  /// 2. 状态列**可能带后缀**：`✅（2026年6月13日）`、`✅（官方地址）` → 用 `contains` 判。
  /// 3. 镜像行里第一列可能是 `http://`（第 59 行就是 `http://z-lib.sk/`）→ 两种协议都收。
  static List<MirrorEntry> parseMirrorMarkdown(String markdown) {
    if (markdown.trim().isEmpty) return const <MirrorEntry>[];
    // host → 目前状态最好的那条
    final Map<String, MirrorEntry> best = <String, MirrorEntry>{};
    for (final String raw in markdown.split('\n')) {
      final String line = raw.trim();
      if (!line.startsWith('|')) continue;
      final List<String> cells = line.split('|');
      // `| a | b |` 拆出来是 ['', ' a ', ' b ', ''] —— 恰好两列才是镜像表
      if (cells.length != 4) continue;
      final String first = cells[1].trim();
      final String second = cells[2].trim();
      if (first.isEmpty) continue;
      final String? url = _firstUrlIn(first);
      if (url == null) continue;
      final Uri? uri = Uri.tryParse(url);
      if (uri == null || uri.host.isEmpty) continue;
      if (uri.scheme != 'http' && uri.scheme != 'https') continue; // 相对 / 锚点 / 其它协议跳过
      final String host = uri.host.toLowerCase();
      final String status = _statusFromMark(second);
      // 判不出状态的行直接丢弃（v1.21.24 用户决定）：README 里另有若干两列表格
      // （官方/其它清单），它们没有状态列，收进来只会让选择面板变脏。
      if (status == 'UNKNOWN') continue;
      final MirrorEntry entry = MirrorEntry(url: url, host: host, status: status);
      final MirrorEntry? exists = best[host];
      if (exists == null || _statusRank(entry.status) > _statusRank(exists.status)) {
        best[host] = entry;
      }
    }
    return _sorted(best.values.toList());
  }

  /// 单元格里第一个链接的目标 URL；没有链接格式就认开头的裸 URL
  ///
  /// 例：`[https://z-lib.sk/](https://z-lib.sk/)（官方地址）` → `https://z-lib.sk/`
  static String? _firstUrlIn(String cell) {
    final RegExpMatch? link = RegExp(r'\[[^\]]*\]\(([^)]+)\)').firstMatch(cell);
    if (link != null) {
      final String target = link.group(1)!.trim();
      return target.isEmpty ? null : target;
    }
    final RegExpMatch? bare = RegExp(r'^(https?://\S+)').firstMatch(cell);
    return bare?.group(1);
  }

  /// 状态列 → 本工程的 status 词表
  ///
  /// ⚠️ 顺序要紧：`✅` 必须先判（有些行写成 `✅ 可以用，❌ 不需要` 这种复合说明）。
  static String _statusFromMark(String cell) {
    if (cell.contains('✅')) return 'UP';
    if (cell.contains('⚠')) return 'DEGRADED';
    if (cell.contains('❌')) return 'DOWN';
    final String upper = cell.toUpperCase();
    if (RegExp(r'\bPROTECTED\b').hasMatch(upper)) return 'PROTECTED';
    if (RegExp(r'\bUP\b').hasMatch(upper)) return 'UP';
    if (RegExp(r'\bDOWN\b').hasMatch(upper)) return 'DOWN';
    return 'UNKNOWN';
  }

  /// 状态好坏排序（同一 host 重复出现时留最好的那条）
  ///
  /// 任务书给的是 `UP > DEGRADED > UNKNOWN > DOWN`；`PROTECTED` 在本工程里
  /// 与 UP 同属"能用"（见 [MirrorEntry.usable]），所以排在 UP 之后、DEGRADED 之前。
  static int _statusRank(String status) => switch (status) {
        'UP' => 4,
        'PROTECTED' => 3,
        'DEGRADED' => 2,
        'UNKNOWN' => 1,
        _ => 0, // DOWN / TIMEOUT
      };

  // ---------------- getzlib.com 解析（v1.21.22 新增） ----------------

  /// 解析 `getzlib.com`（Z-Library 域名指引页）
  ///
  /// 它**不是状态板**，而是"当前推荐的域名 + 若干条候选 + Wikipedia 核对时间"。
  /// 实测结构（2026-10-10 抓取，见交付物附录）：
  /// ```html
  /// <span …>Listed domain</span>
  /// <a href="https://z-lib.sk/" aria-label="Visit https://z-lib.sk/">https://z-lib.sk/</a>
  /// …
  /// <div class="space-y-3">
  ///   <div class="…rounded-xl…">
  ///     <p class="break-words text-base font-medium text-foreground">https://z-lib.sk/</p>
  ///     <p class="text-xs text-muted-foreground">Link #1 · Wikipedia source checked 2026-10-10T08:27:48.701Z</p>
  ///     <a href="https://z-lib.sk/" …>…</a>
  ///   </div>
  /// ```
  /// 判据：**页面列出来的域名就是它当前推荐的可用域名** → 记为 UP
  /// （页面自带 Wikipedia 核对时间戳，比我们自己探活更省事）。
  static List<MirrorEntry> parseGetZlib(String htmlText) {
    if (htmlText.trim().isEmpty) return const <MirrorEntry>[];
    final List<MirrorEntry> entries = <MirrorEntry>[];
    final Set<String> seen = <String>{};
    try {
      final dom.Document document = html_parser.parse(htmlText);
      // ① `aria-label="Visit https://…"` 的锚点就是"列出的域名"
      for (final dom.Element a in document.querySelectorAll('a[aria-label^="Visit "]')) {
        final String? href = a.attributes['href'];
        if (href == null) continue;
        _addZLib(entries, seen, href);
      }
      // ② 候选列表里的 <p>https://…</p>（旁边带 "Link #N · … checked …"）
      for (final dom.Element p in document.querySelectorAll('p')) {
        final String text = p.text.trim();
        if (!text.startsWith('http')) continue;
        _addZLib(entries, seen, text);
      }
      // ③ 兜底：页面里所有 z-lib host 链接
      if (entries.isEmpty) {
        for (final dom.Element a in document.querySelectorAll('a[href]')) {
          _addZLib(entries, seen, a.attributes['href'] ?? '');
        }
      }
    } catch (_) {
      return const <MirrorEntry>[];
    }
    return _sorted(entries);
  }

  /// 只收 Z-Library 自家域名（`z-lib.*` / `zlibrary*` / `*.z-lib.*`）
  static void _addZLib(List<MirrorEntry> out, Set<String> seen, String url) {
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return;
    final String host = uri.host.toLowerCase();
    final bool looksZLib = host == 'z-lib.sk' ||
        host.contains('z-lib') ||
        host.startsWith('zlibrary') ||
        host.contains('.z-lib.');
    if (!looksZLib) return;
    final String key = host;
    if (!seen.add(key)) return;
    out.add(MirrorEntry(url: uri.toString(), host: host, status: 'UP'));
  }

  static MirrorEntry _entry(String url, String status) {
    final uri = Uri.tryParse(url);
    final host = uri?.host ?? url;
    return MirrorEntry(url: url, host: host, status: status);
  }

  /// 可用的排前面，其余按域名字母序
  static List<MirrorEntry> _sorted(List<MirrorEntry> entries) {
    final list = List<MirrorEntry>.of(entries);
    list.sort((a, b) {
      if (a.usable != b.usable) return a.usable ? -1 : 1;
      return a.host.compareTo(b.host);
    });
    return list;
  }
}

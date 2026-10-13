import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 网页翻译（整页代理）。
///
/// **首选谷歌翻译**：`translate.googleapis.com/translate_a/single` 是谷歌翻译
/// **网页版内部**的整页代理接口 —— 参数直拼、行为等价于用户手动在谷歌翻译里
/// 打开本页。⚠️ 它**没有官方文档承诺**，国内网络下也**大概率不可达**，
/// 所以必须有兜底。
///
/// **兜底百度翻译**：`fanyi.baidu.com/transpage` 是**真·整页代理**（不是交互式
/// 翻译页），国内可直连。实测（2026-10-10 本机直连）：200 / 38KB ✅。
///
/// ## ⚠️ 为什么把微软 `translatetheweb.com` 整条链路删掉（v1.21.36）
///
/// 用户报「Edge 翻译通常不生效」。根因是**探测判据太松**：
/// 老实现只要 `httpClient.send()` 不抛异常就算"可达"，而微软代理在国内网络下
/// 恰好是「**能连上、返回 200、但内容不是翻译结果**」（错误页 / 空页）。
/// 于是探测"通过" → 用户被引到一个根本没翻译的页面上。
///
/// 这是**比"连不上"更糟的失败模式**：连不上用户会重试或换路，
/// 返回一个假的翻译页用户只会以为功能坏了。所以整条微软链路删除，
/// 并把判据收紧成「状态码 2xx/3xx **且** 有响应体」（见 [resolveUrl]）。
///
/// ## 语言码不能混（踩过就会"翻成别的语言"或"干脆不翻"）
///
/// | 引擎 | 目标语言码 | 源语言码 |
/// | --- | --- | --- |
/// | 谷歌 | `zh-CN` | `auto` |
/// | 百度 | `zh` | `auto` |
///
/// 这个类只负责拼地址与选路；翻译本身由谷歌 / 百度完成，本应用不解析结果。
class WebTranslate {
  WebTranslate._();

  /// 默认目标语言（**谷歌的语言码**）
  ///
  /// ⚠️ 谷歌用 `zh-CN`；百度用 `zh`（见 [urlForFallback] 的默认值）。
  /// 两个语言码**不能互换**：传错谷歌会把整页翻成别的语言，或干脆不翻。
  static const String defaultTarget = 'zh-CN';

  /// 首选：谷歌整页代理（`translate_a/single`）
  static const String endpoint =
      'https://translate.googleapis.com/translate_a/single';

  /// 兜底：百度整页翻译（国内可直连）
  static const String fallbackEndpoint = 'https://fanyi.baidu.com/transpage';

  /// 探测超时：太久等于没兜底（用户在等页面打开）
  ///
  /// ⚠️ 这个值不要调大：探测是串在"点翻译 → 打开页面"之间的。
  static const Duration probeTimeout = Duration(seconds: 4);

  /// 探测时最多读多少字节的响应体
  ///
  /// 只用来判「有没有真的吐东西」——错误页 / 空页在这里就能被识别出来。
  static const int _probeBodyBytes = 512;

  /// 生成整页翻译地址（谷歌）；[pageUrl] 不是 http(s) 时返回 null（调用方给提示）
  ///
  /// 参数说明（`translate_a/single` 的约定）：
  /// - `client=gtx`：**必带**，网页版客户端标识；缺了会被当非法调用；
  /// - `sl`：源语言，`auto` = 自动检测；
  /// - `tl`：目标语言，见 [defaultTarget]（**谷歌的 `zh-CN`**）；
  /// - `dt=t`："翻译文本"这一档；
  /// - `q`：要翻译的整页 URL（整体编码）。
  static String? urlFor(
    String pageUrl, {
    String target = defaultTarget,
    String source = 'auto',
  }) {
    final trimmed = pageUrl.trim();
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      return null;
    }
    return '$endpoint?client=gtx&sl=$source&tl=$target&dt=t'
        '&q=${Uri.encodeComponent(trimmed)}';
  }

  /// 兜底地址（百度整页翻译）；入参校验与 [urlFor] 一致
  ///
  /// 参数沿用老实现（**不要改**）：`query` / `from` / `to` / `source=url`。
  /// 百度这套是老接口，语言码用粗粒度值 —— 这里给 `zh`，不是 `zh-CN`。
  static String? urlForFallback(
    String pageUrl, {
    String target = 'zh',
    String source = 'auto',
  }) {
    final trimmed = pageUrl.trim();
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      return null;
    }
    return '$fallbackEndpoint?query=${Uri.encodeComponent(trimmed)}'
        '&from=$source&to=$target&source=url';
  }

  /// 这个地址能不能翻译
  static bool canTranslate(String pageUrl) => urlFor(pageUrl) != null;

  /// **挑一个真正能打开的翻译地址**：先探谷歌，不可达就退百度。
  ///
  /// 返回 null = 不是 http(s) 页面（调用方给提示，不跳转）。
  /// [client] 仅供测试注入。
  ///
  /// ## 判据（本次修正的核心）
  ///
  /// **状态码 2xx/3xx 且响应体非空**才算可达 —— 不能只看"连接是否成功"。
  /// 老实现只看连得上，于是"200 但返回错误页"被判成可达，
  /// 用户被引到一个没翻译的页面（就是本次要修的症状）。
  static Future<String?> resolveUrl(
    String pageUrl, {
    http.Client? client,
    String target = defaultTarget,
  }) async {
    final primary = urlFor(pageUrl, target: target);
    if (primary == null) return null; // 非 http(s)：连兜底也不给
    final own = client == null;
    final http.Client httpClient = client ?? http.Client();
    try {
      final http.Request request = http.Request('GET', Uri.parse(endpoint))
        ..headers['Accept'] = 'text/html';
      // 只要头 512 字节：探测不该为了"看看内容"把整页读下来
      request.headers['Range'] = 'bytes=0-$_probeBodyBytes';
      final http.StreamedResponse response =
          await httpClient.send(request).timeout(probeTimeout);
      final int status = response.statusCode;
      if (status < 200 || status >= 400) {
        // 明确的服务端错误 / 重定向到错误页：退兜底
        return urlForFallback(pageUrl);
      }
      // 状态码 OK 还不够：错误页 / 空页也会是 200（微软就是这种失败模式）。
      // 这里读一小段 body，空的就是不可用。
      //
      // ⚠️ 按**字节**截断：`Stream.take(n)` 取的是 n 个 chunk、不是 n 字节，
      // 用它会把大响应整段读下来（探测不该付这个代价）。
      final BytesBuilder probe = BytesBuilder(copy: false);
      await for (final List<int> chunk
          in response.stream.timeout(probeTimeout)) {
        final int room = _probeBodyBytes - probe.length;
        if (room <= 0) break;
        probe.add(chunk.length <= room ? chunk : chunk.sublist(0, room));
      }
      if (probe.length == 0) return urlForFallback(pageUrl);
      return primary;
    } catch (_) {
      // 连不上 / 超时 / 读 body 出错（实测国内就是这条）→ 用国内可达的整页代理
      return urlForFallback(pageUrl);
    } finally {
      if (own) httpClient.close();
    }
  }
}

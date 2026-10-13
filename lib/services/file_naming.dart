/// 文件命名规则：**尽量保留原名**，只清洗真正非法的字符
///
/// 下载与导入两侧都走这里，保证「原名」在整条链路上不被改掉：
/// 浏览器里下载下来的名字 = 服务端给的名字，导入文档库后的书名 = 去掉扩展名的原名。
class FileNaming {
  FileNaming._();

  /// 跨平台并集：Windows 非法字符 + 控制字符 + NUL
  ///
  /// 只清洗这些 —— 空格、中文、括号、`#`、`+`、`%`、`&`、`'` 都是合法字符，
  /// 必须原样保留，否则「保留原文件名」就名存实亡。
  static final RegExp illegal = RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]');

  /// 基名最长保留多少字符（组合后仍要留出 ` (12)` 与扩展名的余量）
  ///
  /// ext4 单个文件名上限 255 字节，而中文一个字 3 字节 —— 80 字约 240 字节。
  static const int maxBaseLength = 80;

  /// MIME → 扩展名（服务端没给名字、URL 也没有扩展名时用来补一个）
  static const Map<String, String> _mimeExtensions = <String, String>{
    'application/pdf': 'pdf',
    'application/epub+zip': 'epub',
    'application/x-mobipocket-ebook': 'mobi',
    'application/vnd.amazon.ebook': 'azw3',
    'text/plain': 'txt',
    'application/zip': 'zip',
  };

  /// 清洗文件名：只替换非法字符，其余原样保留
  ///
  /// 返回空串表示这个名字没法用（调用方自己兜底）。
  static String sanitize(String name) {
    var text = name.replaceAll(illegal, '_');
    // 首尾空白与结尾的点：结尾点在某些文件系统 / MediaStore 上会被吞掉或报错
    text = text.trim();
    while (text.endsWith('.')) {
      text = text.substring(0, text.length - 1).trim();
    }
    if (text.isEmpty) return '';
    return _truncate(text);
  }

  /// 过长时截断基名，保留扩展名
  static String _truncate(String name) {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    if (base.length <= maxBaseLength) return name;
    final ext = dot > 0 ? name.substring(dot) : '';
    return '${base.substring(0, maxBaseLength)}$ext';
  }

  /// 是否带扩展名（`.` 开头的隐藏文件不算）
  static bool hasExtension(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 && dot < name.length - 1;
  }

  /// MIME → 扩展名；认不出来返回空串
  static String extensionForMime(String? mimeType) {
    final key = (mimeType ?? '').toLowerCase().split(';').first.trim();
    return _mimeExtensions[key] ?? '';
  }

  /// 由路径取文件名
  static String baseName(String path) {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? path : parts.last;
  }

  /// 由文件名取书名：去掉扩展名
  static String titleOf(String fileName) {
    final name = sanitize(baseName(fileName));
    if (name.isEmpty) return '未命名文档';
    final dot = name.lastIndexOf('.');
    final title = (dot > 0 ? name.substring(0, dot) : name).trim();
    return title.isEmpty ? '未命名文档' : title;
  }

  /// 下载文件名：**服务端建议名优先，其次 URL 末段**，最后才兜底
  ///
  /// [suggested] 已经是服务端给的名字（通常带正确扩展名）；
  /// [urlPath] 是 URL 的 path 部分（调用方负责去掉查询串）。
  static String downloadName({String? suggested, String? urlPath, String? mimeType}) {
    var name = sanitize(_decode(suggested ?? ''));
    if (name.isEmpty) {
      final last = (urlPath ?? '').split('/').where((part) => part.isNotEmpty).toList();
      name = sanitize(_decode(last.isEmpty ? '' : last.last));
    }
    if (name.isEmpty) name = 'download_${DateTime.now().millisecondsSinceEpoch}';
    if (!hasExtension(name)) {
      final ext = extensionForMime(mimeType);
      if (ext.isNotEmpty) name = '$name.$ext';
    }
    return name;
  }

  /// 重名时按 Android 下载器的习惯加 ` (1)`、` (2)`：**保留原名而不是覆盖**
  static String uniqueName(
    String name,
    bool Function(String candidate) exists, {
    int maxTries = 99,
  }) {
    if (!exists(name)) return name;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    for (var i = 1; i <= maxTries; i++) {
      final candidate = '$base ($i)$ext';
      if (!exists(candidate)) return candidate;
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    return '${_truncate(base)} ($stamp)$ext';
  }

  /// 从 `Content-Disposition` 响应头里取文件名（v1.21.39）
  ///
  /// ## 为什么需要它
  ///
  /// WebView 的 `DownloadListener.onDownloadStart` 给的建议名来自它自己看到的
  /// 那次响应头；而 Z-Library 这类站是 `/dl/xxx → 302 → CDN`，
  /// **重定向之后 WebView 往往拿不到原始响应头**，名字就退化成 URL 末段
  /// （用户实测下下来叫 `redirection.pdf`）。所以重定向场景要**自己再问一次服务端**。
  ///
  /// ## 解析规则（RFC 6266 / RFC 5987）
  ///
  /// 1. `filename*=UTF-8''%E4%B8%96%E7%95%8C...` —— RFC 5987 扩展形式，
  ///    带字符集与语言，值是**百分号编码**的；优先用它；
  /// 2. `filename="世界通史.pdf"` —— 带引号的普通形式；
  /// 3. `filename=世界通史.pdf` —— 不带引号（有些服务端这么发）；
  /// 4. **两种都给时 `filename*` 赢**（RFC 6266 明确要求）；
  /// 5. 解析出来的名字**再过一遍 [sanitize]**（服务端可能给非法字符）；
  /// 6. `inline` / 没有 filename / 空头 → 返回 null（调用方自己兜底）。
  static String? parseContentDisposition(String? header) {
    final raw = header?.trim() ?? '';
    if (raw.isEmpty) return null;

    // ① RFC 5987：filename*=UTF-8''<percent-encoded>（charset 也可能是 ISO-8859-1）
    //
    // ⚠️ 值用 `[^;'"]+` 而不是 `[^;]+`：后者会把结尾的引号一起吃掉
    // （`filename*="UTF-8''%E4%B9%A6.pdf"` → 值尾巴多个 `"`），
    // 而去引号那一步只在**首尾同时是引号**时才生效，救不回来 —— 实测多出一个 `_`。
    final star = RegExp(
      r"""filename\*\s*=\s*([^']*)'[^']*'([^;'"]+)""",
      caseSensitive: false,
    ).firstMatch(raw);
    if (star != null) {
      // charset 理论上可能是 ISO-8859-1，但本项目处理的都是 UTF-8
      // （`_decode` 走 `Uri.decodeComponent`）；这里不按 charset 分支，
      // 非 UTF-8 时至少把百分号解开、别把名字整条丢掉。
      // ⚠️ 顺序：**先去引号，再百分号解码**。
      // 反过来的话（先解码再去引号）`filename*="UTF-8''%E4%B9%A6.pdf"` 末尾那个
      // 引号会先被 [sanitize] 变成下划线，于是名字里多出一个 `_`（实测踩到）。
      final value = _stripQuotes(star.group(2)!.trim());
      if (value.isEmpty) return null;
      final decoded = sanitize(_decode(value));
      return decoded.isEmpty ? null : decoded;
    }

    // ② / ③ 普通 filename，带不带引号都吃
    final plain = RegExp(
      r'''filename\s*=\s*(?:"([^"]*)"|([^;]+))''',
      caseSensitive: false,
    ).firstMatch(raw);
    if (plain != null) {
      final value = _stripQuotes((plain.group(1) ?? plain.group(2) ?? '').trim());
      if (value.isNotEmpty) {
        final decoded = sanitize(_decode(value));
        if (decoded.isNotEmpty) return decoded;
      }
    }

    // ④ inline / 只有 disposition 类型没有 filename / 全是非法字符
    return null;
  }

  /// 去掉成对的引号（单双都认）；只有确实成对才去
  static String _stripQuotes(String value) {
    if (value.length >= 2) {
      final first = value[0];
      final last = value[value.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        return value.substring(1, value.length - 1).trim();
      }
    }
    return value;
  }

  /// 百分号解码；失败就用原样（下载链接里很常见 `%E7%BA%A2...`）
  static String _decode(String value) {
    final text = value.trim();
    if (text.isEmpty || !text.contains('%')) return text;
    try {
      return Uri.decodeComponent(text);
    } catch (_) {
      return text;
    }
  }
}

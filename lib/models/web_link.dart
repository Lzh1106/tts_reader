/// 浏览器收藏 / 浏览记录条目
class WebLink {
  const WebLink({
    required this.title,
    required this.url,
    required this.createdAt,
    this.isShortcut = false,
  });

  final String title;
  final String url;
  final DateTime createdAt;

  /// 是否被用户手动加为「快捷方式」
  ///
  /// 起始页的快捷方式格子只显示这一类：普通收藏（浏览时点「收藏本页」留下的）
  /// 仍然只进「收藏夹」，不会把起始页塞满。
  final bool isShortcut;

  /// 标题为空时退回域名
  String get displayTitle {
    final trimmed = title.trim();
    if (trimmed.isNotEmpty) return trimmed;
    return host.isEmpty ? url : host;
  }

  /// 主机名（解析不出来时为空串）
  String get host {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return '';
    }
  }

  /// 去掉 `www.` 的主机名，用来把「同一个站点」归到一起
  String get bareHost {
    final value = host.toLowerCase();
    return value.startsWith('www.') ? value.substring(4) : value;
  }

  /// 是不是**搜索引擎的结果页**
  ///
  /// 依据是主机名 + 查询参数：`bing.com/search?q=`、`baidu.com/s?wd=` 等等。
  /// 这类 URL 不该出现在快捷方式里 —— 一次搜索留一个格子，起始页很快就满屏了。
  bool get isSearchResult {
    if (host.isEmpty) return false;
    final query = Uri.tryParse(url)?.queryParameters ?? const <String, String>{};
    bool hasAnyOf(List<String> keys) => keys.any(query.containsKey);

    final site = bareHost;
    if (site.endsWith('bing.com')) return hasAnyOf(<String>['q']);
    if (site.endsWith('baidu.com')) return hasAnyOf(<String>['wd', 'word']);
    if (site.endsWith('google.com') ||
        site.endsWith('google.com.hk') ||
        site.endsWith('googleusercontent.com')) {
      return hasAnyOf(<String>['q']);
    }
    if (site.endsWith('duckduckgo.com')) return hasAnyOf(<String>['q']);
    if (site.endsWith('sogou.com')) return hasAnyOf(<String>['query', 'keyword']);
    if (site.endsWith('so.com') || site.endsWith('360.cn')) {
      return hasAnyOf(<String>['q']);
    }
    if (site.endsWith('search.yahoo.com')) return hasAnyOf(<String>['p']);
    // 通用兜底：路径像搜索、且带着查询词
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return (path.contains('search') || path == '/s' || path.contains('/web')) &&
        hasAnyOf(<String>['q', 'wd', 'query', 'keyword', 'p']);
  }

  WebLink copyWith({String? title, bool? isShortcut}) => WebLink(
        title: title ?? this.title,
        url: url,
        createdAt: createdAt,
        isShortcut: isShortcut ?? this.isShortcut,
      );

  Map<String, dynamic> toJson() => {
    'title': title,
    'url': url,
    'createdAt': createdAt.toIso8601String(),
    if (isShortcut) 'shortcut': true,
  };

  factory WebLink.fromJson(Map<String, dynamic> json) => WebLink(
    title: json['title'] as String? ?? '',
    url: json['url'] as String? ?? '',
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    isShortcut: json['shortcut'] as bool? ?? false,
  );

  @override
  String toString() => '$displayTitle <$url>';
}

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart' as xml;

/// EPUB 目录（EPUB3 的 nav 文档 / EPUB2 的 NCX）里的一条
class EpubTocEntry {
  const EpubTocEntry({
    required this.title,
    required this.href,
    this.anchor,
    this.depth = 0,
  });

  /// 显示名
  final String title;

  /// 归一化后的文件路径（相对 zip 根，已去掉 `#锚点`）
  final String href;

  /// `#` 后面的锚点（可能为空）
  final String? anchor;

  /// 层级：0 是顶层
  final int depth;

  @override
  String toString() => '${'  ' * depth}$title → $href${anchor == null ? '' : '#$anchor'}';
}

/// EPUB 目录解析（纯函数，便于单测）
///
/// 为什么要自己解析：目录标题通常只存在于 nav 文档 / NCX 里，
/// 而正文文件里的 `<title>` 常常整本书都是同一个书名（每章都一样），
/// 于是「按 `<title>` 起章名」会得到一堆重复标题。
/// 这里把目录解析出来 → 按 href 映射到正文文件 → 用它给章节起名并保留层级。
class EpubTocParser {
  EpubTocParser._();

  static const int maxEntries = 5000;
  static const int maxDepth = 8;

  /// 解析 EPUB3 的 nav 文档（`<nav epub:type="toc">` 里的嵌套 `<ol>`）
  ///
  /// 找不到 toc 类型的 nav 时退回「第一个含链接的 nav」。
  static List<EpubTocEntry> parseNav(String htmlText, {String navDir = ''}) {
    final entries = <EpubTocEntry>[];
    if (htmlText.trim().isEmpty) return entries;
    try {
      final document = html_parser.parse(htmlText);
      final navs = document.querySelectorAll('nav');
      dom.Element? target;
      for (final nav in navs) {
        final type = (nav.attributes['epub:type'] ?? nav.attributes['type'] ?? '').toLowerCase();
        if (type.contains('toc')) {
          target = nav;
          break;
        }
      }
      if (target == null) {
        for (final nav in navs) {
          if (nav.querySelector('a[href]') != null) {
            target = nav;
            break;
          }
        }
      }
      // 没有 nav 标签时，整篇按目录处理（有些书的 toc 页就是一个裸 <ol>）
      final root = target ?? (document.querySelector('ol, ul') != null ? document.body : null);
      if (root == null) return entries;
      final lists = root.querySelectorAll('ol, ul');
      if (lists.isEmpty) return entries;
      // 最外层列表：取没有被其它列表包住的那些
      for (final list in lists) {
        if (_hasListAncestor(list, root)) continue;
        _walkNavList(list, navDir, 0, entries);
      }
    } catch (_) {
      // 结构异常：当作没有目录
    }
    return entries;
  }

  static bool _hasListAncestor(dom.Element node, dom.Element root) {
    var parent = node.parent;
    while (parent != null && parent != root) {
      if (parent.localName == 'ol' || parent.localName == 'ul') return true;
      parent = parent.parent;
    }
    return false;
  }

  static void _walkNavList(
    dom.Element list,
    String navDir,
    int depth,
    List<EpubTocEntry> out,
  ) {
    if (depth > maxDepth || out.length >= maxEntries) return;
    for (final item in list.children.where((child) => child.localName == 'li')) {
      if (out.length >= maxEntries) return;
      // 一个 li 里可能先有 <a>（有链接）或只有 <span>（分组标题，没链接）
      final anchor = item.children.firstWhere(
        (child) => child.localName == 'a' && (child.attributes['href'] ?? '').isNotEmpty,
        orElse: () => dom.Element.tag('a'),
      );
      final href = anchor.attributes['href'] ?? '';
      if (href.isNotEmpty) {
        final entry = _entry(title: anchor.text, href: href, dir: navDir, depth: depth);
        if (entry != null) out.add(entry);
        // 有链接的条目：子列表按目录层级继续往下走
        for (final child in item.querySelectorAll('ol, ul')) {
          _walkNavList(child, navDir, depth + 1, out);
        }
        continue;
      }

      // 没有链接的分组标题（如「第一卷」）：用它给子项做前缀，避免层级信息丢失。
      // 注意子列表只走这一次 —— 上面那条 continue 就是为了不重复走。
      final label = item.children
          .firstWhere(
            (child) => child.localName == 'span' || child.localName == 'div',
            orElse: () => dom.Element.tag('span'),
          )
          .text
          .trim();
      final before = out.length;
      for (final child in item.querySelectorAll('ol, ul')) {
        _walkNavList(child, navDir, depth + 1, out);
      }
      if (label.isEmpty) continue;
      for (var i = before; i < out.length; i++) {
        out[i] = EpubTocEntry(
          title: '$label · ${out[i].title}',
          href: out[i].href,
          anchor: out[i].anchor,
          depth: out[i].depth,
        );
      }
    }
  }

  /// 解析 EPUB2 的 NCX（`navMap > navPoint` 递归）
  static List<EpubTocEntry> parseNcx(String xmlText, {String ncxDir = ''}) {
    final entries = <EpubTocEntry>[];
    if (xmlText.trim().isEmpty) return entries;
    try {
      final document = xml.XmlDocument.parse(xmlText);
      final maps = document.findAllElements('navMap');
      if (maps.isEmpty) return entries;
      for (final point in maps.first.findElements('navPoint')) {
        _walkNavPoint(point, ncxDir, 0, entries);
        if (entries.length >= maxEntries) break;
      }
    } catch (_) {
      // 结构异常：当作没有目录
    }
    return entries;
  }

  static void _walkNavPoint(
    xml.XmlElement point,
    String dir,
    int depth,
    List<EpubTocEntry> out,
  ) {
    if (depth > maxDepth || out.length >= maxEntries) return;
    final label = point.findElements('navLabel').isEmpty
        ? ''
        : point.findElements('navLabel').first.findAllElements('text').isEmpty
        ? ''
        : point.findElements('navLabel').first.findAllElements('text').first.innerText;
    final content = point.findElements('content').isEmpty
        ? null
        : point.findElements('content').first.getAttribute('src');
    if (content != null && content.trim().isNotEmpty) {
      final entry = _entry(title: label, href: content, dir: dir, depth: depth);
      if (entry != null) out.add(entry);
    }
    for (final child in point.findElements('navPoint')) {
      _walkNavPoint(child, dir, depth + 1, out);
      if (out.length >= maxEntries) return;
    }
  }

  static EpubTocEntry? _entry({
    required String title,
    required String href,
    required String dir,
    required int depth,
  }) {
    final cleaned = cleanTitle(title);
    final split = splitHref(href);
    if (split.$1.isEmpty) return null;
    return EpubTocEntry(
      title: cleaned.isEmpty ? split.$1 : cleaned,
      href: normalizePath(split.$1, baseDir: dir),
      anchor: split.$2,
      depth: depth,
    );
  }

  /// 拆分 `文件#锚点`
  static (String, String?) splitHref(String href) {
    final text = href.trim();
    if (text.isEmpty) return ('', null);
    final hash = text.indexOf('#');
    if (hash < 0) return (text, null);
    final anchor = text.substring(hash + 1).trim();
    return (text.substring(0, hash), anchor.isEmpty ? null : anchor);
  }

  /// 路径归一化：URL 解码、去掉 `./`、处理 `../`、统一分隔符
  ///
  /// 目录里的 href 是相对 nav/ncx 所在目录写的，这里换算成「相对 zip 根」的路径，
  /// 才能和 OPF 里 manifest 的 href 对上。
  static String normalizePath(String path, {String baseDir = ''}) {
    var text = path.trim().replaceAll('\\', '/');
    if (text.isEmpty) return '';
    try {
      text = Uri.decodeFull(text);
    } catch (_) {
      // 解码失败就用原样
    }
    final segments = <String>[];
    if (text.startsWith('/')) {
      // 以 / 开头表示从 zip 根开始，忽略 baseDir
    } else if (baseDir.isNotEmpty) {
      for (final part in baseDir.split('/')) {
        if (part.isNotEmpty && part != '.') segments.add(part);
      }
    }
    for (final part in text.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(part);
    }
    return segments.join('/');
  }

  /// 目录条目按文件分组；同一文件的多条按出现顺序保留
  static Map<String, List<EpubTocEntry>> byFile(List<EpubTocEntry> entries) {
    final map = <String, List<EpubTocEntry>>{};
    for (final entry in entries) {
      map.putIfAbsent(entry.href, () => <EpubTocEntry>[]).add(entry);
    }
    return map;
  }

  /// 标题清洗：压缩空白、去掉控制字符、截断
  static String cleanTitle(String raw) {
    final text = raw
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.length > 120) return '${text.substring(0, 120)}…';
    return text;
  }
}

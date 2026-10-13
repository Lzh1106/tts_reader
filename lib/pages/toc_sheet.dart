import 'package:flutter/material.dart';

import '../models/structured_document.dart';

/// 目录面板：原书自带目录（PDF 书签 / EPUB nav 与 NCX）+ 章节 / 页数跳转
///
/// 独立成文件是为了能直接写 widget 测试（`test/toc_sheet_test.dart`）。
class TocSheet extends StatefulWidget {
  const TocSheet({
    super.key,
    required this.document,
    required this.cursor,
    required this.paragraphsPerPage,
  });

  final StructuredDocument document;
  final (int, int, int) cursor;
  final int paragraphsPerPage;

  @override
  State<TocSheet> createState() => _TocSheetState();
}

class _TocSheetState extends State<TocSheet> {
  late final TextEditingController _pageInput = TextEditingController(
    text: '${widget.document.pageOf(widget.cursor.$1, widget.cursor.$2, widget.paragraphsPerPage)}',
  );
  final TextEditingController _search = TextEditingController();

  /// 原书自带的目录（PDF 书签 / EPUB 的 nav 与 NCX）有内容时默认显示它
  late bool _showOutline = widget.document.hasOutline;

  /// 章号过滤结果；为空表示不过滤
  late List<int> _matches = const <int>[];

  /// 目录条目过滤结果
  late List<DocumentOutlineEntry> _outlineMatches = const <DocumentOutlineEntry>[];

  /// 总页数只算一次：几千章的 TXT 每次 build 都重算会明显卡
  late final int _totalPages = widget.document.chapterIsPage
      ? widget.document.chapters.length
      : widget.document.totalPages(widget.paragraphsPerPage);

  @override
  void dispose() {
    _pageInput.dispose();
    _search.dispose();
    super.dispose();
  }

  void _applySearch(String value) {
    final keyword = value.trim().toLowerCase();
    if (keyword.isEmpty) {
      setState(() {
        _matches = const <int>[];
        _outlineMatches = const <DocumentOutlineEntry>[];
      });
      return;
    }
    final document = widget.document;
    final chapters = document.chapters;
    final matches = <int>[];
    for (var i = 0; i < chapters.length; i++) {
      if (chapters[i].title.toLowerCase().contains(keyword)) matches.add(i);
      // 目录搜索只在用户输入时跑一次，几千章也是毫秒级；上限避免极端情况拖住界面
      if (matches.length >= 500) break;
    }
    final outline = <DocumentOutlineEntry>[];
    for (final entry in document.outline) {
      if (entry.title.toLowerCase().contains(keyword)) outline.add(entry);
      if (outline.length >= 500) break;
    }
    setState(() {
      _matches = matches;
      _outlineMatches = outline;
    });
  }

  void _jumpToPage() {
    final page = int.tryParse(_pageInput.text.trim());
    if (page == null || page < 1) return;
    final document = widget.document;
    if (document.chapterIsPage) {
      final index = page > document.chapters.length ? document.chapters.length - 1 : page - 1;
      Navigator.pop(context, (index, 0));
      return;
    }
    final perPage = widget.paragraphsPerPage;
    if (perPage < 1 || _totalPages < 1) return;
    // 页码指「整篇第几页」：先夹取到有效范围（越界跳最后一页而不是回到开头），
    // 再逐章累加定位。全程只做算术，不构造区间列表 —— 几千章的书也是微秒级。
    // 注意别用 clamp()：它返回 num，后面和下标混用会被判成 double。
    final lastPage = _totalPages - 1;
    final raw = page - 1;
    final target = raw < 0 ? 0 : (raw > lastPage ? lastPage : raw);
    var acc = 0;
    for (var c = 0; c < document.chapters.length; c++) {
      final count = document.pageCountOf(c, perPage);
      if (acc + count > target) {
        Navigator.pop(context, (c, document.pageStartOf(c, target - acc, perPage) ?? 0));
        return;
      }
      acc += count;
    }
    Navigator.pop(context, (document.chapters.length - 1, 0));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final document = widget.document;
    final perPage = widget.paragraphsPerPage;
    final asPages = document.chapterIsPage;
    final current = widget.cursor.$1;

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: <Widget>[
                Text('目录', style: theme.textTheme.titleLarge),
                const Spacer(),
                Text(
                  asPages ? '共 ${document.chapters.length} 页' : '共 ${document.chapters.length} 章',
                  style: theme.textTheme.labelMedium,
                ),
              ],
            ),
          ),
          // 原书自带目录（PDF 书签 / EPUB nav 与 NCX）与「我们自己切的章节」是两套东西，
          // 有目录时让用户自己选看哪一套
          if (document.hasOutline)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: SegmentedButton<bool>(
                segments: <ButtonSegment<bool>>[
                  ButtonSegment<bool>(
                    value: true,
                    icon: const Icon(Icons.list_alt, size: 18),
                    label: Text('原书目录（${document.outline.length}）'),
                  ),
                  ButtonSegment<bool>(
                    value: false,
                    icon: const Icon(Icons.menu_book_outlined, size: 18),
                    label: Text(asPages ? '全部页码' : '章节'),
                  ),
                ],
                selected: <bool>{_showOutline},
                showSelectedIcon: false,
                onSelectionChanged: (selection) =>
                    setState(() => _showOutline = selection.first),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _pageInput,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.go,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: '跳转到第几页',
                      helperText: asPages
                          ? '当前第 ${current + 1} 页，共 ${document.chapters.length} 页'
                          : '当前第 ${document.pageOf(current, widget.cursor.$2, perPage)} 页 / 全篇 $_totalPages 页（每页 $perPage 段）',
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _jumpToPage(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _jumpToPage, child: const Text('跳转')),
              ],
            ),
          ),
          // 几千章的小说（或几百条的原书目录）没有搜索就只能靠翻，这里给个过滤器
          if (!asPages && (document.chapters.length >= 20 || document.outline.length >= 20))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  labelText: '搜索章节名',
                  helperText: _matches.isEmpty
                      ? '输入章名关键字，例如「第 3 章」「风起」'
                      : '匹配到 ${_matches.length} 章${_matches.length >= 500 ? '（只显示前 500 条）' : ''}',
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清空',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _search.clear();
                            _applySearch('');
                          },
                        ),
                  border: const OutlineInputBorder(),
                ),
                onChanged: _applySearch,
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: _showOutline && document.hasOutline
                ? _outlineList(document, current, perPage, scheme, theme)
                : asPages
                ? _pageList(document, current, scheme, theme)
                : _chapterList(document, current, perPage, scheme, theme),
          ),
        ],
      ),
    );
  }

  /// 原书自带的目录：按层级缩进，点一下跳到对应章节 / 页码
  Widget _outlineList(
    StructuredDocument document,
    int current,
    int perPage,
    ColorScheme scheme,
    ThemeData theme,
  ) {
    final searching = _search.text.trim().isNotEmpty;
    final entries = searching ? _outlineMatches : document.outline;
    if (entries.isEmpty) {
      return Center(child: Text(searching ? '目录里没有匹配的条目' : '这本书没有自带目录', style: theme.textTheme.bodyMedium));
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final active = entry.chapter == current;
        // 缩进按层级，最多 4 级，再深就都按 4 级对齐（省得标题被挤没）
        final indent = 16.0 + (entry.depth > 4 ? 4 : entry.depth) * 16.0;
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.only(left: indent, right: 16),
          title: Text(
            entry.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: active ? TextStyle(color: scheme.primary, fontWeight: FontWeight.w600) : null,
          ),
          subtitle: Text(
            document.chapterIsPage ? '第 ${entry.chapter + 1} 页' : '第 ${entry.chapter + 1} 章',
            style: theme.textTheme.labelSmall,
          ),
          trailing: active ? Icon(Icons.play_arrow, size: 18, color: scheme.primary) : null,
          onTap: () => Navigator.pop(context, (entry.chapter, entry.paragraph)),
        );
      },
    );
  }

  /// PDF：直接列页码，点页即跳到该页朗读
  Widget _pageList(StructuredDocument document, int current, ColorScheme scheme, ThemeData theme) {
    return ListView.builder(
      itemCount: document.chapters.length,
      itemBuilder: (context, index) {
        final chapter = document.chapters[index];
        final active = index == current;
        return ListTile(
          dense: true,
          leading: CircleAvatar(
            radius: 14,
            backgroundColor: active ? scheme.primary : scheme.surfaceContainerHighest,
            child: Text(
              '${index + 1}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
            ),
          ),
          title: Text(active ? '${chapter.title}（当前）' : chapter.title),
          subtitle: Text('${chapter.paragraphs.length} 段'),
          trailing: active ? Icon(Icons.play_arrow, size: 18, color: scheme.primary) : null,
          onTap: () => Navigator.pop(context, (index, 0)),
        );
      },
    );
  }

  Widget _chapterList(
    StructuredDocument document,
    int current,
    int perPage,
    ColorScheme scheme,
    ThemeData theme,
  ) {
    // 搜索时只列匹配到的章节；否则列全部（ListView.builder 保证只构建可见项）。
    // 注意判据是「搜索框里有没有字」，不是「匹配结果空不空」——
    // 搜不到东西时要显示「没有匹配」，而不是把全部章节又列出来。
    final searching = _search.text.trim().isNotEmpty;
    final count = searching ? _matches.length : document.chapters.length;
    if (count == 0) {
      return Center(
        child: Text('没有匹配的章节', style: theme.textTheme.bodyMedium),
      );
    }
    return ListView.builder(
      itemCount: count,
      itemBuilder: (context, position) {
        final chapterIndex = searching ? _matches[position] : position;
        final chapter = document.chapters[chapterIndex];
        final active = chapterIndex == current;
        final pageCount = document.pageCountOf(chapterIndex, perPage);
        return ExpansionTile(
          // 搜索时默认展开当前章，避免匹配结果还要再点一次
          initiallyExpanded: active,
          leading: CircleAvatar(
            radius: 14,
            backgroundColor: active ? scheme.primary : scheme.surfaceContainerHighest,
            child: Text(
              '${chapterIndex + 1}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
            ),
          ),
          title: Text(
            chapter.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: active ? TextStyle(color: scheme.primary, fontWeight: FontWeight.w600) : null,
          ),
          subtitle: Text('${chapter.paragraphs.length} 段 · $pageCount 页'),
          // 章节内容很多时，展开后一次性塞几百个 ListTile 会卡：这里只在展开时才建，
          // 且页数少于 200 才逐页列出
          children: <Widget>[
            if (pageCount <= 200)
              for (var i = 0; i < pageCount; i++)
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 64, right: 16),
                  title: Text('第 ${i + 1} 页'),
                  subtitle: Text(
                    '第 ${i * perPage + 1}-${(i * perPage + perPage) > chapter.paragraphs.length ? chapter.paragraphs.length : i * perPage + perPage} 段',
                  ),
                  trailing: active &&
                          document.pageOf(widget.cursor.$1, widget.cursor.$2, perPage) == i + 1
                      ? Icon(Icons.play_arrow, size: 18, color: scheme.primary)
                      : null,
                  onTap: () => Navigator.pop(context, (chapterIndex, i * perPage)),
                )
            else
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(left: 64, right: 16),
                title: const Text('这一章页数很多，用上面的页码直接跳'),
                onTap: () => Navigator.pop(context, (chapterIndex, 0)),
              ),
          ],
        );
      },
    );
  }
}

import 'package:flutter/material.dart';

import '../models/web_link.dart';
import '../services/book_source_directory.dart';
import '../services/storage_service.dart';
import 'mirror_picker.dart';

/// 书源管理：浏览器里「书源」菜单的快捷入口列表
///
/// Z-Library 这类镜像域名变动极频繁，所以做成可增删改的列表：
/// 打不开时在这里换一个地址即可，不用改代码。
class BookSourcesPage extends StatefulWidget {
  const BookSourcesPage({super.key});

  @override
  State<BookSourcesPage> createState() => _BookSourcesPageState();
}

class _BookSourcesPageState extends State<BookSourcesPage> {
  List<WebLink> _sources = const <WebLink>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sources = await StorageService.instance.loadBookSources();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _loading = false;
    });
  }

  Future<void> _save(List<WebLink> sources) async {
    await StorageService.instance.saveBookSources(sources);
    if (mounted) setState(() => _sources = sources);
  }

  Future<void> _edit(WebLink? source) async {
    final result = await showDialog<WebLink>(
      context: context,
      builder: (_) => _SourceDialog(source: source),
    );
    if (result == null) return;
    final sources = List<WebLink>.of(_sources);
    if (source == null) {
      sources.add(result);
    } else {
      final index = sources.indexWhere((item) => item.url == source.url && item.title == source.title);
      if (index >= 0) {
        sources[index] = result;
      } else {
        sources.add(result);
      }
    }
    await _save(sources);
  }

  Future<void> _remove(WebLink source) async {
    final messenger = ScaffoldMessenger.of(context);
    await _save(
      _sources.where((item) => !(item.url == source.url && item.title == source.title)).toList(),
    );
    messenger.showSnackBar(SnackBar(content: Text('已删除「${source.title}」')));
  }

  Future<void> _restoreDefaults() async {
    final now = DateTime.now();
    await _save(<WebLink>[
      for (final item in StorageService.defaultBookSources)
        WebLink(title: item.$1, url: item.$2, createdAt: now),
    ]);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已恢复默认书源')));
  }

  /// 从镜像状态站检索当前可用域名，选中后加进书源
  Future<void> _addFromDirectory() async {
    final mirror = await showMirrorPicker(context);
    if (mirror == null || !mounted) return;
    if (_sources.any((item) => item.url == mirror.url)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${mirror.host} 已经在书源里了')));
      return;
    }
    final sources = List<WebLink>.of(_sources)
      ..add(
        WebLink(
          title: '${mirror.host}（${mirror.statusLabel}）',
          url: mirror.url,
          createdAt: DateTime.now(),
        ),
      );
    await _save(sources);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已加入书源：${mirror.host}')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源'),
        actions: <Widget>[
          IconButton(
            tooltip: '检索可用域名',
            onPressed: _addFromDirectory,
            icon: const Icon(Icons.travel_explore),
          ),
          // 「恢复默认」只在真的还有内置条目时才给（v1.21.23 起默认为空）
          if (StorageService.defaultBookSources.isNotEmpty)
            IconButton(
              tooltip: '恢复默认',
              onPressed: _restoreDefaults,
              icon: const Icon(Icons.settings_backup_restore),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add),
        label: const Text('新增书源'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              children: <Widget>[
                for (final source in _sources)
                  Card.filled(
                    margin: const EdgeInsets.only(bottom: 8),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      leading: const Icon(Icons.auto_stories_outlined),
                      title: Text(source.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(source.url, maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                        tooltip: '删除',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _remove(source),
                      ),
                      onTap: () => _edit(source),
                    ),
                  ),
                if (_sources.isEmpty)
                  const Card.filled(
                    margin: EdgeInsets.only(bottom: 8),
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        '还没有书源。\n'
                        '· 点右下角「新增书源」手动填地址；\n'
                        '· 或点右上角「检索可用域名」自动取当前可用的镜像。',
                      ),
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  '· 这里只存网址，浏览器菜单「书源」里点一下就直接打开。\n'
                  '· Z-Library 这类站点换域名很频繁：点右上角的「检索可用域名」，'
                  '应用会从 ${BookSourceDirectory.directoryUrl} 取当前可用的镜像，选一个加进来即可。\n'
                  '· 地址必须是 http/https 开头。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
    );
  }
}

class _SourceDialog extends StatefulWidget {
  const _SourceDialog({required this.source});

  /// null 表示新增
  final WebLink? source;

  @override
  State<_SourceDialog> createState() => _SourceDialogState();
}

class _SourceDialogState extends State<_SourceDialog> {
  late final TextEditingController _title = TextEditingController(text: widget.source?.title ?? '');
  late final TextEditingController _url = TextEditingController(text: widget.source?.url ?? '');

  @override
  void dispose() {
    _title.dispose();
    _url.dispose();
    super.dispose();
  }

  /// 校验地址：必须是 http/https
  String? get _error {
    final value = _url.text.trim();
    if (value.isEmpty) return '网址不能为空';
    final uri = Uri.tryParse(value);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return '网址要以 http:// 或 https:// 开头';
    }
    return null;
  }

  void _submit() {
    if (_error != null) return;
    final url = _url.text.trim();
    final title = _title.text.trim();
    Navigator.pop(
      context,
      WebLink(
        title: title.isEmpty ? Uri.parse(url).host : title,
        url: url,
        createdAt: widget.source?.createdAt ?? DateTime.now(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return AlertDialog(
      title: Text(widget.source == null ? '新增书源' : '编辑书源'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: _title,
            decoration: const InputDecoration(
              labelText: '名称',
              hintText: '例如：Z-Library（镜像 1）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '网址',
              hintText: 'https://example.com/',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          if (error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: error == null ? _submit : null, child: const Text('保存')),
      ],
    );
  }
}

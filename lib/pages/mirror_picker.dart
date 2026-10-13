import 'package:flutter/material.dart';

import '../services/book_source_directory.dart';
import 'book_sources_page.dart';

/// 从镜像状态站检索可用域名，返回用户选中的那一个
///
/// Z-Library 这类站点换域名很频繁，内置固定地址很快就会失效；
/// 状态站持续探测这些镜像，这里直接取「当前能用的」给用户选。
///
/// v1.21.22：多源聚合（并行）+ 2 小时本地缓存；全部源失败时给明确提示，
/// 并给一个「去手动书源」的入口兜底。
Future<MirrorEntry?> showMirrorPicker(
  BuildContext context, {
  String service = BookSourceDirectory.defaultService,
}) => showModalBottomSheet<MirrorEntry>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => _MirrorSheet(initialService: service),
);

class _MirrorSheet extends StatefulWidget {
  const _MirrorSheet({required this.initialService});

  final String initialService;

  @override
  State<_MirrorSheet> createState() => _MirrorSheetState();
}

class _MirrorSheetState extends State<_MirrorSheet> {
  late String _service = widget.initialService;
  late Future<DirectoryResult> _future = _load();

  Future<DirectoryResult> _load({bool forceRefresh = false}) =>
      BookSourceDirectory.fetch(service: _service, forceRefresh: forceRefresh);

  void _reload({String? service, bool forceRefresh = false}) {
    setState(() {
      if (service != null) _service = service;
      _future = _load(forceRefresh: forceRefresh);
    });
  }

  /// 兜底：直接去书源管理页手动加一个地址
  void _openManualSources() {
    Navigator.pop(context); // 先收起选择面板，避免两层页面叠着
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const BookSourcesPage()),
    );
  }

  /// 添加自定义状态源（v1.21.24）——内置源全挂时的最后兜底
  Future<void> _addCustomSource() async {
    final TextEditingController controller = TextEditingController();
    final String? input = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('添加自定义状态源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('填一个状态页或 Markdown 镜像列表的地址，'
                '会和内置源一起并行检索。'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: 'https://example.com/mirrors.md',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (String value) => Navigator.pop(dialogContext, value),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (input == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final List<String> before = await BookSourceDirectory.loadCustomSources();
    final List<String> after = await BookSourceDirectory.addCustomSource(input);
    if (!mounted) return;
    if (after.length == before.length) {
      messenger.showSnackBar(SnackBar(
        content: Text(BookSourceDirectory.normalizeSourceUrl(input) == null
            ? '地址不合法（要 http/https）'
            : '这个源已经加过了'),
      ));
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('已添加自定义状态源，正在重新检索…')));
    _reload(forceRefresh: true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.travel_explore, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('检索可用域名', style: theme.textTheme.titleMedium),
                  ),
                  TextButton.icon(
                    onPressed: () => _reload(forceRefresh: true),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('刷新'),
                  ),
                  IconButton(
                    tooltip: '添加自定义状态源',
                    onPressed: _addCustomSource,
                    icon: const Icon(Icons.add_link, size: 20),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '并行检索 ${BookSourceDirectory.directoryUrls.length} 个内置状态站'
                '（${BookSourceDirectory.directoryUrls.map((String u) => Uri.parse(u).host).join(' / ')}），'
                '本机实测后按可用性排序；结果缓存 ${BookSourceDirectory.cacheTtl.inHours} 小时。'
                '右上角可加自定义源。',
                style: theme.textTheme.bodySmall,
              ),
            ),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: <Widget>[
                  for (final item in BookSourceDirectory.services)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(item.$2),
                        selected: _service == item.$1,
                        onSelected: (_) => _reload(service: item.$1),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 16),
            Flexible(
              child: FutureBuilder<DirectoryResult>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snapshot.hasError) {
                    return _failed(context, '检索失败：${snapshot.error}');
                  }
                  final DirectoryResult result = snapshot.data ??
                      const DirectoryResult(entries: <MirrorEntry>[]);
                  final List<MirrorEntry> entries = result.entries;
                  if (entries.isEmpty) {
                    final String failedHosts = result.failedSources
                        .map((String u) => Uri.parse(u).host)
                        .join('、');
                    return _failed(
                      context,
                      '所有状态站都没返回可用域名'
                      '${failedHosts.isEmpty ? '' : '（$failedHosts）'}。\n'
                      '常见原因：网络不通 / 状态站改版。',
                    );
                  }
                  final String? sourceHost = result.sourceUrl == null
                      ? null
                      : Uri.parse(result.sourceUrl!).host;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (sourceHost != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '数据来自 $sourceHost'
                              '${result.fromCache ? '（本地缓存，${BookSourceDirectory.cacheTtl.inHours} 小时内有效）' : ''}'
                              ' · 第三方探测，仅供参考',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ),
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            final scheme = theme.colorScheme;
                            return ListTile(
                              leading: Icon(
                                entry.usable ? Icons.check_circle_outline : Icons.error_outline,
                                color: entry.usable ? scheme.primary : scheme.error,
                              ),
                              title: Text(entry.host, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text('${entry.statusLabel} · ${entry.url}'),
                              onTap: () => Navigator.pop(context, entry),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 全部失败：明确说明 + 重试 + 去手动书源（用户报"经常连不上"，这里给兜底）
  Widget _failed(BuildContext context, String message) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: <Widget>[
                FilledButton.tonal(
                  onPressed: () => _reload(forceRefresh: true),
                  child: const Text('重试'),
                ),
                OutlinedButton(
                  onPressed: _openManualSources,
                  child: const Text('去手动书源'),
                ),
              ],
            ),
          ],
        ),
      );
}

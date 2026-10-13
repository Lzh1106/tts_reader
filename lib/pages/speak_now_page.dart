import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/document_service.dart';
import '../services/speak_intake.dart';
import '../services/storage_service.dart';
import '../tts/tts_manager.dart';
import '../widgets/adaptive.dart';

/// 即读页（Speak Now）：T2S 四个朗读入口的统一落点。
///
/// - 打字朗读（[SpeakSource.type]）：空白进入，输入后朗读；
/// - 剪贴板朗读（[SpeakSource.clipboard]）：读剪贴板里的文本；
/// - 分享朗读 / 划词朗读 / 打开文本：其它应用把文本送进来，进来即开始朗读。
///
/// 朗读走 [TtsManager.speakLines] 的纯文本队列（与网页朗读同一条链路）：
/// 文本按 [DocumentService.readChunks] 切成不超过 240 字的片段，逐段朗读并高亮，
/// 点任意一段可从该段重读，配合上一段 / 下一段按钮完成「跳读」。
class SpeakNowPage extends StatefulWidget {
  const SpeakNowPage({
    super.key,
    this.initialText = '',
    this.source = SpeakSource.type,
    this.autoSpeak = false,
    this.fromExternalApp = false,
  });

  /// 初始文本（分享 / 划词送进来的正文，或剪贴板内容）
  final String initialText;

  /// 文本来源，决定标题与提示
  final SpeakSource source;

  /// 进入后是否立刻开始朗读
  final bool autoSpeak;

  /// 是否由外部应用唤起（显示「来自其他应用」提示条）
  final bool fromExternalApp;

  @override
  State<SpeakNowPage> createState() => _SpeakNowPageState();
}

class _SpeakNowPageState extends State<SpeakNowPage> {
  final TtsManager _tts = TtsManager.instance;
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final GlobalKey _activeKey = GlobalKey();

  List<String> _chunks = const <String>[];

  /// 编辑态：显示输入框；朗读态：显示分片列表 + 高亮
  bool _editing = true;

  /// 当前高亮片段（朗读结束后保留在最后读到的位置）
  int _active = 0;

  /// 上一次自动滚动到的片段，避免每帧都滚
  int? _followed;

  bool _ownsReading = false;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialText;
    if (widget.initialText.trim().isNotEmpty) {
      _editing = false;
      _chunks = DocumentService.readChunks(widget.initialText);
      if (widget.autoSpeak) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _start(0);
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 当前文本切成的可朗读片段
  List<String> get _preview => _chunks.isEmpty && _controller.text.trim().isNotEmpty
      ? DocumentService.readChunks(_controller.text)
      : _chunks;

  // ---------------- 朗读控制 ----------------

  void _start(int index) {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      _toast('请先输入或粘贴要朗读的文本');
      return;
    }
    final chunks = DocumentService.readChunks(text);
    if (chunks.isEmpty) {
      _toast('没有可朗读的内容');
      return;
    }
    setState(() {
      _chunks = chunks;
      _editing = false;
      _active = index < 0 ? 0 : (index >= chunks.length ? chunks.length - 1 : index);
      _followed = null;
      _ownsReading = true;
    });
    _tts.speakLines(chunks, start: _active);
  }

  void _togglePlay() {
    if (_tts.speaking && !_tts.paused) {
      _tts.pause();
      return;
    }
    if (_tts.speaking && _tts.paused) {
      _tts.resume();
      return;
    }
    _start(_active);
  }

  void _skip(int delta) {
    if (_chunks.isEmpty) {
      _start(0);
      return;
    }
    var target = _active + delta;
    if (target < 0) target = 0;
    if (target > _chunks.length - 1) target = _chunks.length - 1;
    _start(target);
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        _toast('剪贴板里没有文本');
        return;
      }
      if (!mounted) return;
      setState(() {
        _controller.text = text;
        _chunks = const <String>[];
      });
      _toast('已粘贴剪贴板文本，点播放开始朗读');
    } catch (_) {
      _toast('读取剪贴板失败');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _follow(int index) {
    if (index == _followed) return;
    _followed = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _activeKey.currentContext;
      if (context == null || !mounted) return;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 200),
        alignment: 0.4,
      );
    });
  }

  Future<void> _showRateSheet() async {
    var value = _tts.rate;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('语速 ${value.toStringAsFixed(2)}×', style: Theme.of(context).textTheme.titleMedium),
              Slider(
                value: value,
                min: 0.5,
                max: 2,
                divisions: 15,
                label: '${value.toStringAsFixed(2)}×',
                onChanged: (double next) {
                  setSheetState(() => value = next);
                  unawaited(_tts.setRate(next));
                },
              ),
              Text(
                '部分系统引擎对语速的支持有限，实际快慢可能与显示值略有差异。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- 界面 ----------------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _tts,
      builder: (context, _) {
        final reading = _ownsReading && _tts.readingPlain;
        if (reading && _tts.plainTotal == _chunks.length) {
          _active = _tts.plainIndex;
          _follow(_active);
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(_title()),
            actions: <Widget>[
              if (!_editing)
                IconButton(
                  tooltip: '语速',
                  onPressed: _showRateSheet,
                  icon: const Icon(Icons.speed),
                ),
              IconButton(
                tooltip: _editing ? '开始朗读' : '编辑文本',
                onPressed: () => setState(() => _editing = !_editing),
                icon: Icon(_editing ? Icons.play_circle_outline : Icons.edit_outlined),
              ),
            ],
          ),
          body: Column(
            children: <Widget>[
              if (widget.fromExternalApp && widget.initialText.trim().isNotEmpty)
                _hintBanner(context),
              if (_tts.error != null) _errorBanner(context, _tts.error!),
              Expanded(
                child: _editing
                    ? _editor(context)
                    : _readingBackground(child: _reader(context)),
              ),
            ],
          ),
          bottomNavigationBar: _editing ? _editBar(context) : _readBar(context, reading),
        );
      },
    );
  }

  String _title() {
    final label = widget.source.label;
    if (_editing) return label;
    return '$label · ${_chunks.length} 段';
  }

  Widget _hintBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: <Widget>[
          Icon(Icons.input, size: 18, color: scheme.onSecondaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '来自其他应用的文本，已切成 ${_preview.length} 段，点播放开始朗读',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(BuildContext context, String error) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }

  Widget _editor(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: TextField(
        controller: _controller,
        maxLines: null,
        expands: true,
        autofocus: widget.initialText.trim().isEmpty,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          alignLabelWithHint: true,
          hintText: '在这里输入或粘贴要朗读的文本（也可从其它应用分享 / 划词送进来）',
        ),
        onChanged: (_) {
          setState(() {
            _chunks = const <String>[];
            _active = 0;
          });
        },
      ),
    );
  }

  /// 阅读底色（跟随「阅读排版」设置；未设自定义底色则交给主题）
  Widget _readingBackground({required Widget child}) {
    final background = StorageService.instance.readerStyle.value.background;
    return background == null ? child : ColoredBox(color: background, child: child);
  }

  Widget _reader(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 与阅读页共用同一套排版 / 底色设置
    final style = StorageService.instance.readerStyle.value;
    final highlight = style.highlightColors(scheme);
    final chunks = _preview;
    // 平板横屏下限宽居中，和阅读页保持一致
    return ContentWidth(
      maxWidth: 820,
      child: ListView.builder(
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(style.pageMargin + 4, 8, style.pageMargin + 4, 24),
        itemCount: chunks.length,
        itemBuilder: (context, index) {
          final isActive = index == _active;
          return Padding(
            key: isActive ? _activeKey : null,
            padding: EdgeInsets.symmetric(vertical: style.paragraphSpacing / 2),
            child: InkWell(
              onTap: () => _start(index),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: isActive ? highlight.$1 : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Text(
                    chunks[index],
                    style: style.apply(theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
                      color: isActive ? highlight.$2 : style.theme.foreground,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _editBar(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: <Widget>[
              TextButton.icon(
                onPressed: _pasteFromClipboard,
                icon: const Icon(Icons.content_paste_go),
                label: const Text('粘贴'),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => setState(() {
                  _controller.clear();
                  _chunks = const <String>[];
                  _active = 0;
                }),
                icon: const Icon(Icons.clear_all),
                label: const Text('清空'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => _start(0),
                icon: const Icon(Icons.play_arrow),
                label: const Text('开始朗读'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _readBar(BuildContext context, bool reading) {
    final playing = reading && _tts.playing;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
              IconButton.filledTonal(
                tooltip: '上一段',
                onPressed: () => _skip(-1),
                icon: const Icon(Icons.skip_previous),
              ),
              IconButton.filledTonal(
                tooltip: '重读本段',
                onPressed: () => _start(_active),
                icon: const Icon(Icons.replay),
              ),
              IconButton.filled(
                tooltip: playing ? '暂停' : '播放',
                iconSize: 30,
                onPressed: _togglePlay,
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              ),
              IconButton.filledTonal(
                tooltip: '停止',
                onPressed: () => unawaited(_tts.stop()),
                icon: const Icon(Icons.stop),
              ),
              IconButton.filledTonal(
                tooltip: '下一段',
                onPressed: () => _skip(1),
                icon: const Icon(Icons.skip_next),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

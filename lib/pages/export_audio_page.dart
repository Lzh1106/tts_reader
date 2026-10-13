import 'dart:async';

import 'package:flutter/material.dart';

import '../models/structured_document.dart';
import '../services/audio_export.dart';
import '../services/text_processor.dart';
import '../tts/system_tts_synthesizer.dart';
import '../tts/tts_manager.dart';

/// 导出朗读音频（对应 T2S 的「导出为音频文件」）
///
/// 用系统 TTS 把文本合成成一个个音频文件，交给系统媒体库的「音乐」目录，
/// 之后可以用任意播放器离线听。范围可以只导当前章，也可以整本。
class ExportAudioPage extends StatefulWidget {
  const ExportAudioPage({
    super.key,
    required this.title,
    required this.chapters,
    required this.initialChapter,
  });

  /// 书名（用做文件名前缀）
  final String title;

  final List<Chapter> chapters;

  /// 打开时默认选中的章（朗读游标所在章）
  final int initialChapter;

  @override
  State<ExportAudioPage> createState() => _ExportAudioPageState();
}

class _ExportAudioPageState extends State<ExportAudioPage> {
  /// true = 只导当前章，false = 整本
  late bool _currentChapterOnly = true;

  late int _chapter = widget.initialChapter.clamp(
    0,
    widget.chapters.isEmpty ? 0 : widget.chapters.length - 1,
  );

  AudioExportPlan? _plan;
  AudioExportProgress? _progress;
  AudioExportReport? _report;
  SystemTtsSynthesizer? _synth;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _rebuildPlan();
  }

  @override
  void dispose() {
    _synth?.cancel();
    unawaited(_synth?.dispose());
    super.dispose();
  }

  /// 要导出的章：当前章或全部
  List<int> get _selectedChapters => _currentChapterOnly
      ? <int>[_chapter]
      : List<int>.generate(widget.chapters.length, (index) => index);

  void _rebuildPlan() {
    // 先套一遍朗读文本预处理规则：导出的音频要和播放时听到的一致
    final chapters = <(String, String)>[
      for (final index in _selectedChapters)
        (
          widget.chapters[index].title,
          TextProcessor.instance.apply(widget.chapters[index].text),
        ),
    ];
    _plan = AudioExporter.plan(chapters: chapters, baseName: widget.title);
  }

  /// 估算朗读时长：按每秒约 5 个字（正常语速）粗算，只用于给用户一个量级
  String get _estimate {
    final plan = _plan;
    if (plan == null || plan.isEmpty) return '';
    final seconds = (plan.totalChars / 5).round();
    final duration = seconds < 60
        ? '$seconds 秒'
        : '${(seconds / 60).round()} 分钟';
    return '共 ${plan.parts.length} 个文件 · ${plan.totalChars} 字 · 约 $duration';
  }

  Future<void> _start() async {
    final plan = _plan;
    if (plan == null || plan.isEmpty) {
      _snack('这一章没有可导出的文字');
      return;
    }
    if (!_currentChapterOnly && plan.parts.length > 300) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('整本导出耗时较长'),
          content: Text(
            '整本会生成 ${plan.parts.length} 个音频文件，'
            '合成过程要保持屏幕点亮，中途可以随时取消。\n确定开始吗？',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('开始导出'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    // 导出与朗读共用系统 TTS 引擎，先把朗读停下来，避免互相打断
    await TtsManager.instance.stop();
    if (!mounted) return;

    final synth = SystemTtsSynthesizer(
      rate: TtsManager.instance.rate,
      pitch: TtsManager.instance.pitch,
      voiceId: TtsManager.instance.voiceId,
    );
    _synth = synth;
    setState(() {
      _running = true;
      _report = null;
      _progress = const AudioExportProgress(done: 0, total: 0, failed: 0);
    });

    final report = await AudioExporter.run(
      plan,
      synth: synth.synthesize,
      isCancelled: () => !mounted || synth.isCancelled,
      onProgress: (progress) {
        if (mounted) setState(() => _progress = progress);
      },
    );
    await synth.dispose();
    if (!mounted) return;
    setState(() {
      _running = false;
      _report = report;
    });
  }

  void _cancel() {
    _synth?.cancel();
    setState(() {});
  }

  void _snack(String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plan = _plan;
    final progress = _progress;
    final report = _report;
    return Scaffold(
      appBar: AppBar(title: const Text('导出朗读音频')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: <Widget>[
          Card.filled(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '导出范围',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const <ButtonSegment<bool>>[
                      ButtonSegment<bool>(value: true, label: Text('当前章')),
                      ButtonSegment<bool>(value: false, label: Text('整本')),
                    ],
                    selected: <bool>{_currentChapterOnly},
                    onSelectionChanged: _running
                        ? null
                        : (selection) => setState(() {
                            _currentChapterOnly = selection.first;
                            _report = null;
                            _rebuildPlan();
                          }),
                  ),
                  if (_currentChapterOnly) ...<Widget>[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      value: _chapter,
                      decoration: const InputDecoration(
                        labelText: '章节',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: <DropdownMenuItem<int>>[
                        for (var index = 0; index < widget.chapters.length; index++)
                          DropdownMenuItem<int>(
                            value: index,
                            child: Text(
                              widget.chapters[index].title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: _running
                          ? null
                          : (value) => setState(() {
                              _chapter = value ?? _chapter;
                              _report = null;
                              _rebuildPlan();
                            }),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(_estimate, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
          Card.filled(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (_running) ...<Widget>[
                    LinearProgressIndicator(
                      value: progress == null || progress.total == 0
                          ? null
                          : progress.fraction,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '正在合成 ${progress?.done ?? 0}/${progress?.total ?? 0}'
                      '${(progress?.failed ?? 0) > 0 ? '（失败 ${progress!.failed}）' : ''}',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _cancel,
                      icon: const Icon(Icons.stop),
                      label: const Text('取消导出'),
                    ),
                  ] else
                    FilledButton.icon(
                      onPressed: plan == null || plan.isEmpty ? null : _start,
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('开始导出'),
                    ),
                ],
              ),
            ),
          ),
          if (report != null) _resultCard(report),
          Card.filled(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '说明',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '· 音频由系统 TTS 合成，文件保存在系统媒体库的「音乐」目录里，'
                    '文件名形如「书名-001.wav」，可以用任意播放器离线听。\n'
                    '· 每段一个文件：系统 TTS 单次合成有长度上限，一整本书必然要分段，'
                    '文件名末尾的三位序号就是播放顺序。\n'
                    '· 系统 TTS 单次合成长度有限，导出前会先按句子切片，不会丢字。\n'
                    '· 导出用的是手机自带的语音引擎，音色与「设置 → 语音」一致；'
                    '云端 TTS 不支持导出。\n'
                    '· 需要 Android 11 及以上（更早的系统要授予存储权限）。',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultCard(AudioExportReport report) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final succeeded = report.files.length;
    final failed = report.failed.length;
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  report.cancelled
                      ? Icons.pause_circle_outline
                      : (failed > 0 ? Icons.warning_amber_outlined : Icons.check_circle_outline),
                  color: report.cancelled
                      ? scheme.onSurfaceVariant
                      : (failed > 0 ? scheme.error : scheme.primary),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    report.cancelled
                        ? '已取消：成功 $succeeded 个'
                        : '导出完成：成功 $succeeded 个${failed > 0 ? '，失败 $failed 个' : ''}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            if (succeeded > 0) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '文件：${report.files.first}'
                '${succeeded > 1 ? ' … ${report.files.last}' : ''}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                '在「音乐」目录里可以找到这 $succeeded 个文件。',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (failed > 0) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '失败的片段可以重试；若整批都失败，请到系统设置里确认语音引擎有可用语音数据。',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

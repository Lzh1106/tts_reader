import 'dart:async';

import 'package:flutter/material.dart';

import '../services/speech_diag_export.dart';
import '../services/speech_diagnostics.dart';

/// 「导出朗读诊断」对话框（设置页与阅读页指示灯共用）。
///
/// 流程（v1.21.13 / B-P3）：
/// ① 勾选是否「包含全部事件」；
/// ② 行数达到 [SpeechDiagExport.largeExportLineThreshold] 时先确认一次；
/// ③ 导出期间对话框里显示进度（主线程逐行写 → 有逐行进度；超大导出走隔离线程
///    → 只有不确定进度）；
/// ④ 结论交回调用方，由调用方弹 SnackBar（路径 + 体积 KB）。
Future<void> showSpeechDiagExportDialog(BuildContext context) async {
  final SpeechDiagExportOutcome? outcome =
      await showDialog<SpeechDiagExportOutcome>(
    context: context,
    builder: (dialogContext) => const _SpeechDiagExportDialog(),
  );
  if (outcome == null || !context.mounted) return;

  final SpeechDiagCopyResult? copied = outcome.copy;
  if (copied != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(copied.message)),
    );
    return;
  }

  final SpeechDiagWriteResult? result = outcome.result;
  if (result == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('导出失败：${outcome.error}')),
    );
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('已导出 ${result.sizeText}：${result.path}'),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(
        label: '分享',
        onPressed: () {
          // 分享的就是刚写出的那一份（目录里文件名按时间戳排序，最新的在最前）
          unawaited(SpeechDiagExport.shareLatest().catchError((Object _) => null));
        },
      ),
    ),
  );
}

class _SpeechDiagExportDialog extends StatefulWidget {
  const _SpeechDiagExportDialog();

  @override
  State<_SpeechDiagExportDialog> createState() =>
      _SpeechDiagExportDialogState();
}

class _SpeechDiagExportDialogState extends State<_SpeechDiagExportDialog> {
  bool _includeAll = false;
  bool _busy = false;

  /// 走隔离线程（大导出）时没有逐行进度，只能给不确定进度条。
  bool _isolated = false;
  int _written = 0;
  int _total = 0;

  Future<void> _runExport() async {
    final Map<String, String> metaSnapshot = SpeechDiagExport.meta();
    final int estimate = SpeechDiagnostics.instance.estimateExportLines(
      includeAllEvents: _includeAll,
      meta: metaSnapshot,
    );
    final bool isolated = SpeechDiagExport.needsLargeExportConfirm(estimate);

    if (isolated) {
      final bool? go = await showDialog<bool>(
        context: context,
        builder: (confirmContext) => AlertDialog(
          title: const Text('这次导出很大'),
          content: Text(
            '本次要写出约 $estimate 行'
            '（达到 ${SpeechDiagExport.largeExportLineThreshold} 行阈值）。\n\n'
            '导出会在后台线程里逐行写，界面不会卡，但可能要几秒到几十秒。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(confirmContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(confirmContext).pop(true),
              child: const Text('继续导出'),
            ),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }

    setState(() {
      _busy = true;
      _isolated = isolated;
      _written = 0;
      _total = estimate;
    });

    try {
      final SpeechDiagWriteResult result = await SpeechDiagExport.writeFile(
        includeAllEvents: _includeAll,
        onProgress: isolated
            ? null
            : (int written) {
                if (!mounted) return;
                setState(() => _written = written);
              },
      );
      if (!mounted) return;
      Navigator.of(context).pop(SpeechDiagExportOutcome.ok(result));
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(SpeechDiagExportOutcome.failed(e));
    }
  }

  Future<void> _copySummary() async {
    final SpeechDiagCopyResult result =
        await SpeechDiagExport.copyToClipboard(includeAllEvents: _includeAll);
    if (!mounted) return;
    Navigator.of(context).pop(SpeechDiagExportOutcome.copied(result));
  }

  @override
  Widget build(BuildContext context) {
    final int eventCount = SpeechDiagnostics.instance.eventCount;
    final SpeechDiagReport report = SpeechDiagnostics.instance.analyze();
    return AlertDialog(
      title: const Text('导出朗读诊断'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('当前事件 $eventCount 条，'
              '判定 ${SpeechDiagnostics.levelEmoji(report.level)}'
              '${report.hitsSummary.isEmpty ? '' : '（${report.hitsSummary}）'}'),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _includeAll,
            onChanged: _busy
                ? null
                : (bool? value) =>
                    setState(() => _includeAll = value ?? false),
            title: const Text('包含全部事件'),
            subtitle: const Text('默认只导「元信息 + 判定摘要 + 异常窗口」；'
                '勾上会把每条事件都写进去（文件更大）'),
          ),
          const Text(
            '默认落点：app_flutter/speech_diag/speech_diag_<时间戳>.log，'
            '可用 `adb shell run-as com.example.tts_reader cat <路径>` 直接取走。',
            style: TextStyle(fontSize: 12),
          ),
          if (_includeAll) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '已勾选「包含全部事件」：复制到剪贴板只会复制前 '
              '${speechDiagSizeText(SpeechDiagExport.clipboardByteLimit)}'
              '（超出部分自动截断），完整内容请用「导出」落盘。',
              style: const TextStyle(fontSize: 12),
            ),
          ],
          if (_busy) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _isolated
                  ? '正在导出（大文件走后台线程，界面不会卡）…'
                  : '正在导出… $_written / $_total 行',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: _isolated || _total <= 0
                  ? null
                  : (_written / _total).clamp(0.0, 1.0),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        // B-P4：复制改成「超 500KB 自动按行截断 + 尾注说明」之后，
        // 事件多也能安全复制，不再限制「只在事件数较少时提供」。
        if (!_busy)
          TextButton(
            onPressed: () => unawaited(_copySummary()),
            child: const Text('复制到剪贴板'),
          ),
        FilledButton(
          onPressed: _busy ? null : () => unawaited(_runExport()),
          child: const Text('导出'),
        ),
      ],
    );
  }
}

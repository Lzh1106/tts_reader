import 'dart:async';

import 'package:flutter/material.dart';

import '../services/speech_diag_export.dart';
import '../services/speech_diagnostics.dart';
import '../services/storage_service.dart';
import 'speech_diag_export_dialog.dart';

/// 朗读诊断指示灯（阅读页 / PDF 原版式页共用）。
///
/// v1.21.13 / B-P5：原先它是 `ReaderPage` 里的内联 `FloatingActionButton`
/// （`reader_page.dart` 私有方法），所以只有走 `ReaderPage` 的 TXT / EPUB /
/// PDF **文本模式**有指示灯，**PDF 原版式**（`PdfReadingPage`）没有。
/// 这里把结构原样搬出来，两个页面共用同一个实现。
///
/// ⚠️ 门控（照搬原注释）：只在用户于设置里显式打开「朗读诊断」时出现，**默认关**。
/// 这里**不能**写成 `kDebugMode || ...`：`flutter test` 也是在 debug 下跑的，
/// 那样指示灯会出现在所有 widget 测试里 —— 实测会让
/// `reader_ui_features_test` 的两条「控制中心折叠」用例找不到控制条
/// （Scaffold 多了 FAB 之后布局/命中行为变化）。
///
/// 返回 null = 诊断关闭（调用方塞 `Scaffold.floatingActionButton` 时就是「没有」，
/// 塞 Stack 时用 `if (x != null)` 跳过，两种情况都不占布局）。
///
/// [heroTag] 必须每个页面不同：阅读页与 PDF 页都挂 FAB 时，同名 Hero 会在
/// 路由切换动画里撞车（"multiple heroes that share the same tag"）。
Widget? speechDiagIndicator(
  BuildContext context, {
  String heroTag = 'speech-diag-indicator',
}) {
  if (!StorageService.instance.speechDiagEnabled.value) return null;
  final SpeechDiagReport report = SpeechDiagnostics.instance.analyze();
  _autoSaveIfNewRed(report);
  return FloatingActionButton.small(
    heroTag: heroTag,
    tooltip: '朗读诊断 ${SpeechDiagnostics.levelEmoji(report.level)}'
        '${report.hitsSummary.isEmpty ? '' : ' · ${report.hitsSummary}'}',
    backgroundColor:
        report.hasRed ? Theme.of(context).colorScheme.errorContainer : null,
    onPressed: () => unawaited(showSpeechDiagSheet(context)),
    child: Text(
      SpeechDiagnostics.levelEmoji(report.level),
      style: const TextStyle(fontSize: 16),
    ),
  );
}

/// 上一次自动落盘时的命中数（避免每帧重复写盘）。
///
/// 放在模块级而不是 State 里：指示灯现在由两个页面共用，落盘节流也该是全局的。
int _diagAutoSavedHits = 0;

/// 出现 🔴 且命中数变了 → 自动覆盖落盘一份（失败不影响朗读）。
void _autoSaveIfNewRed(SpeechDiagReport report) {
  if (!report.hasRed || report.hits.length == _diagAutoSavedHits) return;
  _diagAutoSavedHits = report.hits.length;
  unawaited(() async {
    try {
      await SpeechDiagExport.writeRolling();
    } catch (_) {
      // 落盘失败不影响朗读
    }
  }());
}

/// 点开指示灯：最近 50 条事件 + 判定结果 + 导出入口。
Future<void> showSpeechDiagSheet(BuildContext context) async {
  final SpeechDiagnostics diag = SpeechDiagnostics.instance;
  final SpeechDiagReport report = diag.analyze();
  final List<String> lines = diag.recentLines(50);
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '朗读诊断 ${SpeechDiagnostics.levelEmoji(report.level)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              report.hitsSummary.isEmpty
                  ? '未命中任何判据（事件 ${diag.eventCount} 条）'
                  : '命中：${report.hitsSummary}（事件 ${diag.eventCount} 条）',
            ),
            const SizedBox(height: 10),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: lines.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    lines[index],
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(() async {
                      // B-P4：复制完把「用了多少 KB / 有没有截断」告诉用户
                      final SpeechDiagCopyResult result =
                          await SpeechDiagExport.copyToClipboard(
                              includeAllEvents: false);
                      messenger.showSnackBar(
                        SnackBar(content: Text(result.message)),
                      );
                    }());
                  },
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('复制摘要'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(showSpeechDiagExportDialog(context));
                  },
                  icon: const Icon(Icons.ios_share_outlined),
                  label: const Text('导出'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

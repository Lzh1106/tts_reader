import 'package:flutter/material.dart';

import 'pdf_read_session.dart';

/// PDF 朗读页的控制栏：**迷你条** 与 **展开态**。
///
/// ## 行为对齐 HANDOFF §4.92
///
/// 方块键（■）在阅读页的语义是「**收起成迷你条**，会话保留」——
/// 与文档库那条「整条消失 + 会话清掉」**不一样**，别一起改。
///
/// ```
/// 迷你条：  ▶  《书名》· 第 3/319 页                        ⌃
/// 展开态：  ⏮  ⏯  ⏭   |  语速 1.0×  |  目录  |  ⌄  |  ■
/// ```
///
/// 迷你条的圆形播放键 = [PdfReadSession.resume]（从当前句继续），
/// 箭头展开成完整控制条；展开态的「⌄」收起回迷你条。
class PdfControlBar extends StatelessWidget {
  const PdfControlBar({
    super.key,
    required this.collapsed,
    required this.title,
    required this.pageLabel,
    required this.playing,
    required this.paused,
    required this.rate,
    required this.onToggleCollapsed,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
    required this.onStop,
    required this.onRateChanged,
    required this.onOpenToc,
  });

  /// 是否收起成迷你条
  final bool collapsed;

  final String title;
  final String pageLabel;

  /// **正在出声**（暂停态为 false）
  final bool playing;

  /// **暂停**（与"方块键停声"区分开）
  ///
  /// ⚠️ v1.21.38：这两个字段必须分开传（原来是只看 `playing` 的二态）。
  /// 用户报的「方块键停声后，通知栏暂停/播放与栏内不同步」根因就在这里：
  /// - 通知栏的判据是 `hasSession && playing && !paused`（三态）；
  /// - 而栏内原来只有 `playing`，于是"暂停"与"方块键停声"都显示成 ▶，
  ///   用户按栏内 ▶ 时走的分支却不一样（`_togglePlayPause` 要看 `isPaused`）。
  /// 现在两处共用同一套三态口径，图标与行为不会再分叉。
  final bool paused;

  final double rate;

  final VoidCallback onToggleCollapsed;
  final VoidCallback onPlayPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onStop;
  final ValueChanged<double> onRateChanged;
  final VoidCallback onOpenToc;

  static const Key miniBarKey = ValueKey<String>('pdf-control-mini');
  static const Key expandedKey = ValueKey<String>('pdf-control-expanded');
  static const Key playPauseKey = ValueKey<String>('pdf-control-play-pause');
  static const Key stopKey = ValueKey<String>('pdf-control-stop');
  static const Key prevKey = ValueKey<String>('pdf-control-prev');
  static const Key nextKey = ValueKey<String>('pdf-control-next');
  static const Key tocKey = ValueKey<String>('pdf-control-toc');
  static const Key expandKey = ValueKey<String>('pdf-control-expand');
  static const Key collapseKey = ValueKey<String>('pdf-control-collapse');

  /// 语速档位（与原阅读页一致）
  static const List<double> ratePresets = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: collapsed
            ? _miniBar(context, theme)
            : _expandedBar(context, theme),
      ),
    );
  }

  /// 46dp 迷你条：圆形播放键 + 「《书名》· 第 N/M 页」+ 展开箭头
  Widget _miniBar(BuildContext context, ThemeData theme) {
    return SizedBox(
      key: miniBarKey,
      height: 46,
      child: Row(
        children: <Widget>[
          const SizedBox(width: 4),
          SizedBox(
            width: 36,
            height: 36,
            child: IconButton(
              key: playPauseKey,
              padding: EdgeInsets.zero,
              iconSize: 22,
              // 迷你条的播放键语义是「继续」（从当前句接着读）
              onPressed: onPlayPause,
              icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
              tooltip: playing ? '暂停' : '继续朗读',
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$title · $pageLabel',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          IconButton(
            key: expandKey,
            onPressed: onToggleCollapsed,
            icon: const Icon(Icons.keyboard_arrow_up),
            tooltip: '展开控制栏',
          ),
        ],
      ),
    );
  }

  Widget _expandedBar(BuildContext context, ThemeData theme) {
    return Column(
      key: expandedKey,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // 第一行：书名 + 页码 + 收起
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              Text(pageLabel, style: theme.textTheme.labelMedium),
              IconButton(
                key: collapseKey,
                onPressed: onToggleCollapsed,
                icon: const Icon(Icons.keyboard_arrow_down),
                tooltip: '收起成小条',
              ),
            ],
          ),
        ),
        // 第二行：播放控制
        //
        // ⚠️ IconButton 默认 48×48（HANDOFF §9.45）：这一行有 4 个按钮，
        // 窄屏（320dp）会 overflow。用 Wrap 而不是 Row 兜住。
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            IconButton(
              key: prevKey,
              onPressed: onPrevious,
              icon: const Icon(Icons.skip_previous),
              tooltip: '上一句',
            ),
            IconButton(
              key: playPauseKey,
              onPressed: onPlayPause,
              iconSize: 32,
              icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
              tooltip: playing ? '暂停' : '继续朗读',
            ),
            IconButton(
              key: nextKey,
              onPressed: onNext,
              icon: const Icon(Icons.skip_next),
              tooltip: '下一句',
            ),
            IconButton(
              key: tocKey,
              onPressed: onOpenToc,
              icon: const Icon(Icons.list_alt),
              tooltip: '目录',
            ),
            IconButton(
              key: stopKey,
              onPressed: onStop,
              icon: const Icon(Icons.stop),
              tooltip: '结束朗读',
            ),
          ],
        ),
        // 第三行：语速
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(
            children: <Widget>[
              Text('语速', style: theme.textTheme.labelMedium),
              Expanded(
                child: Slider(
                  value: _nearestPreset(rate),
                  min: 0,
                  max: (ratePresets.length - 1).toDouble(),
                  divisions: ratePresets.length - 1,
                  label: '${_nearestPreset(rate).toStringAsFixed(2)}×',
                  onChanged: (value) =>
                      onRateChanged(ratePresets[value.round()]),
                ),
              ),
              Text('${rate.toStringAsFixed(2)}×',
                  style: theme.textTheme.labelMedium),
            ],
          ),
        ),
      ],
    );
  }

  /// 把任意语速吸附到最近的档位（滑块只能停在这些点上）
  double _nearestPreset(double value) {
    var best = ratePresets.first;
    for (final preset in ratePresets) {
      if ((preset - value).abs() < (best - value).abs()) best = preset;
    }
    return best;
  }
}

/// 通知栏 / 耳机按键的**音频会话来源**抽象。
///
/// ## 为什么要有这层
///
/// 通知栏（`TtsAudioHandler`）原来直接抓着 `TtsManager`。但 PDF 朗读是一条
/// **平行的会话**（`PdfReadSession`）——它的位置自持、不读 `TtsManager.cursor`，
/// 两者没有从属关系。如果 handler 继续硬绑 `TtsManager`，PDF 在放的时候
/// 通知栏就只能显示 TXT 那一套（或者干脆不显示）。
///
/// 所以把「handler 需要会话提供什么」抽成这个接口，两个实现各给一份：
///
/// | 实现 | 说明 |
/// | --- | --- |
/// | `TtsManager` | 原有行为，**一个字节都不改语义**（有设备用例守着） |
/// | `PdfReadSession` | PDF 会话：进度按页算，seek 不可用 |
///
/// ## 两个实现必须在的地方
///
/// handler 通过 [TtsAudioHandler.activate] 切换当前来源，`activate` 的调用点
/// 只有三处（对齐 HANDOFF §4.65 的教训：**绝不能放进 `TtsManager.stop()`**，
/// 那会把 registerEngine / 换书路径里正常的 stop 也变成换源）：
///
/// 1. `TtsManager._restart()` 开头；
/// 2. `TtsManager.speakLines()` 开头；
/// 3. `PdfReadSession.startAt()` 开头。
abstract class AudioSessionSource {
  /// 音频会话的稳定标识：**同一个 id 重复 activate 是幂等的**。
  ///
  /// handler 用它判「这次 activate 是不是换了来源」——
  /// 不判的话每读一句都会重建通知，进度条会闪。
  String get sourceId;

  /// 会话是否还活着（决定控制栏显不显示、通知要不要留）
  bool get hasSession;

  /// 被顶替时要做的收尾（切到别的来源时处理器会调它）
  ///
  /// 实现要在这里停掉自己的声音与推送：否则旧来源还会继续往同一条通知上
  /// 推状态，出现「两本书抢一条通知」。
  void onStop();

  /// 正在出声（未暂停）
  bool get playing;

  /// 已暂停（会话还在，只是没出声）
  bool get paused;

  /// 通知栏主标题（书名）
  String get documentTitle;

  /// 通知栏副标题（「第 3/319 页 · 第 2 句」这类）
  String get positionLabel;

  /// 说话速率（通知栏 `PlaybackState.speed`）
  double get rate;

  /// 伪时间轴的总刻度 / 当前刻度
  ///
  /// 原实现是「每单元一秒」的伪时间轴（HANDOFF §4.6），PDF 会话沿用同一套
  /// 刻度约定，只是「单元」的含义不同（TXT = 句，PDF = 页）。
  int get progressTotal;
  int get progressIndex;

  /// **进度条能不能拖**
  ///
  /// TXT 会话为 true（原有行为：`systemActions: {seek}` 支持拖动跳转）；
  /// PDF 会话为 false —— 拖到「第 5.3 句」没有意义，而且 PDF 的位置跳转
  /// 必须走整页/整句，不能按比例插值。
  ///
  /// ⚠️ 用**能力标志**而不是「拖了抛异常」：抛异常会被上层吞掉，
  /// 用户看到的是「拖了没反应」，那比不给拖还糟。
  bool get canSeek;

  /// 从当前位置继续（通知栏播放键 / 耳机播放键）
  void playFromCursor();

  /// 暂停
  Future<void> pause();

  /// 按比例跳转（通知栏拖动）。只在 [canSeek] 为真时被调用。
  void seekToProgress(double fraction);

  /// 「上一首 / 下一首」。TXT 语义是**章**（原有行为）；
  /// PDF 一章即一页（HANDOFF §4.28），所以映射到相邻页的首句。
  void skipChapter(int delta);

  /// 按句前进 / 后退
  void skipSentenceForward();
  void skipSentenceBackward();

  /// 快进 / 快退（部分耳机长按映射到这里）：TXT 是**翻页**，PDF 也按页
  void skipPageForward();
  void skipPageBackward();
}

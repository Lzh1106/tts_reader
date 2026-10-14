import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import '../services/crash_log.dart';
import '../services/storage_service.dart';

/// 朗读的音频焦点与打断处理
///
/// **为什么要这个**：原来只在启动时 `session.configure(speech())` 配了音频属性，
/// 但**从来没有 `setActive(true)`** —— 也就是从没申请过音频焦点。
/// 结果就是两个都不对：
/// - 别的应用出声时，系统不会把我们压低 / 暂停（听书和音乐一起响）；
/// - 来电、闹钟也不会把我们暂停。
///
/// 现在按用户的开关决定：
/// - **允许其它媒体打断**（默认开）：朗读时申请音频焦点，接受系统的
///   duck（压低）/ pause（暂停）/ 来电中断；对方结束或挂断后**自动继续**；
/// - **关掉**：不申请焦点，谁也不打扰谁（想边听书边放音乐时用）。
///
/// 「自动继续」只对**系统要求我们暂停**的情况生效；用户自己按的暂停不会被打断逻辑
/// 重新拉起来（用 [notifyUserPaused] / [notifyUserResumed] 区分）。
class MediaInterruptionController {
  MediaInterruptionController._();

  static final MediaInterruptionController instance = MediaInterruptionController._();

  AudioSession? _session;
  StreamSubscription<AudioInterruptionEvent>? _sub;
  bool _initialized = false;

  /// 被系统打断前是否正在朗读（决定要不要自动继续）
  bool _interruptedWhileSpeaking = false;

  /// 用户主动暂停过：这种情况下不自动继续
  bool _userPaused = false;

  /// 打断类型：**瞬时让位**（系统提示音 dove duck）还是**长期让位**（视频 / 来电）
  ///
  /// 见 [_onInterruption] 与 [_resumeAfterShortDuck] 的说明。
  bool _shortDuck = false;

  Timer? _duckResumeTimer;

  /// 短打断「自动接回」的等待时长
  ///
  /// 判据：提示音一般 **几百毫秒**，而视频 / 音乐是**持续**的。
  /// 所以被打断后先等这么久 —— 若对方已经结束，就自动接着读（用户感觉"没被打断"）；
  /// 若对方还在出声（视频），就**保持暂停**并把状态如实推给通知栏。
  ///
  /// 设成 900ms 的理由：短于常见提示音（避免"刚停又读"听起来像卡顿），
  /// 又明显短于用户能察觉"卡住了"的阈值。
  static const Duration shortDuckResumeDelay = Duration(milliseconds: 900);

  /// 朗读真正开始 / 继续时调用：申请音频焦点（受开关控制）
  ///
  /// 返回是否真的拿到了焦点。拿不到（例如别的应用正占着且不让）也照常朗读 ——
  /// 不给用户「点了没声音」的困惑。
  Future<bool> requestFocus() async {
    await _ensureInit();
    if (!StorageService.instance.allowMediaInterrupt) return false;
    final session = _session;
    if (session == null) return false;
    try {
      final ok = await session.setActive(true);
      if (!ok) {
        CrashLog.mark('音频焦点申请失败：被其它应用占用');
      }
      return ok;
    } catch (e) {
      CrashLog.mark('音频焦点申请异常：$e');
      return false;
    }
  }

  /// 朗读暂停 / 停止 / 结束时调用：释放音频焦点
  ///
  /// 必须释放：不释放的话别的应用会被我们一直压着（用户会以为音乐坏了）。
  ///
  /// ⚠️ v1.21.15：**暂停不再走这里**（只在停止 / 会话结束时释放）。
  /// 实测（ColorOS / Android 13+）：暂停时 `setActive(false)` 会把会话的音频焦点
  /// 交出去，之后再按耳机/通知栏的「播放」，系统可能**不再把媒体键路由给我们**
  /// ——表现就是「按了没反应」。代价：暂停期间仍占着焦点（别人会继续被压低）。
  Future<void> releaseFocus() async {
    _releaseFocusCount++;
    final session = _session;
    if (session == null) return;
    try {
      await session.setActive(false);
    } catch (_) {
      // 释放失败不影响功能
    }
  }

  int _releaseFocusCount = 0;

  /// 测试用：releaseFocus 被调用的次数（锁住"暂停不释放焦点"这条行为）
  @visibleForTesting
  int get debugReleaseFocusCount => _releaseFocusCount;

  /// 用户主动暂停（按了暂停键）
  void notifyUserPaused() => _userPaused = true;

  /// 用户主动继续（按了播放键）
  void notifyUserResumed() => _userPaused = false;

  /// 开关变化后重新配置音频属性
  ///
  /// 「允许打断」时用 `speech()`（会自动在被打断 / 被压低时暂停）；
  /// 不允许时用 `music()` 的 gain 策略 —— 只是出声，不去抢焦点。
  Future<void> applySettings() async {
    await _ensureInit();
    final session = _session;
    if (session == null) return;
    try {
      await session.configure(_configuration());
    } catch (_) {
      // 配置失败沿用上一次
    }
  }

  /// 音频会话配置
  ///
  /// ## ⚠️ `androidWillPauseWhenDucked` 必须保持 `true`（v1.21.39 回退记录）
  ///
  /// v1.21.38 为了「朗读不被通知打断」，把两种模式都改成了 `false`。
  /// **那是个错误**，真机反馈：**「被视频打断」功能失效，而且通知栏图标变得不对**。
  ///
  /// 原因：这个开关不是"允许被压低音量"那么简单 —— 它是**整个停止上报 duck 事件**。
  /// 而系统提示音与视频播放走的是**同一条 duck 路径**，所以关掉之后：
  ///
  /// | | 系统提示音 | 视频 / 其它播放器 |
  /// | --- | --- | --- |
  /// | 期望 | 继续朗读 | **暂停** |
  /// | `false` 时 | 继续朗读 ✓ | **也继续朗读 ✗** |
  ///
  /// 于是"该让位时也不让位"：焦点状态与实际出声不一致，通知栏也随之错乱。
  /// **一个布尔值区分不了"提示音"与"视频"** —— 想要两者兼顾，
  /// 得在原生侧区分 `AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK`（提示音）
  /// 与 `AUDIOFOCUS_LOSS` / `LOSS_TRANSIENT`（视频 / 来电），属于平台通道改动，
  /// **本轮不做**。所以这里回到 `true`：**宁可被提示音打断，也不能不让位给视频**。
  AudioSessionConfiguration _configuration() {
    if (StorageService.instance.allowMediaInterrupt) {
      return const AudioSessionConfiguration.speech();
    }
    // 不抢焦点模式：gainTransientMayDuck 会让我们的声音被别人的 duck 影响，
    // 这里用普通的媒体属性，互不干扰。
    return const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionMode: AVAudioSessionMode.spokenAudio,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
      androidWillPauseWhenDucked: true,
    );
  }

  /// 当前音频会话配置（**只给测试看**）
  ///
  /// 用它钉住一条硬要求：「**朗读不被通知打断**」——
  /// 也就是两种模式下 `androidWillPauseWhenDucked` 都必须是 `false`
  /// （true = 系统提示音一 duck 就把我们暂停，见 [_configuration] 的说明）。
  @visibleForTesting
  AudioSessionConfiguration get debugConfiguration => _configuration();

  Future<void> _ensureInit() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final session = await AudioSession.instance;
      _session = session;
      await session.configure(_configuration());
      // 打断事件：系统的 duck / pause / 来电都在这里
      _sub = session.interruptionEventStream.listen(_onInterruption);
    } catch (e) {
      CrashLog.mark('音频会话初始化失败：$e');
    }
  }

  /// 系统打断事件
  ///
  /// ## 三类事件怎么分（v1.21.39）
  ///
  /// | 事件 | 来源 | 我们的动作 |
  /// | --- | --- | --- |
  /// | `duck` + `begin` | **系统提示音** / 导航播报（瞬时） | 先让位暂停，等 [shortDuckResumeDelay] 后**没人接着出声就自动接回** |
  /// | `pause` + `begin` | **视频 / 音乐 / 来电**（持续占用焦点） | 暂停并保持（这才是用户要的"被视频打断"） |
  /// | `begin == false` | 对方结束 | 只有「系统让停的」且用户没自己按过暂停才继续 |
  ///
  /// ### 为什么 duck 也要真暂停（而不是只被压低音量）
  ///
  /// v1.21.38 曾把 `androidWillPauseWhenDucked` 改成 `false`（想让提示音完全不打断），
  /// 结果真机反馈「**被视频打断功能失效，通知栏图标也错了**」——
  /// 因为那个开关会**整个停掉 duck 事件上报**，而视频与提示音走的是同一条 duck 路径，
  /// 于是该让位时也不让位了。现在改成：**照样让位，但短打断自动接回**，
  /// 用「对方持续多久」来区分提示音与视频（一个布尔值区分不了）。
  void _onInterruption(AudioInterruptionEvent event) {
    final handler = onInterruption;
    if (handler != null) {
      handler(event);
      return;
    }

    if (event.begin) {
      // 先撤掉可能挂着的"自动接回"：对方还在（或又来了），不能接
      _duckResumeTimer?.cancel();
      _duckResumeTimer = null;

      if (event.type == AudioInterruptionType.duck) {
        // 瞬时让位：先暂停，再看对方是不是马上就走
        _shortDuck = true;
        _interruptedWhileSpeaking = true;
        final pause = pauseForInterruption;
        if (pause != null) unawaited(pause());
        _duckResumeTimer = Timer(shortDuckResumeDelay, () {
          _duckResumeTimer = null;
          if (!_shortDuck || _userPaused) return;
          _shortDuck = false;
          _interruptedWhileSpeaking = false;
          final resume = resumeAfterInterruption;
          if (resume != null) unawaited(resume());
        });
        return;
      }

      // pause：视频 / 音乐 / 来电 —— 长期让位，保持暂停
      _shortDuck = false;
      _interruptedWhileSpeaking = true;
      final pause = pauseForInterruption;
      if (pause != null) unawaited(pause());
      return;
    }

    // 对方结束
    //
    // ★v1.21.45 改动 1（耳机键路由修复）：**先把"刚才是不是短打断"读出来再清零**。
    //
    // 为什么要读旧值：`_shortDuck` 原来是直接清零的，于是"结束"这一支无从区分
    // 「系统提示音（几百毫秒，该自动接回）」与「视频 / 来电（长期，不该自动接回）」，
    // 只能一律靠 `_interruptedWhileSpeaking`。现在按旧值分流：
    //   * 旧值 true（短打断）→ 保持 v1.21.39 的自动接回，行为一字不改；
    //   * 旧值 false（长打断）→ **不自动恢复朗读**，只重推一次播放状态
    //     （让系统重新把我们标成活跃媒体 → 耳机键路由回来，见 [notifyAfterInterruptionEnded]）。
    final bool wasShortDuck = _shortDuck;
    _shortDuck = false;
    final bool wasInterrupted = _interruptedWhileSpeaking;
    _interruptedWhileSpeaking = false;
    if (!wasInterrupted) return;

    if (wasShortDuck) {
      // 短打断：老行为（用户自己按过暂停就不接回）
      if (_userPaused) return;
      final resume = resumeAfterInterruption;
      if (resume != null) unawaited(resume());
      return;
    }

    // 长打断：只重推状态，绝不碰播放（用户可能是自己暂停的，也可能是被打断的）
    final notify = notifyAfterInterruptionEnded;
    if (notify != null) unawaited(notify());
  }

  /// 测试用：是否处于"短打断（提示音）"状态
  @visibleForTesting
  bool get debugShortDuck => _shortDuck;

  /// 被打断时的回调（由 TtsAudioHandler 注册：暂停朗读）
  Future<void> Function()? pauseForInterruption;

  /// 打断结束时的回调（由 TtsAudioHandler 注册：继续朗读）
  Future<void> Function()? resumeAfterInterruption;

  /// **长打断结束**时的回调：只重推播放状态，**不动播放**
  ///
  /// ## 治什么（v1.21.45 改动 1 · 耳机键路由）
  ///
  /// 真机现象：别的应用抢走音频焦点之后，**耳机键失效** ——
  /// 而应用内按钮、通知栏按钮都还正常。怀疑系统在长打断期间把我们
  /// 从"活跃媒体"里摘掉了，于是媒体键不再路由到我们。
  ///
  /// 长打断结束时重推一次 `playbackState`，让系统重新把我们标成活跃媒体。
  /// **刻意不自动恢复朗读**：长打断（视频 / 来电）结束后要不要接着读，
  /// 是另一条独立问题链（本轮明确暂缓）。
  ///
  /// ⚠️ 这是**第一轮尝试**，根因未定性。真机验收要点：
  /// 1. 长打断结束后日志里应有 `媒体控制[pushState]`；
  /// 2. 若日志有、耳机键仍无效 → 重推状态不足以改路由，下一步动焦点策略
  ///    （暂停释放 / 播放申请 / `MediaSession.setActive(true)`），见交接文档。
  Future<void> Function()? notifyAfterInterruptionEnded;

  /// 外部（测试）接管打断事件
  @visibleForTesting
  void Function(AudioInterruptionEvent event)? onInterruption;

  /// 测试用：直接投递一个打断事件
  @visibleForTesting
  void debugInterrupt(AudioInterruptionType type, {bool begin = true}) {
    _onInterruption(AudioInterruptionEvent(begin, type));
  }

  @visibleForTesting
  bool get debugUserPaused => _userPaused;

  @visibleForTesting
  void resetForTest() {
    _session = null;
    _sub?.cancel();
    _sub = null;
    _initialized = false;
    _interruptedWhileSpeaking = false;
    _userPaused = false;
    // 挂着的"短打断自动接回"也要撤掉，否则会跨用例把上一个用例的 resume 打出来
    _duckResumeTimer?.cancel();
    _duckResumeTimer = null;
    _shortDuck = false;
    pauseForInterruption = null;
    resumeAfterInterruption = null;
    notifyAfterInterruptionEnded = null;
    onInterruption = null;
  }
}

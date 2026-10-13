import 'dart:async';

import 'package:flutter/foundation.dart';

import 'storage_service.dart';

/// 自动休眠（对应 T2S 的 `tts.autosleep.settings`）
///
/// 两条独立的停止条件，都可以单独开关：
/// 1. **空闲暂停**：连续 N 分钟没有任何操作（翻页、点句子、按控制键）就自动暂停；
/// 2. **定时停止**：一次朗读会话累计满 N 分钟就彻底停下（睡前听书用）。
///
/// 这里只负责「什么时候该动手」，动手交给 [TtsManager] 注册的两个回调，
/// 因此可以用注入时钟把分钟级行为压到毫秒级做测试。
class AutoSleepController {
  AutoSleepController._();

  /// 全局单例
  static final AutoSleepController instance = AutoSleepController._();

  /// 检查间隔：分钟级阈值不需要更密
  static const Duration tickInterval = Duration(seconds: 5);

  /// 空闲暂停阈值（分钟），0 = 关闭
  int idleMinutes = 0;

  /// 定时停止阈值（分钟），0 = 关闭
  int stopMinutes = 0;

  /// 时钟。测试注入固定时钟后再调用 [check]，无需真的等几分钟
  DateTime Function() now = DateTime.now;

  /// 空闲到点：暂停朗读
  Future<void> Function()? onIdleTimeout;

  /// 定时到点：停止朗读
  Future<void> Function()? onStopTimeout;

  /// 自动休眠动作的通知（界面弹一下提示条用）
  final ValueNotifier<String?> notice = ValueNotifier<String?>(null);

  /// 测试用：把阈值压到毫秒级，走真实事件循环验证链路
  @visibleForTesting
  Duration? idleOverride;

  @visibleForTesting
  Duration? stopOverride;

  /// 测试用：把「多久检查一次」也压到毫秒级
  @visibleForTesting
  Duration? tickIntervalOverride;

  DateTime? _sessionStart;
  DateTime? _lastActivity;
  bool _playing = false;
  bool _idleFired = false;
  Timer? _ticker;
  bool _initialized = false;

  /// 生效中的空闲阈值
  Duration get idleTimeout => idleOverride ?? Duration(minutes: idleMinutes);

  /// 生效中的定时停止阈值
  Duration get stopTimeout => stopOverride ?? Duration(minutes: stopMinutes);

  /// 是否有任一条生效
  bool get enabled => idleTimeout > Duration.zero || stopTimeout > Duration.zero;

  /// 会话是否进行中（朗读中或暂停中）
  bool get inSession => _sessionStart != null;

  /// 离下一次自动动作还有多久（界面展示用），没有则返回 null
  Duration? get nextIn {
    final start = _sessionStart;
    if (start == null) return null;
    final stamp = now();
    Duration? soonest;
    if (stopTimeout > Duration.zero) {
      soonest = _positive(stopTimeout - stamp.difference(start));
    }
    final activity = _lastActivity;
    if (_playing && !_idleFired && idleTimeout > Duration.zero && activity != null) {
      final idle = _positive(idleTimeout - stamp.difference(activity));
      if (idle != null && (soonest == null || idle < soonest)) soonest = idle;
    }
    return soonest;
  }

  /// 设置页的一行说明
  String get summary {
    final parts = <String>[];
    if (idleMinutes > 0) parts.add('无操作 $idleMinutes 分钟后暂停');
    if (stopMinutes > 0) parts.add('朗读满 $stopMinutes 分钟后停止');
    return parts.isEmpty ? '已关闭' : parts.join('，');
  }

  static Duration? _positive(Duration value) => value <= Duration.zero ? Duration.zero : value;

  /// 启动时载入阈值
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    final settings = await StorageService.instance.loadAutoSleep();
    idleMinutes = settings.$1;
    stopMinutes = settings.$2;
  }

  /// 保存阈值
  Future<void> configure({int? idle, int? stop}) async {
    if (idle != null) idleMinutes = idle < 0 ? 0 : idle;
    if (stop != null) stopMinutes = stop < 0 ? 0 : stop;
    await StorageService.instance.saveAutoSleep(idleMinutes, stopMinutes);
    _syncTicker();
  }

  /// 一次朗读会话开始（TtsManager 的会话边界）
  void beginSession() {
    _sessionStart = now();
    _lastActivity = _sessionStart;
    _idleFired = false;
    _syncTicker();
  }

  /// 一次朗读会话结束（读完 / 失败 / 被停止）
  void endSession() {
    _sessionStart = null;
    _lastActivity = null;
    _playing = false;
    _idleFired = false;
    _syncTicker();
  }

  /// 播放状态变化（暂停 / 继续）：空闲判定只在真正播着的时候计时
  void setPlaying(bool playing) {
    if (_playing == playing) return;
    _playing = playing;
    if (playing) {
      // 重新播起来算一次「有动静」，否则暂停久了会被立刻判定为空闲
      _lastActivity = now();
      _idleFired = false;
      _sessionStart ??= now();
    }
    _syncTicker();
  }

  /// 用户有操作（翻页 / 点句子 / 按控制键 / 切粒度）：空闲计时重来
  void notifyUserActivity() {
    _lastActivity = now();
    _idleFired = false;
  }

  /// 清掉一次性提示
  void clearNotice() => notice.value = null;

  /// 评估一次阈值；由内部定时器驱动，测试可直接调用
  void check() {
    final start = _sessionStart;
    if (start == null) return;
    final stamp = now();

    if (stopTimeout > Duration.zero && stamp.difference(start) >= stopTimeout) {
      final callback = onStopTimeout;
      notice.value = '朗读已满 ${_label(stopTimeout)}，自动停止';
      endSession();
      if (callback != null) unawaited(Future<void>.sync(callback));
      return;
    }

    final activity = _lastActivity;
    if (_playing &&
        !_idleFired &&
        idleTimeout > Duration.zero &&
        activity != null &&
        stamp.difference(activity) >= idleTimeout) {
      _idleFired = true; // 只暂停一次，等下次操作再重新计时
      final callback = onIdleTimeout;
      notice.value = '已 ${_label(idleTimeout)} 没有操作，自动暂停';
      if (callback != null) unawaited(Future<void>.sync(callback));
    }
  }

  /// 阈值都是 0 时不建定时器：测试环境（widget 测试）最怕留下悬挂定时器
  void _syncTicker() {
    final wanted = _sessionStart != null && enabled;
    if (wanted && _ticker == null) {
      _ticker = Timer.periodic(tickIntervalOverride ?? tickInterval, (_) => check());
    } else if (!wanted && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  /// 仅供测试：清空状态与阈值
  @visibleForTesting
  void resetForTest() {
    _ticker?.cancel();
    _ticker = null;
    _initialized = false;
    idleMinutes = 0;
    stopMinutes = 0;
    idleOverride = null;
    stopOverride = null;
    tickIntervalOverride = null;
    _sessionStart = null;
    _lastActivity = null;
    _playing = false;
    _idleFired = false;
    notice.value = null;
    onIdleTimeout = null;
    onStopTimeout = null;
    now = DateTime.now;
  }

  static String _label(Duration value) {
    final minutes = value.inMinutes;
    if (minutes >= 1) return '$minutes 分钟';
    final seconds = value.inSeconds;
    if (seconds >= 1) return '$seconds 秒';
    return '${value.inMilliseconds} 毫秒';
  }
}

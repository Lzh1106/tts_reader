import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 后台朗读保活：熄屏之后朗读不中断
///
/// 原生侧持的是 `PARTIAL_WAKE_LOCK`（屏幕可以关，CPU 继续跑）+ `WifiLock`
/// （云端 TTS 边下边播时网络不被挂起）。**不要**用 `wakelock_plus` 来做这件事：
/// 它在 Android 上加的是 `FLAG_KEEP_SCREEN_ON`（屏幕常亮），与熄屏继续读正好相反。
///
/// 只负责「保活开关」和「电池优化白名单」两件事，电源策略都在原生侧。
class KeepAliveService {
  KeepAliveService._();

  /// 全局单例
  static final KeepAliveService instance = KeepAliveService._();

  /// 与原生约定的通道名
  static const String channelName = 'tts_reader/power';

  /// 测试可替换的通道
  @visibleForTesting
  static MethodChannel channel = const MethodChannel(channelName);

  bool _held = false;
  bool _supported = true;

  /// 当前是否持有唤醒锁
  bool get held => _held;

  /// 当前平台是否支持（桌面 / 测试环境为 false）
  bool get supported => _supported;

  /// 拿锁（正在朗读且未暂停时调用，重复调用无害）
  Future<bool> acquire() async {
    if (_held) return true;
    try {
      final Object? raw = await channel.invokeMethod<Object?>('acquire');
      _held = raw == true;
      _supported = true;
    } on MissingPluginException {
      _supported = false;
      _held = false;
    } catch (_) {
      _held = false;
    }
    return _held;
  }

  /// 放锁（暂停 / 停止 / 读完时调用）
  Future<void> release() async {
    if (!_held && !_supported) return;
    _held = false;
    try {
      await channel.invokeMethod<Object?>('release');
    } catch (_) {
      // 释放失败无所谓：锁会在进程结束时由系统回收
    }
  }

  /// 是否已在电池优化白名单里（Android 6 以下恒为 true）
  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final Object? raw = await channel.invokeMethod<Object?>('status');
      if (raw is Map) return raw['ignoringBatteryOptimizations'] == true;
    } on MissingPluginException {
      _supported = false;
    } catch (_) {
      // 读不到就当作没有
    }
    return false;
  }

  /// 跳到系统的「忽略电池优化」授权页
  Future<void> requestIgnoreBatteryOptimizations() async {
    try {
      await channel.invokeMethod<Object?>('requestIgnoreBatteryOptimizations');
    } catch (_) {
      // 个别 ROM 没有这个页面，忽略
    }
  }

  /// 仅供测试：恢复初始状态
  @visibleForTesting
  void resetForTest() {
    _held = false;
    _supported = true;
    channel = const MethodChannel(channelName);
  }
}

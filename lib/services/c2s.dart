import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 复制即朗读（C2S）的配置与运行状态
///
/// 对应 T2S 的 `copy2speak` 模块：悬浮朗读按钮 + 快捷设置磁贴 + 开机自启。
/// 配置存在原生侧（服务与磁贴都要读，不能只放 Dart 内存里）。
@immutable
class C2sConfig {
  const C2sConfig({
    this.enabled = false,
    this.autoShow = true,
    this.sizeDp = 52,
    this.running = false,
    this.overlayPermission = false,
    this.minSizeDp = 40,
    this.maxSizeDp = 72,
  });

  /// 从原生返回的 Map 解析；缺字段按默认值补齐
  factory C2sConfig.fromMap(Object? raw) {
    if (raw is! Map) return const C2sConfig();
    return C2sConfig(
      enabled: raw['enabled'] == true,
      autoShow: raw['autoShow'] != false,
      sizeDp: _int(raw['sizeDp'], 52),
      running: raw['running'] == true,
      overlayPermission: raw['overlayPermission'] == true,
      minSizeDp: _int(raw['minSizeDp'], 40),
      maxSizeDp: _int(raw['maxSizeDp'], 72),
    );
  }

  static int _int(Object? value, int fallback) =>
      value is num ? value.toInt() : (value is String ? int.tryParse(value) ?? fallback : fallback);

  /// 总开关：是否启用复制即朗读
  final bool enabled;

  /// 复制文本后是否自动把悬浮球弹出来
  final bool autoShow;

  /// 悬浮球直径（dp）
  final int sizeDp;

  /// 悬浮球当前是否真的在运行
  final bool running;

  /// 是否已获得「显示在其他应用上层」权限
  final bool overlayPermission;

  final int minSizeDp;
  final int maxSizeDp;

  /// 开关打开、有权限、且服务确实在跑
  bool get active => enabled && running;

  /// 需要先解决权限
  bool get needsPermission => enabled && !overlayPermission;

  C2sConfig copyWith({
    bool? enabled,
    bool? autoShow,
    int? sizeDp,
    bool? running,
    bool? overlayPermission,
  }) => C2sConfig(
    enabled: enabled ?? this.enabled,
    autoShow: autoShow ?? this.autoShow,
    sizeDp: sizeDp ?? this.sizeDp,
    running: running ?? this.running,
    overlayPermission: overlayPermission ?? this.overlayPermission,
    minSizeDp: minSizeDp,
    maxSizeDp: maxSizeDp,
  );

  @override
  bool operator ==(Object other) =>
      other is C2sConfig &&
      other.enabled == enabled &&
      other.autoShow == autoShow &&
      other.sizeDp == sizeDp &&
      other.running == running &&
      other.overlayPermission == overlayPermission;

  @override
  int get hashCode => Object.hash(enabled, autoShow, sizeDp, running, overlayPermission);
}

/// 复制即朗读控制器：读写原生配置、申请悬浮窗权限、开关悬浮球
///
/// 所有通道调用都容忍原生实现缺失（桌面 / 测试环境），失败时退回默认配置，
/// 保证「附加能力坏掉不影响主流程」。
class C2sController extends ChangeNotifier {
  C2sController._();

  /// 全局单例
  static final C2sController instance = C2sController._();

  /// 与原生约定的通道名
  static const String channelName = 'tts_reader/c2s';

  /// 测试可替换的通道
  @visibleForTesting
  static MethodChannel channel = const MethodChannel(channelName);

  C2sConfig _config = const C2sConfig();
  bool _supported = true;
  bool _initialized = false;

  C2sConfig get config => _config;

  /// 当前平台是否支持（桌面 / 测试环境为 false）
  bool get supported => _supported;

  /// 启动时载入一次配置，并在开关打开但悬浮球没跑起来时补拉一次
  ///
  /// 这同时兜住了「开机自启被系统拦掉」的情况：用户一打开应用，悬浮球就回来了。
  Future<void> bootstrap() async {
    await refresh();
    if (!_supported) return;
    if (_config.enabled && _config.overlayPermission && !_config.running) {
      await apply(enabled: true);
    }
  }

  /// 从原生侧读最新配置
  Future<void> refresh() async {
    try {
      final Object? raw = await channel.invokeMethod<Object?>('getConfig');
      _config = C2sConfig.fromMap(raw);
      _supported = true;
    } on MissingPluginException {
      _supported = false;
      _config = const C2sConfig();
    } catch (_) {
      // 读失败就保持现状
    }
    _initialized = true;
    notifyListeners();
  }

  /// 写入配置并返回悬浮球是否在运行
  Future<bool> apply({bool? enabled, bool? autoShow, int? sizeDp}) async {
    // 先本地生效，界面不等原生回复也能立刻变
    _config = _config.copyWith(enabled: enabled, autoShow: autoShow, sizeDp: sizeDp);
    notifyListeners();
    try {
      final Object? raw = await channel.invokeMethod<Object?>('apply', <String, dynamic>{
        if (enabled != null) 'enabled': enabled,
        if (autoShow != null) 'autoShow': autoShow,
        if (sizeDp != null) 'sizeDp': sizeDp,
      });
      _config = _config.copyWith(running: raw == true);
      notifyListeners();
      return raw == true;
    } on MissingPluginException {
      _supported = false;
      notifyListeners();
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 是否有悬浮窗权限
  Future<bool> hasOverlayPermission() async {
    try {
      final Object? raw = await channel.invokeMethod<Object?>('hasOverlayPermission');
      final granted = raw == true;
      _config = _config.copyWith(overlayPermission: granted);
      notifyListeners();
      return granted;
    } on MissingPluginException {
      _supported = false;
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 跳到系统设置申请悬浮窗权限（回来要重新 [refresh]）
  Future<void> requestOverlayPermission() async {
    try {
      await channel.invokeMethod<Object?>('requestOverlayPermission');
    } catch (_) {
      // 没有这个系统页面时忽略
    }
  }

  /// 读剪贴板并朗读（走原生透明界面，Android 10+ 才读得到内容）
  Future<void> speakClipboard() async {
    try {
      await channel.invokeMethod<Object?>('speakClipboard');
    } catch (_) {
      // 忽略：调用方会给提示
    }
  }

  /// 是否已初始化过（设置页据此决定要不要刷新）
  bool get initialized => _initialized;

  /// 仅供测试：恢复初始状态
  @visibleForTesting
  void resetForTest() {
    _config = const C2sConfig();
    _supported = true;
    _initialized = false;
    channel = const MethodChannel(channelName);
  }
}

import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import '../services/storage_service.dart';

/// 应用主题的组装：种子色 / 手机动态取色 + 可选的自定义背景图
///
/// 需求来源：
/// 1. 「软件主题支持手机动态取色」—— Android 12+ 的 Material You 取色；
/// 2. 「支持自定义图片主题，可调节背景透明度」—— 整界面铺背景图 + 透明度可调；
/// 3. 两者**可叠加**：取色决定按钮 / 高亮等强调色，背景图决定底。
///
/// 背景图的铺法：套在 `MaterialApp.builder` 上，用 `Stack` 把图放在所有界面**下面**，
/// 同时把主题的 `scaffoldBackgroundColor` 设为透明，页面自身不再盖住图。
class AppTheme {
  const AppTheme._();

  /// 默认种子色（用户可换成动态取色）
  static const Color seedColor = Color(0xFF6750A4);

  /// 背景图存在时的默认不透明度
  static const double defaultImageOpacity = 0.35;

  /// 取色来源：动态取色可用时用系统色，否则回退到种子色
  static ColorScheme _scheme({
    required Brightness brightness,
    ColorScheme? dynamic,
  }) {
    final useDynamic = StorageService.instance.useDynamicColor;
    if (useDynamic && dynamic != null) {
      // dynamic_color 给的 scheme 已经带正确 brightness，直接沿用
      return dynamic;
    }
    return ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness);
  }

  /// 有背景图时页面要透明，图才透得出来
  static ThemeData _theme(ColorScheme scheme, {required bool imageBehind}) =>
      ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor:
            imageBehind ? Colors.transparent : scheme.surface,
      );

  /// 包一层「动态取色」监听：系统换壁纸 / 换取色时界面自动跟着变
  ///
  /// 亮 / 暗由 `MaterialApp.themeMode` 决定用哪一套，所以这里把两套都给出去。
  static Widget build({
    required Widget Function(ThemeData light, ThemeData dark) builder,
  }) {
    final storage = StorageService.instance;
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final imageBehind = storage.hasBackgroundImage;
        return builder(
          _theme(_scheme(brightness: Brightness.light, dynamic: lightDynamic),
              imageBehind: imageBehind),
          _theme(_scheme(brightness: Brightness.dark, dynamic: darkDynamic),
              imageBehind: imageBehind),
        );
      },
    );
  }

  /// 整界面背景层：背景图 + 一层按主题色的遮罩（保证文字可读）
  ///
  /// 遮罩的作用：图直接铺在文字下面会花，尤其是深色图配深色字。
  /// 用主题底色按 `1 - 透明度` 覆盖，透明度越高图越清楚、文字对比越低 ——
  /// 这个平衡交给用户用滑块调。
  static Widget backgroundLayer({
    required BuildContext context,
    required Widget child,
  }) {
    final storage = StorageService.instance;
    final path = storage.backgroundImage;
    if (path.trim().isEmpty) return child;
    final file = File(path);
    if (!file.existsSync()) return child;

    final scheme = Theme.of(context).colorScheme;
    final opacity = storage.backgroundImageOpacity.clamp(0.0, 1.0);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Image.file(
          file,
          fit: BoxFit.cover,
          // 解码失败（图被删 / 格式不支持）时不要崩，退回纯色
          errorBuilder: (context, error, stack) => ColoredBox(
            color: scheme.surface,
          ),
        ),
        // 主题色遮罩：透明度越低遮得越厚、文字越清楚
        ColoredBox(
          color: scheme.surface.withOpacity((1 - opacity).clamp(0.0, 0.92)),
        ),
        child,
      ],
    );
  }
}

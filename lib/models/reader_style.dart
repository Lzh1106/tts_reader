import 'package:flutter/material.dart';

/// 阅读区配色（对应 T2S 的 ThemeSettingsActivity / CustomTheme.xml）
///
/// `follow` 表示跟随应用主题（亮色 / 暗色），其余是固定的阅读底色，
/// 夜间读书时比整机暗色主题更省眼。
enum ReadingTheme {
  follow('跟随主题', null, null),
  paper('纸白', Color(0xFFFFFFFF), Color(0xFF1B1B1B)),
  sepia('羊皮纸', Color(0xFFF7EFDF), Color(0xFF3E2F1C)),
  eyeCare('护眼绿', Color(0xFFCCE8CF), Color(0xFF16301C)),
  night('夜间', Color(0xFF101014), Color(0xFFC9C9C9));

  const ReadingTheme(this.label, this.background, this.foreground);

  final String label;

  /// 阅读区背景（null = 跟随应用主题）
  final Color? background;

  /// 正文颜色（null = 跟随应用主题）
  final Color? foreground;

  /// 是否使用自定义阅读底色
  bool get isCustom => background != null;
}

/// 阅读页排版设置：字号、行距、字距、页边距、段间距、字体、底色
///
/// 只影响正文渲染，不改变文档内容；所有取值都带上下限夹取，
/// 因为设置是从持久化里读回来的，历史数据 / 手改数据都可能有越界值。
class ReaderStyle {
  const ReaderStyle({
    this.fontSize = 17,
    this.lineHeight = 1.7,
    this.letterSpacing = 0,
    this.pageMargin = 12,
    this.paragraphSpacing = 3,
    this.fontFamily = '',
    this.theme = ReadingTheme.follow,
  });

  factory ReaderStyle.fromJson(Map<String, dynamic> json) => const ReaderStyle().copyWith(
    fontSize: _double(json['fontSize']),
    lineHeight: _double(json['lineHeight']),
    letterSpacing: _double(json['letterSpacing']),
    pageMargin: _double(json['pageMargin']),
    paragraphSpacing: _double(json['paragraphSpacing']),
    fontFamily: json['fontFamily'] is String ? json['fontFamily'] as String : null,
    theme: _theme(json['theme']),
  );

  /// 出厂默认
  static const ReaderStyle defaults = ReaderStyle();

  /// 字号范围
  static const double minFontSize = 12;
  static const double maxFontSize = 30;

  /// 行距范围
  static const double minLineHeight = 1.2;
  static const double maxLineHeight = 2.4;

  /// 字距范围
  static const double maxLetterSpacing = 3;

  /// 页边距范围
  static const double maxPageMargin = 48;

  /// 段间距范围
  static const double maxParagraphSpacing = 24;

  /// 可选字体（空串 = 跟随系统；其余是各平台都有的通用字族）
  static const List<(String, String)> fontChoices = <(String, String)>[
    ('', '系统'),
    ('serif', '衬线'),
    ('sans-serif', '无衬线'),
    ('monospace', '等宽'),
  ];

  /// 正文字号
  final double fontSize;

  /// 行高倍数
  final double lineHeight;

  /// 字距（中文排版常用 0.5 ~ 1）
  final double letterSpacing;

  /// 正文左右页边距
  final double pageMargin;

  /// 段落之间的间距
  final double paragraphSpacing;

  /// 字体族，空串表示跟随系统
  final String fontFamily;

  /// 阅读区配色
  final ReadingTheme theme;

  static double? _double(Object? value) => value is num ? value.toDouble() : null;

  static ReadingTheme _theme(Object? value) {
    if (value is String) {
      for (final item in ReadingTheme.values) {
        if (item.name == value) return item;
      }
    }
    return ReadingTheme.follow;
  }

  static double _clamp(double value, double min, double max) =>
      value.isNaN ? min : (value < min ? min : (value > max ? max : value));

  ReaderStyle copyWith({
    double? fontSize,
    double? lineHeight,
    double? letterSpacing,
    double? pageMargin,
    double? paragraphSpacing,
    String? fontFamily,
    ReadingTheme? theme,
  }) => ReaderStyle(
    fontSize: _clamp(fontSize ?? this.fontSize, minFontSize, maxFontSize),
    lineHeight: _clamp(lineHeight ?? this.lineHeight, minLineHeight, maxLineHeight),
    letterSpacing: _clamp(letterSpacing ?? this.letterSpacing, 0, maxLetterSpacing),
    pageMargin: _clamp(pageMargin ?? this.pageMargin, 0, maxPageMargin),
    paragraphSpacing: _clamp(
      paragraphSpacing ?? this.paragraphSpacing,
      0,
      maxParagraphSpacing,
    ),
    fontFamily: fontFamily ?? this.fontFamily,
    theme: theme ?? this.theme,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'letterSpacing': letterSpacing,
    'pageMargin': pageMargin,
    'paragraphSpacing': paragraphSpacing,
    'fontFamily': fontFamily,
    'theme': theme.name,
  };

  /// 是否是出厂设置（设置页据此显示「已改动」）
  bool get isDefault =>
      fontSize == defaults.fontSize &&
      lineHeight == defaults.lineHeight &&
      letterSpacing == defaults.letterSpacing &&
      pageMargin == defaults.pageMargin &&
      paragraphSpacing == defaults.paragraphSpacing &&
      fontFamily == defaults.fontFamily &&
      theme == defaults.theme;

  /// 在主题基础样式上套排版参数
  TextStyle apply(TextStyle base) => base.copyWith(
    fontSize: fontSize,
    height: lineHeight,
    letterSpacing: letterSpacing,
    fontFamily: fontFamily.isEmpty ? null : fontFamily,
    color: theme.foreground,
  );

  /// 阅读区背景：null 表示交给主题
  Color? get background => theme.background;

  /// 章节标题条底色：自定义底色下用正文色的极淡叠加，避免出现一块突兀的灰
  Color headerColor(ColorScheme scheme) {
    final bg = theme.background;
    if (bg == null) return scheme.surfaceContainerHighest;
    return Color.alphaBlend((theme.foreground ?? scheme.onSurface).withOpacity(0.06), bg);
  }

  /// 正在朗读的句子高亮配色 (背景, 前景)
  ///
  /// **跟随主题**（v1.21.5 起）：底色 / 字色成对取自当前 ColorScheme 的
  /// `primaryContainer` / `onPrimaryContainer`。设置里「手机动态取色」开着时
  /// 这对角色色来自系统壁纸取出的强调色，关掉则来自内置种子色 ——
  /// 高亮自动跟着主题走，不再写死任何色值。
  ///
  /// 暗底例外（§4.53 的思路保留）：阅读底色本身是暗的（夜间），或跟随主题
  /// 且系统处于暗色模式时，改用**同一色相的暗色派生**（不再写死深蓝），
  /// 保证「暗底上高亮文字可读」。
  (Color, Color) highlightColors(ColorScheme scheme) {
    final background = theme.background;
    final darkSurface = background != null
        ? background.computeLuminance() < 0.5
        : scheme.brightness == Brightness.dark;
    if (darkSurface == (scheme.brightness == Brightness.dark)) {
      // 方向与主题一致：M3 成对角色天然满足可读性（tone 差 ≥ 30）
      return (scheme.primaryContainer, scheme.onPrimaryContainer);
    }
    // 方向相反（例如「纸白」阅读底配系统暗色主题、夜间底配系统亮色主题）：
    // 仍从当前主题的 container 色相派生一套深 / 浅对，不引入固定色值。
    final hsl = HSLColor.fromColor(scheme.primaryContainer);
    final saturation = hsl.saturation.clamp(0.25, 0.9);
    if (darkSurface) {
      return (
        hsl.withSaturation(saturation).withLightness(0.28).toColor(),
        hsl.withLightness(0.92).toColor(),
      );
    }
    return (
      hsl.withSaturation(saturation).withLightness(0.86).toColor(),
      hsl.withLightness(0.12).toColor(),
    );
  }

  /// PDF 原版式高亮块的**半透明底色**（绘制处用，替代写死的 `0x59FFC107`）
  ///
  /// PDF 原版式的页面永远是白底黑字（位图自带白色背景），所以这里恒取
  /// **浅色调**：亮面直接用 `primaryContainer`（跟随主题 / 动态取色）；
  /// 暗面把同一色相的 `primaryContainer` 提到高亮度、低饱和再用 ——
  /// 色相仍来自当前主题，不会在白纸压一块深色。
  ///
  /// 透明度沿用现有值（`0x59` ≈ 35%，§4.44 的 T2S 观感），只换色相不换画法。
  static Color pdfHighlightColor(ColorScheme scheme) {
    final hsl = HSLColor.fromColor(scheme.primaryContainer);
    final lightness = scheme.brightness == Brightness.dark
        ? hsl.lightness.clamp(0.82, 0.92)
        : hsl.lightness;
    return hsl
        .withSaturation(hsl.saturation.clamp(0.25, 0.85))
        .withLightness(lightness)
        .toColor()
        .withOpacity(0x59 / 0xFF);
  }



  /// 设置页里的一行摘要
  String get summary {
    final font = fontChoices.where((choice) => choice.$1 == fontFamily).toList();
    final fontLabel = font.isEmpty ? '系统' : font.first.$2;
    return '字号 ${fontSize.round()} · 行距 ${lineHeight.toStringAsFixed(1)} · '
        '页边距 ${pageMargin.round()} · $fontLabel字体 · ${theme.label}';
  }
}

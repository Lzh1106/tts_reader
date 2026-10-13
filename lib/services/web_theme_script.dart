/// 内置浏览器「与应用一体化」要注入的样式与脚本
/// 为什么需要它：内置浏览器里的网页有自己的底色，亮色主题下白底没问题，
/// 但**暗色主题**下白得刺眼，与整个应用的观感割裂；有些页面还自带一条
/// 与系统风格完全不同的滚动条。这里注入一小段 CSS 让它们跟随应用主题。
///
/// 注意只改「底色 / 滚动条 / 选中色」这几项，不动字号、行高、字体 ——
/// 那属于网页自己的排版，改了会破坏站点。
///
/// 这个类只产出字符串（纯函数），不碰 WebView，便于单测。
class WebThemeScript {
  WebThemeScript._();

  /// 注入用的 `<style>` 元素 id（重复注入时先删旧的）
  static const String styleElementId = '__tts_reader_theme__';

  /// 暗色主题下的页面底色（与 Material 3 的 surface 接近）
  static const String darkSurface = '#121212';
  static const String darkSurfaceElevated = '#1E1E1E';
  static const String darkOnSurface = '#E6E1E5';
  static const String darkOutline = '#49454F';

  /// 亮色主题下的滚动条颜色
  static const String lightScrollThumb = '#00000033';
  static const String darkScrollThumb = '#FFFFFF33';

  /// 生成要注入的 CSS（[dark] 为真时同时压暗页面底色）
  ///
  /// `:root` 上的 `color-scheme` 很关键：它让浏览器把**表单控件、
  /// 默认滚动条、以及页面自己没写底色时的画布底色**都切到暗色，
  /// 比逐个元素覆盖颜色更彻底、也不容易和站点样式打架。
  static String css({required bool dark}) {
    final thumb = dark ? darkScrollThumb : lightScrollThumb;
    final buffer = StringBuffer()
      ..writeln('html, body {')
      // 页面自己设了背景就别覆盖：用 transparent 让底下露出来的仍是站点自己的颜色
      ..writeln('  background-color: transparent;')
      ..writeln('}')
      ..writeln('::-webkit-scrollbar { width: 8px; height: 8px; }')
      ..writeln('::-webkit-scrollbar-track { background: transparent; }')
      ..writeln('::-webkit-scrollbar-thumb {')
      ..writeln('  background-color: $thumb;')
      ..writeln('  border-radius: 4px;')
      ..writeln('}');
    if (dark) {
      // 只在暗色主题下压暗：亮色下网页原本的白底就是对的
      buffer
        ..writeln(':root { color-scheme: dark; }')
        ..writeln('html { background-color: $darkSurface !important; }')
        ..writeln('body { background-color: $darkSurface !important; }')
        // 站点自己写死浅色底（常见于老站点）时也压下去，否则暗色下会闪白块
        ..writeln('body[style*="background"], body[bgcolor] {')
        ..writeln('  background-color: $darkSurface !important;')
        ..writeln('}')
        ..writeln('::selection { background-color: $darkOutline; color: $darkOnSurface; }');
    }
    return buffer.toString();
  }

  /// 生成注入脚本：写一个 `<style>` 元素（重复调用会替换掉旧的）
  static String inject({required bool dark}) {
    final escaped = css(dark: dark)
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll('\n', r'\n');
    return '''
(function () {
  var id = '$styleElementId';
  var old = document.getElementById(id);
  if (old && old.parentNode) { old.parentNode.removeChild(old); }
  var style = document.createElement('style');
  style.id = id;
  style.type = 'text/css';
  style.appendChild(document.createTextNode('$escaped'));
  var target = document.head || document.documentElement;
  if (target) { target.appendChild(style); }
  return true;
})();
''';
  }
}

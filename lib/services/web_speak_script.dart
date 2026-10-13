/// 内置浏览器注入脚本（对应 T2S 的 `assets/js_compiled/.../browser.js`）
///
/// 抽成常量而不是散在页面里，是为了让「JS 侧回传的 handler 名」与
/// 「原生侧注册的 handler 名」在代码上就是同一个值 —— 这两处一旦不一致，
/// 双击朗读会静默失效（不报错、也不出声），是本功能最容易踩的坑。
class WebSpeakScript {
  WebSpeakScript._();

  /// 双击正文回传文本用的 JS 桥方法名（原生侧必须注册同名 handler）
  static const String handlerName = 'speakNode';

  /// 双击判定窗口：这么短时间内连点同一个块级元素即视为双击（与 T2S 的取值一致）
  static const int doubleTapWindowMs = 600;

  /// 同一个元素重复触发之间的静默期，避免一次双击被算成两次
  static const int repeatGuardMs = 400;

  /// 会被打标的块级元素
  static const String nodeSelector = 'p,li,h1,h2,h3,h4,h5,h6,blockquote,dd,dt,td,th,figcaption,pre';

  /// 网页正文抽取：优先正文容器，去掉导航 / 脚本 / 样式
  static const String extract = '''
(function () {
  var root = document.querySelector('article') || document.querySelector('main') || document.body;
  if (!root) return '';
  var clone = root.cloneNode(true);
  var drop = clone.querySelectorAll('script,style,noscript,nav,header,footer,aside,form,iframe,svg,button');
  for (var i = 0; i < drop.length; i++) { drop[i].remove(); }
  return (clone.innerText || clone.textContent || '').trim();
})();
''';

  /// 给正文块级元素打标 + 上报双击
  ///
  /// 只在页面里挂一个捕获阶段监听：命中 `[data-t2s-node]` 的块级元素才算，
  /// 判定窗口内连点同一个元素就把该段文字回传给原生直接朗读。
  /// 整段包在 try/catch 里：页面结构再奇怪也不能影响正常浏览。
  static const String doubleTap = '''
(function () {
  var SELECTOR = '$nodeSelector';
  try {
    if (!window.__t2sBound) {
      window.__t2sBound = true;
      var lastId = null;
      var lastAt = 0;
      var busy = false;
      document.addEventListener('click', function (event) {
        var target = event.target;
        if (!target || !target.closest) return;
        var el = target.closest('[data-t2s-node]');
        if (!el) return;
        var id = el.getAttribute('data-t2s-node');
        var now = Date.now();
        if (id === lastId && now - lastAt < $doubleTapWindowMs) {
          lastId = null;
          lastAt = 0;
          if (busy) return;
          var text = (el.innerText || '').trim();
          if (!text) return;
          busy = true;
          try {
            window.flutter_inappwebview.callHandler('$handlerName', text);
          } catch (e) {
            /* 原生侧没接上就安静退出 */
          }
          setTimeout(function () { busy = false; }, $repeatGuardMs);
          return;
        }
        lastId = id;
        lastAt = now;
      }, true);
    }
    var nodes = document.querySelectorAll(SELECTOR);
    var count = 0;
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.getAttribute('data-t2s-node') !== null) continue;
      if (el.closest('nav,header,footer,aside,form,script,style,noscript')) continue;
      if ((el.innerText || '').trim().length < 2) continue;
      el.setAttribute('data-t2s-node', String(count));
      count++;
    }
  } catch (e) {
    /* 页面结构再奇怪也不该影响正常浏览 */
  }
})();
''';
}

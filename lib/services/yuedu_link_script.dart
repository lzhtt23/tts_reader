import 'dart:convert';

/// 内置浏览器里拦截 `yuedu://` / `legado://` 链接的注入脚本
///
/// ## 为什么光靠 `shouldOverrideUrlLoading` 不够
///
/// 真机实测（2026-10-18 18:39，`dy.mgz6.com` 的「喵公子订阅源」按钮）：
/// 页面上那种按钮是 `<a href="yuedu://…">` 或按钮里 `location.href = 'yuedu://…'`。
/// 前者一般能被 `shouldOverrideUrlLoading` 抓到，但**后者在部分 Android WebView 上
/// 直接静默失败**（自定义 scheme 被当成未知链接丢掉，连导航回调都不触发），
/// 表现就是「点了没反应」。
///
/// 所以在 DOM 层先截一道：捕获阶段监听点击，命中自定义 scheme 就
/// `preventDefault()` 并通过 JS handler 把整条链接交给 Dart。
/// Dart 侧仍然走「确认 → 勾选 → 导入」那条既有流程。
class YueduLinkScript {
  YueduLinkScript._();

  /// Dart 侧的 handler 名
  static const String handlerName = 'yueduLink';

  /// 注入的 JS
  ///
  /// 注意：
  /// * 用捕获阶段（`true`），赶在站点自己的监听器之前；
  /// * `window.__yueduHooked` 防止重复注入（每次页面加载都会跑一遍）；
  /// * 只拦 `yuedu:` / `legado:` 两种，不碰正常链接。
  static String get source => '''
(function () {
  if (window.__yueduHooked) return;
  window.__yueduHooked = true;

  function report(link) {
    try {
      window.flutter_inappwebview.callHandler('$handlerName', link);
    } catch (e) {}
  }

  // ① 点击 <a href="yuedu://...">：直接拦
  document.addEventListener('click', function (ev) {
    var node = ev.target;
    while (node && node.tagName !== 'A') node = node.parentNode;
    if (!node || !node.getAttribute) return;
    var href = node.getAttribute('href') || '';
    if (/^(yuedu|legado):/i.test(href)) {
      ev.preventDefault();
      ev.stopPropagation();
      report(href);
    }
  }, true);

  // ② 按钮里用 location.href / window.open 跳转：改写这两个入口
  function wrap(fnName) {
    var original = window[fnName];
    window[fnName] = function (url) {
      if (typeof url === 'string' && /^(yuedu|legado):/i.test(url)) {
        report(url);
        return null;
      }
      return original.apply(window, arguments);
    };
  }
  wrap('open');

  try {
    var loc = window.location;
    // location.href 是访问器，改写需要重新定义
    var desc = Object.getOwnPropertyDescriptor(Location.prototype, 'href');
    if (desc && desc.set) {
      Object.defineProperty(loc, 'href', {
        get: desc.get,
        set: function (url) {
          if (typeof url === 'string' && /^(yuedu|legado):/i.test(url)) {
            report(url);
            return;
          }
          desc.set.call(this, url);
        },
      });
    }
  } catch (e) {}
})();
''';

  /// 把 JS 字符串安全地塞进 `evaluateJavascript`
  static String callHandler(String link) =>
      "window.flutter_inappwebview.callHandler('$handlerName', ${jsonEncode(link)});";
}

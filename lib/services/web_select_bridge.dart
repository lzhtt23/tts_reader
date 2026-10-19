import 'dart:convert';

/// 网页 `<select>` 的桥接脚本
///
/// ## 为什么需要
///
/// Android WebView 的 `<select>` 靠 `WebChromeClient` 弹系统选择器。
/// `flutter_inappwebview` 这层没有把它接出来 —— 真机上表现就是
/// 「点语言下拉框什么都没发生」（用户 2026-10-19 在 Anna's Archive 上遇到）。
///
/// 于是自己接管：页面里拦下 select 的点击，把选项传给 Flutter，
/// 由 Flutter 弹一个 Material 单选面板，选完再回写并派发 `change` 事件。
///
/// ## 为什么不用「把 select 换成自定义控件」
///
/// 那种改法会破坏站点自己的事件监听、表单提交和样式。
/// 这里只**拦住弹窗这一步**，其余行为（值、change、表单）保持页面原样。
class WebSelectBridge {
  WebSelectBridge._();

  /// Dart 侧 handler 名
  static const String handlerName = 'selectPopup';

  /// 注入脚本（幂等：`__flSelectHooked` 防重复）
  static String get source => '''
(function () {
  if (window.__flSelectHooked) return;
  window.__flSelectHooked = true;
  var seq = 0;
  var lastEl = null;
  var lastAt = 0;

  function labelOf(sel) {
    return sel.getAttribute('aria-label') || sel.getAttribute('title') ||
           sel.getAttribute('name') || '';
  }

  function handle(sel, ev) {
    if (!sel || sel.disabled) return;
    ev.preventDefault();
    ev.stopPropagation();
    var id = sel.getAttribute('data-fl-sel');
    if (!id) { id = 's' + (++seq); sel.setAttribute('data-fl-sel', id); }
    var opts = [];
    for (var i = 0; i < sel.options.length; i++) {
      var o = sel.options[i];
      opts.push({
        index: i,
        text: (o.text || '').trim(),
        selected: !!o.selected,
        disabled: !!o.disabled
      });
    }
    try {
      window.flutter_inappwebview.callHandler('$handlerName', {
        id: id,
        label: labelOf(sel),
        multiple: !!sel.multiple,
        options: opts
      });
    } catch (e) {}
  }

  // Android WebView 里点 select 会派发 pointerdown / touchstart / mousedown / click
  // 这一串；只挂一个会漏，全挂又会重复弹。所以统一入口 + 去重。
  function onPress(ev) {
    var t = ev.target;
    while (t && t.tagName !== 'SELECT') t = t.parentNode;
    if (!t || t.disabled) return;
    ev.preventDefault();
    var now = Date.now();
    if (t === lastEl && now - lastAt < 500) return; // 同一次点击的后续事件
    lastEl = t;
    lastAt = now;
    handle(t, ev);
  }

  ['pointerdown', 'touchstart', 'mousedown', 'click'].forEach(function (name) {
    document.addEventListener(name, onPress, { capture: true, passive: false });
  });
})();
''';

  /// 生成「把选中项写回页面」的脚本
  ///
  /// [index] 为单选时的下标；[multiIndexes] 为多选时要选中的下标集合。
  static String applyScript({
    required String id,
    int? index,
    List<int>? multiIndexes,
  }) {
    final String safeId = const JsonEncoder().convert(id);
    final String body = multiIndexes != null
        ? 'var want = ${jsonEncode(multiIndexes)};\n'
            '      for (var i = 0; i < sel.options.length; i++) {\n'
            '        sel.options[i].selected = want.indexOf(i) >= 0;\n'
            '      }'
        : 'sel.selectedIndex = ${index ?? -1};';
    return '''
(function () {
  try {
    var sel = document.querySelector('[data-fl-sel=' + $safeId + ']');
    if (!sel) {
      sel = document.querySelector('[data-fl-sel="' + $safeId + '"]');
    }
    if (!sel) return false;
    $body
    sel.dispatchEvent(new Event('input', { bubbles: true }));
    sel.dispatchEvent(new Event('change', { bubbles: true }));
    return true;
  } catch (e) { return false; }
})();
''';
  }
}

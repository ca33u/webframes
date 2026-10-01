import Foundation

/// JavaScript injected into every frame WKWebView at document-start.
/// Handles element highlighting, DOM inspection, and scroll forwarding.
nonisolated enum InspectBridgeScript {
    static let source: String = #"""
(function(){
  if (window.__wfBridgeInstalled) return;
  window.__wfBridgeInstalled = true;

  function send(msg){
    try{ window.webkit.messageHandlers.wfFrame.postMessage(msg); }
    catch(e){}
  }

  // Scroll forwarding
  var scrollTick = false;
  function postScroll(){
    send({ type: 'wf-scroll', scrollX: window.scrollX, scrollY: window.scrollY });
  }
  window.addEventListener('scroll', function(){
    if (scrollTick) return;
    scrollTick = true;
    requestAnimationFrame(function(){ postScroll(); scrollTick = false; });
  }, true);
  if (document.readyState === 'complete') postScroll();
  else window.addEventListener('load', postScroll);

  // URL forwarding — the native card shows the live document URL like a
  // browser address bar, so we emit on initial load + every SPA nav. The
  // webview's own `didCommit` fires for full page loads but NOT for
  // pushState/replaceState, so we monkey-patch those.
  function postNav(){
    send({ type: 'wf-nav', url: location.href });
  }
  window.addEventListener('load', postNav);
  window.addEventListener('popstate', postNav);
  window.addEventListener('hashchange', postNav);
  try {
    var _ps = history.pushState;
    history.pushState = function(){ var r = _ps.apply(this, arguments); postNav(); return r; };
    var _rs = history.replaceState;
    history.replaceState = function(){ var r = _rs.apply(this, arguments); postNav(); return r; };
  } catch (e) {}
  postNav();

  // Highlight overlay
  var hlOverlay = null, hlLabel = null;
  function ensureHighlight(){
    if (hlOverlay) return;
    hlOverlay = document.createElement('div');
    hlOverlay.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;' +
      'box-sizing:border-box;border:2px solid #FE6337;background:rgba(254,99,55,.08);' +
      'transition:left .08s ease-out,top .08s ease-out,width .08s ease-out,height .08s ease-out;' +
      'display:none;border-radius:3px;';
    (document.body || document.documentElement).appendChild(hlOverlay);
    hlLabel = document.createElement('div');
    hlLabel.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;' +
      'background:#FE6337;color:#fff;font:600 11px/1.3 -apple-system,system-ui,sans-serif;' +
      'padding:2px 6px;border-radius:3px;white-space:nowrap;display:none;';
    (document.body || document.documentElement).appendChild(hlLabel);
  }
  // frameCorner: the frame's bottom corner radius in CSS pixels (0 if
  // unknown). The outline is clipped to the viewport so all four sides stay
  // visible for elements larger than the frame; corners that sit on the
  // frame's own corners take its shape (square on top under the header,
  // rounded at the bottom).
  function paintHighlight(el, frameCorner){
    if (!el || el === document.body || el === document.documentElement){
      if (hlOverlay) hlOverlay.style.display = 'none';
      if (hlLabel) hlLabel.style.display = 'none';
      return;
    }
    ensureHighlight();
    var r = el.getBoundingClientRect();
    var W = document.documentElement.clientWidth || window.innerWidth;
    var H = document.documentElement.clientHeight || window.innerHeight;
    var left = Math.max(0, r.left), top = Math.max(0, r.top);
    var right = Math.min(W, r.right), bottom = Math.min(H, r.bottom);
    if (right - left < 1 || bottom - top < 1){ clearHighlight(); return; }
    var atL = left <= 0.5, atT = top <= 0.5, atR = right >= W - 0.5, atB = bottom >= H - 0.5;
    var fc = (frameCorner || 0) + 'px';
    function corner(onX, onY, bottomEdge){ return (onX && onY) ? (bottomEdge ? fc : '0') : '3px'; }
    hlOverlay.style.left = left + 'px';
    hlOverlay.style.top = top + 'px';
    hlOverlay.style.width = (right - left) + 'px';
    hlOverlay.style.height = (bottom - top) + 'px';
    hlOverlay.style.borderRadius = corner(atL, atT, false) + ' ' + corner(atR, atT, false) + ' ' +
      corner(atR, atB, true) + ' ' + corner(atL, atB, true);
    hlOverlay.style.display = 'block';
    var tag = el.tagName.toLowerCase();
    var cls = (typeof el.className === 'string' && el.className.trim())
      ? '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.') : '';
    var id = el.id ? '#' + el.id : '';
    hlLabel.textContent = tag + id + cls;
    hlLabel.style.display = 'block';
    var lx = left + (atL ? 4 : 0);
    var ly = top - 20;
    if (ly < 2) ly = atT ? top + 4 : Math.min(bottom + 4, H - 20);
    hlLabel.style.left = Math.max(0, lx) + 'px';
    hlLabel.style.top = ly + 'px';
  }
  function clearHighlight(){
    if (hlOverlay) hlOverlay.style.display = 'none';
    if (hlLabel) hlLabel.style.display = 'none';
  }

  function getSelector(node){
    if (node.id) return '#' + CSS.escape(node.id);
    var parts = []; var cur = node;
    while (cur && cur !== document.body && cur !== document.documentElement){
      var seg = cur.tagName.toLowerCase();
      if (cur.id){ seg = '#' + CSS.escape(cur.id); parts.unshift(seg); break; }
      if (cur.className && typeof cur.className === 'string'){
        var cls = cur.className.trim().split(/\s+/).filter(c => !c.startsWith('_') && c.length < 40).slice(0, 2);
        if (cls.length) seg += '.' + cls.map(c => CSS.escape(c)).join('.');
      }
      var parent = cur.parentElement;
      if (parent){
        var siblings = [...parent.children].filter(c => c.tagName === cur.tagName);
        if (siblings.length > 1) seg += ':nth-child(' + (Array.from(parent.children).indexOf(cur) + 1) + ')';
      }
      parts.unshift(seg); cur = cur.parentElement;
    }
    return parts.join(' > ');
  }
  function getFullPath(node){
    var parts = []; var cur = node;
    while (cur && cur !== document.documentElement){
      var seg = cur.tagName.toLowerCase();
      if (cur.id) seg += '#' + cur.id;
      else if (cur.className && typeof cur.className === 'string'){
        var cls = cur.className.trim().split(/\s+/).filter(c => c.length < 40 && !c.startsWith('_')).slice(0, 2);
        if (cls.length) seg += '[class="' + cls.join(' ') + '"]';
      }
      parts.unshift(seg); cur = cur.parentElement;
    }
    return parts.join(' > ');
  }
  // Walk up from `node` to the nearest ancestor that looks like a
  // *component root* — either a React/Vue component boundary, an
  // explicit `data-component` / `data-testid` marker, or a meaningful
  // semantic container. Raw `elementFromPoint` lands on the deepest
  // inline descendant (text span, inner wrapper div), which reads as
  // "pixel picker" instead of "component picker"; this helper lifts the
  // highlight up to something the designer would actually annotate.
  // Falls back to `node` itself if nothing matches.
  var SEMANTIC_TAGS = {
    button: 1, a: 1, input: 1, select: 1, textarea: 1, label: 1,
    form: 1, fieldset: 1, section: 1, article: 1, aside: 1, nav: 1,
    header: 1, footer: 1, main: 1, figure: 1, details: 1, summary: 1,
    dialog: 1, table: 1, tr: 1, li: 1, ul: 1, ol: 1,
    img: 1, video: 1, audio: 1, picture: 1, svg: 1,
    // Text-bearing block/inline elements — authors annotate these by name
    // all the time ("the H1", "the hero paragraph"). Without these, the
    // climb jumps past the headline into the containing <section>.
    h1: 1, h2: 1, h3: 1, h4: 1, h5: 1, h6: 1,
    p: 1, blockquote: 1
  };
  function isFiberComponent(el){
    var fiberKey = Object.keys(el).find(function(k){
      return k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$');
    });
    if (!fiberKey) return false;
    var fiber = el[fiberKey];
    // Only the fiber whose `stateNode` is THIS element AND whose `type`
    // is a function (custom component) counts. The fiber chain also
    // includes host (intrinsic) fibers for <div>/<span> etc — those
    // would match every DOM node and defeat the purpose.
    while (fiber){
      if (fiber.stateNode === el &&
          fiber.type &&
          typeof fiber.type === 'function'){
        return true;
      }
      // Don't walk up past the node — we want to know if *this element*
      // is a component root, not whether any ancestor is.
      if (fiber.stateNode && fiber.stateNode !== el) break;
      fiber = fiber.return;
    }
    return false;
  }
  // Some pages stack decorative overlays with `pointer-events: none`, so
  // `elementFromPoint` falls through to a big wrapping `<section>` or
  // `<main>` and the user can't pick the child (heading, badge) they
  // actually clicked on. When that happens, manually descend into the
  // element's subtree and return the smallest child whose rect still
  // contains (x, y). That's almost always the leaf the author intended.
  function deepestAtPoint(root, x, y){
    if (!root) return null;
    var rect = root.getBoundingClientRect();
    var bigArea = 60000;  // ~245 * 245 — comfortably bigger than a button
    if (rect.width * rect.height <= bigArea) return root;
    var best = root;
    var bestArea = rect.width * rect.height;
    var stack = [root];
    var guard = 0;
    while (stack.length && guard++ < 4000){
      var cur = stack.pop();
      var kids = cur.children;
      for (var i = 0; i < kids.length; i++){
        var ch = kids[i];
        var r = ch.getBoundingClientRect();
        if (r.width < 2 || r.height < 2) continue;
        if (x < r.left || x > r.right || y < r.top || y > r.bottom) continue;
        var a = r.width * r.height;
        if (a < bestArea){ bestArea = a; best = ch; }
        stack.push(ch);
      }
    }
    return best;
  }

  function findComponentRoot(node){
    var cur = node;
    var startRect = node.getBoundingClientRect();
    var startArea = Math.max(1, startRect.width * startRect.height);
    // Cap the climb to 12 hops — deep wrapper chains (e.g. emotion/
    // styled-components) otherwise drift the highlight too far up.
    for (var hops = 0; cur && cur !== document.body && hops < 12; hops++){
      // Explicit authoring markers beat everything — if a team tagged
      // the element, that's the component they want picked.
      if (cur.dataset){
        if (cur.dataset.component || cur.dataset.testid) return cur;
      }
      if (isFiberComponent(cur)) return cur;
      if (cur.__vue__) return cur;
      var tag = cur.tagName && cur.tagName.toLowerCase();
      if (tag && SEMANTIC_TAGS[tag]) return cur;
      // Guard against "bounce to section": if the next parent's area is
      // >4× what we started with AND we've already walked some hops, the
      // climb has overshot the user's actual target. Return the last
      // reasonable ancestor (or the original node if we haven't moved).
      var parent = cur.parentElement;
      if (parent && hops > 0){
        var pr = parent.getBoundingClientRect();
        if (pr.width * pr.height > startArea * 4) return cur;
      }
      cur = parent;
    }
    return node;
  }
  function getComponentName(node){
    var cur = node;
    while (cur && cur !== document.body){
      var fiberKey = Object.keys(cur).find(k => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$'));
      if (fiberKey){
        var fiber = cur[fiberKey];
        while (fiber){
          if (fiber.type && typeof fiber.type === 'function') return fiber.type.displayName || fiber.type.name || null;
          if (fiber.type && typeof fiber.type === 'object' && fiber.type.render) return fiber.type.render.displayName || fiber.type.render.name || null;
          fiber = fiber.return;
        }
      }
      if (cur.__vue__){
        var name = cur.__vue__.$options && (cur.__vue__.$options.name || cur.__vue__.$options._componentTag);
        if (name) return name;
      }
      if (cur.dataset && cur.dataset.component) return cur.dataset.component;
      if (cur.dataset && cur.dataset.testid) return cur.dataset.testid;
      cur = cur.parentElement;
    }
    return null;
  }
  // Mirrors snapshotComputedStyles() in webframes-extantion/content.js — the
  // full 27-key set the editor's Content/Font/Sizing/Spacing tabs read from
  // and emit structured edits against. Keep this list in lock-step with the
  // extension so both clients produce identical annotation payloads.
  function snapshotComputedStyles(el){
    var cs = window.getComputedStyle(el);
    return {
      // content
      text: (el.textContent || '').trim().slice(0, 500),
      // font
      fontSize: cs.fontSize,
      fontWeight: cs.fontWeight,
      lineHeight: cs.lineHeight,
      color: cs.color,
      textAlign: cs.textAlign,
      fontFamily: cs.fontFamily,
      // sizing
      width: cs.width,
      height: cs.height,
      minWidth: cs.minWidth,
      minHeight: cs.minHeight,
      maxWidth: cs.maxWidth,
      maxHeight: cs.maxHeight,
      // spacing
      paddingTop: cs.paddingTop,
      paddingRight: cs.paddingRight,
      paddingBottom: cs.paddingBottom,
      paddingLeft: cs.paddingLeft,
      marginTop: cs.marginTop,
      marginRight: cs.marginRight,
      marginBottom: cs.marginBottom,
      marginLeft: cs.marginLeft,
      // display
      display: cs.display,
      position: cs.position,
      background: cs.backgroundColor,
      borderRadius: cs.borderRadius,
      border: cs.border,
      opacity: cs.opacity
    };
  }

  function collectContext(el){
    var rect = el.getBoundingClientRect();
    var ctx = {
      selector: getSelector(el),
      path: getFullPath(el),
      tagName: el.tagName.toLowerCase(),
      componentName: getComponentName(el),
      textContent: (el.textContent || '').trim().slice(0, 120),
      outerHTML: (el.outerHTML || '').slice(0, 500),
      attributes: {},
      computedStyles: snapshotComputedStyles(el),
      boundingRect: { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height) },
      viewport: { width: window.innerWidth, height: window.innerHeight },
      scrollX: window.scrollX,
      scrollY: window.scrollY
    };
    ['class','href','src','alt','placeholder','type','role','aria-label','data-testid'].forEach(function(a){
      if (el.hasAttribute(a)) ctx.attributes[a] = el.getAttribute(a);
    });
    return ctx;
  }

  // SVG foreignObject → PNG dataURL. Mirrors captureElement() in the
  // extension. Graceful fallback to null on:
  //   - zero-size rects
  //   - cross-origin taint (toDataURL throws SecurityError)
  //   - 1.5s timeout (some pages with heavy @font-face never fire onload)
  function captureElement(target){
    return new Promise(function(resolve){
      var done = false;
      var timer = setTimeout(function(){
        if (!done){ done = true; resolve(null); }
      }, 1500);
      try {
        var rect = target.getBoundingClientRect();
        var w = Math.min(rect.width, 800);
        var h = Math.min(rect.height, 600);
        if (w < 1 || h < 1){
          done = true; clearTimeout(timer); resolve(null); return;
        }
        var canvas = document.createElement('canvas');
        var sc = Math.min(2, 480 / Math.max(w, h));
        canvas.width = Math.round(w * sc);
        canvas.height = Math.round(h * sc);
        var ctx2 = canvas.getContext('2d');
        var html = target.outerHTML;
        if (html.length > 50000) html = html.slice(0, 50000);
        var styles = '';
        try {
          for (var i = 0; i < document.styleSheets.length; i++){
            try {
              var rules = document.styleSheets[i].cssRules;
              for (var j = 0; j < rules.length; j++) styles += rules[j].cssText + ' ';
            } catch (ex) {}
          }
        } catch (ex) {}
        var svg =
          '<svg xmlns="http://www.w3.org/2000/svg" width="' + canvas.width +
          '" height="' + canvas.height + '">' +
          '<foreignObject width="100%" height="100%">' +
          '<div xmlns="http://www.w3.org/1999/xhtml" style="transform:scale(' + sc +
          ');transform-origin:0 0;width:' + w + 'px;height:' + h + 'px;overflow:hidden;">' +
          '<style>' + styles + '</style>' + html +
          '</div></foreignObject></svg>';
        var img = new Image();
        var blob = new Blob([svg], { type: 'image/svg+xml;charset=utf-8' });
        var url = URL.createObjectURL(blob);
        img.onload = function(){
          if (done) return;
          done = true; clearTimeout(timer);
          try {
            ctx2.drawImage(img, 0, 0);
            URL.revokeObjectURL(url);
            resolve(canvas.toDataURL('image/png', 0.85));
          } catch (ex) {
            URL.revokeObjectURL(url);
            resolve(null);
          }
        };
        img.onerror = function(){
          if (done) return;
          done = true; clearTimeout(timer);
          URL.revokeObjectURL(url);
          resolve(null);
        };
        img.src = url;
      } catch (ex) {
        if (!done){ done = true; clearTimeout(timer); resolve(null); }
      }
    });
  }

  // Area comment: the element that encloses the selected region (its
  // context is what agents map to source), the region in CSS pixels, and
  // the distinct elements visible inside it. No screenshot: the outline on
  // the frame shows the region.
  function inspectArea(msg){
    var W = window.innerWidth, H = window.innerHeight;
    var r = { x: msg.area.xPct / 100 * W, y: msg.area.yPct / 100 * H,
              w: msg.area.wPct / 100 * W, h: msg.area.hPct / 100 * H };
    function contains(el){
      var b = el.getBoundingClientRect();
      return b.left <= r.x + 2 && b.top <= r.y + 2 && b.right >= r.x + r.w - 2 && b.bottom >= r.y + r.h - 2;
    }
    var seen = [], inside = [];
    for (var i = 0; i < 5; i++){
      for (var j = 0; j < 5; j++){
        var px = r.x + r.w * (i + 0.5) / 5, py = r.y + r.h * (j + 0.5) / 5;
        var raw = document.elementFromPoint(px, py);
        var leaf = raw ? deepestAtPoint(raw, px, py) : null;
        if (!leaf || seen.indexOf(leaf) >= 0) continue;
        seen.push(leaf);
        if (inside.length < 12){
          inside.push({ selector: getSelector(leaf), tagName: leaf.tagName.toLowerCase(),
                        text: (leaf.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 60) });
        }
      }
    }
    var el = seen[0] || null;
    while (el && el !== document.body && !contains(el)) el = el.parentElement;
    var ctx = el ? collectContext(el) : { viewport: { width: W, height: H }, scrollX: window.scrollX, scrollY: window.scrollY };
    ctx.area = { x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.w), height: Math.round(r.h) };
    ctx.areaElements = inside;
    send({ type: 'wf-dom-context', annId: msg.annId, context: ctx });
  }

  window.addEventListener('wf-from-canvas', function(e){
    var msg = e.detail;
    if (!msg || !msg.type) return;
    switch (msg.type){
      case 'wf-highlight': {
        var px = msg.xPct / 100 * window.innerWidth;
        var py = msg.yPct / 100 * window.innerHeight;
        var raw = document.elementFromPoint(px, py);
        var leaf = raw ? deepestAtPoint(raw, px, py) : null;
        var frameCorner = (msg.bodyScreenWidth > 0 && msg.cornerRadius > 0)
          ? msg.cornerRadius * window.innerWidth / msg.bodyScreenWidth : 0;
        paintHighlight(leaf ? findComponentRoot(leaf) : null, frameCorner);
        break;
      }
      case 'wf-highlight-off':
        clearHighlight();
        break;
      case 'wf-inspect': {
        if (msg.area){ inspectArea(msg); break; }
        var px = msg.xPct / 100 * window.innerWidth;
        var py = msg.yPct / 100 * window.innerHeight;
        var raw = document.elementFromPoint(px, py);
        var leaf = raw ? deepestAtPoint(raw, px, py) : null;
        var el = leaf ? findComponentRoot(leaf) : null;
        if (!el){ send({ type: 'wf-dom-context', annId: msg.annId, context: null }); break; }
        send({ type: 'wf-dom-context', annId: msg.annId, context: collectContext(el) });
        // Screenshot is computed asynchronously; send as a follow-up so the
        // pin gets a thumbnail without blocking the initial reply.
        captureElement(el).then(function(dataUrl){
          send({ type: 'wf-dom-screenshot', annId: msg.annId, screenshot: dataUrl });
        });
        break;
      }
      default: break;
    }
  });
})();
"""#
}

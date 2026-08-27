//
//  JSONViewerScript.h
//  Sonrisa
//
//  Pretty JSON viewer injected into pages whose main-frame document is JSON
//  (Chromium renders raw JSON as a single <pre> in a synthesized HTML doc).
//  Injected by the renderer helper (helper/helper_main.mm) at OnLoadEnd, same
//  as the autofill script — browser-process ExecuteJavaScript is a silent
//  no-op under the chrome-style CEF runtime.
//
//  The script is inert on non-JSON pages: it bails unless document.contentType
//  is a JSON type AND the body is Chromium's plain-text <pre> AND the text
//  parses as JSON.
//
//  NOTE: scripts/embed_cef.sh caches the helper binary; this header is part of
//  its rebuild check — touching it forces a helper rebuild.
//

#ifndef SONRISA_JSON_VIEWER_SCRIPT_H_
#define SONRISA_JSON_VIEWER_SCRIPT_H_

constexpr const char kSonrisaJSONViewerScript[] = R"JS(
(function () {
  if (window.__sonrisaJSONViewer) { return; }

  var ct = (document.contentType || "").toLowerCase();
  var isJSONType = ct === "application/json" || ct === "text/json" ||
                   /\+json$/.test(ct);
  if (!isJSONType) { return; }

  // Chromium displays raw JSON as a synthesized doc containing a <pre> with
  // the source text; newer builds add a "pretty print" checkbox and a second
  // (hidden) formatted <pre> around it, so don't assume a single body child.
  // Prefer the source <pre>; fall back to the whole body text.
  if (!document.body) { return; }
  var pre = document.querySelector("body > pre") ||
            document.querySelector("body pre");
  var rawText = pre ? pre.textContent : document.body.textContent;
  var data;
  try { data = JSON.parse(rawText); } catch (e) { return; }

  window.__sonrisaJSONViewer = true;

  // Always dark, monochrome base; the app's accent color (fetched from the
  // browser process below) drives keys, toggles, links and the active button.
  var CSS = [
    ":root { color-scheme: dark; }",
    "body.sonrisa-json { --sj-accent: #0A84FF; margin: 0; background: #16181d;",
    "  color: #d7dae0;",
    "  font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; }",
    ".sj-toolbar { position: sticky; top: 0; display: flex; gap: 6px;",
    "  padding: 6px 12px; background: #1e2127; border-bottom: 1px solid #2c3038;",
    "  font-family: -apple-system, sans-serif; font-size: 12px; z-index: 1; }",
    ".sj-toolbar button { font: inherit; padding: 2px 10px; border-radius: 6px;",
    "  border: 1px solid #2c3038; background: #262a31; color: inherit;",
    "  cursor: pointer; }",
    ".sj-toolbar button.sj-on { background: var(--sj-accent);",
    "  border-color: var(--sj-accent); color: #ffffff; }",
    ".sj-tree, .sj-raw { padding: 10px 14px; }",
    ".sj-raw { white-space: pre-wrap; word-break: break-word; margin: 0; }",
    ".sj-row { list-style: none; }",
    ".sj-tree ul { margin: 0; padding-left: 18px; border-left: 1px solid",
    "  rgba(128,128,128,0.25); }",
    ".sj-tree > ul { padding-left: 0; border-left: none; }",
    ".sj-key { color: var(--sj-accent); }",
    ".sj-str { color: #d7dae0; }",
    ".sj-str a { color: var(--sj-accent); }",
    ".sj-num, .sj-bool { color: #eceef2; font-weight: 600; }",
    ".sj-null { color: #8b919c; font-style: italic; }",
    ".sj-punct, .sj-count { color: #8b919c; }",
    ".sj-count { font-size: 11px; margin-left: 4px; }",
    ".sj-toggle { display: inline-block; width: 14px; cursor: pointer;",
    "  user-select: none; color: var(--sj-accent); }",
    ".sj-toggle::before { content: '\\25BE'; }",
    ".sj-collapsed > .sj-head .sj-toggle::before { content: '\\25B8'; }",
    ".sj-collapsed > ul { display: none; }",
    ".sj-head { cursor: pointer; }"
  ].join("\n");

  var AUTO_EXPAND_DEPTH = 2;
  var AUTO_EXPAND_MAX_CHILDREN = 200;
  var URL_RE = /^https?:\/\/\S+$/;

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) { e.className = cls; }
    if (text !== undefined) { e.textContent = text; }
    return e;
  }

  function leafValue(value) {
    if (value === null) { return el("span", "sj-null", "null"); }
    var t = typeof value;
    if (t === "number") { return el("span", "sj-num", String(value)); }
    if (t === "boolean") { return el("span", "sj-bool", String(value)); }
    // string
    var span = el("span", "sj-str");
    if (URL_RE.test(value)) {
      span.appendChild(document.createTextNode('"'));
      var a = el("a", null, value);
      a.href = value;
      span.appendChild(a);
      span.appendChild(document.createTextNode('"'));
    } else {
      span.textContent = JSON.stringify(value);
    }
    return span;
  }

  function keySpan(key) {
    var frag = document.createDocumentFragment();
    if (key !== undefined) {
      frag.appendChild(el("span", "sj-key", JSON.stringify(String(key))));
      frag.appendChild(el("span", "sj-punct", ": "));
    }
    return frag;
  }

  // One row (<li>) for a key/value pair or array element. Object/array
  // children are built lazily on first expand so huge documents stay cheap.
  function renderRow(key, value, depth) {
    var li = el("li", "sj-row");
    var isArr = Array.isArray(value);
    var isObj = value !== null && typeof value === "object";

    if (!isObj) {
      li.appendChild(el("span", "sj-toggle-pad", " "));
      li.firstChild.style.display = "inline-block";
      li.firstChild.style.width = "14px";
      li.appendChild(keySpan(key));
      li.appendChild(leafValue(value));
      return li;
    }

    var keys = isArr ? null : Object.keys(value);
    var count = isArr ? value.length : keys.length;
    var head = el("span", "sj-head");
    head.appendChild(el("span", "sj-toggle"));
    head.appendChild(keySpan(key));
    head.appendChild(el("span", "sj-punct", isArr ? "[…]" : "{…}"));
    head.appendChild(el("span", "sj-count",
        count + (count === 1 ? " item" : " items")));
    li.appendChild(head);

    li.className = "sj-row sj-collapsed";
    var built = false;
    function build() {
      if (built) { return; }
      built = true;
      var ul = el("ul");
      if (isArr) {
        for (var i = 0; i < value.length; i++) {
          ul.appendChild(renderRow(i, value[i], depth + 1));
        }
      } else {
        for (var k = 0; k < keys.length; k++) {
          ul.appendChild(renderRow(keys[k], value[keys[k]], depth + 1));
        }
      }
      li.appendChild(ul);
    }
    head.addEventListener("click", function () {
      build();
      li.classList.toggle("sj-collapsed");
    });
    if (count > 0 && depth < AUTO_EXPAND_DEPTH &&
        count <= AUTO_EXPAND_MAX_CHILDREN) {
      build();
      li.classList.remove("sj-collapsed");
    }
    return li;
  }

  // Rebuild the document around the viewer.
  document.body.textContent = "";
  document.body.className = "sonrisa-json";
  document.documentElement.style.colorScheme = "dark";

  // Pull the app's accent color from the browser process (cefQuery routes to
  // PasswordQueryHandler's "theme" command). Persistent: the browser pushes a
  // fresh payload whenever the accent changes, so open viewers update live.
  // Default accent applies until the first reply lands.
  if (window.cefQuery) {
    window.cefQuery({
      request: JSON.stringify({ cmd: "theme" }),
      persistent: true,
      onSuccess: function (resp) {
        try {
          var t = JSON.parse(resp);
          if (t && /^#[0-9A-Fa-f]{6}$/.test(t.accent || "")) {
            document.body.style.setProperty("--sj-accent", t.accent);
          }
        } catch (e) {}
      },
      onFailure: function () {}
    });
  }

  var style = el("style", null, CSS);
  document.head.appendChild(style);

  var toolbar = el("div", "sj-toolbar");
  var prettyBtn = el("button", "sj-on", "Pretty");
  var rawBtn = el("button", null, "Raw");
  toolbar.appendChild(prettyBtn);
  toolbar.appendChild(rawBtn);

  var tree = el("div", "sj-tree");
  var rootList = el("ul");
  rootList.appendChild(renderRow(undefined, data, 0));
  tree.appendChild(rootList);

  var rawPre = el("pre", "sj-raw", rawText);
  rawPre.style.display = "none";

  prettyBtn.addEventListener("click", function () {
    tree.style.display = "";
    rawPre.style.display = "none";
    prettyBtn.className = "sj-on";
    rawBtn.className = "";
  });
  rawBtn.addEventListener("click", function () {
    tree.style.display = "none";
    rawPre.style.display = "";
    rawBtn.className = "sj-on";
    prettyBtn.className = "";
  });

  document.body.appendChild(toolbar);
  document.body.appendChild(tree);
  document.body.appendChild(rawPre);
})();
)JS";

#endif  // SONRISA_JSON_VIEWER_SCRIPT_H_

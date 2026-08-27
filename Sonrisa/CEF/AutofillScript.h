//
//  AutofillScript.h
//  Sonrisa
//
//  Password-autofill script injected into pages. Shared by the renderer
//  helper (helper/helper_main.mm), which injects it at OnLoadEnd — injection
//  MUST happen in the renderer process: browser-process ExecuteJavaScript is
//  a silent no-op under the chrome-style CEF runtime.
//
//  Security: the script runs on every page; the browser-process query handler
//  (PasswordQueryHandler) re-derives the host from the frame's real URL and
//  rejects non-https (except localhost), so an http page can neither read nor
//  save credentials.
//
//  NOTE: scripts/embed_cef.sh caches the helper binary; it re-builds when this
//  file or helper_main.mm changes.
//

#ifndef SONRISA_AUTOFILL_SCRIPT_H_
#define SONRISA_AUTOFILL_SCRIPT_H_

constexpr const char kSonrisaAutofillScript[] = R"JS(
(function () {
  if (window.__sonrisaAutofill || !window.cefQuery) { return; }
  window.__sonrisaAutofill = true;

  var savedCreds = null;      // null until fetched from the app
  var requested = false;
  var lastReported = "";

  function isVisible(el) {
    return !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  }

  function passwordFields() {
    return Array.prototype.filter.call(
        document.querySelectorAll("input[type=password]"), isVisible);
  }

  // The username field is the explicitly-annotated one if present, otherwise
  // the last visible text-like input before the password field.
  function usernameFieldFor(passField) {
    var scope = passField.form || document;
    var explicit = scope.querySelector(
        "input[autocomplete=username], input[autocomplete=email]");
    if (explicit && isVisible(explicit)) { return explicit; }
    var candidates = scope.querySelectorAll(
        "input[type=text], input[type=email], input[type=tel], input:not([type])");
    var best = null;
    for (var i = 0; i < candidates.length; i++) {
      var el = candidates[i];
      if (!isVisible(el)) { continue; }
      if (el.compareDocumentPosition(passField) & Node.DOCUMENT_POSITION_FOLLOWING) {
        best = el;
      }
    }
    return best;
  }

  // Assign through the prototype setter so frameworks (React, Vue, ...) that
  // patch the value property still see the change, then fire the events they
  // listen for.
  function setValue(el, value) {
    var desc = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value");
    desc.set.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function fill() {
    if (!savedCreds || !savedCreds.length) { return; }
    var fields = passwordFields();
    for (var i = 0; i < fields.length; i++) {
      var pass = fields[i];
      if (pass.value) { continue; }
      var user = usernameFieldFor(pass);
      var cred = savedCreds[0];
      if (user && user.value) {
        for (var j = 0; j < savedCreds.length; j++) {
          if (savedCreds[j].username === user.value) { cred = savedCreds[j]; break; }
        }
      }
      if (user && !user.value && cred.username) { setValue(user, cred.username); }
      setValue(pass, cred.password);
    }
  }

  function requestCredentials() {
    if (requested) { fill(); return; }
    requested = true;
    window.cefQuery({
      request: JSON.stringify({ cmd: "get" }),
      onSuccess: function (response) {
        try { savedCreds = JSON.parse(response).credentials || []; }
        catch (e) { savedCreds = []; }
        fill();
      },
      onFailure: function () { savedCreds = []; }
    });
  }

  function scan() {
    if (passwordFields().length) { requestCredentials(); }
  }

  function reportCredentials(scope) {
    if (!scope || !scope.querySelector) { return; }
    var pass = scope.querySelector("input[type=password]");
    if (!pass || !pass.value) { return; }
    var user = usernameFieldFor(pass);
    var key = (user ? user.value : "") + " " + pass.value;
    if (key === lastReported) { return; }
    lastReported = key;
    window.cefQuery({
      request: JSON.stringify({
        cmd: "save",
        username: user ? user.value : "",
        password: pass.value
      }),
      onSuccess: function () {},
      onFailure: function () {}
    });
  }

  document.addEventListener("submit", function (e) {
    reportCredentials(e.target);
  }, true);

  // Many sites sign in via fetch/XHR without a real form submission; capture
  // the values when a submit-ish button is clicked or Enter is pressed in a
  // password field.
  document.addEventListener("click", function (e) {
    var btn = e.target && e.target.closest
        ? e.target.closest("button, input[type=submit]") : null;
    if (!btn) { return; }
    reportCredentials(btn.form || btn.closest("form") || document);
  }, true);
  document.addEventListener("keydown", function (e) {
    var t = e.target;
    if (e.key === "Enter" && t && t.type === "password" && t.value) {
      reportCredentials(t.form || document);
    }
  }, true);

  // SPAs render login forms after load; rescan (debounced) on DOM changes.
  var scheduled = false;
  new MutationObserver(function () {
    if (scheduled) { return; }
    scheduled = true;
    setTimeout(function () { scheduled = false; scan(); }, 300);
  }).observe(document.documentElement, { childList: true, subtree: true });

  scan();

  // ---- Form autocomplete (previously entered values) -----------------------
  // Chromium's native autofill dropdown can't render under chrome-style CEF
  // with native parent views, so the app draws its own.

  function fieldKey(el) {
    if (!el || el.tagName !== "INPUT" || el.type === "password") { return ""; }
    var t = (el.type || "text").toLowerCase();
    if (["text", "email", "tel", "search", "url"].indexOf(t) < 0) { return ""; }
    if ((el.autocomplete || "").toLowerCase() === "off") { return ""; }
    return el.name || el.id || "";
  }

  document.addEventListener("submit", function (e) {
    var form = e.target;
    if (!form || !form.querySelectorAll) { return; }
    var inputs = form.querySelectorAll("input");
    for (var i = 0; i < inputs.length; i++) {
      var key = fieldKey(inputs[i]);
      var val = inputs[i].value;
      if (!key || !val || val.length > 64) { continue; }
      window.cefQuery({
        request: JSON.stringify({ cmd: "formsave", field: key, value: val }),
        onSuccess: function () {}, onFailure: function () {}
      });
    }
  }, true);

  var acBox = null, acItems = [], acIndex = -1, acField = null, acValues = [];

  function acHide() {
    if (acBox) { acBox.remove(); }
    acBox = null; acItems = []; acIndex = -1; acField = null;
  }

  function acPick(i) {
    if (i >= 0 && i < acItems.length && acField) { setValue(acField, acItems[i]); }
    acHide();
  }

  function acShow(el, values) {
    acHide();
    if (!values.length) { return; }
    acField = el;
    acItems = values;
    var r = el.getBoundingClientRect();
    acBox = document.createElement("sonrisa-autocomplete");
    acBox.style.cssText = "position:fixed;left:" + r.left + "px;top:" + r.bottom +
        "px;z-index:2147483647;";
    var shadow = acBox.attachShadow({ mode: "open" });
    var dark = window.matchMedia &&
        window.matchMedia("(prefers-color-scheme: dark)").matches;
    var list = document.createElement("div");
    list.style.cssText = "min-width:" + Math.max(r.width, 120) + "px;" +
        "background:" + (dark ? "#2a2a2c" : "#fff") + ";" +
        "color:" + (dark ? "#eee" : "#111") + ";" +
        "border:1px solid " + (dark ? "#484848" : "#c8c8c8") + ";" +
        "border-radius:6px;box-shadow:0 4px 14px rgba(0,0,0,.25);" +
        "font:13px -apple-system,sans-serif;overflow:hidden;margin-top:2px";
    values.forEach(function (v, i) {
      var row = document.createElement("div");
      row.textContent = v;
      row.dataset.i = i;
      row.style.cssText = "padding:5px 10px;cursor:default;white-space:nowrap";
      row.addEventListener("mousedown", function (e2) { e2.preventDefault(); acPick(i); });
      row.addEventListener("mouseenter", function () { acSelect(shadow, i); });
      list.appendChild(row);
    });
    shadow.appendChild(list);
    document.documentElement.appendChild(acBox);
    acBox.__shadow = shadow;
  }

  function acSelect(shadow, i) {
    var rows = shadow.querySelectorAll("div > div");
    for (var j = 0; j < rows.length; j++) {
      rows[j].style.background = j === i ? "rgba(80,140,255,.3)" : "";
    }
    acIndex = i;
  }

  function acRefresh(el) {
    var typed = (el.value || "").toLowerCase();
    var matches = acValues.filter(function (v) {
      return v.toLowerCase().indexOf(typed) === 0 && v !== el.value;
    });
    acShow(el, matches.slice(0, 6));
  }

  document.addEventListener("focusin", function (e) {
    var el = e.target;
    var key = fieldKey(el);
    if (!key) { return; }
    window.cefQuery({
      request: JSON.stringify({ cmd: "formget", field: key }),
      onSuccess: function (resp) {
        try { acValues = JSON.parse(resp).values || []; } catch (err) { acValues = []; }
        if (document.activeElement === el && acValues.length) { acRefresh(el); }
      },
      onFailure: function () { acValues = []; }
    });
  }, true);

  document.addEventListener("input", function (e) {
    if (acValues.length && fieldKey(e.target) && document.activeElement === e.target) {
      acRefresh(e.target);
    }
  }, true);

  document.addEventListener("focusout", function () {
    setTimeout(acHide, 150);
  }, true);

  window.addEventListener("scroll", acHide, true);

  document.addEventListener("keydown", function (e) {
    if (!acBox) { return; }
    var shadow = acBox.__shadow;
    if (e.key === "ArrowDown") {
      e.preventDefault(); acSelect(shadow, Math.min(acIndex + 1, acItems.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault(); acSelect(shadow, Math.max(acIndex - 1, 0));
    } else if (e.key === "Enter" && acIndex >= 0) {
      e.preventDefault(); acPick(acIndex);
    } else if (e.key === "Escape") {
      acHide();
    }
  }, true);
})();
)JS";

#endif  // SONRISA_AUTOFILL_SCRIPT_H_

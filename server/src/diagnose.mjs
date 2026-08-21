/**
 * A diagnostic view.
 *
 * Plain HTML, inline script, no WebAssembly and no nested frame — so it renders
 * under the strictest policy a host is likely to apply. Its job is to report
 * what the *real* view environment allows, instead of us inferring it from
 * error pages.
 *
 * The useful part is the `securitypolicyviolation` listener: when the host's
 * CSP blocks something, the event carries `violatedDirective` and
 * `originalPolicy` — the entire policy string, straight from the host.
 */

export const DIAGNOSE_URI = "ui://showtime/diagnose.html";

export function renderDiagnoseHtml({ origin }) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Showtime · view diagnostics</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0; padding: 14px;
    font: 12.5px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
    background: #fff; color: #16150f;
  }
  @media (prefers-color-scheme: dark) { body { background: #1b1b19; color: #f5f4ef; } }
  h1 { font-size: 13px; margin: 0 0 10px; letter-spacing: .04em; text-transform: uppercase; opacity: .6; }
  .row { display: flex; gap: 8px; padding: 4px 0; border-bottom: 1px solid rgba(128,128,128,.25); }
  .k { flex: 0 0 190px; opacity: .7; }
  .v { flex: 1; word-break: break-word; white-space: pre-wrap; }
  .ok { color: #2f855a; } .bad { color: #c53030; } .warn { color: #b7791f; }
  #csp { margin-top: 12px; padding: 8px; background: rgba(128,128,128,.12); border-radius: 6px; white-space: pre-wrap; word-break: break-word; }
</style>
</head>
<body>
<h1>Showtime — view environment report</h1>
<div id="out"></div>
<div id="csp">CSP: waiting for a violation to reveal it…</div>

<script>
(function () {
  var out = document.getElementById("out");
  var cspBox = document.getElementById("csp");
  var ORIGIN = ${JSON.stringify(origin)};

  function row(k, v, cls) {
    var d = document.createElement("div");
    d.className = "row";
    d.innerHTML = '<div class="k"></div><div class="v"></div>';
    d.children[0].textContent = k;
    d.children[1].textContent = String(v);
    if (cls) d.children[1].className = "v " + cls;
    out.appendChild(d);
    return d;
  }

  // The whole point: a CSP violation hands us the policy that caused it.
  var sawViolation = false;
  document.addEventListener("securitypolicyviolation", function (e) {
    sawViolation = true;
    cspBox.textContent =
      "BLOCKED: " + e.violatedDirective +
      "\\nblocked URI: " + e.blockedURI +
      "\\n\\nfull policy:\\n" + (e.originalPolicy || "(not exposed)");
  });

  row("location.origin", location.origin);
  row("crossOriginIsolated", typeof crossOriginIsolated !== "undefined" ? crossOriginIsolated : "n/a");
  row("isSecureContext", window.isSecureContext);
  row("in an iframe", window.parent !== window);
  row("has opener", !!window.opener);

  // 1. WebAssembly — the reason this app nests a frame at all.
  try {
    // The 8-byte empty module: magic + version.
    new WebAssembly.Module(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]));
    row("WebAssembly.Module", "ALLOWED — a single-frame Flutter build would work", "ok");
  } catch (err) {
    row("WebAssembly.Module", "BLOCKED — " + err.message, "bad");
  }

  // 2. Nested frame to our origin, which is what is currently failing.
  var frameRow = row("nested iframe", "testing…", "warn");
  var f = document.createElement("iframe");
  f.style.cssText = "width:1px;height:1px;opacity:.01;position:absolute;left:-9999px";
  f.src = ORIGIN + "/app/?chrome=off";
  var settled = false;
  f.addEventListener("load", function () {
    if (settled) return;
    settled = true;
    frameRow.children[1].textContent = "LOADED from " + ORIGIN;
    frameRow.children[1].className = "v ok";
  });
  f.addEventListener("error", function () {
    if (settled) return;
    settled = true;
    frameRow.children[1].textContent = "ERROR event from " + ORIGIN;
    frameRow.children[1].className = "v bad";
  });
  document.body.appendChild(f);
  setTimeout(function () {
    if (settled) return;
    settled = true;
    frameRow.children[1].textContent =
      "NO load event after 6s — blocked before the document loaded";
    frameRow.children[1].className = "v bad";
  }, 6000);

  // 3. Can we reach our own origin over fetch at all?
  var fetchRow = row("fetch our origin", "testing…", "warn");
  fetch(ORIGIN + "/health")
    .then(function (r) { return r.json(); })
    .then(function (j) {
      fetchRow.children[1].textContent = "OK — " + JSON.stringify(j.server);
      fetchRow.children[1].className = "v ok";
    })
    .catch(function (e) {
      fetchRow.children[1].textContent = "FAILED — " + e.message;
      fetchRow.children[1].className = "v bad";
    });

  // 4. Loading a script from our origin (resourceDomains / script-src).
  var scriptRow = row("script from origin", "testing…", "warn");
  var s = document.createElement("script");
  s.src = ORIGIN + "/app/flutter_bootstrap.js";
  s.onload = function () {
    scriptRow.children[1].textContent = "LOADED — script-src allows our origin";
    scriptRow.children[1].className = "v ok";
  };
  s.onerror = function () {
    scriptRow.children[1].textContent = "BLOCKED or failed";
    scriptRow.children[1].className = "v bad";
  };
  document.head.appendChild(s);

  setTimeout(function () {
    if (!sawViolation) {
      cspBox.textContent =
        "No CSP violation fired. Either nothing was blocked by CSP " +
        "(the failure is a response-header block such as COEP/CORP, which does " +
        "not raise this event), or the policy allowed everything tried above.";
    }
  }, 7000);

  row("user agent", navigator.userAgent);
})();
</script>
</body>
</html>`;
}

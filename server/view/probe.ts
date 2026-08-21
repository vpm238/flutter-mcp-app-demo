/**
 * The view-environment probe, rendered *inside the shell resource itself*.
 *
 * It deliberately does not live in a second `ui://` resource. A host registers
 * the resources it learns about when the connector is added; a tool pointing at
 * a URI the host does not know about renders nothing at all, silently. Reusing
 * the one resource that already renders removes that failure mode.
 *
 * Everything here is plain DOM and inline logic — no WebAssembly, no nested
 * frame — so it survives a policy strict enough to stop the app itself.
 */

type Verdict = "ok" | "bad" | "warn";

export function renderProbe(appOrigin: string) {
  document.body.replaceChildren();
  document.body.style.cssText =
    "margin:0;padding:14px;font:12.5px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;" +
    "background:var(--color-background-primary,#fff);color:var(--color-text-primary,#16150f)";

  const title = document.createElement("h1");
  title.textContent = "Showtime — view environment report";
  title.style.cssText =
    "font-size:12px;margin:0 0 10px;letter-spacing:.05em;text-transform:uppercase;opacity:.6";
  document.body.appendChild(title);

  const rows = document.createElement("div");
  document.body.appendChild(rows);

  const cspBox = document.createElement("div");
  cspBox.style.cssText =
    "margin-top:12px;padding:8px;background:rgba(128,128,128,.14);border-radius:6px;" +
    "white-space:pre-wrap;word-break:break-word";
  cspBox.textContent = "CSP: nothing has been blocked by CSP yet.";
  document.body.appendChild(cspBox);

  const tint: Record<Verdict, string> = {
    ok: "#2f855a",
    bad: "#c53030",
    warn: "#b7791f",
  };

  function row(key: string, value: string, verdict?: Verdict) {
    const line = document.createElement("div");
    line.style.cssText =
      "display:flex;gap:8px;padding:4px 0;border-bottom:1px solid rgba(128,128,128,.25)";
    const k = document.createElement("div");
    k.style.cssText = "flex:0 0 180px;opacity:.7";
    k.textContent = key;
    const v = document.createElement("div");
    v.style.cssText = "flex:1;word-break:break-word;white-space:pre-wrap";
    v.textContent = value;
    if (verdict) v.style.color = tint[verdict];
    line.append(k, v);
    rows.appendChild(line);
    return (text: string, next: Verdict) => {
      v.textContent = text;
      v.style.color = tint[next];
    };
  }

  // A CSP violation hands us the policy that caused it — the one thing an
  // error page never tells you.
  document.addEventListener("securitypolicyviolation", (e) => {
    cspBox.textContent =
      `BLOCKED: ${e.violatedDirective}\nblocked URI: ${e.blockedURI}\n\n` +
      `full policy:\n${e.originalPolicy || "(not exposed)"}`;
  });

  row("location.origin", location.origin);
  row("opaque origin", String(location.origin === "null"));
  row(
    "crossOriginIsolated",
    typeof crossOriginIsolated !== "undefined" ? String(crossOriginIsolated) : "n/a",
  );
  row("isSecureContext", String(window.isSecureContext));
  row("nested in a frame", String(window.parent !== window));

  // The premise of the whole two-frame design. If this is allowed, the nesting
  // is unnecessary and Flutter can be served straight into this document.
  try {
    new WebAssembly.Module(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]));
    row("WebAssembly", "ALLOWED — Flutter could run in this frame directly", "ok");
  } catch (err) {
    row("WebAssembly", `BLOCKED — ${(err as Error).message}`, "bad");
  }

  // The thing that is actually failing today.
  const frameResult = row("nested iframe", "testing…", "warn");
  const probeFrame = document.createElement("iframe");
  probeFrame.style.cssText =
    "position:absolute;left:-9999px;width:1px;height:1px;opacity:.01";
  probeFrame.src = `${appOrigin}/app/?chrome=off`;
  let settled = false;
  probeFrame.addEventListener("load", () => {
    if (settled) return;
    settled = true;
    frameResult(`LOADED from ${appOrigin}`, "ok");
  });
  probeFrame.addEventListener("error", () => {
    if (settled) return;
    settled = true;
    frameResult("ERROR event — the frame was refused", "bad");
  });
  document.body.appendChild(probeFrame);
  setTimeout(() => {
    if (settled) return;
    settled = true;
    frameResult("NO load event after 6s — blocked before loading", "bad");
  }, 6000);

  const fetchResult = row("fetch our origin", "testing…", "warn");
  fetch(`${appOrigin}/health`)
    .then((r) => r.json())
    .then((j) => fetchResult(`OK — ${JSON.stringify(j.server)}`, "ok"))
    .catch((e) => fetchResult(`FAILED — ${e.message}`, "bad"));

  const scriptResult = row("script from origin", "testing…", "warn");
  const script = document.createElement("script");
  script.src = `${appOrigin}/app/flutter_bootstrap.js`;
  script.onload = () => scriptResult("LOADED — script-src allows our origin", "ok");
  script.onerror = () => scriptResult("BLOCKED or failed to load", "bad");
  document.head.appendChild(script);

  row("user agent", navigator.userAgent);
}

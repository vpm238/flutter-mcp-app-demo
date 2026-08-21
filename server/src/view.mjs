/**
 * The `ui://` resource: a shell that owns the MCP Apps connection and mounts
 * the Flutter build — in this document where the host's CSP allows WebAssembly,
 * in a nested frame on our own origin where it does not.
 *
 * The shell decides that at runtime (see `view/bridge.ts`), so the markup here
 * carries neither an `<iframe>` nor a `<base>`: whichever mount wins creates
 * what it needs. What the document does carry is the origin to reach us at, and
 * a placeholder, so there is never an empty panel.
 *
 * The bridge is inlined rather than fetched, so the resource itself needs no
 * `script-src` origins at all; the origins it does need are declared in
 * `viewMeta` in `mcp.mjs`.
 */

import { VIEW_BRIDGE_JS, VIEW_BUILD_ID } from "./generated/view-bridge.mjs";

export function renderViewHtml({ origin }) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Showtime</title>
<style>
  /* When Flutter mounts in this document, this *is* the app's page.
     overflow:hidden belongs on a page that owns the whole viewport; here
     the document is a panel in someone else's conversation, and hiding the
     overflow means anything past the panel's height is simply unreachable —
     which on a phone is most of the app. Flutter scrolls its own content, and
     the document scrolls if it ever needs to. overscroll-behavior:contain
     keeps a swipe at the end of a list from dragging the chat behind it,
     without disabling scrolling itself. */
  html, body {
    margin: 0; padding: 0; background: transparent;
    overscroll-behavior: contain;
    -webkit-tap-highlight-color: transparent;
  }
  html { height: 100%; }
  body { min-height: 100%; }

  /* Flutter handles every gesture itself, including scrolling its own lists.
     Without this the browser may decide a vertical swipe belongs to an
     ancestor — and the ancestor here is somebody's chat transcript, so the
     conversation scrolls under your finger and the view never moves. Claiming
     the gesture is what makes the app scrollable by touch inside a panel. */
  html, body { touch-action: none; }
  #app { display: block; width: 100%; height: 100%; border: 0; }
  #status {
    position: absolute; inset: 0; display: grid; place-items: center;
    font: 500 13px/1.4 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    color: color-mix(in srgb, currentColor 55%, transparent);
    pointer-events: none;
  }
  /* Visible on purpose: if the panel shows this, the shell is running, and we
     know which build of it — which a host that caches resources otherwise
     makes unknowable from the outside. */
  .build { opacity: .45; font-size: 11px; }
</style>
</head>
<body>
<div id="status">Opening the box office… <span class="build">${VIEW_BUILD_ID}</span></div>
<script>window.__SHOWTIME_ORIGIN = ${jsString(origin)};
window.__SHOWTIME_BUILD = ${jsString(VIEW_BUILD_ID)};</script>
<script>${inlineScript(VIEW_BRIDGE_JS)}</script>
</body>
</html>`;
}

/** JSON is a subset of JS, but `</script>` inside a string still ends the tag. */
function jsString(value) {
  return JSON.stringify(value).replace(/<\//g, "<\\/");
}

function inlineScript(source) {
  return source.replace(/<\/script/gi, "<\\/script");
}

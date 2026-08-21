/**
 * The `ui://` resource: a shell that owns the MCP Apps connection and mounts
 * the Flutter build in a nested frame.
 *
 * It is deliberately tiny and fully self-contained — the relay is inlined, so
 * the resource needs no `script-src` origins. The only origin it declares is
 * `frame-src`, for the inner app (see `viewMeta` in `mcp.mjs`).
 */

import { VIEW_BRIDGE_JS } from "./generated/view-bridge.mjs";

export function renderViewHtml({ origin }) {
  const appUrl = `${origin}/app/`;

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Showtime</title>
<style>
  html, body { margin: 0; padding: 0; height: 100%; background: transparent; }
  #app { display: block; width: 100%; height: 100%; border: 0; }
  #status {
    position: absolute; inset: 0; display: grid; place-items: center;
    font: 500 13px/1.4 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    color: color-mix(in srgb, currentColor 55%, transparent);
    pointer-events: none;
  }
</style>
</head>
<body>
<div id="status">Opening the box office…</div>
<iframe
  id="app"
  title="Showtime seat picker"
  allow="clipboard-write; fullscreen"
  referrerpolicy="no-referrer"
></iframe>
<script>window.__SHOWTIME_APP_URL = ${jsString(appUrl)};</script>
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

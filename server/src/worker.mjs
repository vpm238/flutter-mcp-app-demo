/**
 * Cloudflare Worker: the MCP endpoint plus the static Flutter build.
 *
 *   POST /mcp     Streamable HTTP, stateless — one request, one JSON response.
 *   GET  /app/…   the Flutter web build (served by Workers static assets).
 *   GET  /        a landing page pointing at both.
 *
 * Both live on one origin on purpose: the `ui://` shell nests `/app/` in an
 * iframe, and same-origin means the app's own fetches (CanvasKit, fonts) need
 * no CORS and run under our headers rather than the host's CSP.
 */

import {
  clearBeacons,
  listBeacons,
  recordBeacon,
  renderBeaconPage,
} from "./beacon-store.mjs";
import { getLastInitialize, handleRpc, SERVER_INFO } from "./mcp.mjs";

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, DELETE, OPTIONS",
  "access-control-allow-headers":
    "content-type, authorization, mcp-session-id, mcp-protocol-version, accept",
  "access-control-expose-headers": "mcp-session-id, mcp-protocol-version",
  "access-control-max-age": "86400",
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS });
    }

    if (url.pathname === "/mcp" || url.pathname === "/mcp/") {
      return handleMcp(request, url);
    }

    if (url.pathname === "/debug/last-initialize") {
      return json({ lastInitialize: await getLastInitialize() });
    }

    // The view pings this as it reaches each step. A request arriving here is
    // proof the code that made it ran — which, inside a host sandbox with no
    // console and no network tab, is otherwise unobservable.
    if (url.pathname === "/beacon") {
      const entry = await recordBeacon(request, {
        stage: url.searchParams.get("stage") ?? "?",
        note: url.searchParams.get("note") ?? undefined,
      });
      return json({ recorded: entry });
    }

    if (url.pathname === "/debug/requests") {
      if (url.searchParams.get("clear") === "1") await clearBeacons();
      const entries = await listBeacons();
      // Rendered as a page: whoever needs to read it is the person whose
      // browser produced the entries, and opening it there is the only way to
      // be sure of reaching the same colo that stored them.
      return new Response(renderBeaconPage(entries), {
        headers: { "content-type": "text/html; charset=utf-8", ...CORS },
      });
    }

    if (url.pathname === "/health") {
      return json({ ok: true, server: SERVER_INFO });
    }

    if (url.pathname === "/") {
      return new Response(landingPage(url.origin), {
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    }

    // Everything else is the Flutter build. `/app` without the slash would make
    // the app resolve its assets one directory too high.
    if (url.pathname === "/app") {
      return Response.redirect(`${url.origin}/app/`, 301);
    }

    return withAssetHeaders(await env.ASSETS.fetch(request));
  },
};

/**
 * The view runs in a frame sandboxed without `allow-same-origin`, so its
 * document has an opaque origin and its own subresource fetches — CanvasKit,
 * the font files — arrive as cross-origin requests with `Origin: null`.
 * Without these headers Flutter never gets its renderer.
 */
function withAssetHeaders(response) {
  const headers = new Headers(response.headers);
  headers.set("access-control-allow-origin", "*");
  headers.set("cross-origin-resource-policy", "cross-origin");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

async function handleMcp(request, url) {
  if (request.method === "GET") {
    // No server-initiated stream: everything this server says is a reply.
    return new Response("Method Not Allowed", {
      status: 405,
      headers: { allow: "POST, DELETE, OPTIONS", ...CORS },
    });
  }

  if (request.method === "DELETE") {
    return new Response(null, { status: 204, headers: CORS });
  }

  if (request.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405, headers: CORS });
  }

  let payload;
  try {
    payload = await request.json();
  } catch {
    return json(
      { jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } },
      400,
    );
  }

  const context = { origin: url.origin };

  // A client may batch messages into an array.
  if (Array.isArray(payload)) {
    const responses = [];
    for (const message of payload) {
      const response = await handleRpc(message, context);
      if (response) responses.push(response);
    }
    return responses.length === 0
      ? new Response(null, { status: 202, headers: CORS })
      : json(responses);
  }

  const response = await handleRpc(payload, context);
  return response === null
    ? new Response(null, { status: 202, headers: CORS })
    : json(response);
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...CORS },
  });
}

function landingPage(origin) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Showtime — an MCP App in Flutter web</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0; min-height: 100vh; display: grid; place-items: center;
    font: 400 16px/1.6 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    background: #f6f6f4; color: #16150f;
  }
  @media (prefers-color-scheme: dark) { body { background: #1b1b19; color: #f5f4ef; } }
  main { max-width: 34rem; padding: 2rem 1.5rem; }
  h1 { font-size: 1.6rem; letter-spacing: -0.02em; margin: 0 0 .4rem; }
  p { margin: 0 0 1rem; opacity: .8; }
  code, a.endpoint {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .9rem;
  }
  .row { display: flex; gap: .6rem; flex-wrap: wrap; margin-top: 1.4rem; }
  a.btn {
    display: inline-block; padding: .6rem 1rem; border-radius: 8px;
    text-decoration: none; font-weight: 600; font-size: .92rem;
    background: #c65b2a; color: #fff;
  }
  a.btn.ghost { background: transparent; color: inherit; border: 1px solid currentColor; opacity: .75; }
</style>
</head>
<body>
<main>
  <h1>Showtime</h1>
  <p>An MCP App: pick a date, a performance, and your seats. Built with Flutter
  web, so the pickers render as Cupertino on iOS, Material 3 on Android, and a
  wide pointer-first layout on a laptop — from one build.</p>
  <p>Add <a class="endpoint" href="${origin}/mcp">${origin}/mcp</a> as a custom
  connector to use it inside Claude.</p>
  <div class="row">
    <a class="btn" href="/app/">Open the standalone demo</a>
    <a class="btn ghost" href="/app/?persona=ios">as iOS</a>
    <a class="btn ghost" href="/app/?persona=android">as Android</a>
    <a class="btn ghost" href="/app/?persona=desktop">as desktop</a>
  </div>
</main>
</body>
</html>`;
}

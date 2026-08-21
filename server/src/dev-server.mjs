/**
 * Local dev server — the same routes as the Worker, on plain Node.
 *
 * Lets you exercise the whole thing (MCP endpoint, `ui://` resource, the Flutter
 * build, the dev host) without Cloudflare in the loop:
 *
 *     npm run dev            # http://localhost:8787
 *
 * Point an MCP client at http://localhost:8787/mcp, or open
 * http://localhost:8787/devhost/ to drive the view from a fake host.
 */

import { createReadStream, existsSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { handleRpc, SERVER_INFO } from "./mcp.mjs";
import { renderViewHtml } from "./view.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const publicDir = resolve(here, "../public");
const devhostDir = resolve(here, "../devhost");

const PORT = Number(process.env.PORT ?? 8787);
const HOST = process.env.HOST ?? "127.0.0.1";

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".wasm": "application/wasm",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".svg": "image/svg+xml",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".woff2": "font/woff2",
  ".bin": "application/octet-stream",
  ".map": "application/json",
};

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, DELETE, OPTIONS",
  "access-control-allow-headers":
    "content-type, authorization, mcp-session-id, mcp-protocol-version, accept",
};

/**
 * What `public/_headers` sets on the deployed assets. Mirrored here so the
 * embedding rules are the same locally — a host frame with
 * `Cross-Origin-Embedder-Policy: require-corp` blocks a nested cross-origin
 * frame that does not send COEP itself, and that failure is invisible if the
 * dev server is more permissive than production.
 */
const ASSET_HEADERS = {
  "access-control-allow-origin": "*",
  "cross-origin-resource-policy": "cross-origin",
  "cross-origin-embedder-policy": "require-corp",
};

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host ?? `${HOST}:${PORT}`}`);
  const origin = url.origin;

  if (req.method === "OPTIONS") return send(res, 204, CORS, "");

  if (url.pathname === "/mcp" || url.pathname === "/mcp/") {
    if (req.method === "GET") {
      return send(res, 405, { allow: "POST, DELETE, OPTIONS", ...CORS }, "Method Not Allowed");
    }
    if (req.method === "DELETE") return send(res, 204, CORS, "");
    if (req.method !== "POST") return send(res, 405, CORS, "Method Not Allowed");

    let payload;
    try {
      payload = JSON.parse(await readBody(req));
    } catch {
      return json(res, 400, {
        jsonrpc: "2.0",
        id: null,
        error: { code: -32700, message: "Parse error" },
      });
    }

    if (Array.isArray(payload)) {
      const out = [];
      for (const message of payload) {
        const response = await handleRpc(message, { origin });
        if (response) out.push(response);
      }
      return out.length ? json(res, 200, out) : send(res, 202, CORS, "");
    }

    const response = await handleRpc(payload, { origin });
    return response ? json(res, 200, response) : send(res, 202, CORS, "");
  }

  if (url.pathname === "/health") return json(res, 200, { ok: true, server: SERVER_INFO });

  // The resource HTML, served directly so the dev host can iframe it.
  if (url.pathname === "/view.html") {
    return send(res, 200, { "content-type": MIME[".html"], ...CORS }, renderViewHtml({ origin }));
  }

  if (url.pathname === "/app") return send(res, 301, { location: "/app/" }, "");

  // Mirrors the Worker's /embed/: the same build without COEP, so the shell can
  // try both when a host refuses the frame and will not say why.
  if (url.pathname === "/embed" || url.pathname.startsWith("/embed/")) {
    return serveStatic(res, publicDir, url.pathname.replace(/^\/embed/, "/app") || "/app/", {
      omit: ["cross-origin-embedder-policy"],
    });
  }

  if (url.pathname === "/") {
    return send(res, 302, { location: "/app/" }, "");
  }

  if (url.pathname.startsWith("/devhost")) {
    return serveStatic(res, devhostDir, url.pathname.replace(/^\/devhost/, "") || "/");
  }

  return serveStatic(res, publicDir, url.pathname);
});

server.listen(PORT, HOST, () => {
  console.log(`showtime dev server`);
  console.log(`  MCP endpoint   http://${HOST}:${PORT}/mcp`);
  console.log(`  standalone app http://${HOST}:${PORT}/app/`);
  console.log(`  dev host       http://${HOST}:${PORT}/devhost/`);
});

function serveStatic(res, root, pathname, { omit = [] } = {}) {
  const decoded = decodeURIComponent(pathname);
  let filePath = join(root, normalize(decoded).replace(/^(\.\.[/\\])+/, ""));
  if (!filePath.startsWith(root)) return send(res, 403, {}, "Forbidden");

  if (existsSync(filePath) && statSync(filePath).isDirectory()) {
    filePath = join(filePath, "index.html");
  }
  if (!existsSync(filePath)) return send(res, 404, CORS, "Not found");

  const headers = {
    "content-type": MIME[extname(filePath)] ?? "application/octet-stream",
    "cache-control": "no-cache",
    ...ASSET_HEADERS,
  };
  for (const key of omit) delete headers[key];

  res.writeHead(200, headers);
  createReadStream(filePath).pipe(res);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function json(res, status, body) {
  send(res, status, { "content-type": "application/json", ...CORS }, JSON.stringify(body));
}

function send(res, status, headers, body) {
  res.writeHead(status, headers);
  res.end(body);
}

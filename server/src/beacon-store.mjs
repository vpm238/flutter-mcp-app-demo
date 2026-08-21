/**
 * A short ring buffer of "something reached us", for debugging a view we cannot
 * see or attach a devtools to.
 *
 * The whole difficulty with a host that renders nothing is that every signal is
 * on the far side of a sandbox: no console, no network tab, and an error page
 * that names no cause. But the view *can* still make requests, and a request
 * arriving here is proof that the code making it ran.
 *
 * So the shell pings `/beacon` at each step it reaches, and this records what
 * arrived along with the fetch metadata the browser attaches — `sec-fetch-site`
 * and `origin` in particular, which name the embedder we have otherwise been
 * guessing about.
 *
 * Same Cache API caveat as the handshake store: shared across isolates within a
 * colo, not globally. Reading it from the same browser that produced it lands
 * in the same colo, which is why `/debug/requests` renders as a page.
 */

const KEY = "https://showtime.internal/beacons";
const LIMIT = 40;
const TTL_SECONDS = 3600;

let inMemory = [];

async function readAll() {
  if (typeof caches !== "undefined") {
    try {
      const hit = await caches.default.match(new Request(KEY));
      if (hit) return await hit.json();
    } catch {
      /* fall through to memory */
    }
  }
  return inMemory;
}

async function writeAll(entries) {
  inMemory = entries;
  if (typeof caches === "undefined") return;
  try {
    await caches.default.put(
      new Request(KEY),
      new Response(JSON.stringify(entries), {
        headers: {
          "content-type": "application/json",
          "cache-control": `max-age=${TTL_SECONDS}`,
        },
      }),
    );
  } catch {
    // Best effort: losing a debug breadcrumb must never fail a request.
  }
}

/** Record one arrival. `detail` is whatever the caller wants to remember. */
export async function recordBeacon(request, detail) {
  const headers = request.headers;
  const entry = {
    at: new Date().toISOString(),
    ...detail,
    // The fetch metadata is the point: it describes the context that made the
    // request, which is exactly what we cannot observe from inside the host.
    origin: headers.get("origin"),
    referer: headers.get("referer"),
    secFetchSite: headers.get("sec-fetch-site"),
    secFetchMode: headers.get("sec-fetch-mode"),
    secFetchDest: headers.get("sec-fetch-dest"),
    userAgent: (headers.get("user-agent") ?? "").slice(0, 120),
  };

  const entries = await readAll();
  entries.unshift(entry);
  await writeAll(entries.slice(0, LIMIT));
  return entry;
}

export async function listBeacons() {
  return await readAll();
}

export async function clearBeacons() {
  await writeAll([]);
}

/**
 * Rendered as a page rather than JSON, because the person who needs to read it
 * is the one whose browser produced the entries — and opening it there is the
 * only way to be sure of hitting the same colo that stored them.
 */
export function renderBeaconPage(entries) {
  const rows = entries
    .map((e) => {
      const cells = Object.entries(e)
        .filter(([, v]) => v !== null && v !== undefined && v !== "")
        .map(
          ([k, v]) =>
            `<div class="kv"><span class="k">${escapeHtml(k)}</span>` +
            `<span class="v">${escapeHtml(String(v))}</span></div>`,
        )
        .join("");
      return `<li>${cells}</li>`;
    })
    .join("");

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Showtime — what reached the server</title>
<style>
  :root { color-scheme: light dark; }
  body { margin:0; padding:20px; font:13px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;
         background:#fff; color:#16150f; }
  @media (prefers-color-scheme: dark) { body { background:#1b1b19; color:#f5f4ef; } }
  h1 { font-size:14px; text-transform:uppercase; letter-spacing:.05em; opacity:.6; margin:0 0 4px; }
  p.lede { opacity:.7; margin:0 0 18px; max-width:60ch; }
  ul { list-style:none; margin:0; padding:0; }
  li { padding:10px 0; border-top:1px solid rgba(128,128,128,.3); }
  .kv { display:flex; gap:10px; }
  .k { flex:0 0 130px; opacity:.6; }
  .v { flex:1; word-break:break-all; }
  .empty { padding:20px; background:rgba(128,128,128,.12); border-radius:8px; }
</style>
</head>
<body>
<h1>Showtime — what reached the server</h1>
<p class="lede">Newest first. Each entry is a request the view made from inside
the host's sandbox; <code>secFetchSite</code> and <code>origin</code> describe
the page that made it. If this list is empty, nothing from the view reached us
at all.</p>
${entries.length ? `<ul>${rows}</ul>` : '<div class="empty">No beacons recorded in this location yet.</div>'}
</body>
</html>`;
}

function escapeHtml(value) {
  return value.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}

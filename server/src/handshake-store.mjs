/**
 * A tiny cross-isolate store for the last `initialize` we saw.
 *
 * Whether a host advertises `io.modelcontextprotocol/ui` is the fact that
 * decides if a `ui://` view can render, and it is stated exactly once per
 * connection — during the handshake. A stateless Worker will usually serve the
 * later `tools/call` from a different isolate, so module memory loses it.
 *
 * The Cache API is enough here: it is shared across isolates in a colo, needs
 * no binding, no namespace and no account configuration, and this is a short
 * lived debugging fact rather than durable state. Falls back to module memory
 * where `caches` does not exist (the Node dev server).
 */

const KEY = "https://showtime.internal/last-initialize";
const TTL_SECONDS = 3600;

let inMemory = null;

export async function rememberHandshake(init) {
  inMemory = init;
  if (typeof caches === "undefined") return;
  try {
    await caches.default.put(
      new Request(KEY),
      new Response(JSON.stringify(init), {
        headers: {
          "content-type": "application/json",
          "cache-control": `max-age=${TTL_SECONDS}`,
        },
      }),
    );
  } catch {
    // Best effort: the report degrades to "not observed", never to an error.
  }
}

export async function recallHandshake() {
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

/**
 * The outer half of the MCP Apps relay.
 *
 * This script runs inside the `ui://` resource — the frame the host creates. It
 * owns the real protocol connection (via the official `@modelcontextprotocol/ext-apps`
 * `App` class), mounts the Flutter build in a nested frame served from our own
 * origin, and shuttles messages between the two.
 *
 * The nesting is not decoration. A view frame's CSP `script-src` does not carry
 * `wasm-unsafe-eval` (ext-apps#605) and Flutter web renders through CanvasKit,
 * which is WebAssembly. CSP is per-document and is not inherited by a
 * cross-origin child, so the inner frame — served by our Worker with its own
 * headers — is a place WebAssembly can actually run. The protocol stays out
 * here, where the host expects it.
 *
 * Bundled by `build.mjs` and inlined into the resource HTML, so the view needs
 * no `script-src` origins at all.
 */

import { App, PostMessageTransport } from "@modelcontextprotocol/ext-apps";

import { renderProbe } from "./probe.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

declare global {
  interface Window {
    __SHOWTIME_APP_URL?: string;
  }
}

type ChildMessage = {
  channel: "showtime";
  id?: number;
  method: string;
  params?: Record<string, unknown>;
};

/** How long to wait for the opening tool result before showing the view anyway. */
const TOOL_RESULT_GRACE_MS = 1500;

const frame = document.getElementById("app") as HTMLIFrameElement;
const status = document.getElementById("status");

let latestToolResult: unknown = null;
let resolveFirstResult: ((value: unknown) => void) | null = null;
const firstToolResult = new Promise<unknown>((resolve) => {
  resolveFirstResult = resolve;
});

/** Build an `App` with our handlers already wired, ready to connect. */
function makeApp(): App {
  const app = new App(
    { name: "showtime-view", version: "1.0.0" },
    {},
    // Flutter fills the frame and reports its own size, so the SDK's
    // ResizeObserver would only ever measure our 100%-height shell.
    { autoResize: false },
  );

  app.ontoolresult = (result: CallToolResult) => {
    const data = extract(result);

    // `diagnose_view` reuses this resource rather than registering its own,
    // because a tool pointing at a URI the host never registered renders
    // nothing at all — silently.
    if (data && (data as { probe?: string }).probe === "view-environment") {
      renderProbe(window.__SHOWTIME_APP_URL?.replace(/\/app\/$/, "") ?? "");
      return;
    }

    latestToolResult = data;
    if (resolveFirstResult) {
      resolveFirstResult(data);
      resolveFirstResult = null;
    } else {
      // A later result: the user asked the model to change something while the
      // view was open. Push it down so the app can re-render.
      toChild({ event: "tool-result", payload: JSON.stringify(data ?? null) });
    }
  };

  app.onhostcontextchanged = (patch) => {
    toChild({ event: "host-context", payload: JSON.stringify(snapshotContext(patch)) });
  };

  return app;
}

let app = makeApp();

/** Prefer structured content; fall back to a JSON text block. */
function extract(result: CallToolResult | undefined | null): unknown {
  if (!result) return null;
  if (result.structuredContent) return result.structuredContent;
  const text = result.content?.find((c) => c.type === "text");
  if (!text || typeof (text as { text?: string }).text !== "string") return null;
  try {
    return JSON.parse((text as { text: string }).text);
  } catch {
    return null;
  }
}

/** Flatten the host context into the handful of fields the view actually uses. */
function snapshotContext(context: Record<string, unknown> | undefined) {
  const styles = (context?.styles as { variables?: Record<string, string> })?.variables;
  const dimensions = context?.containerDimensions as
    | { height?: number; maxHeight?: number }
    | undefined;

  return {
    theme: context?.theme ?? "light",
    styles: styles ?? {},
    displayMode: context?.displayMode ?? "inline",
    availableDisplayModes: context?.availableDisplayModes ?? ["inline"],
    maxHeight: dimensions?.maxHeight ?? dimensions?.height ?? null,
    hostName: app.getHostVersion()?.name ?? null,
  };
}

function toChild(message: Record<string, unknown>) {
  frame.contentWindow?.postMessage({ channel: "showtime", ...message }, "*");
}

function reply(id: number | undefined, result: unknown, error?: string) {
  if (id === undefined) return;
  frame.contentWindow?.postMessage(
    { channel: "showtime", id, result, error },
    "*",
  );
}

/**
 * Handshake with retries.
 *
 * `ui/initialize` is fire-and-forget over postMessage: if the host attaches its
 * transport after we send it — which is a normal race, since hosts commonly
 * wire up on the frame's `load` event — the request is simply never heard and
 * the connection stalls until it times out. So try a few times with a short
 * deadline, each attempt on a fresh `App` because a `Protocol` cannot be
 * reconnected once its transport has failed.
 */
async function connectWithRetry(attempts = 6, deadlineMs = 700): Promise<boolean> {
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      await app.connect(new PostMessageTransport(window.parent, window.parent), {
        timeout: deadlineMs,
      });
      return true;
    } catch {
      try {
        await app.close();
      } catch {
        /* the transport may already be gone */
      }
      app = makeApp();
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }
  return false;
}

const connected = connectWithRetry().then((live) => {
  if (!live) {
    // Not fatal: the inner app falls back to fixtures and still renders.
    console.warn("[showtime] no MCP host answered; running on local fixtures");
  }
  return live;
});

connected.then((live) => {
  if (!live) return;
  app.sendLog({ level: "info", data: "Showtime view connected", logger: "showtime" });
});

window.addEventListener("message", async (event: MessageEvent) => {
  if (event.source !== frame.contentWindow) return;
  const message = event.data as ChildMessage;
  if (!message || message.channel !== "showtime") return;

  // The inner app is alive and painting; the placeholder has done its job.
  status?.remove();

  const params = message.params ?? {};

  try {
    switch (message.method) {
      case "ready": {
        const live = await connected;
        if (!live) throw new Error("no host");
        // Give the opening tool result a moment to land, then render regardless.
        const result = await Promise.race([
          firstToolResult,
          new Promise((resolve) => setTimeout(() => resolve(latestToolResult), TOOL_RESULT_GRACE_MS)),
        ]);
        reply(message.id, JSON.stringify({
          context: snapshotContext(app.getHostContext()),
          toolResult: result ?? null,
        }));
        break;
      }

      case "callTool": {
        const result = await app.callServerTool({
          name: String(params.name),
          arguments: JSON.parse(String(params.args ?? "{}")),
        });
        if (result.isError) {
          const text = result.content?.find((c) => c.type === "text");
          throw new Error(
            (text as { text?: string })?.text ?? "the tool reported an error",
          );
        }
        reply(message.id, JSON.stringify({ ok: true, data: extract(result) }));
        break;
      }

      case "requestDisplayMode": {
        const result = await app.requestDisplayMode({
          mode: params.mode as "inline" | "fullscreen" | "pip",
        });
        reply(message.id, JSON.stringify({ mode: result.mode }));
        break;
      }

      case "sendMessage":
        await app.sendMessage({
          role: "user",
          content: [{ type: "text", text: String(params.text ?? "") }],
        });
        break;

      case "updateModelContext":
        await app.updateModelContext({
          content: [{ type: "text", text: String(params.text ?? "") }],
        });
        break;

      case "setSize":
        await app.sendSizeChanged({
          width: Number(params.width) || undefined,
          height: Number(params.height) || undefined,
        });
        break;

      case "log":
        await app.sendLog({
          level: (params.level as "info" | "warning" | "error") ?? "info",
          data: String(params.message ?? ""),
          logger: "showtime",
        });
        break;

      default:
        reply(message.id, undefined, `unknown method: ${message.method}`);
    }
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    if (message.method === "callTool") {
      reply(message.id, JSON.stringify({ ok: false, error: detail }));
    } else {
      reply(message.id, undefined, detail);
    }
  }
});

frame.src = window.__SHOWTIME_APP_URL ?? "/app/";

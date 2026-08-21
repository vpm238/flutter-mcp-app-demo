/**
 * The `ui://` shell: the MCP Apps connection, plus whichever way of mounting
 * Flutter this host actually permits.
 *
 * Flutter web renders through CanvasKit, which is WebAssembly, and since 3.29
 * there is no other renderer. A view frame's CSP `script-src` is not guaranteed
 * to carry `wasm-unsafe-eval` (ext-apps#605), so for a long time this file
 * assumed it never does and always nested a second frame served from our own
 * origin — CSP is per-document and a cross-origin child does not inherit its
 * parent's, so WebAssembly compiles normally in there.
 *
 * That assumption turned out to be the expensive kind: it is untested, it costs
 * a whole extra document and a postMessage relay, and a nested frame is a much
 * bigger ask of a host sandbox than a script tag is — `frame-src` has to name
 * our origin and the host has to honour that. So the shell now *asks* instead:
 *
 *   wasm compiles here      -> mount Flutter in this document. One frame.
 *   wasm is refused here    -> nest the frame, as before.
 *   neither paints          -> render the environment report, in-view and into
 *                              the conversation, instead of a blank panel.
 *
 * Both paths present the identical `showtimeBridge` surface to the Dart side;
 * they differ only in whether the calls cross a postMessage boundary.
 *
 * Bundled by `build.mjs` and inlined into the resource, so the shell itself
 * needs no `script-src` origins.
 */

import { App, PostMessageTransport } from "@modelcontextprotocol/ext-apps";

import { renderProbe } from "./probe.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

declare global {
  interface Window {
    __SHOWTIME_ORIGIN?: string;
    showtimeBridge?: unknown;
  }
}

/** How long to wait for the opening tool result before showing the view anyway. */
const TOOL_RESULT_GRACE_MS = 1500;

/** How long Flutter gets to paint before we report the environment instead. */
const FIRST_FRAME_DEADLINE_MS = 15000;

const ORIGIN = window.__SHOWTIME_ORIGIN ?? "";
const APP_URL = `${ORIGIN}/app/`;

const status = document.getElementById("status");

let latestToolResult: unknown = null;
let resolveFirstResult: ((value: unknown) => void) | null = null;
const firstToolResult = new Promise<unknown>((resolve) => {
  resolveFirstResult = resolve;
});

/** Set once anything has painted, so the watchdog knows to stand down. */
let painted = false;

// ---------------------------------------------------------------------------
// The protocol half
// ---------------------------------------------------------------------------

/** Where a later tool result and host-context patch should be delivered. */
let deliverToolResult: (json: string) => void = () => {};
let deliverHostContext: (json: string) => void = () => {};

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
      painted = true;
      renderProbe(ORIGIN, postFindings);
      return;
    }

    latestToolResult = data;
    if (resolveFirstResult) {
      resolveFirstResult(data);
      resolveFirstResult = null;
    } else {
      // A later result: the user asked the model to change something while the
      // view was open. Push it down so the app can re-render.
      deliverToolResult(JSON.stringify(data ?? null));
    }
  };

  app.onhostcontextchanged = (patch) => {
    deliverHostContext(JSON.stringify(snapshotContext(patch)));
  };

  return app;
}

let app = makeApp();

/** Post a report as a turn, so it is readable by the model and not only on screen. */
function postFindings(summary: string) {
  void connected.then((live) => {
    if (!live) return;
    void app.sendMessage({ role: "user", content: [{ type: "text", text: summary }] });
  });
}

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
    // Not fatal: the app falls back to fixtures and still renders.
    console.warn("[showtime] no MCP host answered; running on local fixtures");
    return false;
  }
  void app.sendLog({ level: "info", data: "Showtime view connected", logger: "showtime" });
  return true;
});

// ---------------------------------------------------------------------------
// The API the Dart side calls, in one place so both mounts share it verbatim
// ---------------------------------------------------------------------------

const api = {
  async ready(): Promise<string> {
    if (!(await connected)) throw new Error("no host");
    // Give the opening tool result a moment to land, then render regardless.
    const result = await Promise.race([
      firstToolResult,
      new Promise((resolve) =>
        setTimeout(() => resolve(latestToolResult), TOOL_RESULT_GRACE_MS),
      ),
    ]);
    return JSON.stringify({
      context: snapshotContext(app.getHostContext()),
      toolResult: result ?? null,
    });
  },

  async callTool(name: string, argsJson: string): Promise<string> {
    const result = await app.callServerTool({
      name,
      arguments: JSON.parse(argsJson || "{}"),
    });
    if (result.isError) {
      const text = result.content?.find((c) => c.type === "text");
      throw new Error(
        (text as { text?: string })?.text ?? "the tool reported an error",
      );
    }
    return JSON.stringify({ ok: true, data: extract(result) });
  },

  async requestDisplayMode(mode: string): Promise<string> {
    const result = await app.requestDisplayMode({
      mode: mode as "inline" | "fullscreen" | "pip",
    });
    return JSON.stringify({ mode: result.mode });
  },

  sendMessage(text: string) {
    void app.sendMessage({ role: "user", content: [{ type: "text", text }] });
  },

  updateModelContext(text: string) {
    void app.updateModelContext({ content: [{ type: "text", text }] });
  },

  setSize(width: number, height: number) {
    void app.sendSizeChanged({
      width: Number(width) || undefined,
      height: Number(height) || undefined,
    });
  },

  log(level: string, message: string) {
    void app.sendLog({
      level: (level as "info" | "warning" | "error") ?? "info",
      data: String(message),
      logger: "showtime",
    });
  },
};

// ---------------------------------------------------------------------------
// Mount A — Flutter in this document
// ---------------------------------------------------------------------------

/**
 * Can WebAssembly compile in this frame? The 8-byte empty module (magic +
 * version) is the cheapest possible answer, and it is a synchronous throw when
 * CSP refuses, so this costs nothing when the answer is yes.
 */
function wasmAllowed(): boolean {
  try {
    new WebAssembly.Module(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]));
    return true;
  } catch {
    return false;
  }
}

function mountDirect() {
  const contextHandlers: Array<(json: string) => void> = [];
  const resultHandlers: Array<(json: string) => void> = [];
  deliverHostContext = (json) => contextHandlers.forEach((h) => h(json));
  deliverToolResult = (json) => resultHandlers.forEach((h) => h(json));

  // No relay: the app calls these directly. The `callTool` rejection is
  // reshaped here because the Dart side expects a resolved `{ok:false}`.
  window.showtimeBridge = {
    ready: () => api.ready(),
    callTool: (name: string, argsJson: string) =>
      api.callTool(name, argsJson).catch((error: unknown) =>
        JSON.stringify({
          ok: false,
          error: error instanceof Error ? error.message : String(error),
        }),
      ),
    requestDisplayMode: (mode: string) => api.requestDisplayMode(mode),
    sendMessage: (text: string) => api.sendMessage(text),
    updateModelContext: (text: string) => api.updateModelContext(text),
    setSize: (w: number, h: number) => api.setSize(w, h),
    log: (level: string, message: string) => api.log(level, message),
    onHostContext: (cb: (json: string) => void) => contextHandlers.push(cb),
    onToolResult: (cb: (json: string) => void) => resultHandlers.push(cb),
  };

  window.addEventListener("flutter-first-frame", () => {
    painted = true;
    status?.remove();
  });

  // Flutter's loader resolves `main.dart.js`, `canvaskit/` and `assets/`
  // against the document's base URI, which here is the host's, not ours.
  const base = document.createElement("base");
  base.href = APP_URL;
  document.head.appendChild(base);

  const boot = document.createElement("script");
  boot.src = `${APP_URL}flutter_bootstrap.js`;
  boot.async = true;
  document.body.appendChild(boot);
}

// ---------------------------------------------------------------------------
// Mount B — Flutter in a nested frame on our own origin
// ---------------------------------------------------------------------------

type ChildMessage = {
  channel: "showtime";
  id?: number;
  method: string;
  params?: Record<string, unknown>;
};

function mountNested() {
  const frame = document.createElement("iframe");
  frame.id = "app";
  frame.title = "Showtime seat picker";
  frame.setAttribute("allow", "clipboard-write; fullscreen");
  frame.setAttribute("referrerpolicy", "no-referrer");
  document.body.appendChild(frame);

  const toChild = (message: Record<string, unknown>) =>
    frame.contentWindow?.postMessage({ channel: "showtime", ...message }, "*");

  deliverHostContext = (payload) => toChild({ event: "host-context", payload });
  deliverToolResult = (payload) => toChild({ event: "tool-result", payload });

  const reply = (id: number | undefined, result: unknown, error?: string) => {
    if (id === undefined) return;
    frame.contentWindow?.postMessage({ channel: "showtime", id, result, error }, "*");
  };

  window.addEventListener("message", async (event: MessageEvent) => {
    if (event.source !== frame.contentWindow) return;
    const message = event.data as ChildMessage;
    if (!message || message.channel !== "showtime") return;

    // The inner app is alive and talking; the placeholder has done its job.
    painted = true;
    status?.remove();

    const params = message.params ?? {};

    try {
      switch (message.method) {
        case "ready":
          reply(message.id, await api.ready());
          break;
        case "callTool":
          reply(
            message.id,
            await api.callTool(String(params.name), String(params.args ?? "{}")),
          );
          break;
        case "requestDisplayMode":
          reply(message.id, await api.requestDisplayMode(String(params.mode)));
          break;
        case "sendMessage":
          api.sendMessage(String(params.text ?? ""));
          break;
        case "updateModelContext":
          api.updateModelContext(String(params.text ?? ""));
          break;
        case "setSize":
          api.setSize(Number(params.width), Number(params.height));
          break;
        case "log":
          api.log(String(params.level ?? "info"), String(params.message ?? ""));
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

  frame.src = APP_URL;
}

// ---------------------------------------------------------------------------
// Pick one, and say so if neither works
// ---------------------------------------------------------------------------

const direct = wasmAllowed();
if (direct) mountDirect();
else mountNested();

void app.sendLog({
  level: "info",
  data: `Showtime mounting ${direct ? "in-frame (wasm allowed)" : "nested (wasm refused)"}`,
  logger: "showtime",
});

/**
 * A blank panel is the worst outcome, because it says nothing about why. If
 * nothing has painted by the deadline, replace the shell with the environment
 * report — which also posts itself into the conversation, where the model and
 * anyone reading the transcript can see it.
 */
setTimeout(() => {
  if (painted) return;
  renderProbe(ORIGIN, postFindings);
}, FIRST_FRAME_DEADLINE_MS);

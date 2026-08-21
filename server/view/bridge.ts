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
 * The nested path then has its own choice to make, for the same reason: whether
 * a host embeds the frame depends on response headers it will not tell us
 * about, so the frame walks a list of ways to serve the same build — with and
 * without COEP — until one of them talks back. A refused frame still fires
 * `load` for the browser's error page, so "the app spoke" is the only signal
 * worth waiting on.
 *
 * Both paths present the identical `showtimeBridge` surface to the Dart side;
 * they differ only in whether the calls cross a postMessage boundary.
 *
 * Bundled by `build.mjs` and inlined into the resource, so the shell itself
 * needs no `script-src` origins.
 */

import { renderProbe } from "./probe.js";
import { ViewApp } from "./protocol.js";

/** The bits of a `CallToolResult` this shell reads. */
type CallToolResult = {
  content?: Array<{ type: string; text?: string }>;
  structuredContent?: Record<string, unknown>;
  isError?: boolean;
};

declare global {
  interface Window {
    __SHOWTIME_ORIGIN?: string;
    __SHOWTIME_BUILD?: string;
    showtimeBridge?: unknown;
  }
}

/** How long to wait for the opening tool result before showing the view anyway. */
const TOOL_RESULT_GRACE_MS = 1500;

/** How long Flutter gets to paint before we report the environment instead. */
const FIRST_FRAME_DEADLINE_MS = 12000;

/** How long one nested-frame candidate gets before we try the next. */
const FRAME_DEADLINE_MS = 3500;

const ORIGIN = window.__SHOWTIME_ORIGIN ?? "";
const BUILD = window.__SHOWTIME_BUILD ?? "unknown";
const APP_URL = `${ORIGIN}/app/`;

/**
 * Tell the server we got this far.
 *
 * Everything about a view that will not render is on the far side of a
 * sandbox: no console, no network tab, and an error page that names no cause.
 * A request arriving at our own origin is the one signal that crosses back, and
 * `connect-src` grants it. So each step the shell reaches pings `/beacon`, and
 * `/debug/requests` — opened in the same browser — says how far it got.
 *
 * If nothing is recorded, the shell never ran, and the problem is upstream of
 * every line in this file.
 */
function beacon(stage: string, note?: string) {
  try {
    const url =
      `${ORIGIN}/beacon?stage=${encodeURIComponent(stage)}&build=${encodeURIComponent(BUILD)}` +
      (note ? `&note=${encodeURIComponent(note)}` : "");
    void fetch(url, { mode: "cors", cache: "no-store" }).catch(() => {});
  } catch {
    // A diagnostic must never be the thing that breaks the view.
  }
}

beacon("shell-booted");

/**
 * Ways to serve the same build, in the order worth trying.
 *
 * They differ only in response headers, which is precisely the thing an
 * embedding host judges the frame on and precisely the thing its error page
 * declines to name. Trying them in turn is cheaper than reasoning about a
 * policy we cannot read.
 */
const FRAME_CANDIDATES = [
  { url: APP_URL, note: "with COEP: require-corp" },
  { url: `${ORIGIN}/embed/`, note: "no COEP" },
];

const status = document.getElementById("status");

let latestToolResult: unknown = null;
let resolveFirstResult: ((value: unknown) => void) | null = null;
const firstToolResult = new Promise<unknown>((resolve) => {
  resolveFirstResult = resolve;
});

/** Set once anything has painted, so the watchdog knows to stand down. */
let painted = false;

/** Set once the nested app has spoken — proof the frame really loaded. */
let alive = false;

/** Which frame URLs were tried, for the report if none of them work. */
const frameAttempts: Array<{ url: string; note: string }> = [];

/** Which mount the wasm probe selected, named for the report. */
let chosenMount = "undecided";

// ---------------------------------------------------------------------------
// The protocol half
// ---------------------------------------------------------------------------

/** Where a later tool result and host-context patch should be delivered. */
let deliverToolResult: (json: string) => void = () => {};
let deliverHostContext: (json: string) => void = () => {};

/** Build a `ViewApp` with our handlers already wired, ready to connect. */
function makeApp(): ViewApp {
  const app = new ViewApp({ name: "showtime-view", version: "1.0.0" });

  // One-shot: the host sends this once, immediately after the handshake, so the
  // handler has to exist before we connect.
  app.ontoolresult = (result: CallToolResult) => {
    const data = extract(result);

    // `diagnose_view` reuses this resource rather than registering its own,
    // because a tool pointing at a URI the host never registered renders
    // nothing at all — silently.
    if (data && (data as { probe?: string }).probe === "view-environment") {
      painted = true;
      renderProbe(ORIGIN, postFindings, probeContext());
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

/** What the shell already knows by the time the report runs. */
function probeContext() {
  return { mount: chosenMount, frameAttempts, build: BUILD };
}

/** Post a report as a turn, so it is readable by the model and not only on screen. */
function postFindings(summary: string) {
  void connected.then((live) => {
    if (!live) return;
    void app.request("ui/message", {
      role: "user",
      content: [{ type: "text", text: summary }],
    });
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
    hostName: app.hostInfo?.name ?? null,
  };
}

/**
 * Handshake with retries.
 *
 * `ui/initialize` is fire-and-forget over postMessage: if the host attaches its
 * transport after we send it — which is a normal race, since hosts commonly
 * wire up on the frame's `load` event — the request is simply never heard and
 * the connection stalls until it times out. So try a few times with a short
 * deadline, and drop anything still in flight between attempts.
 */
async function connectWithRetry(attempts = 6, deadlineMs = 700): Promise<boolean> {
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      await app.connect(deadlineMs);
      return true;
    } catch {
      app.reset();
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
  app.notify("notifications/message", {
    level: "info",
    data: "Showtime view connected",
    logger: "showtime",
  });
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
      context: snapshotContext(app.hostContext),
      toolResult: result ?? null,
    });
  },

  async callTool(name: string, argsJson: string): Promise<string> {
    const result = (await app.request("tools/call", {
      name,
      arguments: JSON.parse(argsJson || "{}"),
    })) as CallToolResult;
    if (result.isError) {
      const text = result.content?.find((c) => c.type === "text");
      throw new Error(
        (text as { text?: string })?.text ?? "the tool reported an error",
      );
    }
    return JSON.stringify({ ok: true, data: extract(result) });
  },

  async requestDisplayMode(mode: string): Promise<string> {
    const result = (await app.request("ui/request-display-mode", { mode })) as {
      mode?: string;
    };
    return JSON.stringify({ mode: result?.mode ?? mode });
  },

  sendMessage(text: string) {
    void app.request("ui/message", {
      role: "user",
      content: [{ type: "text", text }],
    });
  },

  updateModelContext(text: string) {
    void app.request("ui/update-model-context", {
      content: [{ type: "text", text }],
    });
  },

  setSize(width: number, height: number) {
    app.notify("ui/notifications/size-changed", {
      width: Number(width) || undefined,
      height: Number(height) || undefined,
    });
  },

  log(level: string, message: string) {
    app.notify("notifications/message", {
      level: level || "info",
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
  // against `document.baseURI` — which here is the host's sandbox origin, not
  // ours. The obvious fix is a `<base href>`, and it does not work: Claude's
  // view policy is `base-uri 'self'`, and it does not honour the spec's
  // `baseUriDomains`. We only know that because the probe reported the policy.
  //
  // The loader takes the same three paths as explicit config, so pass them
  // instead. `flutter_bootstrap.js` calls `load()` with no arguments, so wrap
  // the loader between the two scripts: `flutter.js` installs it, we decorate
  // it, then the bootstrap sets `buildConfig` and calls through our wrapper.
  // No string surgery on generated code, and nothing to keep in sync.
  const config = {
    entrypointBaseUrl: APP_URL,
    canvasKitBaseUrl: `${APP_URL}canvaskit/`,
    assetBase: APP_URL,
  };

  const loader = document.createElement("script");
  loader.src = `${APP_URL}flutter.js`;
  loader.addEventListener("load", () => {
    const flutter = (window as unknown as { _flutter?: { loader?: { load?: Function } } })._flutter;
    const load = flutter?.loader?.load;
    if (flutter?.loader && typeof load === "function") {
      flutter.loader.load = (options: { config?: object } = {}) =>
        load.call(flutter.loader, {
          ...options,
          config: { ...config, ...options.config },
        });
    } else {
      api.log("error", "flutter.js loaded but installed no loader to configure");
    }

    const boot = document.createElement("script");
    boot.src = `${APP_URL}flutter_bootstrap.js`;
    boot.addEventListener("error", () =>
      api.log("error", `could not load ${APP_URL}flutter_bootstrap.js`),
    );
    document.body.appendChild(boot);
  });
  loader.addEventListener("error", () =>
    api.log("error", `could not load ${APP_URL}flutter.js — script-src refused our origin`),
  );
  document.body.appendChild(loader);
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

    // The inner app is alive and talking — which is the only proof that counts.
    // A frame the host refused still fires `load` for its error page, so this,
    // not the load event, is what stops the candidate walk.
    alive = true;
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

  // Walk the candidates until one of them talks back. A refused frame renders
  // the browser's own error page and reports `load` for it, so a timer on
  // "did the app say anything" is the only reliable signal.
  void (async () => {
    for (const candidate of FRAME_CANDIDATES) {
      frameAttempts.push(candidate);
      api.log("info", `trying the app frame at ${candidate.url} (${candidate.note})`);
      frame.src = candidate.url;

      await new Promise((resolve) => setTimeout(resolve, FRAME_DEADLINE_MS));
      if (alive) {
        api.log("info", `the app frame loaded from ${candidate.url}`);
        return;
      }
    }
    api.log("error", "every app frame candidate was refused by this host");
  })();
}

// ---------------------------------------------------------------------------
// Pick one, and say so if neither works
// ---------------------------------------------------------------------------

const direct = wasmAllowed();
chosenMount = direct
  ? "in this document — WebAssembly is allowed here"
  : "nested frame — WebAssembly is refused in this document";
if (direct) mountDirect();
else mountNested();

api.log("info", `Showtime mounting ${chosenMount}`);
beacon("mount-chosen", chosenMount);

/**
 * A blank panel is the worst outcome, because it says nothing about why. If
 * nothing has painted by the deadline, replace the shell with the environment
 * report — which also posts itself into the conversation, where the model and
 * anyone reading the transcript can see it.
 */
setTimeout(() => {
  if (painted) {
    beacon("painted");
    return;
  }
  beacon("nothing-painted", chosenMount);
  renderProbe(ORIGIN, postFindings, probeContext());
}, FIRST_FRAME_DEADLINE_MS);

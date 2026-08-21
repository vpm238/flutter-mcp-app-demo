/**
 * The MCP Apps view protocol, hand-rolled.
 *
 * This exists for one reason: size. The `App` class from
 * `@modelcontextprotocol/ext-apps` is excellent, but it brings the MCP SDK and
 * zod with it, and this shell inlines its script so the resource needs no
 * `script-src` origins. That made the `ui://` resource ~393 kB of HTML — 99% of
 * it schema machinery — which is an unreasonable thing to hand a host and a
 * plausible reason for one to refuse the resource outright.
 *
 * What the view actually needs is a JSON-RPC 2.0 peer over `postMessage`:
 *
 *   view -> host   ui/initialize                     (request, once)
 *   view -> host   ui/notifications/initialized      (notification, once)
 *   host -> view   ui/notifications/tool-result      (one-shot, right after)
 *   host -> view   ui/notifications/host-context-changed
 *   view -> host   tools/call, ui/message, ui/update-model-context,
 *                  ui/request-display-mode           (requests)
 *   view -> host   ui/notifications/size-changed, notifications/message
 *
 * That is this file, in about a hundred lines and no dependencies. It is the
 * same discipline the MCP server itself follows.
 *
 * Validation is deliberately absent: this is one end of a private conversation
 * with a host whose messages we then hand to typed accessors. The dev host
 * drives this view with the *official* `AppBridge`, so the handshake is still
 * checked against the reference implementation on every run.
 */

export const UI_PROTOCOL_VERSION = "2026-01-26";

type Pending = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
};

export type HostContext = Record<string, unknown>;

export type InitializeResult = {
  protocolVersion?: string;
  hostInfo?: { name?: string; version?: string };
  hostCapabilities?: Record<string, unknown>;
  hostContext?: HostContext;
};

export class ViewApp {
  #seq = 0;
  #pending = new Map<number, Pending>();
  #listening = false;

  hostInfo: { name?: string; version?: string } | undefined;
  hostCapabilities: Record<string, unknown> | undefined;
  hostContext: HostContext | undefined;

  /** One-shot: the host sends this once, immediately after the handshake. */
  ontoolresult: ((result: Record<string, unknown>) => void) | undefined;
  ontoolinput: ((params: Record<string, unknown>) => void) | undefined;
  onhostcontextchanged: ((patch: HostContext) => void) | undefined;

  constructor(private readonly appInfo: { name: string; version: string }) {}

  #post(message: Record<string, unknown>) {
    window.parent.postMessage({ jsonrpc: "2.0", ...message }, "*");
  }

  #listen() {
    if (this.#listening) return;
    this.#listening = true;
    window.addEventListener("message", (event: MessageEvent) => {
      // Anything not from our host is not ours to read.
      if (event.source !== window.parent) return;
      const data = event.data as Record<string, unknown> | null;
      if (!data || data.jsonrpc !== "2.0") return;

      if (data.id !== undefined && (("result" in data) || ("error" in data))) {
        const entry = this.#pending.get(data.id as number);
        if (!entry) return;
        this.#pending.delete(data.id as number);
        clearTimeout(entry.timer);
        if (data.error) {
          const error = data.error as { message?: string };
          entry.reject(new Error(error?.message ?? "the host reported an error"));
        } else {
          entry.resolve(data.result);
        }
        return;
      }

      if (typeof data.method !== "string") return;
      const params = (data.params ?? {}) as Record<string, unknown>;

      switch (data.method) {
        case "ui/notifications/tool-result":
          this.ontoolresult?.(params);
          break;
        case "ui/notifications/tool-input":
          this.ontoolinput?.(params);
          break;
        case "ui/notifications/host-context-changed":
          this.hostContext = { ...this.hostContext, ...params };
          this.onhostcontextchanged?.(params);
          break;
        default:
          break;
      }

      // Every request the host makes needs an answer, even the ones we have
      // nothing to say about — a hanging request stalls its side.
      if (data.id !== undefined) this.#post({ id: data.id, result: {} });
    });
  }

  request(method: string, params: unknown, timeoutMs = 20000): Promise<unknown> {
    const id = ++this.#seq;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error(`${method} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this.#pending.set(id, { resolve, reject, timer });
      this.#post({ id, method, params });
    });
  }

  notify(method: string, params: unknown) {
    this.#post({ method, params });
  }

  /**
   * `ui/initialize`, then `ui/notifications/initialized`.
   *
   * The handshake is fire-and-forget over postMessage, so a host that attaches
   * its transport after we send — normal, since hosts commonly wire up on the
   * frame's `load` event — simply never hears it. Hence the short deadline and
   * the caller's retry loop.
   */
  async connect(timeoutMs = 700): Promise<InitializeResult> {
    this.#listen();
    const result = (await this.request(
      "ui/initialize",
      {
        appInfo: this.appInfo,
        appCapabilities: {},
        protocolVersion: UI_PROTOCOL_VERSION,
      },
      timeoutMs,
    )) as InitializeResult;

    this.hostInfo = result?.hostInfo;
    this.hostCapabilities = result?.hostCapabilities;
    this.hostContext = result?.hostContext;
    this.notify("ui/notifications/initialized", {});
    return result;
  }

  /** Abandon any in-flight requests so a retry starts from a clean slate. */
  reset() {
    for (const entry of this.#pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(new Error("connection reset"));
    }
    this.#pending.clear();
    this.#seq = 0;
  }
}

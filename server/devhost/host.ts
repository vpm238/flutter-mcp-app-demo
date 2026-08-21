/**
 * A minimal MCP Apps host, for developing the view without Claude in the loop.
 *
 * It is a real host, not a mock: it speaks Streamable HTTP to `/mcp` with the
 * official MCP client, renders the `ui://` resource in a sandboxed frame with
 * the same restrictions a production host applies (`allow-scripts`, no
 * `allow-same-origin`), and drives the view over the official `AppBridge`. So
 * if the view works here, it is because it is spec-correct — not because the
 * harness was lenient.
 *
 * It also shows what the model would see: every `ui/message` and
 * `ui/update-model-context` the view sends is printed in the transcript pane.
 */

import { AppBridge, PostMessageTransport } from "@modelcontextprotocol/ext-apps/app-bridge";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

const frameHolder = document.getElementById("frame") as HTMLDivElement;
const transcript = document.getElementById("transcript") as HTMLDivElement;
const themeSelect = document.getElementById("theme") as HTMLSelectElement;
const toolSelect = document.getElementById("tool-args") as HTMLSelectElement;
const reloadButton = document.getElementById("reload") as HTMLButtonElement;

const VIEW_URI = "ui://showtime/booking-v2.html";

let bridge: AppBridge | null = null;
let iframe: HTMLIFrameElement | null = null;

function log(kind: string, detail: string) {
  const row = document.createElement("div");
  row.className = `row ${kind}`;
  row.innerHTML = `<span class="tag">${kind}</span><span class="detail"></span>`;
  (row.querySelector(".detail") as HTMLElement).textContent = detail;
  transcript.prepend(row);
}

/**
 * The panel the host is willing to give us.
 *
 * A real chat client hands a view a slot in a conversation, not a page — often
 * a few hundred pixels tall — and it does not grow just because the view asks.
 * This dev host used to resize the frame to whatever `sizechange` requested,
 * which flattered the layout and hid the only sizing bug that matters. `?panel`
 * caps it: `?panel=inline` is a typical chat slot, `?panel=720x480` is explicit.
 */
function panel(): { width: number; height: number } {
  const raw = new URLSearchParams(location.search).get("panel") ?? "roomy";
  const preset: Record<string, [number, number]> = {
    inline: [700, 420],
    tall: [700, 620],
    roomy: [900, 900],
    phone: [390, 620],
  };
  const explicit = /^(\d+)x(\d+)$/.exec(raw);
  if (explicit) return { width: +explicit[1], height: +explicit[2] };
  const [width, height] = preset[raw] ?? preset.roomy;
  return { width, height };
}

/** `light-dark(<light>, <dark>)` for each token, as a real host emits them. */
function lightDarkPalette(): Record<string, string> {
  const pairs: Record<string, [string, string]> = {
    "--color-background-primary": ["rgba(255, 255, 255, 1)", "rgba(48, 48, 46, 1)"],
    "--color-background-secondary": ["rgba(245, 244, 237, 1)", "rgba(38, 38, 36, 1)"],
    "--color-background-tertiary": ["rgba(250, 249, 245, 1)", "rgba(20, 20, 19, 1)"],
    "--color-text-primary": ["rgba(20, 20, 19, 1)", "rgba(250, 249, 245, 1)"],
    "--color-text-secondary": ["rgba(61, 61, 58, 1)", "rgba(194, 192, 182, 1)"],
    "--color-text-tertiary": ["rgba(115, 114, 108, 1)", "rgba(156, 154, 146, 1)"],
    "--color-border-primary": [
      "rgba(31, 30, 29, 0.4)",
      "rgba(222, 220, 209, 0.4)",
    ],
  };
  return Object.fromEntries(
    Object.entries(pairs).map(([k, [l, d]]) => [k, `light-dark(${l}, ${d})`]),
  );
}

function hostContext() {
  const dark = themeSelect.value === "dark";
  return {
    theme: dark ? ("dark" as const) : ("light" as const),
    displayMode: "inline" as const,
    availableDisplayModes: ["inline" as const, "fullscreen" as const],
    containerDimensions: { maxWidth: panel().width, maxHeight: panel().height },
    // A phone-sized panel is a phone: send what a mobile host sends, so the
    // view's device detection is exercised rather than bypassed.
    ...(panel().width <= 480
      ? {
          platform: "mobile" as const,
          userAgent: new URLSearchParams(location.search).get("as") ?? "claude-ios",
          deviceCapabilities: { touch: true, hover: false },
          safeAreaInsets: { top: 44, right: 0, bottom: 34, left: 0 },
        }
      : { platform: "web" as const, deviceCapabilities: { touch: false, hover: true } }),
    // Sent the way Claude sends them: one `light-dark()` value per token,
    // rather than a pre-resolved colour per theme. A view that parses only the
    // simple form silently discards the host's entire palette and renders its
    // own defaults on the host's background — which is exactly what happened
    // while this harness was emitting plain hex.
    styles: { variables: lightDarkPalette() },
  };
}

/**
 * Build the view's policy from what the server declared, the way SEP-1865
 * describes it.
 *
 * `?wasm=off` drops `wasm-unsafe-eval`, which is the interesting switch: it is
 * the one capability that decides whether the shell can run Flutter in the view
 * document or has to nest a frame, and no host is obliged to grant it
 * (ext-apps#605). Both branches need to work, so both need to be reachable here.
 */
function buildCsp(csp: Record<string, string[]>): string {
  const list = (key: string) => (csp[key] ?? []).join(" ");
  const params = new URLSearchParams(location.search);
  const wasm = params.get("wasm") !== "off";

  // `?host=claude` replays the policy Claude actually applies, reported by the
  // in-view probe rather than guessed. It differs from the spec's shape in two
  // ways that decide the whole design: `frame-src` is `'self' blob: data:`, so
  // `frameDomains` buys nothing and the nested mount can never work there; and
  // `base-uri` is `'self'`, so `baseUriDomains` buys nothing either and a
  // `<base href>` pointing at us is refused. It does grant `'unsafe-eval'`,
  // which is why Flutter can run in the view document at all.
  if (params.get("host") === "claude") {
    const us = list("resourceDomains");
    return [
      "default-src 'self'",
      `script-src 'self' 'unsafe-inline' 'unsafe-eval' blob: data: ${us}`,
      `style-src 'self' 'unsafe-inline' ${us}`,
      `img-src 'self' data: blob: ${us}`,
      `connect-src 'self' ${us}`,
      `font-src 'self' ${us}`,
      `media-src 'self' blob: data: ${us}`,
      `worker-src 'self' blob: ${us}`,
      "frame-src 'self' blob: data:",
      "base-uri 'self'",
      "object-src 'none'",
      "form-action 'self'",
    ]
      .map((d) => d.replace(/\s+/g, " ").trim())
      .join("; ");
  }

  return [
    `default-src 'none'`,
    `script-src 'self' 'unsafe-inline'${wasm ? " 'wasm-unsafe-eval'" : ""} ${list("resourceDomains")}`,
    `style-src 'self' 'unsafe-inline' ${list("resourceDomains")}`,
    `img-src 'self' data: blob: ${list("resourceDomains")}`,
    `font-src 'self' data: ${list("resourceDomains")}`,
    `media-src 'self' data: blob: ${list("resourceDomains")}`,
    `connect-src 'self' ${list("connectDomains")}`,
    `frame-src ${list("frameDomains") || "'none'"}`,
    `base-uri ${list("baseUriDomains") || "'none'"}`,
    `form-action 'none'`,
  ]
    .map((d) => d.replace(/\s+/g, " ").trim())
    .join("; ");
}

/** A srcdoc frame has no response headers, so the policy goes in a meta tag. */
function withCsp(html: string, policy: string): string {
  const tag = `<meta http-equiv="Content-Security-Policy" content="${policy.replace(/"/g, "&quot;")}">`;
  return html.includes("<head>") ? html.replace("<head>", `<head>\n${tag}`) : tag + html;
}

async function boot() {
  transcript.replaceChildren();
  frameHolder.replaceChildren();

  const client = new Client(
    { name: "showtime-devhost", version: "1.0.0" },
    { capabilities: {} },
  );
  // `?mcp=https://…/mcp` points the host at a deployed Worker instead of the
  // local one — the way to check a real deployment end to end, since the
  // Worker sets permissive CORS on /mcp.
  const endpoint =
    new URLSearchParams(location.search).get("mcp") ??
    new URL("/mcp", location.origin).toString();
  const transport = new StreamableHTTPClientTransport(new URL(endpoint));
  await client.connect(transport);
  log("host", `connected to ${client.getServerVersion()?.name ?? "server"} at ${endpoint}`);

  const tools = await client.listTools();
  log("tools/list", tools.tools.map((t) => t.name).join(", "));

  // A `__tool` key in the selected args picks a different tool, so the
  // diagnostics panel can be driven from here too.
  const selected = JSON.parse(toolSelect.value) as Record<string, unknown>;
  const toolName = (selected.__tool as string) ?? "book_show_seats";
  const args = { ...selected };
  delete args.__tool;

  const result = (await client.callTool({
    name: toolName,
    arguments: args,
  })) as CallToolResult;
  log("tools/call", `${toolName} ${JSON.stringify(args)}`);

  const resource = await client.readResource({ uri: VIEW_URI });
  const meta = (resource.contents[0]?._meta as { ui?: { csp?: Record<string, string[]> } })
    ?.ui;
  const policy = buildCsp(meta?.csp ?? {});
  log("resources/read", `${VIEW_URI} · CSP ${policy}`);

  // Enforce the policy, rather than trusting that the view would survive one.
  // A dev host looser than production is a dev host that hides exactly the bugs
  // you only find in production — which is how the missing CORS and COEP
  // headers stayed invisible until this was live inside a real host.
  const html = withCsp(String(resource.contents[0]?.text ?? ""), policy);

  // Same restrictions a real host applies: scripts, no same-origin.
  iframe = document.createElement("iframe");
  iframe.setAttribute("sandbox", "allow-scripts allow-forms");
  iframe.style.width = `${panel().width}px`;
  iframe.style.height = `${panel().height}px`;
  iframe.style.border = "0";
  frameHolder.appendChild(iframe);

  bridge = new AppBridge(
    client,
    { name: "showtime-devhost", version: "1.0.0" },
    {},
    { hostContext: hostContext() },
  );

  bridge.onmessage = async (params) => {
    const text = params.content
      .map((c) => ("text" in c ? c.text : `[${c.type}]`))
      .join(" ");
    log("ui/message", text);
    return {};
  };

  bridge.onupdatemodelcontext = async (params) => {
    const text = params.content
      .map((c) => ("text" in c ? c.text : `[${c.type}]`))
      .join(" ");
    log("model-context", text);
    return {};
  };

  // Advertising fullscreen and then never answering the request is worse than
  // not offering it: the view waits on a reply that never comes. Grant it, and
  // actually grow the frame, so the view can be tested in the mode it asked for.
  bridge.onrequestdisplaymode = async ({ mode }) => {
    const granted = mode === "fullscreen" ? "fullscreen" : "inline";
    if (iframe) {
      // Width as well as height. Claude grants fullscreen at around 1381x908
      // on a laptop, and the two-column layout needs 820 wide before it stops
      // being a scrollbar — so a harness that grows only the height leaves the
      // view in the compact layout and never shows what fullscreen is for.
      iframe.style.height =
        granted === "fullscreen" ? "90vh" : `${panel().height}px`;
      iframe.style.width =
        granted === "fullscreen" ? "94vw" : `${panel().width}px`;

      // `?fullscreen=remount` models a host that presents fullscreen by
      // re-creating the frame rather than resizing it. That restarts the app
      // and drops whatever it had open — which, for a view that asks for
      // fullscreen in order to open a sheet, means the sheet never appears and
      // the UI looks dead. Worth being able to reproduce.
      if (
        granted === "fullscreen" &&
        new URLSearchParams(location.search).get("fullscreen") === "remount"
      ) {
        const html = iframe.getAttribute("srcdoc") ?? "";
        iframe.removeAttribute("srcdoc");
        iframe.setAttribute("srcdoc", html);
        log("display-mode", "fullscreen → frame REMOUNTED (app restarts)");
        return { mode: granted };
      }
    }
    log("display-mode", `${mode} → ${granted}`);
    return { mode: granted };
  };

  // `?autosize=ignore` models Claude on Android: the inline frame is a fixed
  // stub — 411x100 — and `ui/notifications/size-changed` does nothing. The view
  // cannot grow itself, and a view that assumes it can lays its whole UI out in
  // a strip where nothing is where it appears and taps land on nothing.
  const ignoresSize =
    new URLSearchParams(location.search).get("autosize") === "ignore";
  if (ignoresSize) {
    log("host", "autosize=ignore — size-changed does nothing, as on Claude Android");
  }

  bridge.addEventListener("sizechange", ({ width, height }) => {
    if (ignoresSize) {
      log("size", `asked ${Math.round(width ?? 0)}×${Math.round(height ?? 0)} · IGNORED`);
      return;
    }
    // Grant what was asked for, up to the panel. A host is not obliged to
    // honour a size request at all, and none of them grow without limit.
    const cap = panel().height;
    const granted = Math.min(Math.round(height ?? cap), cap);
    if (iframe && height) iframe.style.height = `${granted}px`;
    log(
      "size",
      `asked ${Math.round(width ?? 0)}×${Math.round(height ?? 0)} · granted ${granted}` +
        (granted < Math.round(height ?? 0) ? " (capped by the panel)" : ""),
    );
  });

  // `connect()` resolves once the transport is attached — it does NOT wait for
  // the view's ui/initialize. tool-input and tool-result are one-shot events,
  // so sending them before the view has finished its handshake drops them on
  // the floor, silently. Wait for the `initialized` event instead.
  const initialized = new Promise<void>((resolve) => {
    bridge!.addEventListener("initialized", () => resolve());
  });

  // Attach to the frame's WindowProxy first, then navigate it. The proxy
  // identity survives the navigation, so nothing the view sends is missed.
  await bridge.connect(
    new PostMessageTransport(iframe.contentWindow!, iframe.contentWindow!),
  );
  iframe.setAttribute("srcdoc", html);

  await Promise.race([
    initialized,
    new Promise<void>((_, reject) =>
      setTimeout(() => reject(new Error("view never sent ui/notifications/initialized")), 20000),
    ),
  ]);
  log("host", "view initialized");

  await bridge.sendToolInput({ arguments: args });
  await bridge.sendToolResult(result);
  log("tool-result", "delivered to the view");
}

themeSelect.addEventListener("change", async () => {
  if (!bridge) return;
  await bridge.sendHostContextChange(hostContext());
  log("host", `theme → ${themeSelect.value}`);
});

reloadButton.addEventListener("click", () => {
  void boot().catch((error) => log("error", String(error)));
});

boot().catch((error) => log("error", String(error)));

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

const VIEW_URI = "ui://showtime/booking.html";

let bridge: AppBridge | null = null;
let iframe: HTMLIFrameElement | null = null;

function log(kind: string, detail: string) {
  const row = document.createElement("div");
  row.className = `row ${kind}`;
  row.innerHTML = `<span class="tag">${kind}</span><span class="detail"></span>`;
  (row.querySelector(".detail") as HTMLElement).textContent = detail;
  transcript.prepend(row);
}

function hostContext() {
  const dark = themeSelect.value === "dark";
  return {
    theme: dark ? ("dark" as const) : ("light" as const),
    displayMode: "inline" as const,
    availableDisplayModes: ["inline" as const, "fullscreen" as const],
    containerDimensions: { maxWidth: 900, maxHeight: 900 },
    styles: {
      variables: dark
        ? {
            "--color-background-primary": "#262624",
            "--color-background-secondary": "#30302e",
            "--color-background-tertiary": "#3a3937",
            "--color-text-primary": "#faf9f5",
            "--color-text-secondary": "#b7b5ad",
            "--color-text-tertiary": "#8a8880",
            "--color-border-primary": "#43423f",
          }
        : {
            "--color-background-primary": "#faf9f5",
            "--color-background-secondary": "#ffffff",
            "--color-background-tertiary": "#f0eee6",
            "--color-text-primary": "#141413",
            "--color-text-secondary": "#5e5d59",
            "--color-text-tertiary": "#8a8880",
            "--color-border-primary": "#e5e4df",
          },
    },
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
  const wasm = new URLSearchParams(location.search).get("wasm") !== "off";

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
  iframe.style.width = "100%";
  iframe.style.height = "760px";
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

  bridge.addEventListener("sizechange", ({ width, height }) => {
    if (iframe && height) iframe.style.height = `${Math.round(height)}px`;
    log("size", `${Math.round(width ?? 0)}×${Math.round(height ?? 0)}`);
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

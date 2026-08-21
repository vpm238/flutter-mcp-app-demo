/**
 * A small, dependency-free MCP server.
 *
 * Stateless JSON-RPC over HTTP: one POST, one JSON response. That is a valid
 * Streamable HTTP server and it runs unchanged on Cloudflare Workers, where the
 * Node-oriented transports in the official SDK do not.
 *
 * Four tools, one `ui://` resource:
 *
 *   book_show_seats   model-visible, carries the UI. The tool the model calls.
 *   list_showtimes    refresh the performance list (model + app).
 *   get_seat_map      app-only; the view asks for a house when you pick a time.
 *   confirm_booking   app-only; the user's click is what books, not the model.
 */

import {
  AISLES_AFTER,
  PER_SEAT_FEE_CENTS,
  confirmationCode,
  describeSeats,
  findShow,
  formatMoney,
  formatWhen,
  priceOf,
  seatById,
  seatMapFor,
  slotsFor,
} from "./domain.mjs";
import { recallHandshake, rememberHandshake } from "./handshake-store.mjs";
import { renderViewHtml } from "./view.mjs";

export const SERVER_INFO = {
  name: "showtime",
  title: "Showtime",
  version: "1.0.0",
};

export const VIEW_URI = "ui://showtime/booking.html";

const SUPPORTED_PROTOCOLS = ["2026-01-26", "2025-11-25", "2025-06-18", "2025-03-26"];
const DEFAULT_PROTOCOL = "2025-06-18";

const INSTRUCTIONS = [
  "Showtime books theatre tickets through an interactive view.",
  "",
  "Call `book_show_seats` whenever the user wants to see performance times or",
  "choose seats — it opens a picker where they select the date, the performance,",
  "and the exact seats themselves. Do not try to pick seats on their behalf, and",
  "do not ask for the date and time in chat first: the view is the faster way to",
  "answer those questions. Pass whatever they already told you (`show`,",
  "`party_size`, `when`) so the view opens pre-filled.",
  "",
  "The user's confirmation comes back to you as a message with the seats and a",
  "confirmation code. `confirm_booking` is not yours to call.",
].join("\n");

/** In-memory holds. Per-isolate and therefore best-effort, which is honest for
 *  a demo box office — a real one would put these in KV or Durable Objects. */
const bookings = new Map();

/** The MCP Apps extension id a host advertises when it can render `ui://` views. */
const UI_EXTENSION = "io.modelcontextprotocol/ui";

/**
 * What the last client sent at `initialize`.
 *
 * The spec puts the burden on the server to "check client capabilities before
 * registering UI-enabled tools", so whether a host advertises
 * `io.modelcontextprotocol/ui` is the single fact that decides if a view will
 * ever render. It is also invisible from the outside — hence recording it.
 */
export function getLastInitialize() {
  return recallHandshake();
}

function describeClient(init) {
  if (!init) {
    return "No initialize has been seen by this instance yet.";
  }
  const ui = init.capabilities?.extensions?.[UI_EXTENSION];
  const lines = [
    `client: ${init.clientInfo?.name ?? "?"} ${init.clientInfo?.version ?? ""}`.trim(),
    `protocolVersion: ${init.protocolVersion ?? "?"}`,
    ui
      ? `MCP Apps: ADVERTISED — mimeTypes ${JSON.stringify(ui.mimeTypes ?? [])}`
      : "MCP Apps: NOT ADVERTISED — this client did not offer " +
        `\`${UI_EXTENSION}\`, so it will not render a ui:// view`,
    `raw capabilities: ${JSON.stringify(init.capabilities ?? {})}`,
  ];
  return lines.join("\n");
}

const TOOLS = [
  {
    name: "book_show_seats",
    title: "Book show seats",
    description:
      "Open the seat picker for a show. Renders an interactive date, time, and " +
      "seat-map view so the user chooses for themselves. Use this for any " +
      "request about showtimes, availability, or booking tickets.",
    inputSchema: {
      type: "object",
      properties: {
        show: {
          type: "string",
          description:
            "Show id or title. One of: lighthouse (The Lighthouse Keeper), " +
            "neon-orchestra (Neon Orchestra: Live), coriolanus (Coriolanus). " +
            "Defaults to The Lighthouse Keeper.",
        },
        party_size: {
          type: "integer",
          minimum: 1,
          maximum: 6,
          description: "How many seats the user needs. Defaults to 2.",
        },
        when: {
          type: "string",
          description:
            "Optional ISO date (YYYY-MM-DD) to pre-select, if the user named a day.",
        },
      },
    },
    _meta: {
      ui: { resourceUri: VIEW_URI, visibility: ["model"], prefersBorder: false },
      "ui/resourceUri": VIEW_URI,
    },
  },
  {
    name: "list_showtimes",
    title: "List showtimes",
    description:
      "The performance list for a show: dates, curtain times, seats left, and " +
      "the price floor. Refreshes the open view.",
    inputSchema: {
      type: "object",
      properties: {
        show: { type: "string" },
        party_size: { type: "integer", minimum: 1, maximum: 6 },
        when: { type: "string" },
      },
    },
    _meta: { ui: { resourceUri: VIEW_URI, visibility: ["model", "app"] } },
  },
  {
    name: "get_seat_map",
    title: "Get seat map",
    description: "The seat map for one performance, with per-seat availability.",
    inputSchema: {
      type: "object",
      properties: { slot: { type: "string", description: "Slot id." } },
      required: ["slot"],
    },
    _meta: { ui: { resourceUri: VIEW_URI, visibility: ["app"] } },
  },
  {
    name: "diagnose_view",
    title: "Diagnose the view environment",
    description:
      "Render a diagnostic panel that reports what this host's view sandbox " +
      "allows: WebAssembly, nested frames, fetch and script loads from the " +
      "server's origin, and the Content-Security-Policy itself. Use when the " +
      "booking view fails to render, to find out why.",
    inputSchema: { type: "object", properties: {} },
    _meta: {
      ui: { resourceUri: VIEW_URI, visibility: ["model"], prefersBorder: true },
      "ui/resourceUri": VIEW_URI,
    },
  },
  {
    name: "confirm_booking",
    title: "Confirm booking",
    description:
      "Commit the chosen seats. Called by the view when the user confirms; the " +
      "model must not call it.",
    inputSchema: {
      type: "object",
      properties: {
        slot: { type: "string" },
        seats: { type: "array", items: { type: "string" } },
        show: { type: "string" },
      },
      required: ["slot", "seats"],
    },
    _meta: { ui: { resourceUri: VIEW_URI, visibility: ["app"] } },
  },
];

/**
 * Handle one JSON-RPC message. Returns a response object, or null for
 * notifications (which get a bare 202).
 */
export async function handleRpc(message, { origin }) {
  const { id, method, params = {} } = message ?? {};

  if (method?.startsWith("notifications/")) return null;

  try {
    switch (method) {
      case "initialize":
        await rememberHandshake({
          at: new Date().toISOString(),
          clientInfo: params.clientInfo,
          protocolVersion: params.protocolVersion,
          capabilities: params.capabilities,
        });
        return ok(id, {
          protocolVersion: SUPPORTED_PROTOCOLS.includes(params.protocolVersion)
            ? params.protocolVersion
            : DEFAULT_PROTOCOL,
          capabilities: {
            tools: { listChanged: false },
            resources: { listChanged: false, subscribe: false },
          },
          serverInfo: SERVER_INFO,
          instructions: INSTRUCTIONS,
        });

      case "ping":
        return ok(id, {});

      case "tools/list":
        return ok(id, { tools: TOOLS });

      case "resources/list":
        return ok(id, {
          resources: [
            {
              uri: VIEW_URI,
              name: "Showtime booking view",
              description:
                "Adaptive date, time, and seat picker. Cupertino on iOS, " +
                "Material 3 on Android, a wide pointer-first layout on desktop.",
              mimeType: "text/html;profile=mcp-app",
              _meta: { ui: viewMeta(origin) },
            },
          ],
        });

      case "resources/templates/list":
        // (diagnostic resource is listed above)
        return ok(id, { resourceTemplates: [] });

      case "resources/read": {
        if (params.uri !== VIEW_URI) {
          return err(id, -32602, `Unknown resource: ${params.uri}`);
        }
        return ok(id, {
          contents: [
            {
              uri: VIEW_URI,
              mimeType: "text/html;profile=mcp-app",
              text: renderViewHtml({ origin }),
              _meta: { ui: viewMeta(origin) },
            },
          ],
        });
      }

      case "tools/call":
        return ok(id, await callTool(params.name, params.arguments ?? {}));

      default:
        return err(id, -32601, `Method not found: ${method}`);
    }
  } catch (error) {
    return err(id, -32603, error?.message ?? "Internal error");
  }
}

/**
 * What the host needs in order to build a CSP the view can actually live under.
 *
 * The Flutter app runs in a nested frame served from `origin`, so `frame-src`
 * has to allow it. Everything else the outer shell needs is inline, which the
 * spec's default policy already permits.
 */
function viewMeta(origin) {
  return {
    csp: {
      frameDomains: [origin],
      // The diagnostics panel renders in this same resource and probes the
      // origin directly, so it needs both of these to test anything real.
      connectDomains: [origin],
      resourceDomains: [origin],
    },
    prefersBorder: false,
  };
}

async function callTool(name, args) {
  switch (name) {
    case "book_show_seats":
    case "list_showtimes":
      return sessionResult(args);
    case "get_seat_map":
      return seatMapResult(args);
    case "confirm_booking":
      return confirmResult(args);
    case "diagnose_view": {
      const init = await recallHandshake();
      const ui = init?.capabilities?.extensions?.[UI_EXTENSION];

      // The findings go in structuredContent, not just text: hosts display the
      // structured result and hide the text block, so a report written only as
      // text is invisible exactly where it is needed.
      return {
        content: [{ type: "text", text: describeClient(init) }],
        structuredContent: {
          probe: "view-environment",
          observedInitialize: Boolean(init),
          client: init?.clientInfo?.name ?? null,
          clientVersion: init?.clientInfo?.version ?? null,
          protocolVersion: init?.protocolVersion ?? null,
          mcpAppsAdvertised: Boolean(ui),
          uiMimeTypes: ui?.mimeTypes ?? null,
          rawCapabilities: init?.capabilities ?? null,
          meaning: ui
            ? "This host advertised MCP Apps, so a ui:// view should render."
            : init
              ? "This host did NOT advertise io.modelcontextprotocol/ui, so it " +
                "will not render a ui:// view no matter what the server sends."
              : "This server instance has not seen an initialize — the handshake " +
                "landed on a different isolate. Run this again.",
        },
      };
    }
    default:
      return toolError(`Unknown tool: ${name}`);
  }
}

function sessionResult(args) {
  const show = findShow(args.show);
  const partySize = clampInt(args.party_size, 1, 6, 2);
  const slots = slotsFor(show.id);

  // If the user named a day, land the view on it.
  let preselectedSlotId = null;
  if (args.when) {
    const wanted = String(args.when).slice(0, 10);
    preselectedSlotId =
      slots.find((s) => s.startsAt.startsWith(wanted) && s.seatsLeft > 0)?.id ?? null;
  }

  const data = {
    show,
    slots,
    partySize,
    currency: "USD",
    preselectedSlotId,
  };

  const next = slots.filter((s) => s.seatsLeft > 0).slice(0, 3);
  const summary = [
    `${show.title} — ${show.venue}, ${show.city}.`,
    `Showing the seat picker for ${partySize} ${partySize === 1 ? "seat" : "seats"}.`,
    `Next performances: ${next
      .map((s) => `${formatWhen(s.startsAt)} (${s.seatsLeft} seats left)`)
      .join("; ")}.`,
    "The user picks the date, performance, and seats in the view.",
  ].join(" ");

  return { content: [{ type: "text", text: summary }], structuredContent: data };
}

function seatMapResult(args) {
  const slotId = String(args.slot ?? "");
  if (!slotId) return toolError("A slot id is required.");
  const held = bookings.get(slotId)?.seats ?? [];
  const map = seatMapFor(slotId, { alsoTaken: new Set(held) });
  const free = map.rows.flatMap((r) => r.seats).filter((s) => s.status === "available");

  return {
    content: [
      { type: "text", text: `${free.length} seats available for ${slotId}.` },
    ],
    structuredContent: map,
  };
}

function confirmResult(args) {
  const slotId = String(args.slot ?? "");
  const seatIds = Array.isArray(args.seats) ? args.seats.map(String) : [];
  if (!slotId || seatIds.length === 0) {
    return toolError("A slot id and at least one seat are required.");
  }

  const show = findShow(args.show);
  const slot = slotsFor(show.id).find((s) => s.id === slotId);
  if (!slot) return toolError(`Unknown performance: ${slotId}`);

  const held = bookings.get(slotId)?.seats ?? [];
  const map = seatMapFor(slotId, { alsoTaken: new Set(held) });

  const seats = [];
  for (const id of seatIds) {
    const seat = seatById(map, id);
    if (!seat) return toolError(`Seat ${id} is not in this house.`);
    if (seat.status !== "available") {
      return toolError(`Seat ${id} was taken while you were choosing. Pick another.`);
    }
    seats.push(seat);
  }

  const subtotal = seats.reduce((sum, seat) => sum + priceOf(map, seat), 0);
  const totalCents = subtotal + PER_SEAT_FEE_CENTS * seats.length;
  const code = confirmationCode(slotId, seatIds);

  bookings.set(slotId, { seats: [...held, ...seatIds], code });

  const booking = {
    code,
    seats: seatIds,
    totalCents,
    subtotalCents: subtotal,
    feesCents: PER_SEAT_FEE_CENTS * seats.length,
    startsAt: slot.startsAt,
    showTitle: show.title,
    showId: show.id,
    venue: show.venue,
  };

  return {
    content: [
      {
        type: "text",
        text:
          `Booked ${seats.length} ${seats.length === 1 ? "seat" : "seats"} — ` +
          `${describeSeats(seatIds)} — for ${show.title} at ${show.venue}, ` +
          `${formatWhen(slot.startsAt)}. Total ${formatMoney(totalCents)} ` +
          `(includes ${formatMoney(PER_SEAT_FEE_CENTS * seats.length)} in fees). ` +
          `Confirmation ${code}.`,
      },
    ],
    structuredContent: booking,
  };
}

function toolError(message) {
  return { content: [{ type: "text", text: message }], isError: true };
}

function clampInt(value, lo, hi, fallback) {
  const n = Number.parseInt(value, 10);
  if (Number.isNaN(n)) return fallback;
  return Math.min(hi, Math.max(lo, n));
}

const ok = (id, result) => ({ jsonrpc: "2.0", id, result });
const err = (id, code, message) => ({ jsonrpc: "2.0", id, error: { code, message } });

export const _internals = { TOOLS, AISLES_AFTER, bookings };

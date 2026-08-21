/**
 * Protocol-level tests: the shapes a host actually depends on.
 *
 * Run with `npm test`.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { handleRpc, VIEW_URI } from "../src/mcp.mjs";
import {
  confirmationCode,
  describeSeats,
  seatMapFor,
  slotsFor,
} from "../src/domain.mjs";

const ORIGIN = "https://showtime.example.workers.dev";
const call = (message) => handleRpc(message, { origin: ORIGIN });
const rpc = (method, params, id = 1) => ({ jsonrpc: "2.0", id, method, params });

test("initialize echoes a supported protocol version and advertises both features", async () => {
  const response = await call(
    rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {} }),
  );
  assert.equal(response.result.protocolVersion, "2025-06-18");
  assert.ok(response.result.capabilities.tools);
  assert.ok(response.result.capabilities.resources);
  assert.match(response.result.instructions, /book_show_seats/);
});

test("initialize falls back for an unknown protocol version", async () => {
  const response = await call(rpc("initialize", { protocolVersion: "1999-01-01" }));
  assert.equal(response.result.protocolVersion, "2025-06-18");
});

test("notifications get no response", async () => {
  assert.equal(await call(rpc("notifications/initialized", {})), null);
});

test("every tool points at the view, in both the current and legacy meta keys", async () => {
  const { tools } = (await call(rpc("tools/list"))).result;
  assert.deepEqual(
    tools.map((t) => t.name),
    ["book_show_seats", "list_showtimes", "get_seat_map", "confirm_booking"],
  );
  for (const tool of tools) {
    assert.equal(tool._meta.ui.resourceUri, VIEW_URI);
  }
  // Older hosts only read the flat key; the entry tool must carry both.
  const entry = tools.find((t) => t.name === "book_show_seats");
  assert.equal(entry._meta["ui/resourceUri"], VIEW_URI);

  // The booking tool is the user's to press, not the model's.
  const confirm = tools.find((t) => t.name === "confirm_booking");
  assert.deepEqual(confirm._meta.ui.visibility, ["app"]);
});

test("the resource is served as an MCP app and declares the frame origin", async () => {
  const { contents } = (await call(rpc("resources/read", { uri: VIEW_URI }))).result;
  const [content] = contents;

  assert.equal(content.mimeType, "text/html;profile=mcp-app");
  assert.deepEqual(content._meta.ui.csp.frameDomains, [ORIGIN]);
  assert.deepEqual(content._meta.ui.csp.connectDomains, []);
  assert.deepEqual(content._meta.ui.csp.resourceDomains, []);

  // The shell must be self-contained: the app URL and the inlined relay.
  assert.match(content.text, /<iframe/);
  assert.ok(content.text.includes(`${ORIGIN}/app/`));
  assert.ok(!/<script[^>]+src=/.test(content.text), "no external scripts");
});

test("reading an unknown resource is an error, not a 200 with junk", async () => {
  const response = await call(rpc("resources/read", { uri: "ui://nope" }));
  assert.equal(response.result, undefined);
  assert.equal(response.error.code, -32602);
});

test("book_show_seats returns a session the view can paint immediately", async () => {
  const response = await call(
    rpc("tools/call", {
      name: "book_show_seats",
      arguments: { show: "neon-orchestra", party_size: 4 },
    }),
  );
  const data = response.result.structuredContent;

  assert.equal(data.show.id, "neon-orchestra");
  assert.equal(data.partySize, 4);
  assert.ok(data.slots.length > 0);
  // Text content is what a host without UI support shows the model.
  assert.match(response.result.content[0].text, /Neon Orchestra/);
});

test("party size is clamped rather than trusted", async () => {
  const big = await call(
    rpc("tools/call", { name: "book_show_seats", arguments: { party_size: 99 } }),
  );
  assert.equal(big.result.structuredContent.partySize, 6);

  const junk = await call(
    rpc("tools/call", { name: "book_show_seats", arguments: { party_size: "lots" } }),
  );
  assert.equal(junk.result.structuredContent.partySize, 2);
});

test("a show can be named loosely, the way a user would", async () => {
  for (const query of ["lighthouse", "The Lighthouse Keeper", "the lighthouse one"]) {
    const response = await call(
      rpc("tools/call", { name: "book_show_seats", arguments: { show: query } }),
    );
    assert.equal(response.result.structuredContent.show.id, "lighthouse", query);
  }
});

test("`when` pre-selects a performance on that date", async () => {
  const slots = slotsFor("lighthouse");
  const target = slots.find((s) => s.seatsLeft > 0);
  const day = target.startsAt.slice(0, 10);

  const response = await call(
    rpc("tools/call", { name: "book_show_seats", arguments: { when: day } }),
  );
  const chosen = response.result.structuredContent.preselectedSlotId;
  assert.ok(chosen.includes(day));
});

test("get_seat_map returns a full house", async () => {
  const slot = slotsFor("lighthouse")[0];
  const response = await call(
    rpc("tools/call", { name: "get_seat_map", arguments: { slot: slot.id } }),
  );
  const map = response.result.structuredContent;

  assert.equal(map.rows.length, 14);
  assert.equal(map.rows[0].seats.length, 18);
  assert.deepEqual(map.aislesAfter, [2, 15]);
  assert.deepEqual(
    map.tiers.map((t) => t.id),
    ["premium", "standard", "balcony"],
  );
});

test("confirm_booking prices the seats and adds the per-seat fee", async () => {
  const slot = slotsFor("lighthouse").find((s) => s.seatsLeft > 4);
  const map = seatMapFor(slot.id);
  const free = map.rows
    .flatMap((r) => r.seats)
    .filter((s) => s.status === "available")
    .slice(0, 2);

  const response = await call(
    rpc("tools/call", {
      name: "confirm_booking",
      arguments: { slot: slot.id, seats: free.map((s) => s.id) },
    }),
  );
  const booking = response.result.structuredContent;

  assert.equal(booking.seats.length, 2);
  assert.equal(booking.feesCents, 700);
  assert.equal(booking.totalCents, booking.subtotalCents + booking.feesCents);
  assert.match(booking.code, /^SHOW-[A-Z2-9]{6}$/);
});

test("confirming a taken seat is refused", async () => {
  const slot = slotsFor("coriolanus").find((s) => s.seatsLeft > 0);
  const map = seatMapFor(slot.id);
  const taken = map.rows.flatMap((r) => r.seats).find((s) => s.status === "taken");

  const response = await call(
    rpc("tools/call", {
      name: "confirm_booking",
      arguments: { slot: slot.id, seats: [taken.id], show: "coriolanus" },
    }),
  );
  assert.equal(response.result.isError, true);
  assert.match(response.result.content[0].text, /taken/i);
});

test("a booked seat is held against the next read of that house", async () => {
  const slot = slotsFor("neon-orchestra").find((s) => s.seatsLeft > 4);
  const map = seatMapFor(slot.id);
  const seat = map.rows.flatMap((r) => r.seats).find((s) => s.status === "available");

  await call(
    rpc("tools/call", {
      name: "confirm_booking",
      arguments: { slot: slot.id, seats: [seat.id], show: "neon-orchestra" },
    }),
  );

  const after = (
    await call(rpc("tools/call", { name: "get_seat_map", arguments: { slot: slot.id } }))
  ).result.structuredContent;
  const again = after.rows.flatMap((r) => r.seats).find((s) => s.id === seat.id);
  assert.equal(again.status, "held");
});

test("an unknown method is a JSON-RPC error, not a throw", async () => {
  const response = await call(rpc("does/not/exist", {}));
  assert.equal(response.error.code, -32601);
});

test("seat descriptions collapse runs the way a box office would say them", () => {
  assert.equal(describeSeats(["A5", "A6", "A7"]), "Row A 5–7");
  assert.equal(describeSeats(["A5", "A7"]), "Row A 5, 7");
  assert.equal(describeSeats(["C1", "A5", "A6"]), "Row A 5–6 · Row C 1");
});

test("confirmation codes are stable per order and differ across orders", () => {
  assert.equal(confirmationCode("slot", ["A1", "A2"]), confirmationCode("slot", ["A2", "A1"]));
  assert.notEqual(confirmationCode("slot", ["A1"]), confirmationCode("slot", ["A2"]));
});

test("Mondays are dark and the schedule is a sensible length", () => {
  const slots = slotsFor("lighthouse", { from: new Date(2026, 8, 1) });
  assert.ok(slots.length > 20);
  for (const slot of slots) {
    assert.notEqual(new Date(slot.startsAt).getDay(), 1, slot.id);
  }
});

test("static assets carry the headers the sandboxed frame needs", () => {
  // Cloudflare serves matched assets before the Worker runs, so the Worker's
  // header wrapping never applies to them — `public/_headers` is the only
  // thing that does. Nothing local catches this: the dev server sets these
  // headers itself, so a missing file here only shows up in production as a
  // blank frame.
  const here = dirname(fileURLToPath(import.meta.url));
  const headers = readFileSync(join(here, "../public/_headers"), "utf8");

  const rule = headers.split(/^(?=\/)/m).find((block) => block.startsWith("/app/*"));
  assert.ok(rule, "no /app/* rule in public/_headers");
  assert.match(rule, /Access-Control-Allow-Origin:\s*\*/i);
  assert.match(rule, /Cross-Origin-Resource-Policy:\s*cross-origin/i);
});

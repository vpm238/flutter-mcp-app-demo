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
    [
      "book_show_seats",
      "list_showtimes",
      "get_seat_map",
      "diagnose_view",
      "confirm_booking",
    ],
  );
  for (const tool of tools) {
    // Every tool points at the one resource the host registers. A tool
    // referencing a URI the host never learned about renders nothing, with no
    // error anywhere — so this is worth asserting.
    assert.equal(tool._meta.ui.resourceUri, VIEW_URI, tool.name);
  }
  // Older hosts only read the flat key; the entry tool must carry both.
  const entry = tools.find((t) => t.name === "book_show_seats");
  assert.equal(entry._meta["ui/resourceUri"], VIEW_URI);

  // The booking tool is the user's to press, not the model's.
  const confirm = tools.find((t) => t.name === "confirm_booking");
  assert.deepEqual(confirm._meta.ui.visibility, ["app"]);
});

test("the resource is served as an MCP app and knows where to reach us", async () => {
  const { contents } = (await call(rpc("resources/read", { uri: VIEW_URI }))).result;
  const [content] = contents;

  assert.equal(content.mimeType, "text/html;profile=mcp-app");
  assert.deepEqual(content._meta.ui.csp.frameDomains, [ORIGIN]);

  // The shell must be self-contained: our origin, and the relay inlined so the
  // resource needs no `script-src` origins in order to boot at all.
  assert.ok(content.text.includes(ORIGIN));
  assert.ok(!/<script[^>]+src=/.test(content.text), "no external scripts");
});

test("the shell carries both mounts and chooses at runtime", async () => {
  // Which mount works is a property of the host, not of us: a view CSP is not
  // guaranteed to carry `wasm-unsafe-eval`, and a host is not guaranteed to
  // honour `frameDomains`. Shipping only one mount means guessing which.
  const { contents } = (await call(rpc("resources/read", { uri: VIEW_URI }))).result;
  const html = contents[0].text;

  assert.match(html, /WebAssembly\.Module/, "it tests wasm before choosing");
  assert.match(html, /flutter_bootstrap\.js/, "the in-document mount is present");
  assert.match(html, /"iframe"/, "the nested-frame mount is present");
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
  // Without COEP the browser refuses the frame outright under a
  // `require-corp` embedder — CORP covers subresources, not documents.
  assert.match(rule, /Cross-Origin-Embedder-Policy:\s*require-corp/i);
});

test("the server registers exactly one ui:// resource", async () => {
  const { resources } = (await call(rpc("resources/list"))).result;
  // Hosts register the resources they learn about when the connector is added.
  // A second resource added later is invisible to them, so everything the view
  // needs to do has to live behind this one URI.
  assert.deepEqual(resources.map((r) => r.uri), [VIEW_URI]);
});

test("the view declares every directive either mount needs", async () => {
  const { contents } = (await call(rpc("resources/read", { uri: VIEW_URI }))).result;
  const csp = contents[0]._meta.ui.csp;
  // script-src for the loader, base-uri for the <base> it resolves against,
  // connect-src for canvaskit and the asset bundle, frame-src for the fallback.
  assert.deepEqual(csp.resourceDomains, [ORIGIN]);
  assert.deepEqual(csp.baseUriDomains, [ORIGIN]);
  assert.deepEqual(csp.connectDomains, [ORIGIN]);
  assert.deepEqual(csp.frameDomains, [ORIGIN]);
});

test("the diagnostics probe is bundled into the shell", async () => {
  const { contents } = (await call(rpc("resources/read", { uri: VIEW_URI }))).result;
  assert.match(contents[0].text, /securitypolicyviolation/);
  assert.match(contents[0].text, /view-environment/);
});

test("diagnose_view reports whether the host advertised MCP Apps", async () => {
  // A host that does not advertise `io.modelcontextprotocol/ui` will never
  // render a ui:// view, no matter how correct the server is. That fact is
  // invisible unless the server reports it back in text.
  await call(
    rpc("initialize", {
      protocolVersion: "2025-06-18",
      clientInfo: { name: "probe-client", version: "9.9" },
      capabilities: { extensions: {} },
    }),
  );
  let out = await call(rpc("tools/call", { name: "diagnose_view", arguments: {} }));
  // The structured result is what hosts actually display.
  assert.equal(out.result.structuredContent.mcpAppsAdvertised, false);
  assert.equal(out.result.structuredContent.client, "probe-client");
  assert.match(out.result.content[0].text, /MCP Apps: NOT ADVERTISED/);

  await call(
    rpc("initialize", {
      protocolVersion: "2025-06-18",
      clientInfo: { name: "ui-client", version: "1.0" },
      capabilities: {
        extensions: {
          "io.modelcontextprotocol/ui": { mimeTypes: ["text/html;profile=mcp-app"] },
        },
      },
    }),
  );
  out = await call(rpc("tools/call", { name: "diagnose_view", arguments: {} }));
  assert.equal(out.result.structuredContent.mcpAppsAdvertised, true);
  assert.deepEqual(out.result.structuredContent.uiMimeTypes, [
    "text/html;profile=mcp-app",
  ]);
  assert.match(out.result.content[0].text, /MCP Apps: ADVERTISED/);
});

test("the ui:// resource stays small enough to hand a host", async () => {
  // The shell inlines its script so the resource needs no script-src origins,
  // which makes its size a property of the protocol implementation. Built on
  // the SDK's App class this was 393 kB, ~99% of it zod — an unreasonable
  // thing to ask a host to render, and a plausible refusal all by itself.
  const { contents } = (await call(rpc("resources/read", { uri: VIEW_URI }))).result;
  const kb = contents[0].text.length / 1024;
  assert.ok(kb < 40, `the view resource is ${kb.toFixed(0)} kB; it should stay well under 40`);
});

test("a stale registration still gets today's view, not an error", async () => {
  // Hosts register a connector's resources once and cache what they read. We
  // have watched Claude render a build several deploys old, so the URI a host
  // asks for may predate the current one. Answering it with the current HTML
  // costs nothing and is the difference between a working view and a 404.
  const legacy = "ui://showtime/booking.html";
  const response = await call(rpc("resources/read", { uri: legacy }));
  const [content] = response.result.contents;

  assert.equal(content.uri, legacy, "echo back the URI that was asked for");
  assert.equal(content.mimeType, "text/html;profile=mcp-app");
  assert.match(content.text, /__SHOWTIME_BUILD/, "and serve the current shell");
});

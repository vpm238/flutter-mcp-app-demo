/**
 * The JavaScript half of the cross-language parity check.
 *
 * Asserts `src/domain.mjs` still produces the pinned fixture. Its counterpart,
 * `app/test/parity_test.dart`, asserts the Flutter mirror produces the same
 * thing — so a rule change that only lands on one side fails a build.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { fnv1a, mulberry32, seatMapFor, slotsFor } from "../src/domain.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = JSON.parse(readFileSync(join(here, "parity.fixture.json"), "utf8"));
const from = new Date(`${fixture.from}T00:00:00`);

test("fnv1a matches the fixture", () => {
  for (const [input, expected] of Object.entries(fixture.prng.fnv1a)) {
    assert.equal(fnv1a(input), expected, `fnv1a(${JSON.stringify(input)})`);
  }
});

test("mulberry32 matches the fixture", () => {
  const rand = mulberry32(fnv1a("showtime"));
  for (const expected of fixture.prng.mulberry32) {
    assert.equal(Number(rand().toFixed(12)), expected);
  }
});

test("the schedule matches the fixture", () => {
  for (const [showId, expected] of Object.entries(fixture.shows)) {
    const slots = slotsFor(showId, { from });
    assert.equal(slots.length, expected.slotCount, showId);
    expected.slots.forEach((want, i) => {
      assert.equal(slots[i].id, want.id);
      assert.equal(slots[i].startsAt, want.startsAt);
      assert.equal(slots[i].seatsLeft, want.seatsLeft);
      assert.equal(slots[i].tag ?? null, want.tag ?? null);
    });
  }
});

test("the houses match the fixture", () => {
  for (const expected of Object.values(fixture.shows)) {
    for (const house of expected.houses) {
      const rows = seatMapFor(house.slotId).rows.map((row) =>
        row.seats.map((seat) => (seat.status === "available" ? "." : "x")).join(""),
      );
      assert.deepEqual(rows, house.rows, house.slotId);
    }
  }
});

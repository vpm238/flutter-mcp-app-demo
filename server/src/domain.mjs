/**
 * The fixture box office.
 *
 * This is the authority: the Flutter view's `lib/src/data/catalog.dart` is a
 * deterministic mirror of this file — same shows, same slot rules, same PRNG —
 * so the standalone build renders the identical house. If you change a rule
 * here, change it there (the parity check in `test/parity.test.mjs` will tell
 * you if you forget).
 */

const ROW_COUNT = 14;
export const SEATS_PER_ROW = 18;
export const AISLES_AFTER = [2, 15];
export const PER_SEAT_FEE_CENTS = 350;

const SHOWS = [
  {
    id: "lighthouse",
    title: "The Lighthouse Keeper",
    tagline: "A new musical about the last light on the coast",
    venue: "Aurelia Theatre",
    city: "New York, NY",
    runtimeMinutes: 145,
    rating: "Ages 10+",
    accent: "#f0a04b",
    accentDeep: "#1b2a4a",
  },
  {
    id: "neon-orchestra",
    title: "Neon Orchestra: Live",
    tagline: "Forty players, one synth, zero rehearsals",
    venue: "The Foundry",
    city: "Brooklyn, NY",
    runtimeMinutes: 105,
    rating: "All ages",
    accent: "#4bd0f0",
    accentDeep: "#132033",
  },
  {
    id: "coriolanus",
    title: "Coriolanus",
    tagline: "In repertory. Performed without an interval",
    venue: "Kestrel Playhouse",
    city: "New York, NY",
    runtimeMinutes: 170,
    rating: "Ages 14+",
    accent: "#e2544f",
    accentDeep: "#2a1416",
  },
];

const TIERS = [
  { id: "premium", name: "Premium orchestra", priceCents: 18900, color: "#f0a04b" },
  { id: "standard", name: "Orchestra", priceCents: 12900, color: "#6c8cf0" },
  { id: "balcony", name: "Balcony", priceCents: 7400, color: "#57c98a" },
];

/** Curtain-up times in minutes past midnight, by ISO weekday (1 = Monday, dark). */
const CURTAIN_MINUTES = {
  1: [],
  2: [1170],
  3: [840, 1170],
  4: [1170],
  5: [1200],
  6: [840, 1200],
  7: [900, 1140],
};

export function allShows() {
  return SHOWS;
}

export function tiers() {
  return TIERS;
}

/**
 * Resolve a show by id, or by a loose title match so the model can pass through
 * whatever the user typed ("the lighthouse one").
 */
export function findShow(query) {
  if (!query) return SHOWS[0];
  const needle = String(query).trim().toLowerCase();
  return (
    SHOWS.find((s) => s.id === needle) ??
    SHOWS.find((s) => s.title.toLowerCase() === needle) ??
    SHOWS.find((s) => s.title.toLowerCase().includes(needle)) ??
    SHOWS.find((s) => needle.includes(s.id)) ??
    SHOWS[0]
  );
}

function tierForRow(rowIndex) {
  if (rowIndex < 4) return "premium";
  if (rowIndex < 10) return "standard";
  return "balcony";
}

const pad = (n, width) => String(n).padStart(width, "0");
const ymd = (d) =>
  `${pad(d.getFullYear(), 4)}-${pad(d.getMonth() + 1, 2)}-${pad(d.getDate(), 2)}`;

/** ISO weekday, 1 = Monday, to match Dart's `DateTime.weekday`. */
const isoWeekday = (d) => ((d.getDay() + 6) % 7) + 1;

/** Every performance in the next `days` days. */
export function slotsFor(showId, { days = 21, from = new Date() } = {}) {
  const today = new Date(from.getFullYear(), from.getMonth(), from.getDate());
  const out = [];

  for (let d = 0; d < days; d++) {
    const day = new Date(today.getFullYear(), today.getMonth(), today.getDate() + d);
    for (const minutes of CURTAIN_MINUTES[isoWeekday(day)] ?? []) {
      const startsAt = new Date(
        day.getFullYear(),
        day.getMonth(),
        day.getDate(),
        Math.floor(minutes / 60),
        minutes % 60,
      );
      const id = `${showId}:${ymd(startsAt)}:${pad(minutes, 4)}`;
      const rand = mulberry32(fnv1a(id));
      const capacity = ROW_COUNT * SEATS_PER_ROW;

      // Demand curve: soon + weekend = fuller. Everything else drifts.
      const soon = 1 - d / days;
      const weekend = isoWeekday(day) >= 5 ? 0.18 : 0;
      const base = 0.28 + soon * 0.42 + weekend + rand() * 0.22;
      const takenRatio = clamp(base, 0.05, 1.02);
      const seatsLeft = clamp(Math.round(capacity * (1 - takenRatio)), 0, capacity);

      out.push({
        id,
        startsAt: localIso(startsAt),
        seatsLeft,
        capacity,
        fromCents: 7400,
        tag: tagFor(seatsLeft, capacity, minutes),
      });
    }
  }
  return out;
}

function tagFor(seatsLeft, capacity, minutes) {
  if (seatsLeft === 0) return "Sold out";
  if (seatsLeft / capacity < 0.08) return "Almost sold out";
  if (minutes < 1000) return "Matinee";
  return null;
}

/** The house for one performance. Deterministic in `slotId`. */
export function seatMapFor(slotId, { alsoTaken = new Set() } = {}) {
  const rand = mulberry32(fnv1a(`seatmap:${slotId}`));
  const slotRand = mulberry32(fnv1a(slotId));
  const fillTarget = 0.28 + slotRand() * 0.5;

  const rows = [];
  for (let r = 0; r < ROW_COUNT; r++) {
    const label = String.fromCharCode(65 + r);
    const tier = tierForRow(r);
    // Front and centre goes first; the corners of the balcony go last.
    const rowPull = 1.25 - (r / ROW_COUNT) * 0.55;
    const seats = [];
    for (let c = 0; c < SEATS_PER_ROW; c++) {
      const centreness =
        1 - Math.abs(c - (SEATS_PER_ROW - 1) / 2) / ((SEATS_PER_ROW - 1) / 2);
      const pressure = fillTarget * rowPull * (0.55 + centreness * 0.75);
      const taken = rand() < pressure;
      const id = `${label}${c + 1}`;
      seats.push({
        id,
        row: label,
        number: c + 1,
        col: c,
        tier,
        status: alsoTaken.has(id) ? "held" : taken ? "taken" : "available",
      });
    }
    rows.push({ label, seats });
  }

  return {
    slotId,
    rows,
    tiers: TIERS,
    aislesAfter: AISLES_AFTER,
    seatsPerRow: SEATS_PER_ROW,
  };
}

export function seatById(map, id) {
  for (const row of map.rows) {
    for (const seat of row.seats) if (seat.id === id) return seat;
  }
  return null;
}

export function priceOf(map, seat) {
  const tier = map.tiers.find((t) => t.id === seat.tier) ?? map.tiers[0];
  return tier.priceCents;
}

/** A stable, human-readable confirmation code for a given order. */
export function confirmationCode(slotId, seatIds) {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let h = fnv1a(`${slotId}|${[...seatIds].sort().join(",")}`);
  let out = "SHOW-";
  for (let i = 0; i < 6; i++) {
    out += alphabet[h % alphabet.length];
    h = Math.floor(h / alphabet.length) + 7919;
  }
  return out;
}

/** `A5, A6, A7, C1` → `Row A 5–7, Row C 1`. */
export function describeSeats(seatIds) {
  const byRow = new Map();
  for (const id of [...seatIds].sort()) {
    const row = id.replace(/[0-9]/g, "");
    const number = Number(id.replace(/[^0-9]/g, ""));
    if (!byRow.has(row)) byRow.set(row, []);
    byRow.get(row).push(number);
  }
  const parts = [];
  for (const [row, numbers] of byRow) {
    numbers.sort((a, b) => a - b);
    const runs = [];
    let start = numbers[0];
    let prev = numbers[0];
    for (const n of numbers.slice(1)) {
      if (n === prev + 1) {
        prev = n;
        continue;
      }
      runs.push(start === prev ? `${start}` : `${start}–${prev}`);
      start = prev = n;
    }
    runs.push(start === prev ? `${start}` : `${start}–${prev}`);
    parts.push(`Row ${row} ${runs.join(", ")}`);
  }
  return parts.join(" · ");
}

export function formatMoney(cents, currency = "USD") {
  const symbol = { USD: "$", EUR: "€", GBP: "£" }[currency] ?? "";
  const whole = Math.floor(cents / 100);
  const frac = cents % 100;
  return `${symbol}${whole}${frac === 0 ? "" : "." + pad(frac, 2)}`;
}

export function formatWhen(iso) {
  const d = new Date(iso);
  const days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const hour12 = d.getHours() % 12 === 0 ? 12 : d.getHours() % 12;
  const meridiem = d.getHours() < 12 ? "AM" : "PM";
  return `${days[isoWeekday(d) - 1]} ${months[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()} at ${hour12}:${pad(d.getMinutes(), 2)} ${meridiem}`;
}

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

/**
 * A local-time ISO string with no zone suffix, so `DateTime.parse` in Dart
 * reads it as local rather than shifting it into UTC.
 */
function localIso(d) {
  return (
    `${pad(d.getFullYear(), 4)}-${pad(d.getMonth() + 1, 2)}-${pad(d.getDate(), 2)}` +
    `T${pad(d.getHours(), 2)}:${pad(d.getMinutes(), 2)}:00`
  );
}

// ---------------------------------------------------------------------------
// 32-bit PRNG. `catalog.dart` reimplements this with an explicit imul so both
// languages produce identical streams.
// ---------------------------------------------------------------------------

export function fnv1a(s) {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

export function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

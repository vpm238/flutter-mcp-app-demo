/// The fixture box office.
///
/// This is a deterministic mirror of `server/src/domain.mjs`: same shows, same
/// slot rules, same PRNG. That means the view renders an identical house
/// whether the data came over MCP or was generated locally in standalone mode,
/// so screenshots and demos stay reproducible.
///
/// The PRNG is `mulberry32` seeded with FNV-1a, implemented with an explicit
/// 32-bit multiply so Dart-on-web (where `int` is a double) produces bit-identical
/// results to JavaScript's `Math.imul`.
library;

import '../model.dart';

const int _rowCount = 14;
const int seatsPerRow = 18;
const List<int> aislesAfter = [2, 15];

const List<Map<String, Object>> _showSeeds = [
  {
    'id': 'lighthouse',
    'title': 'The Lighthouse Keeper',
    'tagline': 'A new musical about the last light on the coast',
    'venue': 'Aurelia Theatre',
    'city': 'New York, NY',
    'runtimeMinutes': 145,
    'rating': 'Ages 10+',
    'accent': '#f0a04b',
    'accentDeep': '#1b2a4a',
  },
  {
    'id': 'neon-orchestra',
    'title': 'Neon Orchestra: Live',
    'tagline': 'Forty players, one synth, zero rehearsals',
    'venue': 'The Foundry',
    'city': 'Brooklyn, NY',
    'runtimeMinutes': 105,
    'rating': 'All ages',
    'accent': '#4bd0f0',
    'accentDeep': '#132033',
  },
  {
    'id': 'coriolanus',
    'title': 'Coriolanus',
    'tagline': 'In repertory. Performed without an interval',
    'venue': 'Kestrel Playhouse',
    'city': 'New York, NY',
    'runtimeMinutes': 170,
    'rating': 'Ages 14+',
    'accent': '#e2544f',
    'accentDeep': '#2a1416',
  },
];

const List<Map<String, Object>> _tierSeeds = [
  {'id': 'premium', 'name': 'Premium orchestra', 'priceCents': 18900, 'color': '#f0a04b'},
  {'id': 'standard', 'name': 'Orchestra', 'priceCents': 12900, 'color': '#6c8cf0'},
  {'id': 'balcony', 'name': 'Balcony', 'priceCents': 7400, 'color': '#57c98a'},
];

List<Show> allShows() =>
    _showSeeds.map((s) => Show.fromJson(Map<String, dynamic>.from(s))).toList();

Show showById(String? id) {
  final shows = allShows();
  return shows.firstWhere((s) => s.id == id, orElse: () => shows.first);
}

List<Tier> tiers() =>
    _tierSeeds.map((t) => Tier.fromJson(Map<String, dynamic>.from(t))).toList();

String tierForRow(int rowIndex) {
  if (rowIndex < 4) return 'premium';
  if (rowIndex < 10) return 'standard';
  return 'balcony';
}

/// Curtain-up times, by weekday. `1` = Monday (dark), matching `DateTime.weekday`.
const Map<int, List<int>> _curtainMinutes = {
  1: [],
  2: [1170],
  3: [840, 1170],
  4: [1170],
  5: [1200],
  6: [840, 1200],
  7: [900, 1140],
};

/// Every performance in the next [days] days for [showId].
List<Slot> slotsFor(String showId, {int days = 21, DateTime? from}) {
  final today = _midnight(from ?? DateTime.now());
  final out = <Slot>[];
  for (var d = 0; d < days; d++) {
    final day = today.add(Duration(days: d));
    for (final minutes in _curtainMinutes[day.weekday] ?? const <int>[]) {
      final startsAt =
          DateTime(day.year, day.month, day.day, minutes ~/ 60, minutes % 60);
      final id = '$showId:${_ymd(startsAt)}:${minutes.toString().padLeft(4, '0')}';
      final rand = _mulberry32(_fnv1a(id));
      final capacity = _rowCount * seatsPerRow;

      // Demand curve: soon + weekend = fuller. Everything else drifts.
      final soon = 1 - (d / days);
      final weekend = (day.weekday >= 5) ? 0.18 : 0.0;
      final base = 0.28 + soon * 0.42 + weekend + rand() * 0.22;
      final takenRatio = base.clamp(0.05, 1.02);
      final seatsLeft = (capacity * (1 - takenRatio)).round().clamp(0, capacity);

      out.add(Slot(
        id: id,
        startsAt: startsAt,
        seatsLeft: seatsLeft,
        capacity: capacity,
        fromCents: 7400,
        tag: _tagFor(seatsLeft, capacity, minutes),
      ));
    }
  }
  return out;
}

String? _tagFor(int seatsLeft, int capacity, int minutes) {
  if (seatsLeft == 0) return 'Sold out';
  if (seatsLeft / capacity < 0.08) return 'Almost sold out';
  if (minutes < 1000) return 'Matinee';
  return null;
}

/// The house for one performance. Deterministic in [slotId].
SeatMap seatMapFor(String slotId, {Set<String> alsoTaken = const {}}) {
  final rand = _mulberry32(_fnv1a('seatmap:$slotId'));
  final slotRand = _mulberry32(_fnv1a(slotId));
  final fillTarget = 0.28 + slotRand() * 0.5;

  final rows = <SeatRow>[];
  for (var r = 0; r < _rowCount; r++) {
    final label = String.fromCharCode(65 + r);
    final tier = tierForRow(r);
    // Front and centre goes first; the corners of the balcony go last.
    final rowPull = 1.25 - (r / _rowCount) * 0.55;
    final seats = <Seat>[];
    for (var c = 0; c < seatsPerRow; c++) {
      final centreness =
          1 - ((c - (seatsPerRow - 1) / 2).abs() / ((seatsPerRow - 1) / 2));
      final pressure = fillTarget * rowPull * (0.55 + centreness * 0.75);
      final taken = rand() < pressure;
      final id = '$label${c + 1}';
      seats.add(Seat(
        id: id,
        row: label,
        number: c + 1,
        col: c,
        tierId: tier,
        status: alsoTaken.contains(id)
            ? SeatStatus.held
            : (taken ? SeatStatus.taken : SeatStatus.available),
      ));
    }
    rows.add(SeatRow(label: label, seats: seats));
  }

  return SeatMap(
    slotId: slotId,
    rows: rows,
    tiers: tiers(),
    aislesAfter: aislesAfter,
    seatsPerRow: seatsPerRow,
  );
}

/// Pick the best run of [count] adjacent seats — the "best available" button.
///
/// Scores centre-ness and row position, and refuses to leave a single orphan
/// seat stranded against an aisle, the way a real box office would.
List<Seat> bestAvailable(SeatMap map, int count) {
  if (count <= 0) return const [];
  List<Seat> best = const [];
  var bestScore = -1e9;

  for (var r = 0; r < map.rows.length; r++) {
    final row = map.rows[r];
    for (var start = 0; start + count <= row.seats.length; start++) {
      final run = row.seats.sublist(start, start + count);
      if (run.any((s) => !s.bookable)) continue;
      if (run.any((s) => map.aislesAfter.contains(s.col) && s != run.last)) {
        continue; // don't split a party across an aisle
      }

      final centre = run.map((s) => s.col).reduce((a, b) => a + b) / count;
      final offCentre = (centre - (map.seatsPerRow - 1) / 2).abs();
      // Row 5 (index 4) is the sweet spot in most houses.
      final rowScore = -((r - 4).abs() * 1.6);
      final tier = map.tierFor(run.first);
      final score = rowScore - offCentre * 1.1 + tier.priceCents / 100000;

      if (score > bestScore) {
        bestScore = score;
        best = run;
      }
    }
  }
  return best;
}

DateTime _midnight(DateTime d) => DateTime(d.year, d.month, d.day);

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// ---------------------------------------------------------------------------
// 32-bit PRNG, bit-identical to the JavaScript in server/src/domain.mjs.
// ---------------------------------------------------------------------------

/// `Math.imul`, spelled out so it survives Dart's double-backed web ints.
int _imul(int a, int b) {
  final aHi = (a >>> 16) & 0xFFFF;
  final aLo = a & 0xFFFF;
  final bHi = (b >>> 16) & 0xFFFF;
  final bLo = b & 0xFFFF;
  return (aLo * bLo + ((((aHi * bLo + aLo * bHi) & 0xFFFF) << 16))) & 0xFFFFFFFF;
}

int _fnv1a(String s) {
  var h = 0x811c9dc5;
  for (var i = 0; i < s.length; i++) {
    h ^= s.codeUnitAt(i);
    h = _imul(h, 0x01000193);
  }
  return h & 0xFFFFFFFF;
}

double Function() _mulberry32(int seed) {
  var a = seed & 0xFFFFFFFF;
  return () {
    a = (a + 0x6D2B79F5) & 0xFFFFFFFF;
    var t = _imul(a ^ (a >>> 15), 1 | a);
    t = ((t + _imul(t ^ (t >>> 7), 61 | t)) & 0xFFFFFFFF) ^ t;
    return ((t ^ (t >>> 14)) & 0xFFFFFFFF) / 4294967296.0;
  };
}

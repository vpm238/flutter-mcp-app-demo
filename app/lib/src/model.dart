/// Domain model for the Showtime booking view.
///
/// Everything here is plain data with JSON codecs, because the same shapes
/// travel over the MCP wire: the server produces them in `tools/call` results
/// and this view consumes them. Keeping the codecs in one file makes the
/// contract easy to diff against `server/src/domain.mjs`.
library;

import 'package:flutter/widgets.dart' show Color;

/// A production that can be booked.
class Show {
  const Show({
    required this.id,
    required this.title,
    required this.tagline,
    required this.venue,
    required this.city,
    required this.runtimeMinutes,
    required this.rating,
    required this.accent,
    required this.accentDeep,
  });

  final String id;
  final String title;
  final String tagline;
  final String venue;
  final String city;
  final int runtimeMinutes;
  final String rating;

  /// Brand colours for the hero. Sent as `#rrggbb` on the wire.
  final Color accent;
  final Color accentDeep;

  String get runtimeLabel {
    final h = runtimeMinutes ~/ 60;
    final m = runtimeMinutes % 60;
    if (h == 0) return '${m}m';
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  static Show fromJson(Map<String, dynamic> j) => Show(
        id: j['id'] as String,
        title: j['title'] as String,
        tagline: j['tagline'] as String? ?? '',
        venue: j['venue'] as String? ?? '',
        city: j['city'] as String? ?? '',
        runtimeMinutes: (j['runtimeMinutes'] as num?)?.toInt() ?? 120,
        rating: j['rating'] as String? ?? '',
        accent: _color(j['accent'] as String?, 0xFF6C5CE7),
        accentDeep: _color(j['accentDeep'] as String?, 0xFF2D1B69),
      );
}

/// One performance: a date, a time, and how full it is.
class Slot {
  const Slot({
    required this.id,
    required this.startsAt,
    required this.seatsLeft,
    required this.capacity,
    required this.fromCents,
    this.tag,
  });

  final String id;
  final DateTime startsAt;
  final int seatsLeft;
  final int capacity;
  final int fromCents;

  /// Optional merchandising label, e.g. `Almost sold out`.
  final String? tag;

  bool get soldOut => seatsLeft <= 0;

  /// 0.0 = empty house, 1.0 = sold out. Drives the demand dots.
  double get fill => capacity == 0 ? 0 : 1 - (seatsLeft / capacity);

  Demand get demand {
    if (soldOut) return Demand.soldOut;
    if (fill > 0.85) return Demand.high;
    if (fill > 0.6) return Demand.medium;
    return Demand.low;
  }

  static Slot fromJson(Map<String, dynamic> j) => Slot(
        id: j['id'] as String,
        startsAt: DateTime.parse(j['startsAt'] as String),
        seatsLeft: (j['seatsLeft'] as num).toInt(),
        capacity: (j['capacity'] as num?)?.toInt() ?? 252,
        fromCents: (j['fromCents'] as num?)?.toInt() ?? 0,
        tag: j['tag'] as String?,
      );
}

enum Demand { low, medium, high, soldOut }

/// A price band. Rows are grouped into tiers; tiers carry the price.
class Tier {
  const Tier({
    required this.id,
    required this.name,
    required this.priceCents,
    required this.color,
  });

  final String id;
  final String name;
  final int priceCents;
  final Color color;

  static Tier fromJson(Map<String, dynamic> j) => Tier(
        id: j['id'] as String,
        name: j['name'] as String,
        priceCents: (j['priceCents'] as num).toInt(),
        color: _color(j['color'] as String?, 0xFF6C5CE7),
      );
}

enum SeatStatus { available, taken, held }

class Seat {
  const Seat({
    required this.id,
    required this.row,
    required this.number,
    required this.col,
    required this.tierId,
    required this.status,
  });

  final String id;

  /// Row label, `A`..`N`.
  final String row;

  /// Human seat number within the row, 1-based.
  final int number;

  /// Column index used for layout, so aisles can widen the gaps.
  final int col;
  final String tierId;
  final SeatStatus status;

  bool get bookable => status == SeatStatus.available;

  static Seat fromJson(Map<String, dynamic> j) => Seat(
        id: j['id'] as String,
        row: j['row'] as String,
        number: (j['number'] as num).toInt(),
        col: (j['col'] as num).toInt(),
        tierId: j['tier'] as String,
        status: switch (j['status'] as String?) {
          'taken' => SeatStatus.taken,
          'held' => SeatStatus.held,
          _ => SeatStatus.available,
        },
      );
}

/// The seat map for one slot: rows of seats plus the price bands.
class SeatMap {
  const SeatMap({
    required this.slotId,
    required this.rows,
    required this.tiers,
    required this.aislesAfter,
    required this.seatsPerRow,
  });

  final String slotId;
  final List<SeatRow> rows;
  final List<Tier> tiers;

  /// Column indices that are followed by an aisle.
  final List<int> aislesAfter;
  final int seatsPerRow;

  Tier tierFor(Seat seat) =>
      tiers.firstWhere((t) => t.id == seat.tierId, orElse: () => tiers.first);

  Iterable<Seat> get allSeats => rows.expand((r) => r.seats);

  Seat? seatById(String id) {
    for (final row in rows) {
      for (final seat in row.seats) {
        if (seat.id == id) return seat;
      }
    }
    return null;
  }

  static SeatMap fromJson(Map<String, dynamic> j) => SeatMap(
        slotId: j['slotId'] as String,
        seatsPerRow: (j['seatsPerRow'] as num?)?.toInt() ?? 18,
        aislesAfter: ((j['aislesAfter'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList(),
        tiers: ((j['tiers'] as List?) ?? const [])
            .map((e) => Tier.fromJson(e as Map<String, dynamic>))
            .toList(),
        rows: ((j['rows'] as List?) ?? const [])
            .map((e) => SeatRow.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class SeatRow {
  const SeatRow({required this.label, required this.seats});

  final String label;
  final List<Seat> seats;

  static SeatRow fromJson(Map<String, dynamic> j) => SeatRow(
        label: j['label'] as String,
        seats: ((j['seats'] as List?) ?? const [])
            .map((e) => Seat.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// A confirmed booking, returned by the `confirm_booking` tool.
class Booking {
  const Booking({
    required this.code,
    required this.seatLabels,
    required this.totalCents,
    required this.startsAt,
    required this.showTitle,
    required this.venue,
  });

  final String code;
  final List<String> seatLabels;
  final int totalCents;
  final DateTime startsAt;
  final String showTitle;
  final String venue;

  static Booking fromJson(Map<String, dynamic> j) => Booking(
        code: j['code'] as String,
        seatLabels:
            ((j['seats'] as List?) ?? const []).map((e) => '$e').toList(),
        totalCents: (j['totalCents'] as num?)?.toInt() ?? 0,
        startsAt: DateTime.parse(j['startsAt'] as String),
        showTitle: j['showTitle'] as String? ?? '',
        venue: j['venue'] as String? ?? '',
      );
}

/// The payload the `book_show_seats` tool returns: everything needed to paint
/// the first frame without a follow-up round trip.
class BookingSession {
  const BookingSession({
    required this.show,
    required this.slots,
    required this.partySize,
    required this.currency,
    this.preselectedSlotId,
  });

  final Show show;
  final List<Slot> slots;
  final int partySize;
  final String currency;
  final String? preselectedSlotId;

  static BookingSession fromJson(Map<String, dynamic> j) => BookingSession(
        show: Show.fromJson(j['show'] as Map<String, dynamic>),
        slots: ((j['slots'] as List?) ?? const [])
            .map((e) => Slot.fromJson(e as Map<String, dynamic>))
            .toList(),
        partySize: (j['partySize'] as num?)?.toInt() ?? 2,
        currency: j['currency'] as String? ?? 'USD',
        preselectedSlotId: j['preselectedSlotId'] as String?,
      );
}

Color _color(String? hex, int fallback) {
  if (hex == null) return Color(fallback);
  final cleaned = hex.replaceFirst('#', '');
  final value = int.tryParse(cleaned, radix: 16);
  if (value == null) return Color(fallback);
  return Color(cleaned.length <= 6 ? 0xFF000000 | value : value);
}

String formatMoney(int cents, {String currency = 'USD'}) {
  final symbol = switch (currency) {
    'USD' => r'$',
    'EUR' => '€',
    'GBP' => '£',
    _ => '',
  };
  final whole = cents ~/ 100;
  final frac = cents % 100;
  final body = frac == 0
      ? '$whole'
      : '$whole.${frac.toString().padLeft(2, '0')}';
  return '$symbol$body';
}

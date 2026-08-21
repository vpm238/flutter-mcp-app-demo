/// The Dart half of the cross-language parity check.
///
/// `lib/src/data/catalog.dart` is a mirror of `server/src/domain.mjs` — same
/// shows, same schedule rules, same PRNG — so the standalone build renders the
/// identical house to the one the server would have sent. That claim is only
/// worth making if something enforces it, so both sides assert against one
/// fixture generated from the server:
///
///     node server/tools/gen-parity-fixture.mjs
///
/// The interesting part is the PRNG. Dart-on-web backs `int` with a double, so
/// a plain 32-bit multiply loses precision where JavaScript's `Math.imul` does
/// not. `catalog.dart` spells the multiply out; these tests are what prove it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:showtime/src/data/catalog.dart';
import 'package:showtime/src/model.dart';

void main() {
  final file = File('../server/test/parity.fixture.json');
  if (!file.existsSync()) {
    // The app package is usable on its own; skip rather than fail if someone
    // vendored `app/` without the server.
    test('parity fixture is present', () {
      markTestSkipped('no ../server/test/parity.fixture.json');
    }, skip: true);
    return;
  }

  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final from = DateTime.parse('${fixture['from']}T00:00:00');
  final shows = (fixture['shows'] as Map).cast<String, dynamic>();

  test('the schedule matches the server', () {
    for (final entry in shows.entries) {
      final expected = entry.value as Map<String, dynamic>;
      final slots = slotsFor(entry.key, from: from);

      expect(slots.length, expected['slotCount'], reason: entry.key);

      final wanted = (expected['slots'] as List).cast<Map<String, dynamic>>();
      for (var i = 0; i < wanted.length; i++) {
        expect(slots[i].id, wanted[i]['id']);
        expect(slots[i].startsAt, DateTime.parse(wanted[i]['startsAt'] as String));
        expect(slots[i].seatsLeft, wanted[i]['seatsLeft'], reason: slots[i].id);
        expect(slots[i].tag, wanted[i]['tag']);
      }
    }
  });

  test('the generated houses match the server, seat for seat', () {
    for (final show in shows.values) {
      final houses = ((show as Map)['houses'] as List).cast<Map<String, dynamic>>();
      for (final house in houses) {
        final slotId = house['slotId'] as String;
        final rows = seatMapFor(slotId)
            .rows
            .map((row) => row.seats
                .map((seat) => seat.status == SeatStatus.available ? '.' : 'x')
                .join())
            .toList();
        expect(rows, house['rows'], reason: slotId);
      }
    }
  });
}

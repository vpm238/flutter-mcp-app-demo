import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:showtime/src/app.dart';
import 'package:showtime/src/booking_controller.dart';
import 'package:showtime/src/data/catalog.dart';
import 'package:showtime/src/data/data_source.dart';
import 'package:showtime/src/mcp/bridge.dart';
import 'package:showtime/src/theme.dart';
import 'package:showtime/src/ui/desktop_shell.dart';
import 'package:showtime/src/ui/seat_map.dart';

Future<McpHost> _unhosted() => McpHost.connect();

Future<void> _pumpApp(WidgetTester tester, Persona persona) async {
  final host = await _unhosted();
  await tester.pumpWidget(ShowtimeApp(
    host: host,
    box: LocalBoxOffice(),
    initialPersona: persona,
  ));
  await tester.pumpAndSettle();
}

void main() {
  _personaResolution();
  _layoutFit();

  group('catalog', () {
    test('the generated house is stable for a given slot id', () {
      final a = seatMapFor('lighthouse:2026-09-12:1200');
      final b = seatMapFor('lighthouse:2026-09-12:1200');
      expect(a.rows.length, 14);
      expect(a.rows.first.seats.length, seatsPerRow);
      for (var r = 0; r < a.rows.length; r++) {
        for (var c = 0; c < seatsPerRow; c++) {
          expect(a.rows[r].seats[c].status, b.rows[r].seats[c].status);
        }
      }
    });

    test('different slots get different houses', () {
      final a = seatMapFor('lighthouse:2026-09-12:1200');
      final b = seatMapFor('lighthouse:2026-09-13:1200');
      final same = [
        for (var r = 0; r < a.rows.length; r++)
          for (var c = 0; c < seatsPerRow; c++)
            a.rows[r].seats[c].status == b.rows[r].seats[c].status,
      ].where((x) => x).length;
      expect(same, lessThan(a.rows.length * seatsPerRow));
    });

    test('mondays are dark', () {
      final slots = slotsFor('lighthouse', from: DateTime(2026, 9, 1));
      expect(slots.any((s) => s.startsAt.weekday == DateTime.monday), isFalse);
      expect(slots, isNotEmpty);
    });

    test('best available returns adjacent bookable seats in one row', () {
      final map = seatMapFor('lighthouse:2026-09-12:1200');
      final picks = bestAvailable(map, 3);
      expect(picks.length, 3);
      expect(picks.every((s) => s.bookable), isTrue);
      expect(picks.map((s) => s.row).toSet().length, 1);
      expect(picks[1].number, picks[0].number + 1);
      expect(picks[2].number, picks[1].number + 1);
    });

    test('best available never straddles an aisle', () {
      final map = seatMapFor('neon-orchestra:2026-10-03:1200');
      final picks = bestAvailable(map, 4);
      if (picks.isEmpty) return;
      for (final seat in picks.take(picks.length - 1)) {
        expect(map.aislesAfter.contains(seat.col), isFalse);
      }
    });
  });

  group('booking controller', () {
    test('selecting seats past the party size evicts the oldest', () async {
      final controller = BookingController(box: LocalBoxOffice());
      await controller.load();
      controller.setPartySize(2);
      await controller.selectSlot(controller.slotsForSelectedDay.first);

      final free = controller.seatMap!.allSeats.where((s) => s.bookable).toList();
      controller.toggleSeat(free[0]);
      controller.toggleSeat(free[1]);
      controller.toggleSeat(free[2]);

      expect(controller.selectedSeats.length, 2);
      expect(controller.selectedSeats.any((s) => s.id == free[0].id), isFalse);
    });

    test('totals add the per-seat fee', () async {
      final controller = BookingController(box: LocalBoxOffice());
      await controller.load();
      await controller.selectSlot(controller.slotsForSelectedDay.first);
      controller.pickBestAvailable();

      expect(controller.selectedSeats.length, controller.partySize);
      expect(controller.feesCents, perSeatFeeCents * controller.partySize);
      expect(controller.totalCents, controller.subtotalCents + controller.feesCents);
    });

    test('seat summary condenses runs', () async {
      final controller = BookingController(box: LocalBoxOffice());
      await controller.load();
      controller.setPartySize(3);
      await controller.selectSlot(controller.slotsForSelectedDay.first);
      controller.pickBestAvailable();

      expect(controller.seatSummary, matches(RegExp(r'^Row [A-N] \d+–\d+$')));
    });

    test('confirming produces a booking and leaves the confirmed phase', () async {
      final controller = BookingController(box: LocalBoxOffice());
      await controller.load();
      await controller.selectSlot(controller.slotsForSelectedDay.first);
      controller.pickBestAvailable();
      await controller.confirmBooking();

      expect(controller.phase, Phase.confirmed);
      expect(controller.booking!.code, startsWith('LOC-'));
      expect(controller.booking!.seatLabels.length, controller.partySize);
    });
  });

  group('css colour parsing', () {
    test('hex', () {
      expect(parseCssColor('#ff0000'), const Color(0xFFFF0000));
      expect(parseCssColor('#0f0'), const Color(0xFF00FF00));
    });

    test('rgb and hsl', () {
      expect(parseCssColor('rgb(255, 0, 0)'), const Color(0xFFFF0000));
      expect(parseCssColor('hsl(0 100% 50%)'), const Color(0xFFFF0000));
    });

    test('oklch lands close to the sRGB equivalent', () {
      final white = parseCssColor('oklch(1 0 0)')!;
      expect(white.r, closeTo(1.0, 0.01));
      expect(white.g, closeTo(1.0, 0.01));
      expect(white.b, closeTo(1.0, 0.01));
    });

    test('garbage falls back to null so callers can use their own default', () {
      expect(parseCssColor('not-a-colour'), isNull);
      expect(parseCssColor(null), isNull);
    });
  });

  group('personas', () {
    testWidgets('iOS renders Cupertino chrome and a wheel picker', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pumpApp(tester, Persona.ios);

      expect(find.byType(CupertinoSliverNavigationBar), findsOneWidget);
      expect(find.byType(CupertinoListSection), findsWidgets);
      expect(find.byType(CupertinoSlidingSegmentedControl<int>), findsOneWidget);

      // A Cupertino tree has no Material ancestor, so without an explicit
      // default every Text inherits Flutter's missing-style indicator — the
      // yellow double underline. Guard against that coming back.
      final style = DefaultTextStyle.of(tester.element(find.text('Date'))).style;
      expect(style.decoration ?? TextDecoration.none, TextDecoration.none);

      await tester.tap(find.text('Date'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoPicker), findsNWidgets(2));

      // The sheet must stay a sheet: no taller than asked, and never taller
      // than the screen it slides over.
      final sheet = tester.getSize(find.byKey(const ValueKey('ios-wheel-sheet')));
      expect(sheet.height, lessThanOrEqualTo(316));
      expect(sheet.height, lessThan(tester.view.physicalSize.height));

      final sheetStyle =
          DefaultTextStyle.of(tester.element(find.text('Performance'))).style;
      expect(sheetStyle.decoration ?? TextDecoration.none, TextDecoration.none);
    });

    testWidgets('Android renders Material 3 chrome and the date dialog',
        (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pumpApp(tester, Persona.android);

      expect(find.byType(SegmentedButton<int>), findsOneWidget);
      expect(find.byType(FilterChip), findsWidgets);

      await tester.tap(find.text('Pick a date'));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
    });

    testWidgets('desktop renders the month grid and all three panes',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pumpApp(tester, Persona.desktop);

      expect(find.byType(MonthGrid), findsOneWidget);
      expect(find.text('YOUR ORDER'), findsOneWidget);
      expect(find.byType(CupertinoPicker), findsNothing);
    });

    testWidgets('tapping a seat on the desktop map adds it to the order',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pumpApp(tester, Persona.desktop);

      // The first performance is selected on load, so the house is already up.
      expect(find.byType(SeatMapView), findsOneWidget);
      expect(find.text('No seats selected yet.'), findsOneWidget);

      await tester.tap(find.text('Best available'));
      await tester.pumpAndSettle();

      expect(find.text('No seats selected yet.'), findsNothing);
      expect(find.textContaining(RegExp(r'Row [A-N], seat \d+')), findsWidgets);
      expect(find.text('Confirm booking'), findsOneWidget);
    });
  });
}

void _personaResolution() {
  group('persona resolution prefers the host over the user agent', () {
    // Flutter web reads defaultTargetPlatform from the user agent. Inside a
    // chat client that UA describes the webview, not the phone around it, so a
    // view opened in Claude on a phone can render the desktop layout. These
    // cases are the reason `personaFor` exists.
    HostContext host({
      String? platform,
      String? hostUserAgent,
      String? navigatorUserAgent,
      bool? touch,
      bool? hover,
    }) =>
        HostContext(
          hostPlatform: platform,
          hostUserAgent: hostUserAgent,
          navigatorUserAgent: navigatorUserAgent,
          touch: touch,
          hover: hover,
        );

    test('a mobile host never gets the desktop layout', () {
      expect(personaFor(host(platform: 'mobile')), isNot(Persona.desktop));
    });

    test('the host user agent decides iOS from Android', () {
      expect(
        personaFor(host(platform: 'mobile', hostUserAgent: 'claude-ios/1.2')),
        Persona.ios,
      );
      expect(
        personaFor(host(platform: 'mobile', hostUserAgent: 'claude-android/1.2')),
        Persona.android,
      );
    });

    test('the browser user agent is the fallback, not the first answer', () {
      expect(
        personaFor(host(
          platform: 'mobile',
          navigatorUserAgent: 'Mozilla/5.0 (Linux; Android 14; Pixel 8)',
        )),
        Persona.android,
      );
      expect(
        personaFor(host(
          platform: 'mobile',
          navigatorUserAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0)',
        )),
        Persona.ios,
      );
    });

    test('a desktop host stays pointer-first', () {
      expect(personaFor(host(platform: 'desktop')), Persona.desktop);
      expect(personaFor(host(platform: 'web')), Persona.desktop);
    });

    test('a touch-only web host is treated as a phone', () {
      // Claude on a tablet reports `web` with touch and no hover.
      expect(
        personaFor(host(
          platform: 'web',
          touch: true,
          hover: false,
          hostUserAgent: 'claude-ios',
        )),
        Persona.ios,
      );
    });

    test('no host information falls back to the old behaviour', () {
      expect(personaFor(null), detectPersona());
      expect(personaFor(host()), detectPersona());
    });
  });
}

void _layoutFit() {
  group('layout follows the space, not the persona', () {
    // A chat client hands this view a slot in a conversation, not a page. The
    // two-column layout needs room the slot may not have, and asking for more
    // height than the host offered produces a clipped panel, not a taller one.
    test('a conversation-sized slot is compact', () {
      expect(fitFor(const Size(700, 420)), Fit.compact);
      expect(fitFor(const Size(700, 620)), Fit.compact, reason: 'too narrow');
      expect(fitFor(const Size(900, 420)), Fit.compact, reason: 'too short');
    });

    test('a full panel is roomy', () {
      expect(fitFor(const Size(900, 900)), Fit.roomy);
      expect(fitFor(kRoomyMinimum), Fit.roomy, reason: 'the boundary counts');
    });

    testWidgets('a desktop persona in a small slot does not clip', (tester) async {
      tester.view.physicalSize = const Size(700, 420);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final host = await _unhosted();
      await tester.pumpWidget(ShowtimeApp(
        host: host,
        box: LocalBoxOffice(),
        initialPersona: Persona.desktop,
        showChrome: false,
      ));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // The two-column shell is what overflows here; the compact one is not.
      expect(find.byType(DesktopShell), findsNothing);
    });
  });
}

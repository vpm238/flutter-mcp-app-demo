/// Where the view gets its data.
///
/// Two implementations, one interface:
///
/// * [McpBoxOffice] calls back into the MCP server through the host. This is
///   the path that runs inside Claude.
/// * [LocalBoxOffice] generates the same house from the same seeds in-process,
///   so the build also works as a plain web page you can open in a browser.
///
/// The view never knows which one it has.
library;

import '../mcp/bridge.dart';
import '../model.dart';
import 'catalog.dart';

abstract class BoxOffice {
  /// True when a real MCP server is answering.
  bool get isLive;

  Future<BookingSession> openSession({String? showId, int partySize});

  Future<SeatMap> seatMap(String slotId);

  Future<Booking> confirm({
    required String slotId,
    required List<String> seatIds,
    required String showId,
  });
}

class McpBoxOffice implements BoxOffice {
  McpBoxOffice(this.host);

  final McpHost host;

  @override
  bool get isLive => true;

  @override
  Future<BookingSession> openSession({String? showId, int partySize = 2}) async {
    // The tool call that opened this view already carries the first payload.
    final seeded = host.initialToolResult;
    if (seeded != null && showId == null) {
      return BookingSession.fromJson(seeded);
    }
    final data = await host.callTool('list_showtimes', {
      'show': ?showId,
      'party_size': partySize,
    });
    return BookingSession.fromJson(data);
  }

  @override
  Future<SeatMap> seatMap(String slotId) async {
    final data = await host.callTool('get_seat_map', {'slot': slotId});
    return SeatMap.fromJson(data);
  }

  @override
  Future<Booking> confirm({
    required String slotId,
    required List<String> seatIds,
    required String showId,
  }) async {
    final data = await host.callTool('confirm_booking', {
      'slot': slotId,
      'seats': seatIds,
      'show': showId,
    });
    return Booking.fromJson(data);
  }
}

class LocalBoxOffice implements BoxOffice {
  @override
  bool get isLive => false;

  @override
  Future<BookingSession> openSession({String? showId, int partySize = 2}) async {
    final show = showById(showId);
    return BookingSession(
      show: show,
      slots: slotsFor(show.id),
      partySize: partySize,
      currency: 'USD',
    );
  }

  @override
  Future<SeatMap> seatMap(String slotId) async => seatMapFor(slotId);

  @override
  Future<Booking> confirm({
    required String slotId,
    required List<String> seatIds,
    required String showId,
  }) async {
    final show = showById(showId);
    final map = seatMapFor(slotId);
    final seats = seatIds.map(map.seatById).whereType<Seat>().toList();
    final total = seats.fold<int>(0, (sum, s) => sum + map.tierFor(s).priceCents);
    final slot = slotsFor(show.id).firstWhere(
      (s) => s.id == slotId,
      orElse: () => slotsFor(show.id).first,
    );
    return Booking(
      code: _localCode(slotId, seatIds),
      seatLabels: seats.map((s) => '${s.row}${s.number}').toList(),
      totalCents: total + 350 * seats.length,
      startsAt: slot.startsAt,
      showTitle: show.title,
      venue: show.venue,
    );
  }

  String _localCode(String slotId, List<String> seats) {
    final source = '$slotId|${seats.join(',')}';
    var h = 0;
    for (final unit in source.codeUnits) {
      h = (h * 31 + unit) & 0xFFFFFF;
    }
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final out = StringBuffer('LOC-');
    for (var i = 0; i < 6; i++) {
      out.write(alphabet[(h >> (i * 3)) % alphabet.length]);
    }
    return out.toString();
  }
}

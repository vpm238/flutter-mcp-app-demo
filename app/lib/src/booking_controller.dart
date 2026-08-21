/// All booking state, in one listenable.
///
/// The three personas are pure presentation: they read this controller and call
/// into it. That is what keeps the iOS, Android, and desktop trees honest —
/// they cannot drift in behaviour, only in chrome.
library;

import 'package:flutter/foundation.dart';

import 'data/catalog.dart' show bestAvailable;
import 'data/data_source.dart';
import 'mcp/bridge.dart';
import 'model.dart';

/// Booking fee per seat, in cents. Every real box office has one.
const int perSeatFeeCents = 350;

enum Phase { loading, choosingDate, choosingTime, choosingSeats, confirmed }

class BookingController extends ChangeNotifier {
  BookingController({required this.box, this.host});

  final BoxOffice box;
  final McpHost? host;

  BookingSession? session;
  SeatMap? seatMap;
  Booking? booking;

  DateTime? selectedDay;
  Slot? selectedSlot;
  final List<Seat> selectedSeats = [];

  int partySize = 2;
  bool loadingSeatMap = false;
  bool confirming = false;
  String? error;

  Phase _phase = Phase.loading;
  Phase get phase => _phase;

  Show? get show => session?.show;
  String get currency => session?.currency ?? 'USD';

  Future<void> load({String? showId}) async {
    _phase = Phase.loading;
    error = null;
    notifyListeners();
    try {
      final loaded = await box.openSession(showId: showId, partySize: partySize);
      session = loaded;
      partySize = loaded.partySize;
      _phase = Phase.choosingDate;

      final preselected = loaded.preselectedSlotId;
      if (preselected != null) {
        final slot = loaded.slots.where((s) => s.id == preselected).firstOrNull;
        if (slot != null) {
          selectedDay = _dayOf(slot.startsAt);
          await selectSlot(slot);
          return;
        }
      }
      // Land on a populated view rather than an empty one: pick the first
      // performance so the seat map is already on screen.
      final firstDay = daysWithSlots.firstOrNull;
      if (firstDay != null) {
        selectedDay = firstDay;
        final first = slotsOn(firstDay).where((s) => !s.soldOut).firstOrNull ??
            slotsOn(firstDay).firstOrNull;
        if (first != null) {
          await selectSlot(first);
          return;
        }
      }
    } catch (e) {
      error = '$e';
      _phase = Phase.choosingDate;
    }
    notifyListeners();
  }

  /// Every day that has at least one performance, in order.
  List<DateTime> get daysWithSlots {
    final seen = <String, DateTime>{};
    for (final slot in session?.slots ?? const <Slot>[]) {
      final day = _dayOf(slot.startsAt);
      seen.putIfAbsent(_key(day), () => day);
    }
    return seen.values.toList()..sort();
  }

  List<Slot> slotsOn(DateTime day) => (session?.slots ?? const <Slot>[])
      .where((s) => _key(_dayOf(s.startsAt)) == _key(day))
      .toList()
    ..sort((a, b) => a.startsAt.compareTo(b.startsAt));

  bool hasSlotsOn(DateTime day) => slotsOn(day).isNotEmpty;

  List<Slot> get slotsForSelectedDay =>
      selectedDay == null ? const [] : slotsOn(selectedDay!);

  void selectDay(DateTime day) {
    if (selectedDay != null && _key(selectedDay!) == _key(day)) return;
    selectedDay = _dayOf(day);
    selectedSlot = null;
    seatMap = null;
    selectedSeats.clear();
    _phase = Phase.choosingTime;
    notifyListeners();
  }

  void setPartySize(int size) {
    partySize = size.clamp(1, 8);
    if (selectedSeats.length > partySize) {
      selectedSeats.removeRange(partySize, selectedSeats.length);
    }
    notifyListeners();
  }

  Future<void> selectSlot(Slot slot) async {
    selectedSlot = slot;
    selectedSeats.clear();
    seatMap = null;
    loadingSeatMap = true;
    error = null;
    _phase = Phase.choosingSeats;
    notifyListeners();

    try {
      seatMap = await box.seatMap(slot.id);
    } catch (e) {
      error = 'Could not load the seat map: $e';
    } finally {
      loadingSeatMap = false;
      notifyListeners();
    }
  }

  /// Step back to the time list without dropping the chosen day.
  void clearSlot() {
    selectedSlot = null;
    seatMap = null;
    selectedSeats.clear();
    _phase = Phase.choosingTime;
    notifyListeners();
  }

  bool isSelected(Seat seat) => selectedSeats.any((s) => s.id == seat.id);

  /// Tap a seat. Selecting past the party size evicts the oldest pick, which is
  /// what people expect when they change their mind about one seat.
  void toggleSeat(Seat seat) {
    if (!seat.bookable) return;
    final index = selectedSeats.indexWhere((s) => s.id == seat.id);
    if (index >= 0) {
      selectedSeats.removeAt(index);
    } else {
      if (selectedSeats.length >= partySize) selectedSeats.removeAt(0);
      selectedSeats.add(seat);
    }
    selectedSeats.sort((a, b) {
      final byRow = a.row.compareTo(b.row);
      return byRow != 0 ? byRow : a.number.compareTo(b.number);
    });
    notifyListeners();
  }

  /// The "best available" shortcut: the highest-scoring adjacent run.
  void pickBestAvailable() {
    final map = seatMap;
    if (map == null) return;
    final run = bestAvailable(map, partySize);
    if (run.isEmpty) {
      error = 'No $partySize seats together at this performance.';
      notifyListeners();
      return;
    }
    selectedSeats
      ..clear()
      ..addAll(run);
    error = null;
    notifyListeners();
  }

  int get subtotalCents {
    final map = seatMap;
    if (map == null) return 0;
    return selectedSeats.fold(0, (sum, s) => sum + map.tierFor(s).priceCents);
  }

  int get feesCents => selectedSeats.length * perSeatFeeCents;
  int get totalCents => subtotalCents + feesCents;

  bool get canConfirm =>
      selectedSlot != null && selectedSeats.length == partySize && !confirming;

  String get seatSummary => selectedSeats.isEmpty
      ? 'No seats selected'
      : _condenseSeats(selectedSeats);

  Future<void> confirmBooking() async {
    if (!canConfirm) return;
    confirming = true;
    error = null;
    notifyListeners();

    try {
      final result = await box.confirm(
        slotId: selectedSlot!.id,
        seatIds: selectedSeats.map((s) => s.id).toList(),
        showId: session!.show.id,
      );
      booking = result;
      _phase = Phase.confirmed;
      _tellTheModel(result);
    } catch (e) {
      error = 'Booking failed: $e';
    } finally {
      confirming = false;
      notifyListeners();
    }
  }

  /// Hand the conversation the outcome: a durable context note the model can
  /// refer back to, then a short turn so it actually says something.
  void _tellTheModel(Booking result) {
    final host = this.host;
    if (host == null) return;
    final when = _wireDate(result.startsAt);
    host.updateModelContext(
      'The user completed a booking in the Showtime view.\n'
      '- Show: ${result.showTitle}\n'
      '- Venue: ${result.venue}\n'
      '- Performance: $when\n'
      '- Seats: ${result.seatLabels.join(', ')} (${result.seatLabels.length})\n'
      '- Total charged: ${formatMoney(result.totalCents, currency: currency)} '
      '(includes ${formatMoney(feesCents, currency: currency)} in per-seat fees)\n'
      '- Confirmation code: ${result.code}',
    );
    host.sendMessage(
      'I booked ${result.seatLabels.length} '
      '${result.seatLabels.length == 1 ? 'seat' : 'seats'} '
      '(${result.seatLabels.join(', ')}) for ${result.showTitle} on $when. '
      'Confirmation ${result.code}.',
    );
  }

  /// Let the model narrate progress mid-flow without spamming the transcript.
  void noteSelection() {
    final host = this.host;
    final slot = selectedSlot;
    if (host == null || slot == null) return;
    host.updateModelContext(
      'In-progress selection: ${session?.show.title ?? 'show'} at '
      '${_wireDate(slot.startsAt)}, seats $seatSummary, '
      'running total ${formatMoney(totalCents, currency: currency)}.',
    );
  }

  void start() {
    booking = null;
    selectedSeats.clear();
    selectedSlot = null;
    seatMap = null;
    _phase = Phase.choosingDate;
    notifyListeners();
  }

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

  static String _key(DateTime d) => '${d.year}-${d.month}-${d.day}';

  static String _wireDate(DateTime d) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hour12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final minute = d.minute.toString().padLeft(2, '0');
    final meridiem = d.hour < 12 ? 'AM' : 'PM';
    return '${days[d.weekday - 1]} ${months[d.month - 1]} ${d.day}, ${d.year} '
        'at $hour12:$minute $meridiem';
  }
}

/// `A5, A6, A7, C1` → `Row A 5–7, Row C 1`.
String _condenseSeats(List<Seat> seats) {
  final byRow = <String, List<int>>{};
  for (final seat in seats) {
    byRow.putIfAbsent(seat.row, () => []).add(seat.number);
  }
  final parts = <String>[];
  for (final entry in byRow.entries) {
    final numbers = entry.value..sort();
    final runs = <String>[];
    var start = numbers.first;
    var prev = numbers.first;
    for (final n in numbers.skip(1)) {
      if (n == prev + 1) {
        prev = n;
        continue;
      }
      runs.add(start == prev ? '$start' : '$start–$prev');
      start = prev = n;
    }
    runs.add(start == prev ? '$start' : '$start–$prev');
    parts.add('Row ${entry.key} ${runs.join(', ')}');
  }
  return parts.join(' · ');
}

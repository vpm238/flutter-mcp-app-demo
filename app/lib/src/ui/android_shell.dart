/// The Android persona.
///
/// Material 3 throughout: a date-picker dialog with disabled dark days, filter
/// chips for showtimes, a segmented button for party size, and a drag-handled
/// modal bottom sheet for the seat map.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../booking_controller.dart';
import '../model.dart';
import '../theme.dart';
import 'common.dart';
import 'ios_shell.dart' show TicketStub;
import 'seat_map.dart';

class AndroidShell extends StatelessWidget {
  const AndroidShell({super.key, required this.controller, this.header});

  final BookingController controller;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final skin = Skin.of(context);
    final palette = skin.palette;
    final show = controller.show;

    if (show == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      backgroundColor: palette.background,
      body: Column(
        children: [
          ?header,
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverAppBar.medium(
                  pinned: true,
                  automaticallyImplyLeading: false,
                  backgroundColor: palette.background,
                  surfaceTintColor: palette.accent,
                  title: const Text('Book tickets'),
                  titleTextStyle: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                    color: palette.textPrimary,
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  sliver: SliverList.list(
                    children: [
                      ShowHero(show: show, borderRadius: 20),
                      const SizedBox(height: 22),
                      _SectionLabel('When'),
                      const SizedBox(height: 10),
                      _DateStrip(controller: controller),
                      const SizedBox(height: 12),
                      _TimeChips(controller: controller),
                      const SizedBox(height: 24),
                      _SectionLabel('How many'),
                      const SizedBox(height: 10),
                      _PartySize(controller: controller),
                      const SizedBox(height: 24),
                      _SectionLabel('Seats'),
                      const SizedBox(height: 10),
                      _SeatsCard(controller: controller),
                      if (controller.error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          controller.error!,
                          style: TextStyle(color: palette.danger, fontSize: 13),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _AndroidCheckout(controller: controller),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    return Text(
      text,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: palette.textPrimary,
      ),
    );
  }
}

/// A horizontal strip of the next few dates, plus the real M3 date dialog.
class _DateStrip extends StatelessWidget {
  const _DateStrip({required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    final days = controller.daysWithSlots;
    if (days.isEmpty) return const SizedBox.shrink();

    return Column(
      children: [
        SizedBox(
          height: 92,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: days.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final day = days[i];
              final selected = controller.selectedDay != null &&
                  sameDay(day, controller.selectedDay!);
              return _DayCell(
                day: day,
                selected: selected,
                onTap: () => controller.selectDay(day),
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => _openDateDialog(context, controller),
            icon: const Icon(Icons.calendar_month_outlined, size: 18),
            style: OutlinedButton.styleFrom(
              foregroundColor: palette.textPrimary,
              side: BorderSide(color: palette.border),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            label: const Text('Pick a date'),
          ),
        ),
      ],
    );
  }

  Future<void> _openDateDialog(
    BuildContext context,
    BookingController controller,
  ) async {
    final days = controller.daysWithSlots;
    if (days.isEmpty) return;
    final picked = await showDatePicker(
      context: context,
      initialDate: controller.selectedDay ?? days.first,
      firstDate: days.first,
      lastDate: days.last,
      // Dark days are simply not selectable — the dialog greys them out.
      selectableDayPredicate: controller.hasSlotsOn,
      helpText: 'Select a performance date',
    );
    if (picked != null) controller.selectDay(picked);
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.selected,
    required this.onTap,
  });

  final DateTime day;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    return Material(
      color: selected ? palette.accent : palette.surface,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 62,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? palette.accent : palette.border,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                weekdayShort(day).toUpperCase(),
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w600,
                  color: selected ? palette.onAccent : palette.textTertiary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${day.day}',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: selected ? palette.onAccent : palette.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                monthShort(day),
                style: TextStyle(
                  fontSize: 10.5,
                  color: selected
                      ? palette.onAccent.withValues(alpha: 0.85)
                      : palette.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimeChips extends StatelessWidget {
  const _TimeChips({required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    final slots = controller.slotsForSelectedDay;
    if (slots.isEmpty) {
      return Text(
        'No performances on this date.',
        style: TextStyle(color: palette.textSecondary, fontSize: 13.5),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final slot in slots)
          FilterChip(
            selected: controller.selectedSlot?.id == slot.id,
            onSelected:
                slot.soldOut ? null : (_) => controller.selectSlot(slot),
            showCheckmark: false,
            backgroundColor: palette.surface,
            selectedColor: palette.accent.withValues(alpha: 0.18),
            side: BorderSide(
              color: controller.selectedSlot?.id == slot.id
                  ? palette.accent
                  : palette.border,
            ),
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  timeLabel(slot.startsAt),
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: slot.soldOut
                        ? palette.textTertiary
                        : palette.textPrimary,
                  ),
                ),
                const SizedBox(width: 7),
                DemandDots(slot: slot),
                if (slot.tag != null) ...[
                  const SizedBox(width: 7),
                  Text(
                    slot.tag!,
                    style: TextStyle(fontSize: 11, color: palette.textTertiary),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _PartySize extends StatelessWidget {
  const _PartySize({required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<int>(
        segments: [
          for (var i = 1; i <= 6; i++)
            ButtonSegment(value: i, label: Text('$i')),
        ],
        selected: {controller.partySize},
        showSelectedIcon: false,
        onSelectionChanged: (v) => controller.setPartySize(v.first),
      ),
    );
  }
}

class _SeatsCard extends StatelessWidget {
  const _SeatsCard({required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    final ready = controller.selectedSlot != null;
    final chosen = controller.selectedSeats;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.event_seat_outlined,
                    size: 20, color: palette.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    chosen.isEmpty ? 'No seats chosen yet' : controller.seatSummary,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      color: palette.textPrimary,
                    ),
                  ),
                ),
                Text(
                  '${chosen.length}/${controller.partySize}',
                  style: TextStyle(fontSize: 13, color: palette.textTertiary),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  // Beaconed because the device reports Flutter painting and
                  // then nothing happening: this says whether the tap reaches
                  // a widget callback at all, or dies before Flutter sees it.
                  onPressed: ready
                      ? () {
                          Skin.of(context).note('choose-seats', 'pressed');
                          openAndroidSeatSheet(context, controller);
                        }
                      : null,
                  icon: const Icon(Icons.grid_view_rounded, size: 18),
                  label: const Text('Choose seats'),
                ),
                TextButton(
                  onPressed: ready
                      ? () {
                          controller.pickBestAvailable();
                          if (controller.selectedSeats.isNotEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                behavior: SnackBarBehavior.floating,
                                content: Text(
                                    'Picked ${controller.seatSummary}'),
                              ),
                            );
                          }
                        }
                      : null,
                  child: const Text('Best available'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The Android seat picker: a drag-handled modal bottom sheet.
Future<void> openAndroidSeatSheet(
  BuildContext context,
  BookingController controller,
) async {
  // Deliberately *not* asking the host for fullscreen first.
  //
  // That was the previous fix for a sheet landing below the visible panel, and
  // it is worse than the problem: a host may present fullscreen by re-creating
  // the frame rather than resizing it, which restarts the app and destroys the
  // sheet before it opens. Claude on Android does exactly that, and the result
  // is a picker that appears to do nothing at all. Reproduced with
  // `/devhost/?fullscreen=remount`.
  //
  // So the sheet sizes itself to the viewport it has. Fullscreen stays a thing
  // the user can ask for with the expand control, where a restart is at least
  // something they initiated.
  final palette = Skin.of(context).palette;
  final screen = MediaQuery.sizeOf(context);

  // Size the sheet to the house rather than to the screen. The map's height
  // follows from its width, so a fixed-fraction sheet leaves a band of empty
  // grey above and below it on a tall phone.
  //
  // The map gets the room left *after* the chrome, not the whole screen. Fit
  // it to the screen and on a short panel it is taller than the space it has,
  // and the legend and the Done button end up drawn over the back rows.
  const chromeHeight = 64.0 + 44.0 + 78.0; // title, legend, footer
  final ceiling = screen.height * 0.9;
  final forTheMap = math.max(140.0, ceiling - chromeHeight - 24);

  final map = controller.seatMap;
  final geometry = SeatGeometry.fit(
    maxWidth: screen.width - 20,
    maxHeight: forTheMap,
    rowCount: map?.rows.length ?? 14,
    colCount: map?.seatsPerRow ?? 18,
    aislesAfter: map?.aislesAfter ?? const [2, 15],
    style: SeatMapStyle.forPersona(Persona.android),
  );
  final sheetHeight = math.min(ceiling, geometry.height + chromeHeight + 24);

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: palette.surface,
    useSafeArea: true,
    builder: (sheetContext) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final map = controller.seatMap;
        return SizedBox(
          height: sheetHeight,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Choose ${controller.partySize} '
                        '${controller.partySize == 1 ? 'seat' : 'seats'}',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: palette.textPrimary,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: controller.pickBestAvailable,
                      child: const Text('Best available'),
                    ),
                  ],
                ),
              ),
              if (controller.loadingSeatMap || map == null)
                const Expanded(child: Center(child: CircularProgressIndicator()))
              else ...[
                Expanded(
                  // The map fits itself to these constraints, but its seat size
                  // has a floor for touch targets — so in a genuinely short
                  // panel it can still be taller than the box. Clipping keeps
                  // the back rows out of the legend and the Done button rather
                  // than drawing over them.
                  child: ClipRect(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: SeatMapView(
                        map: map,
                        controller: controller,
                        style: SeatMapStyle.forPersona(Persona.android),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: SeatLegend(map: map, compact: true),
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        controller.seatSummary,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: palette.textSecondary,
                        ),
                      ),
                    ),
                    FilledButton(
                      onPressed: controller.selectedSeats.isEmpty
                          ? null
                          : () {
                              controller.noteSelection();
                              Navigator.of(sheetContext).pop();
                            },
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _AndroidCheckout extends StatelessWidget {
  const _AndroidCheckout({required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    final skin = Skin.of(context);
    final palette = skin.palette;
    final hasSeats = controller.selectedSeats.isNotEmpty;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    hasSeats
                        ? formatMoney(controller.totalCents,
                            currency: skin.currency)
                        : '—',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: palette.textPrimary,
                    ),
                  ),
                  Text(
                    hasSeats
                        ? 'Incl. ${formatMoney(controller.feesCents, currency: skin.currency)} fees'
                        : 'Choose your seats',
                    style: TextStyle(fontSize: 12.5, color: palette.textSecondary),
                  ),
                ],
              ),
            ),
            FilledButton(
              onPressed: controller.canConfirm ? controller.confirmBooking : null,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
              ),
              child: controller.confirming
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Confirm'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Material confirmation screen.
class AndroidConfirmation extends StatelessWidget {
  const AndroidConfirmation({super.key, required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    final booking = controller.booking!;

    return Scaffold(
      backgroundColor: palette.background,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: palette.success.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.check_rounded, size: 34, color: palette.success),
              ),
              const SizedBox(height: 16),
              Text(
                'Booking confirmed',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                booking.showTitle,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: palette.textSecondary),
              ),
              const SizedBox(height: 20),
              TicketStub(controller: controller),
              const SizedBox(height: 16),
              TextButton(
                onPressed: controller.start,
                child: const Text('Book another'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

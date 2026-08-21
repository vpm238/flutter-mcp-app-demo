/// The iOS persona.
///
/// Inset-grouped list sections, a wheel picker in a popup surface, a
/// full-screen sheet for the seat map, and a filled Cupertino button pinned to
/// the bottom. Everything a UIKit ticketing app would do.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors, Material;

import '../booking_controller.dart';
import '../model.dart';
import '../theme.dart';
import 'common.dart';
import 'seat_map.dart';

class IosShell extends StatelessWidget {
  const IosShell({super.key, required this.controller, this.header});

  final BookingController controller;

  /// The persona switcher / host badge strip, injected by the root.
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;

    return CupertinoTheme(
      data: CupertinoThemeData(
        brightness: palette.brightness,
        primaryColor: palette.accent,
        scaffoldBackgroundColor: palette.background,
        barBackgroundColor: palette.surface.withValues(alpha: 0.86),
        textTheme: CupertinoTextThemeData(
          primaryColor: palette.accent,
          textStyle: TextStyle(
            fontFamily: 'Inter',
            fontSize: 17,
            letterSpacing: -0.41,
            color: palette.textPrimary,
          ),
        ),
      ),
      child: CupertinoPageScaffold(
        backgroundColor: palette.background,
        child: DefaultTextStyle(
          style: _cupertinoBody(palette),
          child: Column(
            children: [
              ?header,
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    CupertinoSliverNavigationBar(
                      largeTitle: const Text('Tickets'),
                      backgroundColor: palette.surface.withValues(alpha: 0.86),
                      border: Border(
                        bottom: BorderSide(color: palette.border, width: 0.5),
                      ),
                      automaticallyImplyLeading: false,
                    ),
                    SliverToBoxAdapter(child: _IosBody(controller: controller)),
                  ],
                ),
              ),
              _IosCheckoutBar(controller: controller),
            ],
          ),
        ),
      ),
    );
  }
}

/// The body style UIKit would give you: SF-metric size, tight tracking.
TextStyle _cupertinoBody(Palette palette) => TextStyle(
  fontFamily: 'Inter',
  fontSize: 17,
  height: 1.29,
  letterSpacing: -0.41,
  fontWeight: FontWeight.w400,
  color: palette.textPrimary,
  decoration: TextDecoration.none,
);

class _IosBody extends StatelessWidget {
  const _IosBody({required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    final skin = Skin.of(context);
    final palette = skin.palette;
    final show = controller.show;
    if (show == null) {
      return const Padding(
        padding: EdgeInsets.all(48),
        child: Center(child: CupertinoActivityIndicator()),
      );
    }

    final slot = controller.selectedSlot;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ShowHero(show: show),
          const SizedBox(height: 8),
          CupertinoListSection.insetGrouped(
            header: Text('PERFORMANCE', style: _sectionHeader(palette)),
            backgroundColor: Colors.transparent,
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(10),
            ),
            children: [
              CupertinoListTile.notched(
                leading: _TileIcon(
                  icon: CupertinoIcons.calendar,
                  color: palette.accent,
                ),
                title: const Text('Date'),
                additionalInfo: Text(
                  slot == null
                      ? (controller.selectedDay == null
                            ? 'Select'
                            : relativeDayLabel(controller.selectedDay!))
                      : relativeDayLabel(slot.startsAt),
                ),
                trailing: const CupertinoListTileChevron(),
                onTap: () => _openWheel(context, controller),
              ),
              CupertinoListTile.notched(
                leading: _TileIcon(
                  icon: CupertinoIcons.clock,
                  color: palette.accent,
                ),
                title: const Text('Time'),
                additionalInfo: Text(
                  slot == null ? 'Select' : timeLabel(slot.startsAt),
                ),
                trailing: const CupertinoListTileChevron(),
                onTap: () => _openWheel(context, controller),
              ),
            ],
          ),
          CupertinoListSection.insetGrouped(
            header: Text('PARTY SIZE', style: _sectionHeader(palette)),
            backgroundColor: Colors.transparent,
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(10),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: CupertinoSlidingSegmentedControl<int>(
                    groupValue: controller.partySize,
                    backgroundColor: palette.surfaceAlt,
                    thumbColor: palette.surface,
                    onValueChanged: (v) {
                      if (v != null) controller.setPartySize(v);
                    },
                    children: {
                      for (var i = 1; i <= 6; i++)
                        i: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text(
                            '$i',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: palette.textPrimary,
                            ),
                          ),
                        ),
                    },
                  ),
                ),
              ),
            ],
          ),
          CupertinoListSection.insetGrouped(
            header: Text('SEATS', style: _sectionHeader(palette)),
            backgroundColor: Colors.transparent,
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(10),
            ),
            children: [
              CupertinoListTile.notched(
                leading: _TileIcon(
                  icon: CupertinoIcons.square_grid_3x2,
                  color: palette.accent,
                ),
                title: Text(
                  controller.selectedSeats.isEmpty ? 'Choose seats' : 'Seats',
                ),
                subtitle: controller.selectedSeats.isEmpty
                    ? null
                    : Text(controller.seatSummary),
                additionalInfo: controller.selectedSeats.isEmpty
                    ? Text('${controller.partySize} needed')
                    : Text(
                        '${controller.selectedSeats.length}/${controller.partySize}',
                      ),
                trailing: const CupertinoListTileChevron(),
                onTap: slot == null
                    ? null
                    : () => (() { Skin.of(context).note('choose-seats', 'pressed'); openIosSeatSheet(context, controller); })(),
              ),
            ],
          ),
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                controller.error!,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  color: palette.danger,
                ),
              ),
            ),
        ],
      ),
    );
  }

  TextStyle _sectionHeader(Palette palette) => TextStyle(
    fontFamily: 'Inter',
    fontSize: 12.5,
    letterSpacing: 0.4,
    fontWeight: FontWeight.w600,
    color: palette.textTertiary,
  );
}

class _TileIcon extends StatelessWidget {
  const _TileIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 29,
      height: 29,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Icon(icon, size: 17, color: Colors.white),
    );
  }
}

/// The iOS date + time wheels, in a popup surface with a Done toolbar.
Future<void> _openWheel(
  BuildContext context,
  BookingController controller,
) async {
  final palette = Skin.of(context).palette;
  await showCupertinoModalPopup<void>(
    context: context,
    builder: (context) => Container(
      key: const ValueKey('ios-wheel-sheet'),
      height: 316,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      ),
      // Routes mount under the Navigator, not under the shell, so this needs
      // its own default text style or Flutter paints the missing-style rule.
      child: DefaultTextStyle(
        style: _cupertinoBody(palette),
        child: SafeArea(
          top: false,
          child: _DateTimeWheel(controller: controller),
        ),
      ),
    ),
  );
}

class _DateTimeWheel extends StatefulWidget {
  const _DateTimeWheel({required this.controller});

  final BookingController controller;

  @override
  State<_DateTimeWheel> createState() => _DateTimeWheelState();
}

class _DateTimeWheelState extends State<_DateTimeWheel> {
  late List<DateTime> _days;
  late int _dayIndex;
  int _timeIndex = 0;
  late FixedExtentScrollController _dayScroll;

  @override
  void initState() {
    super.initState();
    _days = widget.controller.daysWithSlots;
    final selected = widget.controller.selectedDay;
    _dayIndex = selected == null
        ? 0
        : _days
              .indexWhere((d) => sameDay(d, selected))
              .clamp(0, _days.length - 1);

    final slot = widget.controller.selectedSlot;
    if (slot != null) {
      final times = widget.controller.slotsOn(_days[_dayIndex]);
      _timeIndex = times
          .indexWhere((s) => s.id == slot.id)
          .clamp(0, times.length - 1);
    }
    _dayScroll = FixedExtentScrollController(initialItem: _dayIndex);
  }

  @override
  void dispose() {
    _dayScroll.dispose();
    super.dispose();
  }

  List<Slot> get _times =>
      _days.isEmpty ? const [] : widget.controller.slotsOn(_days[_dayIndex]);

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    if (_days.isEmpty) {
      return const Center(child: CupertinoActivityIndicator());
    }

    final times = _times;
    final chosenTime = times.isEmpty
        ? null
        : times[_timeIndex.clamp(0, times.length - 1)];

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: palette.border, width: 0.5),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              CupertinoButton(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: palette.textSecondary),
                ),
              ),
              Flexible(
                child: Text(
                  'Performance',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: palette.textPrimary,
                  ),
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                onPressed: chosenTime == null
                    ? null
                    : () {
                        widget.controller.selectDay(_days[_dayIndex]);
                        widget.controller.selectSlot(chosenTime);
                        Navigator.of(context).pop();
                      },
                child: Text(
                  'Done',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: palette.accent,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: CupertinoPicker(
                  scrollController: _dayScroll,
                  itemExtent: 36,
                  magnification: 1.08,
                  squeeze: 1.15,
                  useMagnifier: true,
                  selectionOverlay: CupertinoPickerDefaultSelectionOverlay(
                    background: palette.accent.withValues(alpha: 0.12),
                  ),
                  onSelectedItemChanged: (i) => setState(() {
                    _dayIndex = i;
                    _timeIndex = 0;
                  }),
                  children: [
                    for (final day in _days)
                      Center(
                        child: Text(
                          relativeDayLabel(day),
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 19,
                            letterSpacing: -0.3,
                            color: palette.textPrimary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: CupertinoPicker(
                  key: ValueKey(_dayIndex),
                  scrollController: FixedExtentScrollController(
                    initialItem: _timeIndex.clamp(
                      0,
                      times.isEmpty ? 0 : times.length - 1,
                    ),
                  ),
                  itemExtent: 36,
                  magnification: 1.08,
                  squeeze: 1.15,
                  useMagnifier: true,
                  selectionOverlay: CupertinoPickerDefaultSelectionOverlay(
                    background: palette.accent.withValues(alpha: 0.12),
                  ),
                  onSelectedItemChanged: (i) => setState(() => _timeIndex = i),
                  children: [
                    for (final slot in times)
                      Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                timeLabel(slot.startsAt),
                                style: TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 19,
                                  letterSpacing: -0.3,
                                  color: slot.soldOut
                                      ? palette.textTertiary
                                      : palette.textPrimary,
                                ),
                              ),
                              const SizedBox(width: 7),
                              DemandDots(slot: slot),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The full-screen seat sheet.
Future<void> openIosSeatSheet(
  BuildContext context,
  BookingController controller,
) async {
  // No fullscreen request first — see the note in openAndroidSeatSheet. A
  // full-screen route is anchored at the top of the viewport anyway, so it
  // stays visible even when the frame is taller than the panel.
  await Navigator.of(context, rootNavigator: true).push<void>(
    CupertinoPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _IosSeatSheet(controller: controller),
    ),
  );
}

class _IosSeatSheet extends StatelessWidget {
  const _IosSeatSheet({required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    final skin = Skin.of(context);
    final palette = skin.palette;

    return CupertinoTheme(
      data: CupertinoThemeData(
        brightness: palette.brightness,
        primaryColor: palette.accent,
        scaffoldBackgroundColor: palette.background,
      ),
      child: CupertinoPageScaffold(
        backgroundColor: palette.background,
        navigationBar: CupertinoNavigationBar(
          backgroundColor: palette.surface.withValues(alpha: 0.9),
          border: Border(bottom: BorderSide(color: palette.border, width: 0.5)),
          leading: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Close', style: TextStyle(color: palette.accent)),
          ),
          middle: Text(
            'Choose seats',
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: controller.pickBestAvailable,
            child: Text('Best', style: TextStyle(color: palette.accent)),
          ),
        ),
        child: DefaultTextStyle(
          style: _cupertinoBody(palette),
          child: SafeArea(
            child: ListenableBuilder(
              listenable: controller,
              builder: (context, _) {
                final map = controller.seatMap;
                if (controller.loadingSeatMap || map == null) {
                  return const Center(child: CupertinoActivityIndicator());
                }
                return Column(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
                        child: SeatMapView(
                          map: map,
                          controller: controller,
                          style: SeatMapStyle.forPersona(Persona.ios),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: SeatLegend(map: map, compact: true),
                    ),
                    Text(
                      'Pinch to zoom · tap a seat to choose it',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        color: palette.textTertiary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    _IosCheckoutBar(
                      controller: controller,
                      primaryLabel: 'Done',
                      onPrimary: controller.selectedSeats.isEmpty
                          ? null
                          : () {
                              controller.noteSelection();
                              Navigator.of(context).pop();
                            },
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _IosCheckoutBar extends StatelessWidget {
  const _IosCheckoutBar({
    required this.controller,
    this.primaryLabel,
    this.onPrimary,
  });

  final BookingController controller;
  final String? primaryLabel;
  final VoidCallback? onPrimary;

  @override
  Widget build(BuildContext context) {
    final skin = Skin.of(context);
    final palette = skin.palette;
    final hasSeats = controller.selectedSeats.isNotEmpty;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(top: BorderSide(color: palette.border, width: 0.5)),
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
                        ? formatMoney(
                            controller.totalCents,
                            currency: skin.currency,
                          )
                        : '—',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.6,
                      color: palette.textPrimary,
                    ),
                  ),
                  Text(
                    hasSeats
                        ? '${controller.selectedSeats.length} × seats + fees'
                        : 'Choose your seats',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12.5,
                      color: palette.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            CupertinoButton(
              borderRadius: BorderRadius.circular(12),
              color: palette.accent,
              disabledColor: palette.surfaceAlt,
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 13),
              onPressed:
                  onPrimary ??
                  (controller.canConfirm ? controller.confirmBooking : null),
              child: controller.confirming
                  ? const CupertinoActivityIndicator(color: Colors.white)
                  : Text(
                      primaryLabel ?? 'Confirm',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: (onPrimary != null || controller.canConfirm)
                            ? palette.onAccent
                            : palette.textTertiary,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cupertino confirmation screen.
class IosConfirmation extends StatelessWidget {
  const IosConfirmation({super.key, required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    final skin = Skin.of(context);
    final palette = skin.palette;
    final booking = controller.booking!;

    return Material(
      color: palette.background,
      child: SafeArea(
        child: Center(
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
                  child: Icon(
                    CupertinoIcons.checkmark_alt,
                    size: 34,
                    color: palette.success,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'You’re going',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.6,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  booking.showTitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 15,
                    color: palette.textSecondary,
                  ),
                ),
                const SizedBox(height: 20),
                TicketStub(controller: controller),
                const SizedBox(height: 18),
                CupertinoButton(
                  onPressed: controller.start,
                  child: Text(
                    'Book another',
                    style: TextStyle(color: palette.accent),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The confirmation card. Shared by all three personas — a ticket is a ticket.
class TicketStub extends StatelessWidget {
  const TicketStub({super.key, required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    final skin = Skin.of(context);
    final palette = skin.palette;
    final booking = controller.booking!;

    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StubRow(
            label: 'When',
            value:
                '${weekdayLong(booking.startsAt)}, ${monthLong(booking.startsAt)} ${booking.startsAt.day} · ${timeLabel(booking.startsAt)}',
          ),
          _StubRow(label: 'Where', value: booking.venue),
          _StubRow(label: 'Seats', value: controller.seatSummary),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: _Perforation(color: palette.border),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Confirmation',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 11.5,
                      letterSpacing: 0.3,
                      color: palette.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    booking.code,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: palette.textPrimary,
                    ),
                  ),
                ],
              ),
              Text(
                formatMoney(booking.totalCents, currency: skin.currency),
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  color: palette.textPrimary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StubRow extends StatelessWidget {
  const _StubRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 62,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12.5,
                color: palette.textTertiary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14.5,
                fontWeight: FontWeight.w500,
                color: palette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Perforation extends StatelessWidget {
  const _Perforation({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        const dash = 5.0;
        final count = (c.maxWidth / (dash * 2)).floor();
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(
            count,
            (_) => Container(width: dash, height: 1, color: color),
          ),
        );
      },
    );
  }
}

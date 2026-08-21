/// The desktop persona.
///
/// No sheets, no wheels, no dialogs. Everything is on one surface at once: a
/// month grid you can scan, a times column, the full house at full size with
/// hover tooltips, and a running order summary. Pointer-first, keyboard-aware,
/// built for a window rather than a thumb.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../booking_controller.dart';
import '../model.dart';
import '../theme.dart';
import 'common.dart';
import 'ios_shell.dart' show TicketStub;
import 'seat_map.dart';

class DesktopShell extends StatelessWidget {
  const DesktopShell({super.key, required this.controller, this.header});

  final BookingController controller;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    final show = controller.show;
    if (show == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      backgroundColor: palette.background,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?header,
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Three panes need real room. Below that, fold the order into
                // the left column rather than squeezing the house.
                final width = constraints.maxWidth;
                if (width >= 1120) return _WideLayout(controller: controller);
                if (width >= 820) return _MediumLayout(controller: controller);
                return _StackedLayout(controller: controller);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _WideLayout extends StatelessWidget {
  const _WideLayout({required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 296,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: palette.border)),
            ),
            child: _WhenPane(controller: controller),
          ),
        ),
        Expanded(child: _HousePane(controller: controller)),
        SizedBox(
          width: 316,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: palette.surface,
              border: Border(left: BorderSide(color: palette.border)),
            ),
            child: _OrderPane(controller: controller),
          ),
        ),
      ],
    );
  }
}

/// Two panes: when + order on the left, the house on the right.
class _MediumLayout extends StatelessWidget {
  const _MediumLayout({required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 320,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: palette.border)),
            ),
            child: Column(
              children: [
                // One scroll for dates and order together — splitting the
                // column into two scrollers clips both at this width.
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                    children: [
                      ...whenPaneChildren(context, controller),
                      const SizedBox(height: 22),
                      Divider(color: palette.border, height: 1),
                      const SizedBox(height: 18),
                      ...orderPaneChildren(context, controller),
                    ],
                  ),
                ),
                _OrderFooter(controller: controller),
              ],
            ),
          ),
        ),
        Expanded(child: _HousePane(controller: controller)),
      ],
    );
  }
}

class _StackedLayout extends StatelessWidget {
  const _StackedLayout({required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            children: [
              ...whenPaneChildren(context, controller),
              const SizedBox(height: 8),
              SizedBox(height: 420, child: _HousePane(controller: controller)),
              const SizedBox(height: 8),
              ...orderPaneChildren(context, controller),
            ],
          ),
        ),
        _OrderFooter(controller: controller),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Left: the show, a month grid, and the times for the chosen day.
// ---------------------------------------------------------------------------

class _WhenPane extends StatelessWidget {
  const _WhenPane({required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
      children: whenPaneChildren(context, controller),
    );
  }
}

/// The when-pane content, as a list, so narrower layouts can fold it into the
/// same scroll view as the order.
List<Widget> whenPaneChildren(BuildContext context, BookingController controller) {
  final palette = Skin.of(context).palette;
  return [
    ShowHero(show: controller.show!, height: 108, borderRadius: 12, dense: true),
    const SizedBox(height: 20),
    _PaneTitle('Choose a date'),
    const SizedBox(height: 10),
    MonthGrid(controller: controller),
    const SizedBox(height: 22),
    _PaneTitle('Performances'),
    const SizedBox(height: 8),
    if (controller.slotsForSelectedDay.isEmpty)
      Text(
        'Pick a date with a performance.',
        style: TextStyle(fontSize: 13, color: palette.textTertiary),
      )
    else
      for (final slot in controller.slotsForSelectedDay)
        _TimeRow(
          slot: slot,
          selected: controller.selectedSlot?.id == slot.id,
          onTap: slot.soldOut ? null : () => controller.selectSlot(slot),
        ),
  ];
}

class _PaneTitle extends StatelessWidget {
  const _PaneTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        letterSpacing: 0.8,
        fontWeight: FontWeight.w700,
        color: palette.textTertiary,
      ),
    );
  }
}

/// A real month grid — the affordance a laptop user expects instead of a wheel.
class MonthGrid extends StatefulWidget {
  const MonthGrid({super.key, required this.controller});

  final BookingController controller;

  @override
  State<MonthGrid> createState() => _MonthGridState();
}

class _MonthGridState extends State<MonthGrid> {
  DateTime? _month;

  DateTime get month {
    final anchor = _month ??
        widget.controller.selectedDay ??
        widget.controller.daysWithSlots.firstOrNull ??
        DateTime.now();
    return DateTime(anchor.year, anchor.month);
  }

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    final controller = widget.controller;
    final days = controller.daysWithSlots;
    final first = days.firstOrNull ?? DateTime.now();
    final last = days.lastOrNull ?? DateTime.now();

    final firstWeekday = DateTime(month.year, month.month, 1).weekday; // 1 = Mon
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final canGoBack = month.isAfter(DateTime(first.year, first.month));
    final canGoForward = month.isBefore(DateTime(last.year, last.month));

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${monthLong(month)} ${month.year}',
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: palette.textPrimary,
                ),
              ),
            ),
            _ArrowButton(
              icon: Icons.chevron_left_rounded,
              enabled: canGoBack,
              onTap: () => setState(
                  () => _month = DateTime(month.year, month.month - 1)),
            ),
            _ArrowButton(
              icon: Icons.chevron_right_rounded,
              enabled: canGoForward,
              onTap: () => setState(
                  () => _month = DateTime(month.year, month.month + 1)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final label in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
              Expanded(
                child: Center(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: palette.textTertiary,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.05,
          children: [
            for (var i = 1; i < firstWeekday; i++) const SizedBox.shrink(),
            for (var d = 1; d <= daysInMonth; d++)
              _DayButton(
                day: DateTime(month.year, month.month, d),
                controller: controller,
              ),
          ],
        ),
      ],
    );
  }
}

class _ArrowButton extends StatelessWidget {
  const _ArrowButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    return IconButton(
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, size: 20),
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        foregroundColor: palette.textSecondary,
        disabledForegroundColor: palette.textTertiary.withValues(alpha: 0.4),
      ),
    );
  }
}

class _DayButton extends StatelessWidget {
  const _DayButton({required this.day, required this.controller});

  final DateTime day;
  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    final available = controller.hasSlotsOn(day);
    final selected =
        controller.selectedDay != null && sameDay(day, controller.selectedDay!);
    final isToday = sameDay(day, DateTime.now());

    return Padding(
      padding: const EdgeInsets.all(2),
      child: Material(
        color: selected ? palette.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: available ? () => controller.selectDay(day) : null,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: isToday && !selected
                  ? Border.all(color: palette.textTertiary.withValues(alpha: 0.55))
                  : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${day.day}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? palette.onAccent
                        : available
                            ? palette.textPrimary
                            : palette.textTertiary.withValues(alpha: 0.45),
                  ),
                ),
                const SizedBox(height: 2),
                Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: !available
                        ? Colors.transparent
                        : selected
                            ? palette.onAccent.withValues(alpha: 0.8)
                            : palette.accent.withValues(alpha: 0.7),
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

class _TimeRow extends StatefulWidget {
  const _TimeRow({
    required this.slot,
    required this.selected,
    required this.onTap,
  });

  final Slot slot;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<_TimeRow> createState() => _TimeRowState();
}

class _TimeRowState extends State<_TimeRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final skin = Skin.of(context);
    final palette = skin.palette;
    final slot = widget.slot;

    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.selected
                ? palette.accent.withValues(alpha: 0.12)
                : _hover
                    ? palette.surfaceAlt
                    : palette.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.selected ? palette.accent : palette.border,
            ),
          ),
          child: Row(
            children: [
              Text(
                timeLabel(slot.startsAt),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: slot.soldOut ? palette.textTertiary : palette.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              DemandDots(slot: slot),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  slot.soldOut
                      ? 'Sold out'
                      : '${slot.seatsLeft} left · from ${formatMoney(slot.fromCents, currency: skin.currency)}',
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: palette.textTertiary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Centre: the house.
// ---------------------------------------------------------------------------

class _HousePane extends StatelessWidget {
  const _HousePane({required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    final map = controller.seatMap;

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final slot = controller.selectedSlot;
              final title = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    slot == null
                        ? 'Pick a performance'
                        : '${weekdayLong(slot.startsAt)}, '
                            '${monthLong(slot.startsAt)} ${slot.startsAt.day} · '
                            '${timeLabel(slot.startsAt)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 17,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: palette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Choose ${controller.partySize} '
                    '${controller.partySize == 1 ? 'seat' : 'seats'} · '
                    'hover for prices, scroll to zoom',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: palette.textTertiary),
                  ),
                ],
              );

              final controls = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PartyStepper(controller: controller),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: map == null ? null : controller.pickBestAvailable,
                    icon: const Icon(Icons.auto_awesome_outlined, size: 16),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: palette.textPrimary,
                      side: BorderSide(color: palette.border),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    label: const Text('Best available'),
                  ),
                ],
              );

              // Side by side only when the title still gets a usable share.
              if (constraints.maxWidth >= 560) {
                return Row(
                  children: [
                    Expanded(child: title),
                    const SizedBox(width: 12),
                    controls,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  const SizedBox(height: 10),
                  controls,
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: palette.border),
              ),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: controller.loadingSeatMap
                  ? const Center(child: CircularProgressIndicator())
                  : map == null
                      ? Center(
                          child: Text(
                            'Select a date and time to see the house.',
                            style: TextStyle(color: palette.textTertiary),
                          ),
                        )
                      : Column(
                          children: [
                            Expanded(
                              child: SeatMapView(
                                map: map,
                                controller: controller,
                                style: SeatMapStyle.forPersona(Persona.desktop),
                              ),
                            ),
                            const SizedBox(height: 10),
                            SeatLegend(map: map),
                          ],
                        ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PartyStepper extends StatelessWidget {
  const _PartyStepper({required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StepButton(
            icon: Icons.remove_rounded,
            onTap: controller.partySize > 1
                ? () => controller.setPartySize(controller.partySize - 1)
                : null,
          ),
          SizedBox(
            width: 34,
            child: Center(
              child: Text(
                '${controller.partySize}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: palette.textPrimary,
                ),
              ),
            ),
          ),
          _StepButton(
            icon: Icons.add_rounded,
            onTap: controller.partySize < 6
                ? () => controller.setPartySize(controller.partySize + 1)
                : null,
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    return SizedBox(
      width: 32,
      height: 34,
      child: IconButton(
        onPressed: onTap,
        padding: EdgeInsets.zero,
        iconSize: 17,
        icon: Icon(icon),
        style: IconButton.styleFrom(
          foregroundColor: palette.textSecondary,
          disabledForegroundColor: palette.textTertiary.withValues(alpha: 0.4),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Right: the order.
// ---------------------------------------------------------------------------

class _OrderPane extends StatelessWidget {
  const _OrderPane({required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
            children: orderPaneChildren(context, controller),
          ),
        ),
        _OrderFooter(controller: controller),
      ],
    );
  }
}

/// The order lines, as a list, so they can share a scroll view with the dates.
List<Widget> orderPaneChildren(BuildContext context, BookingController controller) {
  final skin = Skin.of(context);
  final palette = skin.palette;
  final map = controller.seatMap;
  final slot = controller.selectedSlot;

  return [
              _PaneTitle('Your order'),
              const SizedBox(height: 14),
              Text(
                controller.show!.title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                slot == null
                    ? 'No performance selected'
                    : '${weekdayShort(slot.startsAt)} ${monthShort(slot.startsAt)} '
                        '${slot.startsAt.day} · ${timeLabel(slot.startsAt)}',
                style: TextStyle(fontSize: 13, color: palette.textSecondary),
              ),
              const SizedBox(height: 18),
              Divider(color: palette.border, height: 1),
              const SizedBox(height: 14),
              if (controller.selectedSeats.isEmpty)
                Text(
                  'No seats selected yet.',
                  style: TextStyle(fontSize: 13, color: palette.textTertiary),
                )
              else
                for (final seat in controller.selectedSeats)
                  _LineItem(
                    left: 'Row ${seat.row}, seat ${seat.number}',
                    sub: map?.tierFor(seat).name ?? '',
                    right: formatMoney(
                      map?.tierFor(seat).priceCents ?? 0,
                      currency: skin.currency,
                    ),
                    dot: map?.tierFor(seat).color,
                    onRemove: () => controller.toggleSeat(seat),
                  ),
              if (controller.selectedSeats.isNotEmpty) ...[
                const SizedBox(height: 6),
                _LineItem(
                  left: 'Booking fee',
                  sub: '${formatMoney(perSeatFeeCents, currency: skin.currency)} per seat',
                  right: formatMoney(controller.feesCents, currency: skin.currency),
                ),
              ],
    if (controller.error != null) ...[
      const SizedBox(height: 12),
      Text(
        controller.error!,
        style: TextStyle(fontSize: 12.5, color: palette.danger),
      ),
    ],
  ];
}

class _OrderFooter extends StatelessWidget {
  const _OrderFooter({required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    final skin = Skin.of(context);
    final palette = skin.palette;

    return Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: palette.border)),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Total',
                    style: TextStyle(fontSize: 13.5, color: palette.textSecondary),
                  ),
                  Text(
                    formatMoney(controller.totalCents, currency: skin.currency),
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.6,
                      color: palette.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed:
                      controller.canConfirm ? controller.confirmBooking : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: palette.accent,
                    foregroundColor: palette.onAccent,
                    padding: const EdgeInsets.symmetric(vertical: 17),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: controller.confirming
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          controller.selectedSeats.length ==
                                  controller.partySize
                              ? 'Confirm booking'
                              : 'Select ${controller.partySize - controller.selectedSeats.length} more',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Confirming posts the booking back into the conversation.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: palette.textTertiary),
              ),
            ],
          ),
        );
  }
}

class _LineItem extends StatelessWidget {
  const _LineItem({
    required this.left,
    required this.sub,
    required this.right,
    this.dot,
    this.onRemove,
  });

  final String left;
  final String sub;
  final String right;
  final Color? dot;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          if (dot != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dot,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 9),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  left,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: palette.textPrimary,
                  ),
                ),
                if (sub.isNotEmpty)
                  Text(
                    sub,
                    style: TextStyle(fontSize: 11.5, color: palette.textTertiary),
                  ),
              ],
            ),
          ),
          Text(
            right,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
          if (onRemove != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: IconButton(
                onPressed: onRemove,
                iconSize: 15,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded),
                tooltip: 'Remove seat',
                style: IconButton.styleFrom(
                  foregroundColor: palette.textTertiary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Desktop confirmation: keep the layout, swap the centre for the stub.
class DesktopConfirmation extends StatelessWidget {
  const DesktopConfirmation({super.key, required this.controller});

  final BookingController controller;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    return Scaffold(
      backgroundColor: palette.background,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.confirmation_number_outlined,
                  size: 38, color: palette.accent),
              const SizedBox(height: 14),
              Text(
                'Booking confirmed',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.6,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'The details went back to the conversation.',
                style: TextStyle(fontSize: 14, color: palette.textSecondary),
              ),
              const SizedBox(height: 24),
              TicketStub(controller: controller),
              const SizedBox(height: 18),
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

/// `B` picks the best available seats, `Esc` clears the selection.
class BookingShortcuts extends StatelessWidget {
  const BookingShortcuts({
    super.key,
    required this.controller,
    required this.child,
  });

  final BookingController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyB): controller.pickBestAvailable,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          for (final seat in [...controller.selectedSeats]) {
            controller.toggleSeat(seat);
          }
        },
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}

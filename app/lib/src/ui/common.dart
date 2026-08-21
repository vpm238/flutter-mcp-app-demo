/// Bits every persona needs: date formatting, the show hero, demand dots, and
/// the persona switcher that makes this demo showable on a laptop.
library;

import 'package:flutter/material.dart';

import '../model.dart';
import '../theme.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _weekdaysLong = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
];
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
const _monthsLong = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String weekdayShort(DateTime d) => _weekdays[d.weekday - 1];
String weekdayLong(DateTime d) => _weekdaysLong[d.weekday - 1];
String monthShort(DateTime d) => _months[d.month - 1];
String monthLong(DateTime d) => _monthsLong[d.month - 1];

String timeLabel(DateTime d) {
  final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final minute = d.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${d.hour < 12 ? 'AM' : 'PM'}';
}

String dayLabel(DateTime d, {bool withWeekday = true}) =>
    '${withWeekday ? '${weekdayShort(d)} ' : ''}${monthShort(d)} ${d.day}';

String relativeDayLabel(DateTime d, {DateTime? now}) {
  final today = _midnight(now ?? DateTime.now());
  final diff = _midnight(d).difference(today).inDays;
  return switch (diff) {
    0 => 'Today',
    1 => 'Tomorrow',
    _ => dayLabel(d),
  };
}

DateTime _midnight(DateTime d) => DateTime(d.year, d.month, d.day);

bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Three dots that fill up as a performance sells out. Cheap, readable, and it
/// gives the time list a reason to exist beyond a row of numbers.
class DemandDots extends StatelessWidget {
  const DemandDots({super.key, required this.slot, this.color});

  final Slot slot;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    final filled = switch (slot.demand) {
      Demand.low => 1,
      Demand.medium => 2,
      Demand.high => 3,
      Demand.soldOut => 0,
    };
    final tint = color ??
        switch (slot.demand) {
          Demand.low => palette.success,
          Demand.medium => palette.accent,
          Demand.high => palette.danger,
          Demand.soldOut => palette.textTertiary,
        };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++)
          Padding(
            padding: const EdgeInsets.only(right: 2.5),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < filled ? tint : palette.textTertiary.withValues(alpha: 0.25),
              ),
            ),
          ),
      ],
    );
  }
}

/// The show hero: a gradient plate with the title, venue, and runtime.
class ShowHero extends StatelessWidget {
  const ShowHero({
    super.key,
    required this.show,
    this.height = 132,
    this.borderRadius = 16,
    this.dense = false,
  });

  final Show show;
  final double height;
  final double borderRadius;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [show.accentDeep, show.accent],
          ),
        ),
        child: Stack(
          children: [
            // A house-light glow behind the title.
            Positioned(
              right: -40,
              top: -60,
              child: Container(
                width: 190,
                height: 190,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Colors.white.withValues(alpha: 0.28),
                      Colors.white.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(dense ? 13 : 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Flexible(
                    child: Text(
                      show.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        color: Colors.white,
                        fontSize: dense ? 19 : 25,
                        height: 1.14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${show.venue} · ${show.city}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: dense ? 11.5 : 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  // Pills need a band of their own; drop them in tight heroes
                  // rather than letting the title lose a line.
                  if (height >= 124) ...[
                    const SizedBox(height: 9),
                    Row(
                      children: [
                        _HeroPill(text: show.runtimeLabel),
                        const SizedBox(width: 7),
                        _HeroPill(text: show.rating),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: 'Inter',
          color: Colors.white,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Lets a laptop viewer force a persona, so the adaptive behaviour is
/// demonstrable without three devices on the desk.
class PersonaSwitcher extends StatelessWidget {
  const PersonaSwitcher({
    super.key,
    required this.value,
    required this.detected,
    required this.onChanged,
    this.dense = false,
  });

  /// null means "follow the browser".
  final Persona? value;
  final Persona detected;
  final ValueChanged<Persona?> onChanged;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    final options = <(String, Persona?)>[
      ('Auto', null),
      ('iOS', Persona.ios),
      ('Android', Persona.android),
      ('Desktop', Persona.desktop),
    ];

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: palette.surfaceAlt,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (label, persona) in options)
            _SwitchChip(
              // On a phone the row has no room for the detected-platform note.
              label: label == 'Auto' && !dense ? 'Auto · ${detected.label}' : label,
              selected: value == persona,
              dense: dense,
              onTap: () => onChanged(persona),
            ),
        ],
      ),
    );
  }
}

class _SwitchChip extends StatelessWidget {
  const _SwitchChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.dense,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Preview as $label',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            padding: EdgeInsets.symmetric(horizontal: dense ? 9 : 12, vertical: dense ? 4 : 6),
            decoration: BoxDecoration(
              color: selected ? palette.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
              boxShadow: selected
                  ? const [BoxShadow(blurRadius: 4, color: Color(0x14000000))]
                  : null,
            ),
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: dense ? 11.5 : 12.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? palette.textPrimary : palette.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small caption that tells you whether the data is coming over MCP.
class SourceBadge extends StatelessWidget {
  const SourceBadge({super.key, required this.live, this.hostName});

  final bool live;
  final String? hostName;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    final label = live ? 'Live · ${hostName ?? 'MCP host'}' : 'Standalone fixtures';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: live ? palette.success : palette.textTertiary,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: palette.textTertiary,
          ),
        ),
      ],
    );
  }
}

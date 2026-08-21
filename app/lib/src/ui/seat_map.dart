/// The seat map: one geometry, one painter, three visual dialects.
///
/// The personas differ in corner radius, seat gap, selection affordance, and
/// whether hover exists at all — but the house, the hit testing, and the
/// curvature are shared. That is the point of the demo: platform feel is a
/// skin over one implementation, not three implementations.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../booking_controller.dart';
import '../model.dart';
import '../theme.dart';

/// Per-persona seat drawing rules.
class SeatMapStyle {
  const SeatMapStyle({
    required this.radius,
    required this.gap,
    required this.rowGap,
    required this.selectedMark,
    required this.showHover,
    required this.curvature,
  });

  final double radius;
  final double gap;
  final double rowGap;

  /// What a chosen seat shows: a tick (iOS), a filled dot (Android), or its
  /// seat number (desktop, where there is room and precision matters).
  final SelectedMark selectedMark;
  final bool showHover;
  final double curvature;

  factory SeatMapStyle.forPersona(Persona persona) => switch (persona) {
        Persona.ios => const SeatMapStyle(
            radius: 5,
            gap: 5,
            rowGap: 9,
            selectedMark: SelectedMark.tick,
            showHover: false,
            curvature: 26,
          ),
        Persona.android => const SeatMapStyle(
            radius: 7,
            gap: 5,
            rowGap: 9,
            selectedMark: SelectedMark.dot,
            showHover: false,
            curvature: 26,
          ),
        Persona.desktop => const SeatMapStyle(
            radius: 3.5,
            gap: 4,
            rowGap: 7,
            selectedMark: SelectedMark.number,
            showHover: true,
            curvature: 30,
          ),
      };
}

enum SelectedMark { tick, dot, number }

/// Where every seat sits, given a box to fit into.
class SeatGeometry {
  SeatGeometry._({
    required this.seat,
    required this.gap,
    required this.rowGap,
    required this.aisleGap,
    required this.labelGutter,
    required this.stageHeight,
    required this.curvature,
    required this.rowCount,
    required this.colCount,
    required this.aislesAfter,
  });

  final double seat;
  final double gap;
  final double rowGap;
  final double aisleGap;
  final double labelGutter;
  final double stageHeight;
  final double curvature;
  final int rowCount;
  final int colCount;
  final List<int> aislesAfter;

  /// Fit the house into [maxWidth] x [maxHeight] without cropping.
  factory SeatGeometry.fit({
    required double maxWidth,
    required double maxHeight,
    required int rowCount,
    required int colCount,
    required List<int> aislesAfter,
    required SeatMapStyle style,
  }) {
    const labelGutter = 22.0;
    final aisleCount = aislesAfter.length;

    // Solve for the seat size that fills the width, then clamp by the height.
    double widthFor(double seat) {
      final aisleGap = seat * 0.85;
      return labelGutter * 2 +
          colCount * seat +
          (colCount - 1) * style.gap +
          aisleCount * aisleGap;
    }

    var seat = 26.0;
    // widthFor is linear in seat, so one solve is exact.
    final unit = widthFor(1.0);
    seat = (maxWidth - (colCount - 1) * style.gap - labelGutter * 2) /
        (unit - (colCount - 1) * style.gap - labelGutter * 2);

    final stageHeight = math.max(34.0, math.min(56.0, maxHeight * 0.11));
    final heightBudget = maxHeight - stageHeight - 12;
    final maxSeatByHeight =
        (heightBudget - (rowCount - 1) * style.rowGap - style.curvature) /
            rowCount;

    seat = math.max(9.0, math.min(seat, math.max(9.0, maxSeatByHeight)));

    // A house is wider than it is deep, so seat size is almost always decided
    // by the width — which leaves a band of empty space above and below on a
    // tall phone. Spread the rows into it instead, up to the point where the
    // gaps would stop reading as a seating plan.
    var rowGap = style.rowGap;
    final natural =
        rowCount * seat + (rowCount - 1) * rowGap + style.curvature;
    if (heightBudget.isFinite && heightBudget > natural && rowCount > 1) {
      final spare = (heightBudget - natural) / (rowCount - 1);
      rowGap = math.min(rowGap + spare, seat * 1.4);
    }

    return SeatGeometry._(
      seat: seat,
      gap: style.gap,
      rowGap: rowGap,
      aisleGap: seat * 0.85,
      labelGutter: labelGutter,
      stageHeight: stageHeight,
      curvature: style.curvature * (seat / 26).clamp(0.45, 1.2),
      rowCount: rowCount,
      colCount: colCount,
      aislesAfter: aislesAfter,
    );
  }

  double get width =>
      labelGutter * 2 +
      colCount * seat +
      (colCount - 1) * gap +
      aislesAfter.length * aisleGap;

  double get height =>
      stageHeight + 12 + rowCount * seat + (rowCount - 1) * rowGap + curvature;

  double xFor(int col) {
    final aislesBefore = aislesAfter.where((a) => a < col).length;
    return labelGutter + col * (seat + gap) + aislesBefore * aisleGap;
  }

  /// Rows arc around the stage, so the outer seats sit closer to it.
  double _arc(int col) {
    final centre = (colCount - 1) / 2;
    final t = centre == 0 ? 0.0 : (col - centre) / centre;
    return -curvature * t * t;
  }

  double yFor(int row, int col) =>
      stageHeight + 12 + curvature + row * (seat + rowGap) + _arc(col);

  Rect rectFor(int row, int col) =>
      Rect.fromLTWH(xFor(col), yFor(row, col), seat, seat);
}

/// A tappable, hoverable, pinch-zoomable seat map.
class SeatMapView extends StatefulWidget {
  const SeatMapView({
    super.key,
    required this.map,
    required this.controller,
    required this.style,
    this.zoomable = true,
    this.onSeatTapped,
  });

  final SeatMap map;
  final BookingController controller;
  final SeatMapStyle style;
  final bool zoomable;
  final ValueChanged<Seat>? onSeatTapped;

  @override
  State<SeatMapView> createState() => _SeatMapViewState();
}

class _SeatMapViewState extends State<SeatMapView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  final TransformationController _view = TransformationController();

  Seat? _hovered;
  Seat? _popped;
  Offset? _cursor;

  @override
  void dispose() {
    _pop.dispose();
    _view.dispose();
    super.dispose();
  }

  Seat? _hitTest(Offset local, SeatGeometry geo) {
    for (var r = 0; r < widget.map.rows.length; r++) {
      final row = widget.map.rows[r];
      for (final seat in row.seats) {
        // Grow the target a little: fingers are wider than seats.
        if (geo.rectFor(r, seat.col).inflate(geo.gap / 2).contains(local)) {
          return seat;
        }
      }
    }
    return null;
  }

  void _handleTap(Offset local, SeatGeometry geo) {
    final seat = _hitTest(local, geo);
    if (seat == null || !seat.bookable) return;
    HapticFeedback.selectionClick();
    setState(() => _popped = seat);
    _pop.forward(from: 0);
    widget.controller.toggleSeat(seat);
    widget.onSeatTapped?.call(seat);
  }

  @override
  Widget build(BuildContext context) {
    final skin = Skin.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final geo = SeatGeometry.fit(
          maxWidth: constraints.maxWidth,
          maxHeight: constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : constraints.maxWidth * 0.85,
          rowCount: widget.map.rows.length,
          colCount: widget.map.seatsPerRow,
          aislesAfter: widget.map.aislesAfter,
          style: widget.style,
        );

        Widget canvas = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _handleTap(details.localPosition, geo),
          child: AnimatedBuilder(
            animation: Listenable.merge([_pop, widget.controller]),
            builder: (context, _) => CustomPaint(
              size: Size(geo.width, geo.height),
              painter: _SeatMapPainter(
                map: widget.map,
                controller: widget.controller,
                geo: geo,
                style: widget.style,
                palette: skin.palette,
                hovered: _hovered,
                popped: _popped,
                popValue: Curves.easeOutBack.transform(_pop.value),
              ),
            ),
          ),
        );

        if (widget.style.showHover) {
          canvas = MouseRegion(
            onHover: (event) {
              final seat = _hitTest(event.localPosition, geo);
              if (seat?.id != _hovered?.id || _cursor != event.localPosition) {
                setState(() {
                  _hovered = seat;
                  _cursor = event.localPosition;
                });
              }
            },
            onExit: (_) => setState(() {
              _hovered = null;
              _cursor = null;
            }),
            cursor: _hovered?.bookable == true
                ? SystemMouseCursors.click
                : MouseCursor.defer,
            child: canvas,
          );
        }

        final sized = SizedBox(width: geo.width, height: geo.height, child: canvas);

        return Center(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (widget.zoomable)
                InteractiveViewer(
                  transformationController: _view,
                  minScale: 1,
                  maxScale: 3.5,
                  clipBehavior: Clip.none,
                  child: sized,
                )
              else
                sized,
              if (_hovered != null && _cursor != null)
                _SeatTooltip(
                  seat: _hovered!,
                  map: widget.map,
                  at: _cursor!,
                  bounds: Size(geo.width, geo.height),
                  currency: skin.currency,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _SeatTooltip extends StatelessWidget {
  const _SeatTooltip({
    required this.seat,
    required this.map,
    required this.at,
    required this.bounds,
    required this.currency,
  });

  final Seat seat;
  final SeatMap map;
  final Offset at;
  final Size bounds;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    final tier = map.tierFor(seat);
    const width = 168.0;
    final left = (at.dx - width / 2).clamp(0.0, math.max(0.0, bounds.width - width)).toDouble();

    return Positioned(
      left: left,
      top: at.dy - 62,
      child: IgnorePointer(
        child: Container(
          width: width,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: palette.isDark ? const Color(0xFF111110) : const Color(0xFF23221F),
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [
              BoxShadow(blurRadius: 16, color: Color(0x33000000), offset: Offset(0, 4)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Row ${seat.row}, seat ${seat.number}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(color: tier.color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      seat.bookable
                          ? '${tier.name} · ${formatMoney(tier.priceCents, currency: currency)}'
                          : 'Taken',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFFBFBDB6), fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SeatMapPainter extends CustomPainter {
  _SeatMapPainter({
    required this.map,
    required this.controller,
    required this.geo,
    required this.style,
    required this.palette,
    required this.hovered,
    required this.popped,
    required this.popValue,
  });

  final SeatMap map;
  final BookingController controller;
  final SeatGeometry geo;
  final SeatMapStyle style;
  final Palette palette;
  final Seat? hovered;
  final Seat? popped;
  final double popValue;

  @override
  void paint(Canvas canvas, Size size) {
    _paintStage(canvas, size);

    final selected = {for (final s in controller.selectedSeats) s.id};

    for (var r = 0; r < map.rows.length; r++) {
      final row = map.rows[r];
      _paintRowLabel(canvas, r, row.label);
      for (final seat in row.seats) {
        _paintSeat(canvas, r, seat, selected.contains(seat.id));
      }
    }
  }

  void _paintStage(Canvas canvas, Size size) {
    final left = geo.labelGutter + geo.seat * 1.2;
    final right = size.width - geo.labelGutter - geo.seat * 1.2;
    final y = geo.stageHeight;

    final path = Path()
      ..moveTo(left, y)
      ..quadraticBezierTo(size.width / 2, y - geo.stageHeight * 0.85, right, y);

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [
            palette.border,
            palette.textTertiary,
            palette.border,
          ],
        ).createShader(Rect.fromLTWH(left, 0, right - left, y)),
    );

    // A soft wash under the arc, so the stage reads as a light source.
    canvas.drawPath(
      Path.from(path)
        ..lineTo(right, y + geo.stageHeight * 0.9)
        ..lineTo(left, y + geo.stageHeight * 0.9)
        ..close(),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            palette.textTertiary.withValues(alpha: palette.isDark ? 0.16 : 0.09),
            palette.textTertiary.withValues(alpha: 0),
          ],
        ).createShader(
            Rect.fromLTWH(left, y - 6, right - left, geo.stageHeight * 0.9)),
    );

    _text(
      canvas,
      'S T A G E',
      Offset(0, y - geo.stageHeight * 0.72),
      width: size.width,
      align: TextAlign.center,
      style: TextStyle(
        fontSize: math.max(8, geo.seat * 0.42),
        fontWeight: FontWeight.w600,
        letterSpacing: 1.4,
        color: palette.textTertiary,
      ),
    );
  }

  void _paintRowLabel(Canvas canvas, int rowIndex, String label) {
    final style = TextStyle(
      fontSize: math.max(7.5, geo.seat * 0.46),
      fontWeight: FontWeight.w600,
      color: palette.textTertiary,
    );
    final y = geo.yFor(rowIndex, 0) + geo.seat * 0.22;
    _text(canvas, label, Offset(0, y),
        width: geo.labelGutter - 4, align: TextAlign.right, style: style);
    _text(
      canvas,
      label,
      Offset(geo.width - geo.labelGutter + 4, geo.yFor(rowIndex, geo.colCount - 1) + geo.seat * 0.22),
      width: geo.labelGutter - 4,
      align: TextAlign.left,
      style: style,
    );
  }

  void _paintSeat(Canvas canvas, int rowIndex, Seat seat, bool isSelected) {
    var rect = geo.rectFor(rowIndex, seat.col);
    final tier = map.tierFor(seat);

    if (popped?.id == seat.id && popValue < 1) {
      final scale = 1 + 0.22 * (1 - popValue);
      rect = Rect.fromCenter(
        center: rect.center,
        width: rect.width * scale,
        height: rect.height * scale,
      );
    }

    final rrect = RRect.fromRectAndCorners(
      rect,
      topLeft: Radius.circular(style.radius),
      topRight: Radius.circular(style.radius),
      bottomLeft: Radius.circular(style.radius * 0.55),
      bottomRight: Radius.circular(style.radius * 0.55),
    );

    if (isSelected) {
      canvas.drawRRect(
        rrect.inflate(2.5),
        Paint()..color = tier.color.withValues(alpha: 0.28),
      );
      canvas.drawRRect(rrect, Paint()..color = tier.color);
      _paintSelectedMark(canvas, rect, seat);
      return;
    }

    switch (seat.status) {
      case SeatStatus.available:
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = tier.color
                .withValues(alpha: palette.isDark ? 0.26 : 0.18),
        );
        canvas.drawRRect(
          rrect.deflate(0.5),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = tier.color.withValues(alpha: palette.isDark ? 0.55 : 0.45),
        );
      case SeatStatus.taken:
      case SeatStatus.held:
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = palette.textTertiary
                .withValues(alpha: palette.isDark ? 0.16 : 0.14),
        );
    }

    if (hovered?.id == seat.id && seat.bookable) {
      canvas.drawRRect(
        rrect.inflate(2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = palette.textPrimary.withValues(alpha: 0.7),
      );
    }
  }

  void _paintSelectedMark(Canvas canvas, Rect rect, Seat seat) {
    switch (style.selectedMark) {
      case SelectedMark.tick:
        final p = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.4, rect.width * 0.11)
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = Colors.white;
        final w = rect.width;
        canvas.drawPath(
          Path()
            ..moveTo(rect.left + w * 0.26, rect.top + w * 0.52)
            ..lineTo(rect.left + w * 0.44, rect.top + w * 0.70)
            ..lineTo(rect.left + w * 0.75, rect.top + w * 0.32),
          p,
        );
      case SelectedMark.dot:
        canvas.drawCircle(
          rect.center,
          rect.width * 0.19,
          Paint()..color = Colors.white,
        );
      case SelectedMark.number:
        if (rect.width < 14) {
          canvas.drawCircle(
              rect.center, rect.width * 0.19, Paint()..color = Colors.white);
          return;
        }
        _text(
          canvas,
          '${seat.number}',
          Offset(rect.left, rect.top + rect.height * 0.22),
          width: rect.width,
          align: TextAlign.center,
          style: TextStyle(
            fontSize: rect.width * 0.5,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        );
    }
  }

  void _text(
    Canvas canvas,
    String text,
    Offset at, {
    required double width,
    required TextAlign align,
    required TextStyle style,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout(minWidth: width, maxWidth: width);
    painter.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_SeatMapPainter old) =>
      old.map != map ||
      old.hovered?.id != hovered?.id ||
      old.popped?.id != popped?.id ||
      old.popValue != popValue ||
      old.palette != palette ||
      old.controller.selectedSeats.length != controller.selectedSeats.length ||
      !_sameSelection(old.controller.selectedSeats, controller.selectedSeats);

  static bool _sameSelection(List<Seat> a, List<Seat> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }
}

/// The price-band key that sits under every seat map.
class SeatLegend extends StatelessWidget {
  const SeatLegend({super.key, required this.map, this.compact = false});

  final SeatMap map;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final skin = Skin.of(context);
    return Wrap(
      spacing: compact ? 12 : 18,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        for (final tier in map.tiers)
          _LegendChip(
            color: tier.color,
            label: compact
                ? formatMoney(tier.priceCents, currency: skin.currency)
                : '${tier.name} · ${formatMoney(tier.priceCents, currency: skin.currency)}',
          ),
        _LegendChip(
          color: skin.palette.textTertiary.withValues(alpha: 0.3),
          label: 'Taken',
        ),
      ],
    );
  }
}

class _LegendChip extends StatelessWidget {
  const _LegendChip({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: palette.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

/// What to show when the host's panel is too small to hold the app.
///
/// Claude on Android gives an inline view a 411x100 frame and does not act on
/// `ui/notifications/size-changed`, so a view cannot grow itself out of it.
/// Laying the real UI out in that strip puts every control off-screen: the
/// panel looks dead and taps land on nothing.
///
/// A strip that size can hold exactly one idea, so this is one line of context
/// and one target. Pressing it asks the host for fullscreen, which is the only
/// route to a usable size on such a host — and the ask is now something the
/// user initiated, which matters because a host may honour it by re-creating
/// the frame and restarting the app.
library;

import 'package:flutter/material.dart';

import '../booking_controller.dart';
import '../theme.dart';

class StubCard extends StatelessWidget {
  const StubCard({
    super.key,
    required this.controller,
    required this.canExpand,
    required this.onExpand,
  });

  final BookingController controller;
  final bool canExpand;
  final Future<void> Function() onExpand;

  @override
  Widget build(BuildContext context) {
    final palette = Skin.of(context).palette;
    final show = controller.show;

    return Material(
      color: palette.background,
      child: InkWell(
        onTap: canExpand ? () => onExpand() : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: show?.accent ?? palette.accent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(
                  Icons.local_activity_rounded,
                  size: 19,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      show?.title ?? 'Choose your seats',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: palette.textPrimary,
                      ),
                    ),
                    Text(
                      canExpand
                          ? 'Tap to pick a date, time and seats'
                          : 'This panel is too small to show the picker',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: palette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (canExpand) ...[
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => onExpand(),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: const Text('Open'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

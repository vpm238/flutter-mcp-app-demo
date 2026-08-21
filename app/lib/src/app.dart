/// The root: connects the controller to a persona, adopts the host theme, and
/// keeps the iframe sized.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'booking_controller.dart';
import 'data/data_source.dart';
import 'mcp/bridge.dart';
import 'theme.dart';
import 'ui/android_shell.dart';
import 'ui/common.dart';
import 'ui/desktop_shell.dart';
import 'ui/ios_shell.dart';

class ShowtimeApp extends StatefulWidget {
  const ShowtimeApp({
    super.key,
    required this.host,
    required this.box,
    this.initialPersona,
    this.showId,
    this.showChrome = true,
  });

  final McpHost host;
  final BoxOffice box;

  /// Forced persona, from `?persona=` — used by screenshot runs and the docs.
  final Persona? initialPersona;
  final String? showId;

  /// The demo strip (persona switcher + connection badge).
  final bool showChrome;

  @override
  State<ShowtimeApp> createState() => _ShowtimeAppState();
}

class _ShowtimeAppState extends State<ShowtimeApp> {
  late final BookingController _controller;
  late HostContext _hostContext;
  StreamSubscription<HostContext>? _contextSub;
  StreamSubscription<Map<String, dynamic>>? _resultSub;

  Persona? _override;

  @override
  void initState() {
    super.initState();
    _override = widget.initialPersona;
    _hostContext = widget.host.context;
    _controller = BookingController(
      box: widget.box,
      host: widget.host.isHosted ? widget.host : null,
    );
    _controller.load(showId: widget.showId);

    _contextSub = widget.host.onContextChanged.listen((context) {
      setState(() => _hostContext = context);
    });

    // The model can steer the open view: "actually, make it Saturday".
    _resultSub = widget.host.onToolResult.listen((_) {
      _controller.load(showId: widget.showId);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _reportSize());
  }

  @override
  void dispose() {
    _contextSub?.cancel();
    _resultSub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// The host's answer where it has one, the browser's otherwise — see
  /// `personaFor`. A chat client's webview lies about the device it is in.
  Persona get _detected => personaFor(widget.host.isHosted ? _hostContext : null);

  Persona get _persona => _override ?? _detected;

  /// Ask the host for a frame the layout actually fits in — and no more.
  ///
  /// A host is not obliged to grant a size request, and a chat client will not
  /// grow a conversation slot without limit. Asking for 660 when the host has
  /// already said it has 420 does not produce 660; it produces 420 with the
  /// bottom sliced off. So ask for what this layout needs, then clamp to what
  /// the host said it had.
  void _reportSize() {
    if (!widget.host.isHosted) return;
    final width = MediaQuery.maybeSizeOf(context)?.width ?? 900;
    final wanted = switch (_layout) {
      Fit.roomy => 660.0,
      Fit.compact => 780.0,
    };
    final cap = _hostContext.maxHeight;
    widget.host.setSize(width, cap == null ? wanted : math.min(wanted, cap));
  }

  /// What the host gave us, or the space we want if it has not said.
  Fit get _layout {
    final size = MediaQuery.maybeSizeOf(context);
    if (size != null) return fitFor(size);
    final cap = _hostContext.maxHeight;
    return cap != null && cap < kRoomyMinimum.height ? Fit.compact : Fit.roomy;
  }

  /// Take the whole screen, and wait for the host to actually give it.
  ///
  /// The host resizes the frame in response, which changes MediaQuery — so a
  /// sheet opened in the same frame would still be laid out against the old
  /// size. One frame of settling is the difference between a seat map you can
  /// see and one positioned below the visible panel.
  Future<void> _goFullscreen() async {
    if (!widget.host.isHosted) return;
    final before = MediaQuery.maybeSizeOf(context);
    widget.host.beacon('make-room',
        'mode=${_hostContext.displayMode} can=${_hostContext.canGoFullscreen} '
        'size=${before?.width.round()}x${before?.height.round()}');
    if (_hostContext.displayMode == 'fullscreen') return;
    if (!_hostContext.canGoFullscreen) return;
    // A host that advertises fullscreen and then does not answer would
    // otherwise hold the sheet closed until the request times out. Waiting is
    // an optimisation; opening is the job.
    final granted = await widget.host
        .requestDisplayMode('fullscreen')
        .timeout(const Duration(milliseconds: 1200), onTimeout: () => 'timeout');

    // Wait for the resize the host performs in response, rather than a fixed
    // delay: on a real device the round trip is slower than any number I would
    // have guessed, and a sheet opened before it lands is sized to the old
    // frame.
    final start = DateTime.now();
    while (DateTime.now().difference(start) < const Duration(seconds: 2)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
      final now = MediaQuery.maybeSizeOf(context);
      if (before == null || now == null || now.height != before.height) break;
    }
    if (!mounted) return;
    final after = MediaQuery.maybeSizeOf(context);
    widget.host.beacon('room-granted',
        'granted=$granted size=${after?.width.round()}x${after?.height.round()}');
  }

  void _setPersona(Persona? persona) {
    setState(() => _override = persona);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportSize());
  }

  @override
  Widget build(BuildContext context) {
    final palette = Palette.fromHost(_hostContext).copyWith(
      accent: _controller.show?.accent,
      onAccent: Colors.white,
    );
    final persona = _persona;

    return Skin(
      persona: persona,
      palette: palette,
      currency: _controller.currency,
      fit: _layout,
      requestRoom: _goFullscreen,
      trace: widget.host.beacon,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Showtime',
        theme: materialTheme(palette, persona),
        home: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => BookingShortcuts(
            controller: _controller,
            child: _body(context, persona),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, Persona persona) {
    if (_controller.phase == Phase.loading) {
      return Scaffold(
        backgroundColor: Skin.of(context).palette.background,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_controller.phase == Phase.confirmed) {
      return switch (persona) {
        Persona.ios => IosConfirmation(controller: _controller),
        Persona.android => AndroidConfirmation(controller: _controller),
        Persona.desktop => DesktopConfirmation(controller: _controller),
      };
    }

    // The persona switcher is a demo affordance, and on a phone-sized panel it
    // costs a fifth of the visible height to show four chips, three of which
    // are wrong for the device in your hand. Inside a host, at that size, the
    // detected persona is the point — so spend the room on the app.
    final showSwitcher =
        widget.showChrome && !(_layout == Fit.compact && widget.host.isHosted);
    final header = showSwitcher ? _chrome(context, persona) : null;

    // The desktop *shell* is a layout, not a design language. In a slot too
    // small for it, a desktop persona gets the single-column layout — still
    // Material, still pointer-first, but it fits instead of clipping.
    return switch (persona) {
      Persona.ios => IosShell(controller: _controller, header: header),
      Persona.android => AndroidShell(controller: _controller, header: header),
      Persona.desktop => _layout == Fit.roomy
          ? DesktopShell(controller: _controller, header: header)
          : AndroidShell(controller: _controller, header: header),
    };
  }

  Widget _chrome(BuildContext context, Persona persona) {
    final palette = Skin.of(context).palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: palette.background,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: PersonaSwitcher(
                  value: _override,
                  detected: _detected,
                  onChanged: _setPersona,
                  dense: persona != Persona.desktop,
                ),
              ),
            ),
            const SizedBox(width: 10),
            if (widget.host.isHosted && _hostContext.canGoFullscreen)
              IconButton(
                tooltip: _hostContext.displayMode == 'fullscreen'
                    ? 'Back to inline'
                    : 'Expand',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  final next = _hostContext.displayMode == 'fullscreen'
                      ? 'inline'
                      : 'fullscreen';
                  final mode = await widget.host.requestDisplayMode(next);
                  if (!mounted) return;
                  setState(() => _hostContext =
                      _hostContext.merge({'displayMode': mode}));
                },
                icon: Icon(
                  _hostContext.displayMode == 'fullscreen'
                      ? Icons.close_fullscreen_rounded
                      : Icons.open_in_full_rounded,
                  color: palette.textSecondary,
                ),
              ),
            SourceBadge(
              live: widget.box.isLive,
              hostName: _hostContext.hostName,
            ),
          ],
        ),
      ),
    );
  }
}

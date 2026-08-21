/// The root: connects the controller to a persona, adopts the host theme, and
/// keeps the iframe sized.
library;

import 'dart:async';

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

  Persona get _persona => _override ?? detectPersona();

  /// Ask the host for a frame tall enough for this persona's layout.
  void _reportSize() {
    if (!widget.host.isHosted) return;
    final width = MediaQuery.maybeSizeOf(context)?.width ?? 900;
    final height = switch (_persona) {
      Persona.desktop => 660.0,
      _ => 780.0,
    };
    widget.host.setSize(width, height);
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

    final header = widget.showChrome ? _chrome(context, persona) : null;

    return switch (persona) {
      Persona.ios => IosShell(controller: _controller, header: header),
      Persona.android => AndroidShell(controller: _controller, header: header),
      Persona.desktop => DesktopShell(controller: _controller, header: header),
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
                  detected: detectPersona(),
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

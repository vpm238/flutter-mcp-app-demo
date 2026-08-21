/// Showtime — an MCP App view, built with Flutter web.
///
/// Boots in two modes without changing a line:
///
/// * **Hosted** — `showtimeBridge` is on the page, so we speak MCP Apps to the
///   host and call tools back on the server.
/// * **Standalone** — no bridge, so the same UI runs off local fixtures. Handy
///   for opening the deployed URL directly in a phone browser.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'src/app.dart';
import 'src/data/data_source.dart';
import 'src/mcp/bridge.dart';
import 'src/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The host renders views in a sandboxed frame with an opaque origin, where
  // touching the History API throws a SecurityError. Nothing here routes, so
  // drop the URL strategy entirely rather than let the engine reach for it.
  if (kIsWeb) setUrlStrategy(null);

  final host = await McpHost.connect();
  final box = host.isHosted ? McpBoxOffice(host) : LocalBoxOffice();

  final query = Uri.base.queryParameters;
  runApp(ShowtimeApp(
    host: host,
    box: box,
    initialPersona: _personaFrom(query['persona']),
    showId: query['show'],
    showChrome: query['chrome'] != 'off',
  ));
}

Persona? _personaFrom(String? value) => switch (value) {
      'ios' => Persona.ios,
      'android' => Persona.android,
      'desktop' => Persona.desktop,
      _ => null,
    };

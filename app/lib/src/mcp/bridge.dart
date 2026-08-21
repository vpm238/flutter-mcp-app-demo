/// Dart side of the MCP Apps bridge.
///
/// The protocol work lives in `bridge/src/bridge.ts`, which wraps the official
/// `@modelcontextprotocol/ext-apps` `App` class and hangs a small JSON-only
/// surface off `globalThis.showtimeBridge`. This file turns that surface into
/// ordinary Dart: futures, streams, and a context object.
///
/// When there is no bridge — the app opened as a plain web page, or a test is
/// running on the VM — [McpHost.connect] returns an instance with
/// [McpHost.isHosted] false and every call becomes a no-op, so callers can fall
/// back to local fixtures without branching on the platform.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/painting.dart' show EdgeInsets;

import 'raw_bridge.dart';

/// What the host told us about itself.
class HostContext {
  const HostContext({
    this.theme = 'light',
    this.styles = const {},
    this.displayMode = 'inline',
    this.availableDisplayModes = const ['inline'],
    this.maxHeight,
    this.hostName,
    this.hostPlatform,
    this.hostUserAgent,
    this.navigatorUserAgent,
    this.touch,
    this.hover,
    this.pointerCoarse,
    this.hoverNone,
    this.maxTouchPoints,
    this.screenWidth,
    this.safeAreaInsets = EdgeInsets.zero,
  });

  /// `light` or `dark`, as reported by the host.
  final String theme;

  /// Host CSS custom properties (`--color-text-primary` and friends). We map
  /// the handful we care about onto Flutter colours so the view sits inside
  /// the conversation rather than on top of it.
  final Map<String, String> styles;

  final String displayMode;
  final List<String> availableDisplayModes;
  final double? maxHeight;
  final String? hostName;

  /// `web`, `desktop` or `mobile`, straight from the host.
  ///
  /// Flutter web derives `defaultTargetPlatform` from the user agent, which is
  /// correct in a browser and wrong inside a chat client's webview: the UA
  /// describes the webview, not the phone around it. So a view opened in
  /// Claude on an iPhone can look like a desktop. The host already knows, and
  /// the protocol carries the answer.
  final String? hostPlatform;

  /// The host application's own identifier — what tells iOS from Android when
  /// `hostPlatform` only says `mobile`.
  final String? hostUserAgent;

  /// The browser's user agent, kept as the last resort.
  final String? navigatorUserAgent;

  final bool? touch;
  final bool? hover;

  /// What the browser knows about the input device, which no host has to send
  /// and no user agent can misreport. A phone answers coarse/none whatever its
  /// webview claims to be; an iPad reports itself as a Macintosh and is only
  /// distinguishable from a laptop by these.
  final bool? pointerCoarse;
  final bool? hoverNone;
  final int? maxTouchPoints;
  final int? screenWidth;

  /// Notch and home-indicator margins, when the host reports them.
  final EdgeInsets safeAreaInsets;

  bool get isDark => theme == 'dark';
  bool get canGoFullscreen => availableDisplayModes.contains('fullscreen');

  static HostContext fromJson(Map<String, dynamic> j) => HostContext(
        theme: j['theme'] as String? ?? 'light',
        styles:
            ((j['styles'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')),
        displayMode: j['displayMode'] as String? ?? 'inline',
        availableDisplayModes:
            ((j['availableDisplayModes'] as List?) ?? const ['inline'])
                .map((e) => '$e')
                .toList(),
        maxHeight: (j['maxHeight'] as num?)?.toDouble(),
        hostName: j['hostName'] as String?,
        hostPlatform: j['hostPlatform'] as String?,
        hostUserAgent: j['hostUserAgent'] as String?,
        navigatorUserAgent: j['navigatorUserAgent'] as String?,
        touch: j['touch'] as bool?,
        hover: j['hover'] as bool?,
        pointerCoarse: j['pointerCoarse'] as bool?,
        hoverNone: j['hoverNone'] as bool?,
        maxTouchPoints: (j['maxTouchPoints'] as num?)?.toInt(),
        screenWidth: (j['screenWidth'] as num?)?.toInt(),
        safeAreaInsets: _insets(j['safeAreaInsets']),
      );

  static EdgeInsets _insets(Object? raw) {
    if (raw is! Map) return EdgeInsets.zero;
    double side(String key) => (raw[key] as num?)?.toDouble() ?? 0;
    return EdgeInsets.fromLTRB(
      side('left'),
      side('top'),
      side('right'),
      side('bottom'),
    );
  }

  HostContext merge(Map<String, dynamic> patch) => HostContext(
        theme: patch['theme'] as String? ?? theme,
        styles: patch['styles'] == null
            ? styles
            : (patch['styles'] as Map).map((k, v) => MapEntry('$k', '$v')),
        displayMode: patch['displayMode'] as String? ?? displayMode,
        availableDisplayModes:
            (patch['availableDisplayModes'] as List?)?.map((e) => '$e').toList() ??
                availableDisplayModes,
        maxHeight: (patch['maxHeight'] as num?)?.toDouble() ?? maxHeight,
        hostName: patch['hostName'] as String? ?? hostName,
        hostPlatform: patch['hostPlatform'] as String? ?? hostPlatform,
        hostUserAgent: patch['hostUserAgent'] as String? ?? hostUserAgent,
        navigatorUserAgent:
            patch['navigatorUserAgent'] as String? ?? navigatorUserAgent,
        touch: patch['touch'] as bool? ?? touch,
        hover: patch['hover'] as bool? ?? hover,
        pointerCoarse: patch['pointerCoarse'] as bool? ?? pointerCoarse,
        hoverNone: patch['hoverNone'] as bool? ?? hoverNone,
        maxTouchPoints:
            (patch['maxTouchPoints'] as num?)?.toInt() ?? maxTouchPoints,
        screenWidth: (patch['screenWidth'] as num?)?.toInt() ?? screenWidth,
        safeAreaInsets: patch['safeAreaInsets'] == null
            ? safeAreaInsets
            : _insets(patch['safeAreaInsets']),
      );
}

/// Thrown when a tool call comes back as an MCP error result.
class ToolCallException implements Exception {
  ToolCallException(this.message);
  final String message;

  @override
  String toString() => 'ToolCallException: $message';
}

/// The app's view of the host. One instance, created in `main()`.
class McpHost {
  McpHost._(this._bridge, this.context, this.initialToolResult);

  final RawBridge? _bridge;

  HostContext context;

  /// The structured payload from the tool call that opened this view, if the
  /// host delivered one before we finished booting.
  final Map<String, dynamic>? initialToolResult;

  bool get isHosted => _bridge != null;

  final _contextChanges = StreamController<HostContext>.broadcast();
  final _toolResults = StreamController<Map<String, dynamic>>.broadcast();

  Stream<HostContext> get onContextChanged => _contextChanges.stream;

  /// Later tool results pushed by the host — e.g. the user asked in prose for a
  /// different night while the view was open.
  Stream<Map<String, dynamic>> get onToolResult => _toolResults.stream;

  /// Connect to the host, or return an unhosted instance if there is none.
  ///
  /// [bridge] overrides the lookup, which is how a test gets a *hosted*
  /// instance on the Dart VM — where there is no page and so no real bridge.
  static Future<McpHost> connect({RawBridge? bridge}) async {
    bridge ??= lookupRawBridge();
    if (bridge == null) {
      return McpHost._(null, const HostContext(), null);
    }

    Map<String, dynamic> snapshot;
    try {
      snapshot = jsonDecode(await bridge.ready()) as Map<String, dynamic>;
    } catch (_) {
      // A host that never answers `initialize` should not take the view down.
      return McpHost._(null, const HostContext(), null);
    }

    final host = McpHost._(
      bridge,
      HostContext.fromJson(
          (snapshot['context'] as Map?)?.cast<String, dynamic>() ?? const {}),
      (snapshot['toolResult'] as Map?)?.cast<String, dynamic>(),
    );

    bridge.onHostContext((json) {
      final patch = jsonDecode(json);
      if (patch is! Map<String, dynamic>) return;
      host.context = host.context.merge(patch);
      host._contextChanges.add(host.context);
    });

    bridge.onToolResult((json) {
      final payload = jsonDecode(json);
      if (payload is Map<String, dynamic>) host._toolResults.add(payload);
    });

    return host;
  }

  /// Call a tool back on the MCP server, through the host.
  Future<Map<String, dynamic>> callTool(
    String name, [
    Map<String, dynamic> args = const {},
  ]) async {
    final bridge = _bridge;
    if (bridge == null) throw ToolCallException('not connected to a host');
    final envelope =
        jsonDecode(await bridge.callTool(name, jsonEncode(args)))
            as Map<String, dynamic>;
    if (envelope['ok'] != true) {
      throw ToolCallException(envelope['error'] as String? ?? 'tool call failed');
    }
    return (envelope['data'] as Map?)?.cast<String, dynamic>() ?? const {};
  }

  /// Hand the model a durable note about what the user did in the UI.
  void updateModelContext(String text) => _bridge?.updateModelContext(text);

  /// Post a turn into the conversation, as if the user had typed it.
  void sendMessage(String text) => _bridge?.sendMessage(text);

  Future<String> requestDisplayMode(String mode) async {
    final bridge = _bridge;
    if (bridge == null) return 'inline';
    try {
      final result = jsonDecode(await bridge.requestDisplayMode(mode))
          as Map<String, dynamic>;
      return result['mode'] as String? ?? context.displayMode;
    } catch (_) {
      return context.displayMode;
    }
  }

  /// Tell the host how tall the iframe should be.
  void setSize(double width, double height) => _bridge?.setSize(width, height);

  void log(String level, String message) => _bridge?.log(level, message);

  /// A breadcrumb to our own origin, readable at `/debug/requests`.
  ///
  /// Inside a host there is no console and no network tab, and on a phone
  /// there is no way to attach one. This is how a bug that only happens on a
  /// real device gets described by the device.
  void beacon(String stage, [String note = '']) =>
      _bridge?.beacon(stage, note);
}

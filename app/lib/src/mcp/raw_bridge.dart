/// The narrow, Dart-typed seam over `globalThis.showtimeBridge`.
///
/// Keeping the JS types behind this interface means [McpHost] and everything
/// above it compiles — and is testable — on the Dart VM, where `dart:js_interop`
/// does not exist.
library;

export 'raw_bridge_stub.dart'
    if (dart.library.js_interop) 'raw_bridge_web.dart';

/// Everything the JavaScript bridge exposes. Strings in, strings out: the wire
/// format is decided in exactly one place.
abstract class RawBridge {
  /// Resolves once the host has answered `initialize`, with a JSON snapshot of
  /// the host context and the tool result that opened the view.
  Future<String> ready();

  /// `{"ok":true,"data":{...}}` or `{"ok":false,"error":"..."}`.
  Future<String> callTool(String name, String argsJson);

  /// `{"mode":"fullscreen"}` — the mode the host actually granted.
  Future<String> requestDisplayMode(String mode);

  void sendMessage(String text);
  void updateModelContext(String text);
  void setSize(double width, double height);
  void log(String level, String message);

  void onHostContext(void Function(String json) callback);
  void onToolResult(void Function(String json) callback);
}

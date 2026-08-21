/// Web build: talk to `globalThis.showtimeBridge`, installed by `bridge.js`.
library;

import 'dart:js_interop';

import 'raw_bridge.dart';

@JS('showtimeBridge')
external _JsBridge? get _showtimeBridge;

extension type _JsBridge._(JSObject _) implements JSObject {
  external JSPromise<JSString> ready();
  external JSPromise<JSString> callTool(String name, String argsJson);
  external JSPromise<JSString> requestDisplayMode(String mode);
  external void sendMessage(String text);
  external void updateModelContext(String text);
  external void setSize(double width, double height);
  external void log(String level, String message);
  external void beacon(String stage, String note);
  external void onHostContext(JSFunction callback);
  external void onToolResult(JSFunction callback);
}

RawBridge? lookupRawBridge() {
  final js = _showtimeBridge;
  return js == null ? null : _WebBridge(js);
}

class _WebBridge implements RawBridge {
  _WebBridge(this._js);

  final _JsBridge _js;

  @override
  Future<String> ready() async => (await _js.ready().toDart).toDart;

  @override
  Future<String> callTool(String name, String argsJson) async =>
      (await _js.callTool(name, argsJson).toDart).toDart;

  @override
  Future<String> requestDisplayMode(String mode) async =>
      (await _js.requestDisplayMode(mode).toDart).toDart;

  @override
  void sendMessage(String text) => _js.sendMessage(text);

  @override
  void updateModelContext(String text) => _js.updateModelContext(text);

  @override
  void setSize(double width, double height) => _js.setSize(width, height);

  @override
  void log(String level, String message) => _js.log(level, message);

  @override
  void beacon(String stage, String note) => _js.beacon(stage, note);

  @override
  void onHostContext(void Function(String json) callback) =>
      _js.onHostContext(((JSString json) => callback(json.toDart)).toJS);

  @override
  void onToolResult(void Function(String json) callback) =>
      _js.onToolResult(((JSString json) => callback(json.toDart)).toJS);
}

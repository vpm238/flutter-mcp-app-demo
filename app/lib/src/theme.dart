/// Personas, palettes, and host theme adoption.
///
/// Two independent axes decide how the view looks:
///
/// * **Persona** — which design language to speak. Derived from
///   `defaultTargetPlatform`, which Flutter web fills in from the browser, so
///   the same build renders Cupertino on an iPhone and Material 3 on a Pixel.
/// * **Palette** — light or dark, and which greys. Adopted from the host's CSS
///   custom properties when we are running inside a chat client, so the view
///   sits inside the conversation instead of on top of it.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'mcp/bridge.dart';

/// Which design language the view speaks.
enum Persona {
  ios('iOS'),
  android('Android'),
  desktop('Desktop');

  const Persona(this.label);
  final String label;
}

/// What the browser says we are running on.
///
/// Correct in a real browser, and the only thing available when this build is
/// opened as a plain web page.
Persona detectPersona() => switch (defaultTargetPlatform) {
      TargetPlatform.iOS => Persona.ios,
      TargetPlatform.android => Persona.android,
      _ => Persona.desktop,
    };

/// What we are running on, in order of how much the answer can be trusted.
///
/// `defaultTargetPlatform` on Flutter web is inferred from the user agent, and
/// inside a chat client the user agent describes the *webview*, not the phone
/// around it. Worse, iPadOS reports itself as a Macintosh, so even a correct
/// reading of the UA puts a tablet on the desktop layout. Getting this wrong is
/// the one unforgivable bug for an adaptive UI, so it asks in this order:
///
///  1. **The input device.** `(pointer: coarse)` and `(hover: none)` come from
///     the browser, cost nothing, and cannot be misreported by a UA string. A
///     phone or tablet answers coarse-and-no-hover whatever else it claims.
///  2. **`hostContext.platform`** — `mobile` settles it when the host sends it.
///  3. **Names**, from the host's own identifier then the browser's UA, to
///     separate iOS from Android once we know it is a touch device.
///  4. **`defaultTargetPlatform`**, unchanged, when there is nothing else.
Persona personaFor(HostContext? host) {
  if (host == null) return detectPersona();

  final named = _appleOrAndroid(
    '${host.hostUserAgent ?? ''} ${host.navigatorUserAgent ?? ''}',
  );

  if (_isTouchDevice(host)) {
    // Known to be a touch device. `named` is usually right; an iPad claiming
    // to be a Macintosh falls through to iOS, which is what it is.
    return named ?? (detectPersona() == Persona.android
        ? Persona.android
        : Persona.ios);
  }

  if (host.hostPlatform == 'desktop' || host.hostPlatform == 'web') {
    return Persona.desktop;
  }

  return named ?? detectPersona();
}

/// Whether this is a finger, not a mouse.
///
/// The media queries are the trustworthy part. `maxTouchPoints` catches an
/// iPad, which answers `pointer: coarse` but is otherwise indistinguishable
/// from a laptop by its user agent. The host's own `deviceCapabilities` and
/// `platform` are consulted last, as corroboration rather than evidence.
bool _isTouchDevice(HostContext host) {
  if (host.pointerCoarse == true && host.hoverNone == true) return true;
  if (host.hostPlatform == 'mobile') return true;
  if (host.touch == true && host.hover == false) return true;
  if ((host.maxTouchPoints ?? 0) > 1 && host.hoverNone == true) return true;
  return false;
}

/// iOS or Android if either is named, otherwise nothing.
Persona? _appleOrAndroid(String haystack) {
  final s = haystack.toLowerCase();
  if (s.contains('android')) return Persona.android;
  if (RegExp(r'iphone|ipad|ipod|\bios\b|darwin|macintosh|mac os')
      .hasMatch(s)) {
    return Persona.ios;
  }
  return null;
}

/// How much room the host actually gave us.
///
/// Persona and fit are different questions, and conflating them is what makes a
/// view look wrong inside a chat client. Persona decides the *design language*;
/// fit decides the *layout*. A desktop browser can hand this view a 700x420
/// slot in the middle of a conversation, and the two-column layout — month
/// grid, times column, a full house at full size — needs roughly 820x560
/// before it stops being a scrollbar.
enum Fit {
  /// Not enough room to be an app at all — a stub card in a conversation.
  ///
  /// Claude on Android hands an inline view a 411x100 frame and does not act
  /// on `ui/notifications/size-changed`, so the view cannot grow itself. Laying
  /// the real UI out in that strip puts every control off-screen and makes the
  /// panel look dead. The honest response is a single thing to press.
  stub,

  /// A single column, with sheets for the big surfaces.
  compact,

  /// Room for the side-by-side layout.
  roomy,
}

/// Below this a panel cannot hold a usable layout, only an invitation to open
/// one. Two rows of Material text plus a touch target is already ~120px.
const double kStubHeight = 240;

/// The two-column layout's minimum. Below either figure it clips rather than
/// reflows, because the seat map has a natural size and the rail beside it
/// does not compress.
const Size kRoomyMinimum = Size(820, 560);

Fit fitFor(Size size) {
  if (size.height < kStubHeight) return Fit.stub;
  return size.width >= kRoomyMinimum.width && size.height >= kRoomyMinimum.height
      ? Fit.roomy
      : Fit.compact;
}

/// Resolved colours for one persona + host theme combination.
@immutable
class Palette {
  const Palette({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.border,
    required this.accent,
    required this.onAccent,
    required this.success,
    required this.danger,
  });

  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color surfaceAlt;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color border;
  final Color accent;
  final Color onAccent;
  final Color success;
  final Color danger;

  bool get isDark => brightness == Brightness.dark;

  Palette copyWith({Color? accent, Color? onAccent}) => Palette(
        brightness: brightness,
        background: background,
        surface: surface,
        surfaceAlt: surfaceAlt,
        textPrimary: textPrimary,
        textSecondary: textSecondary,
        textTertiary: textTertiary,
        border: border,
        accent: accent ?? this.accent,
        onAccent: onAccent ?? this.onAccent,
        success: success,
        danger: danger,
      );

  static const Palette lightDefault = Palette(
    brightness: Brightness.light,
    background: Color(0xFFF6F6F4),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFEFEFEC),
    textPrimary: Color(0xFF16150F),
    textSecondary: Color(0xFF5C5A52),
    textTertiary: Color(0xFF8B8880),
    border: Color(0xFFE1E0DA),
    accent: Color(0xFFC65B2A),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF2F855A),
    danger: Color(0xFFC53030),
  );

  static const Palette darkDefault = Palette(
    brightness: Brightness.dark,
    background: Color(0xFF1B1B19),
    surface: Color(0xFF262523),
    surfaceAlt: Color(0xFF302F2C),
    textPrimary: Color(0xFFF5F4EF),
    textSecondary: Color(0xFFB4B2A9),
    textTertiary: Color(0xFF87857D),
    border: Color(0xFF3A3936),
    accent: Color(0xFFD97757),
    onAccent: Color(0xFF1B1B19),
    success: Color(0xFF68D391),
    danger: Color(0xFFFC8181),
  );

  /// Build a palette from the host's style variables, falling back per-token
  /// so a host that only ships half the palette still looks intentional.
  factory Palette.fromHost(HostContext host) {
    final base = host.isDark ? darkDefault : lightDefault;
    Color pick(String key, Color fallback) =>
        parseCssColor(host.styles[key], dark: host.isDark) ?? fallback;

    return Palette(
      brightness: base.brightness,
      background: pick('--color-background-primary', base.background),
      surface: pick('--color-background-secondary', base.surface),
      surfaceAlt: pick('--color-background-tertiary', base.surfaceAlt),
      textPrimary: pick('--color-text-primary', base.textPrimary),
      textSecondary: pick('--color-text-secondary', base.textSecondary),
      textTertiary: pick('--color-text-tertiary', base.textTertiary),
      border: pick('--color-border-primary', base.border),
      accent: base.accent,
      onAccent: base.onAccent,
      success: pick('--color-text-success', base.success),
      danger: pick('--color-text-danger', base.danger),
    );
  }
}

/// Material theme for the Android and desktop personas.
ThemeData materialTheme(Palette p, Persona persona) {
  final scheme = ColorScheme.fromSeed(
    seedColor: p.accent,
    brightness: p.brightness,
  ).copyWith(
    surface: p.background,
    onSurface: p.textPrimary,
    outlineVariant: p.border,
  );

  // Android keeps Roboto — it is the platform face and part of the tell.
  // Desktop gets Inter, which reads better at the small sizes the wide layout
  // uses for row labels and seat numbers.
  final family = persona == Persona.android ? null : 'Inter';

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: family,
    scaffoldBackgroundColor: p.background,
    splashFactory: persona == Persona.android
        ? InkSparkle.splashFactory
        : InkRipple.splashFactory,
    visualDensity: persona == Persona.desktop
        ? VisualDensity.compact
        : VisualDensity.standard,
    dividerTheme: DividerThemeData(color: p.border, space: 1, thickness: 1),
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(persona == Persona.android ? 20 : 14),
        side: BorderSide(color: p.border),
      ),
    ),
  );
}

/// Inherited persona + palette, so any widget can ask what it should look like.
class Skin extends InheritedWidget {
  const Skin({
    super.key,
    required this.persona,
    required this.palette,
    required this.currency,
    this.fit = Fit.roomy,
    this.requestRoom,
    this.trace,
    required super.child,
  });

  final Persona persona;
  final Palette palette;
  final String currency;

  /// How much room the host gave us. A sheet sized for a phone screen is not
  /// the same as a sheet sized for a panel in a conversation.
  final Fit fit;

  /// Ask the host to make the view fullscreen, and wait until it has.
  ///
  /// A modal sheet is positioned against the Flutter viewport, which inside a
  /// host is the iframe — and the iframe can be taller than the part of it the
  /// user can actually see. A seat map opened in a panel that way is laid out
  /// correctly and still invisible. Asking for the room first is the fix, and
  /// it is also just the right behaviour on a phone.
  final Future<void> Function()? requestRoom;

  /// Report something to our own origin, for a bug that only happens on a
  /// device nobody debugging it is holding.
  final void Function(String stage, String note)? trace;

  static Skin of(BuildContext context) {
    final skin = context.dependOnInheritedWidgetOfExactType<Skin>();
    assert(skin != null, 'No Skin in scope');
    return skin!;
  }

  bool get isCompact => fit != Fit.roomy;
  bool get isStub => fit == Fit.stub;

  void note(String stage, String detail) => trace?.call(stage, detail);

  bool get isIOS => persona == Persona.ios;
  bool get isAndroid => persona == Persona.android;
  bool get isDesktop => persona == Persona.desktop;

  @override
  bool updateShouldNotify(Skin old) =>
      old.persona != persona ||
      old.palette != palette ||
      old.currency != currency ||
      old.fit != fit;
}

// ---------------------------------------------------------------------------
// CSS colour parsing
// ---------------------------------------------------------------------------

/// Parse the colour syntaxes a host is likely to hand us: hex, `rgb()`,
/// `hsl()`, `oklch()` (which modern design systems emit by default), and
/// `light-dark()`.
///
/// `light-dark()` is the one that has to be handled rather than skipped: a host
/// that ships a single stylesheet for both themes sends every colour that way,
/// and the naive parse takes the first `(` — which belongs to `light-dark`
/// itself — and produces nonsense. Claude sends its entire palette like this,
/// so getting it wrong means silently ignoring the host's theme and rendering
/// the app's own defaults on the host's background.
///
/// Returns null for anything unrecognised so callers can fall back rather than
/// render a wrong colour confidently.
Color? parseCssColor(String? input, {bool dark = false}) {
  if (input == null) return null;
  final value = input.trim().toLowerCase();
  if (value.isEmpty || value == 'transparent' || value == 'inherit') return null;

  if (value.startsWith('#')) return _parseHex(value.substring(1));

  final open = value.indexOf('(');
  if (open < 0 || !value.endsWith(')')) return null;
  final fn = value.substring(0, open).trim();
  final inner = value.substring(open + 1, value.length - 1);

  if (fn == 'light-dark') {
    final parts = _splitTopLevel(inner);
    if (parts.length != 2) return null;
    return parseCssColor(parts[dark ? 1 : 0], dark: dark);
  }

  final args = inner
      .replaceAll('/', ' ')
      .replaceAll(',', ' ')
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty)
      .toList();
  if (args.length < 3) return null;

  double? num_(String s, {double scale = 1}) {
    final pct = s.endsWith('%');
    final parsed = double.tryParse(pct ? s.substring(0, s.length - 1) : s);
    if (parsed == null) return null;
    return pct ? parsed / 100 * scale : parsed;
  }

  final alpha = args.length > 3 ? (num_(args[3], scale: 1) ?? 1).clamp(0.0, 1.0) : 1.0;

  switch (fn) {
    case 'rgb':
    case 'rgba':
      final r = num_(args[0], scale: 255);
      final g = num_(args[1], scale: 255);
      final b = num_(args[2], scale: 255);
      if (r == null || g == null || b == null) return null;
      return Color.fromRGBO(r.round(), g.round(), b.round(), alpha.toDouble());
    case 'hsl':
    case 'hsla':
      final h = num_(args[0]);
      final s = num_(args[1], scale: 1);
      final l = num_(args[2], scale: 1);
      if (h == null || s == null || l == null) return null;
      return HSLColor.fromAHSL(
        alpha.toDouble(),
        h % 360,
        s.clamp(0.0, 1.0),
        l.clamp(0.0, 1.0),
      ).toColor();
    case 'oklch':
      final l = num_(args[0], scale: 1);
      final c = double.tryParse(args[1]);
      final h = double.tryParse(args[2].replaceAll('deg', ''));
      if (l == null || c == null || h == null) return null;
      return _oklchToColor(l, c, h, alpha.toDouble());
    default:
      return null;
  }
}

/// Split on commas that are not inside a nested function call.
///
/// `rgba(1, 2, 3, 1), rgba(4, 5, 6, 1)` is two arguments, not eight.
List<String> _splitTopLevel(String input) {
  final parts = <String>[];
  final buffer = StringBuffer();
  var depth = 0;
  for (final rune in input.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == '(') depth++;
    if (ch == ')') depth--;
    if (ch == ',' && depth == 0) {
      parts.add(buffer.toString().trim());
      buffer.clear();
    } else {
      buffer.write(ch);
    }
  }
  final last = buffer.toString().trim();
  if (last.isNotEmpty) parts.add(last);
  return parts;
}

Color? _parseHex(String hex) {
  final expanded = switch (hex.length) {
    3 => hex.split('').map((c) => '$c$c').join(),
    4 => hex.split('').map((c) => '$c$c').join(),
    _ => hex,
  };
  final value = int.tryParse(expanded, radix: 16);
  if (value == null) return null;
  return switch (expanded.length) {
    6 => Color(0xFF000000 | value),
    8 => Color(((value & 0xFF) << 24) | (value >> 8)), // #rrggbbaa
    _ => null,
  };
}

/// Oklch → sRGB. Straight port of the CSS Color 4 reference conversion.
Color _oklchToColor(double lightness, double chroma, double hueDeg, double alpha) {
  final hue = hueDeg * math.pi / 180;
  final a = chroma * math.cos(hue);
  final b = chroma * math.sin(hue);

  final lCone = lightness + 0.3963377774 * a + 0.2158037573 * b;
  final mCone = lightness - 0.1055613458 * a - 0.0638541728 * b;
  final sCone = lightness - 0.0894841775 * a - 1.2914855480 * b;

  final l3 = lCone * lCone * lCone;
  final m3 = mCone * mCone * mCone;
  final s3 = sCone * sCone * sCone;

  final r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3;
  final g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3;
  final bl = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3;

  int channel(double linear) {
    final v = linear <= 0.0031308
        ? 12.92 * linear
        : 1.055 * math.pow(linear, 1 / 2.4) - 0.055;
    return (v.clamp(0.0, 1.0) * 255).round();
  }

  return Color.fromRGBO(channel(r), channel(g), channel(bl), alpha);
}

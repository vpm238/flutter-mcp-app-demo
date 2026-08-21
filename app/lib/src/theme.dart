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

/// What we are running on, preferring the host's answer to the browser's.
///
/// `defaultTargetPlatform` on Flutter web is inferred from the user agent, and
/// inside a chat client the user agent describes the *webview* — so a view
/// opened in Claude on an iPhone can report itself as a desktop and render the
/// wrong design language entirely. The host knows what device it is on, and
/// SEP-1865 gives it fields to say so, so ask before sniffing:
///
///  1. `hostContext.platform` — `mobile` rules out the desktop layout outright.
///  2. `hostContext.userAgent` — the host app's own identifier, which is what
///     separates iOS from Android once we know it is a phone.
///  3. the browser's user agent, then `defaultTargetPlatform`, unchanged.
///
/// A host that sends none of it lands exactly where this code always was.
Persona personaFor(HostContext? host) {
  if (host == null) return detectPersona();

  final fromHost = _appleOrAndroid('${host.hostUserAgent ?? ''} '
      '${host.navigatorUserAgent ?? ''}');

  switch (host.hostPlatform) {
    case 'mobile':
      // Known to be a phone. Pick a design language; iOS is the safer default
      // for an unrecognised one, since Cupertino degrades to plain-looking
      // controls where Material 3 asserts a brand.
      return fromHost ?? (detectPersona() == Persona.android
          ? Persona.android
          : Persona.ios);
    case 'desktop':
    case 'web':
      // A desktop chat client can still be a touch laptop; the layout that
      // matters here is pointer-first either way.
      return host.touch == true && host.hover == false
          ? (fromHost ?? Persona.ios)
          : Persona.desktop;
    default:
      return fromHost ?? detectPersona();
  }
}

/// iOS or Android if either is named, otherwise nothing.
Persona? _appleOrAndroid(String haystack) {
  final s = haystack.toLowerCase();
  if (s.contains('android')) return Persona.android;
  if (RegExp(r'iphone|ipad|ipod|\bios\b|darwin').hasMatch(s)) return Persona.ios;
  return null;
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
        parseCssColor(host.styles[key]) ?? fallback;

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
    required super.child,
  });

  final Persona persona;
  final Palette palette;
  final String currency;

  static Skin of(BuildContext context) {
    final skin = context.dependOnInheritedWidgetOfExactType<Skin>();
    assert(skin != null, 'No Skin in scope');
    return skin!;
  }

  bool get isIOS => persona == Persona.ios;
  bool get isAndroid => persona == Persona.android;
  bool get isDesktop => persona == Persona.desktop;

  @override
  bool updateShouldNotify(Skin old) =>
      old.persona != persona ||
      old.palette != palette ||
      old.currency != currency;
}

// ---------------------------------------------------------------------------
// CSS colour parsing
// ---------------------------------------------------------------------------

/// Parse the colour syntaxes a host is likely to hand us: hex, `rgb()`,
/// `hsl()`, and `oklch()` (which modern design systems emit by default).
///
/// Returns null for anything unrecognised so callers can fall back rather than
/// render a wrong colour confidently.
Color? parseCssColor(String? input) {
  if (input == null) return null;
  final value = input.trim().toLowerCase();
  if (value.isEmpty || value == 'transparent' || value == 'inherit') return null;

  if (value.startsWith('#')) return _parseHex(value.substring(1));

  final open = value.indexOf('(');
  if (open < 0 || !value.endsWith(')')) return null;
  final fn = value.substring(0, open).trim();
  final args = value
      .substring(open + 1, value.length - 1)
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

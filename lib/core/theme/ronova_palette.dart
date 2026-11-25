import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/theme_config.dart';

/// Every colour the Ronova UI draws with, derived from a [ThemeConfig].
///
/// * One wheel active  -> the accent is that single colour everywhere (uniform glow / tint).
/// * Both wheels active -> [accentGradient] blends wheel 1 into wheel 2 across borders, glows,
///   active icons and buttons.
@immutable
class RonovaPalette {
  const RonovaPalette({
    required this.isAbyss,
    required this.dual,
    required this.bg,
    required this.surface,
    required this.surfaceStrong,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent1,
    required this.accent2,
    required this.accentGradient,
    required this.primary,
    required this.accentText,
    required this.glow,
    required this.onAccent,
  });

  static const Color abyssBase = Color(0xFF0A0C12);
  static const Color aetherBase = Color(0xFFF3F5FA);

  final bool isAbyss;
  final bool dual;

  /// Scaffold base colour (#0A0C12 Abyss / #F3F5FA Aether).
  final Color bg;

  /// Translucent card fill (frosted look).
  final Color surface;
  final Color surfaceStrong;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  /// Active accent colours (identical when only one wheel is on).
  final Color accent1;
  final Color accent2;

  /// Split-gradient accent (a flat two-stop gradient when a single wheel is on).
  final LinearGradient accentGradient;

  /// Solid accent for places a gradient cannot go (the blend midpoint when dual).
  final Color primary;

  /// [primary] adjusted so it stays readable as text / thin icons on [bg].
  final Color accentText;

  /// Glow / shadow tint.
  final Color glow;

  /// Foreground that is legible on top of [accentGradient].
  final Color onAccent;

  Brightness get brightness => isAbyss ? Brightness.dark : Brightness.light;

  /// Accent colour at position [t] (0 = wheel 1 side, 1 = wheel 2 side).
  Color accentAt(double t) => Color.lerp(accent1, accent2, t.clamp(0.0, 1.0).toDouble()) ?? primary;

  /// Gradient that follows [begin] -> [end]; flat when only one wheel is active.
  LinearGradient gradient({
    Alignment begin = Alignment.topLeft,
    Alignment end = Alignment.bottomRight,
    double alpha = 1.0,
  }) {
    return LinearGradient(
      begin: begin,
      end: end,
      colors: <Color>[
        accent1.withValues(alpha: alpha),
        accent2.withValues(alpha: alpha),
      ],
    );
  }

  /// Soft ambient glow shadows tinted with the accent colours.
  List<BoxShadow> glowShadows({double strength = 1.0, double blur = 18}) {
    return <BoxShadow>[
      BoxShadow(
        color: accent1.withValues(alpha: 0.30 * strength),
        blurRadius: blur,
        spreadRadius: 0.5,
        offset: const Offset(-2, 0),
      ),
      BoxShadow(
        color: accent2.withValues(alpha: 0.30 * strength),
        blurRadius: blur,
        spreadRadius: 0.5,
        offset: const Offset(2, 0),
      ),
    ];
  }

  static RonovaPalette fromConfig(ThemeConfig config) {
    final isAbyss = config.mode == AppThemeMode.abyss;
    final bg = isAbyss ? abyssBase : aetherBase;

    final Color a1;
    final Color a2;
    final bool dual = config.wheel1Enabled && config.wheel2Enabled;
    if (dual) {
      a1 = config.wheel1Color;
      a2 = config.wheel2Color;
    } else if (config.wheel2Enabled) {
      a1 = config.wheel2Color;
      a2 = config.wheel2Color;
    } else {
      a1 = config.wheel1Color;
      a2 = config.wheel1Color;
    }

    final primary = dual ? (Color.lerp(a1, a2, 0.5) ?? a1) : a1;
    final accentText = ensureContrast(primary, bg, 2.6);
    final avgLuminance = (a1.computeLuminance() + a2.computeLuminance()) / 2.0;

    return RonovaPalette(
      isAbyss: isAbyss,
      dual: dual,
      bg: bg,
      surface: isAbyss ? Colors.white.withValues(alpha: 0.055) : Colors.white.withValues(alpha: 0.66),
      surfaceStrong: isAbyss ? Colors.white.withValues(alpha: 0.10) : Colors.white.withValues(alpha: 0.86),
      border: isAbyss ? Colors.white.withValues(alpha: 0.09) : const Color(0xFF1A2033).withValues(alpha: 0.08),
      textPrimary: isAbyss ? const Color(0xFFEAF0FF) : const Color(0xFF161B2B),
      textSecondary: isAbyss ? const Color(0xFFB4BDD6) : const Color(0xFF4A5470),
      textMuted: isAbyss ? const Color(0xFF7C86A3) : const Color(0xFF858EA8),
      accent1: a1,
      accent2: a2,
      accentGradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[a1, a2],
      ),
      primary: primary,
      accentText: accentText,
      glow: primary,
      onAccent: avgLuminance > 0.55 ? const Color(0xFF10131C) : Colors.white,
    );
  }
}

/// WCAG-style contrast ratio between two opaque colours.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// Nudges [color]'s lightness (keeping its hue) until it reaches [minRatio] against [background].
Color ensureContrast(Color color, Color background, double minRatio) {
  if (contrastRatio(color, background) >= minRatio) return color;
  final hsl = HSLColor.fromColor(color);
  final lighten = background.computeLuminance() < 0.4;
  var lightness = hsl.lightness;
  for (var i = 0; i < 20; i++) {
    lightness = (lighten ? lightness + 0.04 : lightness - 0.04).clamp(0.0, 1.0).toDouble();
    final candidate = hsl.withLightness(lightness).toColor();
    if (contrastRatio(candidate, background) >= minRatio) return candidate;
  }
  return hsl.withLightness(lighten ? 1.0 : 0.0).toColor();
}

import 'package:flutter/material.dart';

enum AppThemeMode {
  /// Soft celestial light base (#F3F5FA).
  aether('Aether'),

  /// Dark obsidian base (#0A0C12).
  abyss('Abyss');

  const AppThemeMode(this.label);
  final String label;
}

/// A named two-colour accent pair that can be applied instantly.
@immutable
class ThemePreset {
  const ThemePreset({
    required this.name,
    required this.color1Name,
    required this.color1,
    required this.color2Name,
    required this.color2,
  });

  final String name;
  final String color1Name;
  final Color color1;
  final String color2Name;
  final Color color2;

  String get subtitle => '$color1Name + $color2Name';
}

int _asInt(Object? value, int fallback) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return fallback;
}

double _asDouble(Object? value, double fallback) {
  if (value is num) return value.toDouble();
  return fallback;
}

bool _asBool(Object? value, bool fallback) => value is bool ? value : fallback;

/// Snaps any value to the three supported album-art visibility levels (0, 0.5, 1).
double snapArtDimLevel(double value) {
  if (value < 0.25) return 0.0;
  if (value < 0.75) return 0.5;
  return 1.0;
}

/// Persistent appearance + playback-surface + gaming-overlay settings.
@immutable
class ThemeConfig {
  const ThemeConfig({
    this.mode = AppThemeMode.abyss,
    this.wheel1Enabled = true,
    this.wheel2Enabled = false,
    this.wheel1Color = const Color(0xFF5CE1E6),
    this.wheel2Color = const Color(0xFFFF3B5C),
    this.presetName = 'Custom',
    this.backgroundImagePath,
    this.backgroundDimOpacity = 0.35,
    this.artDimLevel = 0.0,
    this.isMonoMode = false,
    this.overlayEnabled = false,
    this.doubleTapToOpen = true,
    this.overlayScale = 1.0,
    this.overlayOpacity = 0.9,
  });

  static const ThemeConfig defaults = ThemeConfig();

  static const double maxBackgroundDim = 0.85;

  /// Built-in instant-apply presets (each switches both wheels on for the split-gradient look).
  static const List<ThemePreset> presets = <ThemePreset>[
    ThemePreset(
      name: 'Frost',
      color1Name: 'Glacier Cyan',
      color1: Color(0xFF5CE1E6),
      color2Name: 'Silver Mist',
      color2: Color(0xFFC9D6E8),
    ),
    ThemePreset(
      name: 'Obsidian',
      color1Name: 'Abyssal Violet',
      color1: Color(0xFF8B5CF6),
      color2Name: 'Midnight Charcoal',
      color2: Color(0xFF4B5675),
    ),
    ThemePreset(
      name: 'Kiongozi',
      color1Name: 'Royal Gold',
      color1: Color(0xFFFFC857),
      color2Name: 'Crimson Dawn',
      color2: Color(0xFFE23E57),
    ),
    ThemePreset(
      name: 'Celestia',
      color1Name: 'Soft Pearl',
      color1: Color(0xFFF2E9FF),
      color2Name: 'Sky Azure',
      color2: Color(0xFF4DA8FF),
    ),
    ThemePreset(
      name: 'Pyro Archon',
      color1Name: 'Ember Orange',
      color1: Color(0xFFFF7A2F),
      color2Name: 'Ruby Red',
      color2: Color(0xFFE0243E),
    ),
    ThemePreset(
      name: 'Electro',
      color1Name: 'Neon Amethyst',
      color1: Color(0xFFC15BFF),
      color2Name: 'Electric Indigo',
      color2: Color(0xFF4F5BFF),
    ),
  ];

  static List<String> get knownPresets => <String>[for (final p in presets) p.name];

  final AppThemeMode mode;
  final bool wheel1Enabled;
  final bool wheel2Enabled;
  final Color wheel1Color;
  final Color wheel2Color;
  final String presetName;

  /// Absolute path of the user-picked wallpaper, or null for none.
  final String? backgroundImagePath;

  /// Dim applied over the wallpaper: 0.0 .. [maxBackgroundDim].
  final double backgroundDimOpacity;

  /// Album-art visibility: 0.0 normal, 0.5 dimmed, 1.0 hidden.
  final double artDimLevel;

  final bool isMonoMode;
  final bool overlayEnabled;
  final bool doubleTapToOpen;

  /// Overlay "R" size multiplier (0.5 .. 2.0).
  final double overlayScale;

  /// Overlay opacity (0.2 .. 1.0).
  final double overlayOpacity;

  // ---- Spec-facing aliases ----
  bool get isAbyssMode => mode == AppThemeMode.abyss;
  String? get customBackgroundPath => backgroundImagePath;
  bool get overlayDoubleTap => doubleTapToOpen;

  /// True when both colour wheels are active (split-gradient theme).
  bool get isDual => wheel1Enabled && wheel2Enabled;

  ThemeConfig copyWith({
    AppThemeMode? mode,
    bool? wheel1Enabled,
    bool? wheel2Enabled,
    Color? wheel1Color,
    Color? wheel2Color,
    String? presetName,
    String? backgroundImagePath,
    bool clearBackgroundImage = false,
    double? backgroundDimOpacity,
    double? artDimLevel,
    bool? isMonoMode,
    bool? overlayEnabled,
    bool? doubleTapToOpen,
    double? overlayScale,
    double? overlayOpacity,
  }) {
    return ThemeConfig(
      mode: mode ?? this.mode,
      wheel1Enabled: wheel1Enabled ?? this.wheel1Enabled,
      wheel2Enabled: wheel2Enabled ?? this.wheel2Enabled,
      wheel1Color: wheel1Color ?? this.wheel1Color,
      wheel2Color: wheel2Color ?? this.wheel2Color,
      presetName: presetName ?? this.presetName,
      backgroundImagePath: clearBackgroundImage ? null : (backgroundImagePath ?? this.backgroundImagePath),
      backgroundDimOpacity:
          (backgroundDimOpacity ?? this.backgroundDimOpacity).clamp(0.0, maxBackgroundDim).toDouble(),
      artDimLevel: snapArtDimLevel(artDimLevel ?? this.artDimLevel),
      isMonoMode: isMonoMode ?? this.isMonoMode,
      overlayEnabled: overlayEnabled ?? this.overlayEnabled,
      doubleTapToOpen: doubleTapToOpen ?? this.doubleTapToOpen,
      overlayScale: (overlayScale ?? this.overlayScale).clamp(0.5, 2.0).toDouble(),
      overlayOpacity: (overlayOpacity ?? this.overlayOpacity).clamp(0.2, 1.0).toDouble(),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'mode': mode.name,
      'wheel1Enabled': wheel1Enabled,
      'wheel2Enabled': wheel2Enabled,
      'wheel1Color': wheel1Color.toARGB32(),
      'wheel2Color': wheel2Color.toARGB32(),
      'presetName': presetName,
      'backgroundImagePath': backgroundImagePath,
      'backgroundDimOpacity': backgroundDimOpacity,
      'artDimLevel': artDimLevel,
      'isMonoMode': isMonoMode,
      'overlayEnabled': overlayEnabled,
      'doubleTapToOpen': doubleTapToOpen,
      'overlayScale': overlayScale,
      'overlayOpacity': overlayOpacity,
    };
  }

  factory ThemeConfig.fromJson(Map<String, Object?> json) {
    final modeName = json['mode'];
    final background = json['backgroundImagePath'];
    // Batch 1-3 builds stored `iconDimOpacity` (1.0 = fully visible); map it onto artDimLevel.
    final legacyIconOpacity = json['iconDimOpacity'];
    final artDim = json.containsKey('artDimLevel')
        ? _asDouble(json['artDimLevel'], 0.0)
        : (legacyIconOpacity is num ? 1.0 - legacyIconOpacity.toDouble() : 0.0);
    var wheel1 = _asBool(json['wheel1Enabled'], true);
    final wheel2 = _asBool(json['wheel2Enabled'], false);
    if (!wheel1 && !wheel2) wheel1 = true; // at least one wheel always drives the accent
    return ThemeConfig(
      mode: AppThemeMode.values.firstWhere(
        (m) => m.name == modeName,
        orElse: () => AppThemeMode.abyss,
      ),
      wheel1Enabled: wheel1,
      wheel2Enabled: wheel2,
      wheel1Color: Color(_asInt(json['wheel1Color'], 0xFF5CE1E6)),
      wheel2Color: Color(_asInt(json['wheel2Color'], 0xFFFF3B5C)),
      presetName: json['presetName'] is String ? json['presetName']! as String : 'Custom',
      backgroundImagePath: background is String && background.isNotEmpty ? background : null,
      backgroundDimOpacity: _asDouble(json['backgroundDimOpacity'], 0.35).clamp(0.0, maxBackgroundDim).toDouble(),
      artDimLevel: snapArtDimLevel(artDim),
      isMonoMode: _asBool(json['isMonoMode'], false),
      overlayEnabled: _asBool(json['overlayEnabled'], false),
      doubleTapToOpen: _asBool(json['doubleTapToOpen'], true),
      overlayScale: _asDouble(json['overlayScale'], 1.0).clamp(0.5, 2.0).toDouble(),
      overlayOpacity: _asDouble(json['overlayOpacity'], 0.9).clamp(0.2, 1.0).toDouble(),
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ThemeConfig &&
            other.mode == mode &&
            other.wheel1Enabled == wheel1Enabled &&
            other.wheel2Enabled == wheel2Enabled &&
            other.wheel1Color == wheel1Color &&
            other.wheel2Color == wheel2Color &&
            other.presetName == presetName &&
            other.backgroundImagePath == backgroundImagePath &&
            other.backgroundDimOpacity == backgroundDimOpacity &&
            other.artDimLevel == artDimLevel &&
            other.isMonoMode == isMonoMode &&
            other.overlayEnabled == overlayEnabled &&
            other.doubleTapToOpen == doubleTapToOpen &&
            other.overlayScale == overlayScale &&
            other.overlayOpacity == overlayOpacity;
  }

  @override
  int get hashCode => Object.hash(
        mode,
        wheel1Enabled,
        wheel2Enabled,
        wheel1Color,
        wheel2Color,
        presetName,
        backgroundImagePath,
        backgroundDimOpacity,
        artDimLevel,
        isMonoMode,
        overlayEnabled,
        doubleTapToOpen,
        overlayScale,
        overlayOpacity,
      );
}

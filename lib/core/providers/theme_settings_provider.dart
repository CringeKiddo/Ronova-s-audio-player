import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/theme_config.dart';
import '../storage/preferences_store.dart';
import '../theme/ronova_palette.dart';
import 'app_providers.dart';

/// Aether / Abyss base mode, the dual colour-wheel accent engine, wallpaper, album-art
/// visibility and gaming-overlay settings. Every change is persisted to SharedPreferences
/// (debounced, so dragging a colour wheel does not hammer the disk) and survives relaunches.
class RonovaThemeController extends StateNotifier<ThemeConfig> {
  RonovaThemeController(this._prefs, ThemeConfig initial) : super(initial);

  final PreferencesStore? _prefs;
  Timer? _saveTimer;
  ThemeConfig? _unsaved;

  static const Duration _saveDelay = Duration(milliseconds: 300);

  void _commit(ThemeConfig next) {
    if (next == state) return;
    state = next;
    _unsaved = next;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, _flush);
  }

  void _flush() {
    final pending = _unsaved;
    _unsaved = null;
    _saveTimer = null;
    if (pending != null) {
      unawaited(_prefs?.saveThemeConfig(pending));
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _flush();
    super.dispose();
  }

  // ---- Aether / Abyss ----

  void setAbyssMode(bool abyss) {
    _commit(state.copyWith(mode: abyss ? AppThemeMode.abyss : AppThemeMode.aether));
  }

  void toggleMode() => setAbyssMode(!state.isAbyssMode);

  // ---- Dual colour wheels ----

  /// Switches wheel [wheel] (1 or 2) on/off. At least one wheel always stays on, so turning
  /// off the last active wheel is ignored.
  void setWheelEnabled(int wheel, bool enabled) {
    if (wheel == 1) {
      if (!enabled && !state.wheel2Enabled) return;
      _commit(state.copyWith(wheel1Enabled: enabled, presetName: 'Custom'));
    } else {
      if (!enabled && !state.wheel1Enabled) return;
      _commit(state.copyWith(wheel2Enabled: enabled, presetName: 'Custom'));
    }
  }

  void setWheelColor(int wheel, Color color) {
    final opaque = color.withValues(alpha: 1.0);
    if (wheel == 1) {
      _commit(state.copyWith(wheel1Color: opaque, presetName: 'Custom'));
    } else {
      _commit(state.copyWith(wheel2Color: opaque, presetName: 'Custom'));
    }
  }

  /// Instantly applies a built-in preset (both wheels on -> split-gradient look).
  void applyPreset(ThemePreset preset) {
    _commit(
      state.copyWith(
        wheel1Enabled: true,
        wheel2Enabled: true,
        wheel1Color: preset.color1,
        wheel2Color: preset.color2,
        presetName: preset.name,
      ),
    );
  }

  // ---- Wallpaper ----

  void setBackgroundImage(String path) => _commit(state.copyWith(backgroundImagePath: path));

  void clearBackgroundImage() => _commit(state.copyWith(clearBackgroundImage: true));

  void setBackgroundDim(double value) => _commit(state.copyWith(backgroundDimOpacity: value));

  // ---- Album art ----

  /// 0.0 normal, 0.5 dimmed, 1.0 hidden.
  void setArtDimLevel(double level) => _commit(state.copyWith(artDimLevel: level));

  // ---- Audio channel & gaming overlay ----

  /// Persists the mono / stereo choice. The audio controller forwards it to the C++ engine.
  void setMonoMode(bool mono) => _commit(state.copyWith(isMonoMode: mono));

  void setOverlayEnabled(bool enabled) => _commit(state.copyWith(overlayEnabled: enabled));

  void setOverlayDoubleTap(bool enabled) => _commit(state.copyWith(doubleTapToOpen: enabled));

  void setOverlayScale(double scale) => _commit(state.copyWith(overlayScale: scale));

  void setOverlayOpacity(double opacity) => _commit(state.copyWith(overlayOpacity: opacity));
}

/// Writable theme + settings state (persisted).
final themeSettingsProvider = StateNotifierProvider<RonovaThemeController, ThemeConfig>((ref) {
  final prefs = ref.read(preferencesStoreProvider);
  return RonovaThemeController(prefs, prefs?.loadThemeConfig() ?? ThemeConfig.defaults);
});

/// Read-only view of the current configuration.
final themeConfigProvider = Provider<ThemeConfig>((ref) => ref.watch(themeSettingsProvider));

/// Palette derived from the configuration (rebuilds only when the config changes).
final ronovaPaletteProvider = Provider<RonovaPalette>((ref) {
  return RonovaPalette.fromConfig(ref.watch(themeSettingsProvider));
});

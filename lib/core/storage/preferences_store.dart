import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/theme_config.dart';

/// Thin typed wrapper over SharedPreferences for instant, synchronous reads
/// of themes, favorites and the active EQ preset after a single async open.
class PreferencesStore {
  PreferencesStore._(this._prefs);

  final SharedPreferences _prefs;

  static const String _kThemeConfig = 'ronova.theme_config.v1';
  static const String _kFavoritePresetIds = 'ronova.favorite_eq_preset_ids.v1';
  static const String _kActiveEqPresetId = 'ronova.active_eq_preset_id.v1';
  static const String _kEqState = 'ronova.eq_state.v1';
  static const String _kBootCount = 'ronova.boot_count.v1';
  static const String _kPlaylists = 'ronova.playlists.v1';
  static const String _kPlaylistsV2 = 'ronova.playlists.v2';
  static const String _kPlaybackPrefs = 'ronova.playback_prefs.v1';

  static Future<PreferencesStore> open() async {
    return PreferencesStore._(await SharedPreferences.getInstance());
  }

  ThemeConfig loadThemeConfig() {
    final raw = _prefs.getString(_kThemeConfig);
    if (raw == null) return ThemeConfig.defaults;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return ThemeConfig.fromJson(Map<String, Object?>.from(decoded));
      }
    } on FormatException {
      // Corrupted payload: fall back to defaults below.
    }
    return ThemeConfig.defaults;
  }

  Future<bool> saveThemeConfig(ThemeConfig config) {
    return _prefs.setString(_kThemeConfig, jsonEncode(config.toJson()));
  }

  Set<String> loadFavoritePresetIds() {
    return (_prefs.getStringList(_kFavoritePresetIds) ?? const <String>[]).toSet();
  }

  Future<bool> saveFavoritePresetIds(Set<String> ids) {
    return _prefs.setStringList(_kFavoritePresetIds, ids.toList()..sort());
  }

  /// True once the favourite presets were saved at least once (even as an empty set), which lets
  /// the equalizer seed first-run favourites without bringing them back after the user cleared them.
  bool get hasSavedFavoritePresetIds => _prefs.containsKey(_kFavoritePresetIds);

  String? get activeEqPresetId => _prefs.getString(_kActiveEqPresetId);

  Future<bool> setActiveEqPresetId(String id) {
    return _prefs.setString(_kActiveEqPresetId, id);
  }

  // ---- Equalizer dials (16 bands, 808 sub-bass, stereo width, pre-amp, custom user slot) ----

  Map<String, Object?> loadEqState() {
    final raw = _prefs.getString(_kEqState);
    if (raw == null) return <String, Object?>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    } on FormatException {
      // Corrupted payload: fall back to the flat reference preset.
    }
    return <String, Object?>{};
  }

  Future<bool> saveEqState(Map<String, Object?> state) {
    return _prefs.setString(_kEqState, jsonEncode(state));
  }

  int get bootCount => _prefs.getInt(_kBootCount) ?? 0;

  /// Increments and returns the persisted launch counter.
  Future<int> incrementBootCount() async {
    final next = bootCount + 1;
    await _prefs.setInt(_kBootCount, next);
    return next;
  }

  // ---- Playlists (name -> ordered list of file paths) ----

  Map<String, List<String>> loadPlaylists() {
    final raw = _prefs.getString(_kPlaylists);
    if (raw == null) return <String, List<String>>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return <String, List<String>>{
          for (final entry in decoded.entries)
            '${entry.key}': <String>[
              if (entry.value is List)
                for (final item in entry.value as List) '$item',
            ],
        };
      }
    } on FormatException {
      // Corrupted payload: start with no playlists.
    }
    return <String, List<String>>{};
  }

  Future<bool> savePlaylists(Map<String, List<String>> playlists) {
    return _prefs.setString(_kPlaylists, jsonEncode(playlists));
  }

  // ---- Playlists v2 (rich, customizable playlists stored as JSON) ----

  /// Null when v2 has never been saved (the provider then migrates the legacy name -> paths map).
  List<Map<String, Object?>>? loadPlaylistsV2() {
    final raw = _prefs.getString(_kPlaylistsV2);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return <Map<String, Object?>>[
          for (final item in decoded)
            if (item is Map) Map<String, Object?>.from(item),
        ];
      }
    } on FormatException {
      // Corrupted payload: start empty.
    }
    return <Map<String, Object?>>[];
  }

  Future<bool> savePlaylistsV2(List<Map<String, Object?>> playlists) {
    return _prefs.setString(_kPlaylistsV2, jsonEncode(playlists));
  }

  // ---- Playback preferences (sort order, shuffle, repeat, reverb, upscaler ...) ----

  Map<String, Object?> loadPlaybackPrefs() {
    final raw = _prefs.getString(_kPlaybackPrefs);
    if (raw == null) return <String, Object?>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    } on FormatException {
      // Corrupted payload: fall back to defaults.
    }
    return <String, Object?>{};
  }

  Future<bool> savePlaybackPrefs(Map<String, Object?> prefs) {
    return _prefs.setString(_kPlaybackPrefs, jsonEncode(prefs));
  }
}

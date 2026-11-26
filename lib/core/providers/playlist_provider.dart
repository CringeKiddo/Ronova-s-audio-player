import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/playlist.dart';
import '../storage/preferences_store.dart';
import 'app_providers.dart';

/// All playlists, persisted as JSON. On first run the old "name -> file paths" playlists are
/// migrated into the new format.
class PlaylistController extends StateNotifier<List<Playlist>> {
  PlaylistController(this._prefs) : super(const <Playlist>[]) {
    _load();
  }

  final PreferencesStore? _prefs;

  void _load() {
    final prefs = _prefs;
    if (prefs == null) return;
    final saved = prefs.loadPlaylistsV2();
    if (saved != null) {
      state = <Playlist>[for (final json in saved) Playlist.fromJson(json)];
      return;
    }
    final legacy = prefs.loadPlaylists();
    if (legacy.isEmpty) return;
    var n = 0;
    state = <Playlist>[
      for (final entry in legacy.entries)
        Playlist(
          id: 'legacy_${n++}_${DateTime.now().microsecondsSinceEpoch}',
          name: entry.key,
          paths: entry.value,
          createdMs: DateTime.now().millisecondsSinceEpoch,
        ),
    ];
    _save();
  }

  void _save() {
    final prefs = _prefs;
    if (prefs == null) return;
    unawaited(prefs.savePlaylistsV2(<Map<String, Object?>>[for (final p in state) p.toJson()]));
  }

  void _set(List<Playlist> next) {
    state = next;
    _save();
  }

  Playlist? byId(String id) {
    for (final p in state) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Creates a playlist and returns it.
  Playlist create(String name, {List<String> paths = const <String>[]}) {
    final clean = name.trim().isEmpty ? 'New playlist' : name.trim();
    final playlist = Playlist(
      id: '${DateTime.now().microsecondsSinceEpoch}_${math.Random().nextInt(9999)}',
      name: clean,
      paths: paths,
      createdMs: DateTime.now().millisecondsSinceEpoch,
    );
    _set(<Playlist>[...state, playlist]);
    return playlist;
  }

  void update(Playlist playlist) {
    _set(<Playlist>[for (final p in state) p.id == playlist.id ? playlist : p]);
  }

  void delete(String id) => _set(<Playlist>[for (final p in state) if (p.id != id) p]);

  Playlist? duplicate(String id) {
    final source = byId(id);
    if (source == null) return null;
    final copy = Playlist(
      id: '${DateTime.now().microsecondsSinceEpoch}_${math.Random().nextInt(9999)}',
      name: '${source.name} (copy)',
      description: source.description,
      paths: List<String>.of(source.paths),
      colorValue: source.colorValue,
      iconKey: source.iconKey,
      coverPath: source.coverPath,
      sort: source.sort,
      autoShuffle: source.autoShuffle,
      repeat: source.repeat,
      speedOverride: source.speedOverride,
      reverbOverride: source.reverbOverride,
      compactRows: source.compactRows,
      showArtwork: source.showArtwork,
      createdMs: DateTime.now().millisecondsSinceEpoch,
    );
    _set(<Playlist>[...state, copy]);
    return copy;
  }

  /// Adds songs (skipping ones already inside). Returns how many were really added.
  int addTracks(String id, Iterable<String> filePaths) {
    final playlist = byId(id);
    if (playlist == null) return 0;
    final existing = playlist.paths.toSet();
    final fresh = <String>[
      for (final path in filePaths)
        if (existing.add(path)) path,
    ];
    if (fresh.isEmpty) return 0;
    update(playlist.copyWith(paths: <String>[...playlist.paths, ...fresh]));
    return fresh.length;
  }

  void removeTrack(String id, String filePath) {
    final playlist = byId(id);
    if (playlist == null) return;
    update(playlist.copyWith(paths: <String>[for (final p in playlist.paths) if (p != filePath) p]));
  }

  /// Moves a song inside the manual order (indices are positions in [Playlist.paths]).
  void reorder(String id, int oldIndex, int newIndex) {
    final playlist = byId(id);
    if (playlist == null) return;
    final list = List<String>.of(playlist.paths);
    if (oldIndex < 0 || oldIndex >= list.length) return;
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    target = target.clamp(0, list.length - 1).toInt();
    final item = list.removeAt(oldIndex);
    list.insert(target, item);
    update(playlist.copyWith(paths: list));
  }

  void togglePinned(String id) {
    final playlist = byId(id);
    if (playlist != null) update(playlist.copyWith(pinned: !playlist.pinned));
  }

  /// Drops files that no longer exist in the library from every playlist.
  void clearMissing(String id, Set<String> knownPaths) {
    final playlist = byId(id);
    if (playlist == null) return;
    update(playlist.copyWith(paths: <String>[for (final p in playlist.paths) if (knownPaths.contains(p)) p]));
  }
}

final playlistsProvider = StateNotifierProvider<PlaylistController, List<Playlist>>((ref) {
  return PlaylistController(ref.read(preferencesStoreProvider));
});

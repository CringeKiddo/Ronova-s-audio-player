import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/local_track_database.dart';
import '../ffi/ronova_ffi_bindings.dart';
import '../models/audio_track.dart';
import '../models/theme_config.dart';
import '../services/native_platform_service.dart';
import '../storage/preferences_store.dart';
import 'app_providers.dart';
import 'theme_settings_provider.dart';

enum RepeatMode { off, all, one }

/// Everything the library, mini-player, center player box and settings screens read.
@immutable
class AudioLibraryState {
  const AudioLibraryState({
    this.allTracks = const <AudioTrack>[],
    this.visibleTracks = const <AudioTrack>[],
    this.sortOrder = TrackSortOrder.downloadNewestFirst,
    this.searchQuery = '',
    this.hasLoaded = false,
    this.isRefreshing = false,
    this.permissionDenied = false,
    this.currentTrack,
    this.queue = const <AudioTrack>[],
    this.queueIndex = -1,
    this.isPlaying = false,
    this.isShuffle = false,
    this.repeatMode = RepeatMode.off,
    this.positionMs = 0,
    this.durationMs = 0,
    this.speed = 1.0,
    this.reverbEnabled = false,
    this.roomSpace = 0.35,
    this.upscalerGainDb = 0.0,
    this.masterVolume = 1.0,
    this.ronovaModeActive = false,
    this.limiterReductionDb = 0.0,
    this.outputRoute = HeadsetHardwareInfo.speaker,
    this.playlists = const <String, List<String>>{},
    this.engineAvailable = false,
    this.errorMessage,
  });

  /// Whole library in the current sort order (hidden tracks excluded).
  final List<AudioTrack> allTracks;

  /// [allTracks] after the live title / artist search filter.
  final List<AudioTrack> visibleTracks;
  final TrackSortOrder sortOrder;
  final String searchQuery;

  /// True once the cached (or scanned) library has been shown at least once.
  final bool hasLoaded;

  /// True while the background MediaStore re-scan is running.
  final bool isRefreshing;
  final bool permissionDenied;

  final AudioTrack? currentTrack;
  final List<AudioTrack> queue;
  final int queueIndex;
  final bool isPlaying;
  final bool isShuffle;
  final RepeatMode repeatMode;
  final int positionMs;
  final int durationMs;

  /// 1.0 down to 0.1 in 0.05 steps.
  final double speed;
  final bool reverbEnabled;

  /// 0.0 .. 1.0 room size of the pitch-linked reverb.
  final double roomSpace;

  /// 0.0 .. 24.0 dB clean volume upscaler.
  final double upscalerGainDb;

  /// 0.0 .. 1.0 linear master volume.
  final double masterVolume;
  final bool ronovaModeActive;

  /// Live brickwall-limiter gain reduction in dB (0 when idle).
  final double limiterReductionDb;
  final HeadsetHardwareInfo outputRoute;

  /// Playlist name -> ordered file paths.
  final Map<String, List<String>> playlists;
  final bool engineAvailable;
  final String? errorMessage;

  bool get hasCurrent => currentTrack != null;
  bool get isSlowed => speed < 0.999;
  bool get upscalerEnabled => upscalerGainDb > 0.05;
  double get progress => durationMs <= 0 ? 0.0 : (positionMs / durationMs).clamp(0.0, 1.0).toDouble();

  int get totalDurationMs {
    var total = 0;
    for (final track in allTracks) {
      total += track.durationMs;
    }
    return total;
  }

  AudioLibraryState copyWith({
    List<AudioTrack>? allTracks,
    List<AudioTrack>? visibleTracks,
    TrackSortOrder? sortOrder,
    String? searchQuery,
    bool? hasLoaded,
    bool? isRefreshing,
    bool? permissionDenied,
    AudioTrack? currentTrack,
    bool clearCurrentTrack = false,
    List<AudioTrack>? queue,
    int? queueIndex,
    bool? isPlaying,
    bool? isShuffle,
    RepeatMode? repeatMode,
    int? positionMs,
    int? durationMs,
    double? speed,
    bool? reverbEnabled,
    double? roomSpace,
    double? upscalerGainDb,
    double? masterVolume,
    bool? ronovaModeActive,
    double? limiterReductionDb,
    HeadsetHardwareInfo? outputRoute,
    Map<String, List<String>>? playlists,
    bool? engineAvailable,
    String? errorMessage,
    bool clearError = false,
  }) {
    return AudioLibraryState(
      allTracks: allTracks ?? this.allTracks,
      visibleTracks: visibleTracks ?? this.visibleTracks,
      sortOrder: sortOrder ?? this.sortOrder,
      searchQuery: searchQuery ?? this.searchQuery,
      hasLoaded: hasLoaded ?? this.hasLoaded,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      permissionDenied: permissionDenied ?? this.permissionDenied,
      currentTrack: clearCurrentTrack ? null : (currentTrack ?? this.currentTrack),
      queue: queue ?? this.queue,
      queueIndex: queueIndex ?? this.queueIndex,
      isPlaying: isPlaying ?? this.isPlaying,
      isShuffle: isShuffle ?? this.isShuffle,
      repeatMode: repeatMode ?? this.repeatMode,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      speed: speed ?? this.speed,
      reverbEnabled: reverbEnabled ?? this.reverbEnabled,
      roomSpace: roomSpace ?? this.roomSpace,
      upscalerGainDb: upscalerGainDb ?? this.upscalerGainDb,
      masterVolume: masterVolume ?? this.masterVolume,
      ronovaModeActive: ronovaModeActive ?? this.ronovaModeActive,
      limiterReductionDb: limiterReductionDb ?? this.limiterReductionDb,
      outputRoute: outputRoute ?? this.outputRoute,
      playlists: playlists ?? this.playlists,
      engineAvailable: engineAvailable ?? this.engineAvailable,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

typedef _TrackComparator = int Function(AudioTrack a, AudioTrack b);

_TrackComparator _comparatorFor(TrackSortOrder order) {
  switch (order) {
    case TrackSortOrder.downloadNewestFirst:
      return (a, b) {
        final c = b.dateAdded.compareTo(a.dateAdded);
        return c != 0 ? c : (b.id ?? 0).compareTo(a.id ?? 0);
      };
    case TrackSortOrder.downloadOldestFirst:
      return (a, b) {
        final c = a.dateAdded.compareTo(b.dateAdded);
        return c != 0 ? c : (a.id ?? 0).compareTo(b.id ?? 0);
      };
    case TrackSortOrder.titleAscending:
      return (a, b) {
        final c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
        return c != 0 ? c : (a.id ?? 0).compareTo(b.id ?? 0);
      };
    case TrackSortOrder.titleDescending:
      return (a, b) {
        final c = b.title.toLowerCase().compareTo(a.title.toLowerCase());
        return c != 0 ? c : (b.id ?? 0).compareTo(a.id ?? 0);
      };
  }
}

/// Stale-while-revalidate library + queue + transport controller. Every playback state change is
/// pushed to the C++ engine ([RonovaDspBridge]) and to the Kotlin notification / gaming overlay
/// ([NativePlatformService]).
class AudioLibraryController extends StateNotifier<AudioLibraryState> {
  AudioLibraryController(this._ref) : super(const AudioLibraryState()) {
    _db = _ref.read(trackDatabaseProvider);
    _ffi = _ref.read(ffiBindingsProvider);
    _prefs = _ref.read(preferencesStoreProvider);
    state = state.copyWith(engineAvailable: _ref.read(bootReportProvider).engineInitOk && _ffi != null);
  }

  final Ref _ref;
  late final LocalTrackDatabase? _db;
  late final RonovaFfiBindings? _ffi;
  late final PreferencesStore? _prefs;
  final NativePlatformService _native = NativePlatformService.instance;
  final math.Random _random = math.Random();

  /// Lower-cased "title artist" strings aligned with `state.allTracks` for instant search.
  List<String> _searchKeys = const <String>[];
  final List<int> _history = <int>[];
  StreamSubscription<NativeControlEvent>? _eventSub;
  Timer? _ticker;
  bool _initialised = false;
  bool _restoredLastTrack = false;
  int _tickCount = 0;
  int _ignoreEndUntilMs = 0;
  double _lastBoostDb = 9.0;

  static const double minSpeed = 0.10;
  static const double maxSpeed = 1.00;
  static const double speedStep = 0.05;
  static const double slowToggleSpeed = 0.85;
  static const double maxUpscalerDb = 24.0;

  /// True when Ronova Mode was active when the app last closed; re-engaged once the bridge is up.
  bool _restoreRonovaMode = false;

  // ------------------------------------------------------------------------------------------
  // Startup
  // ------------------------------------------------------------------------------------------

  /// Restores persisted playback settings and shows the cached library immediately.
  /// Call [refreshFromDevice] afterwards (without awaiting) to revalidate in the background.
  Future<void> initialize() async {
    if (_initialised) return;
    _initialised = true;
    _restorePlaybackPrefs();
    await loadCachedTracks();
    _pushDspState();

    _eventSub = _native.events.listen(_onNativeEvent);
    await _native.initialize();
    if (_restoreRonovaMode) unawaited(setRonovaMode(true));
    unawaited(_native.startHeadsetMonitoring());
    unawaited(refreshOutputRoute());
    unawaited(_syncOverlayOnLaunch());
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
    unawaited(_restoreLastTrack());
  }

  /// Reads the indexed SQLite cache and publishes it (typically a few milliseconds).
  Future<void> loadCachedTracks() async {
    final db = _db;
    if (db == null) {
      state = state.copyWith(hasLoaded: true);
      return;
    }
    try {
      final tracks = await db.getTracks(sort: state.sortOrder);
      _publishLibrary(tracks);
    } catch (error) {
      state = state.copyWith(hasLoaded: true, errorMessage: 'Could not read the library cache: $error');
    }
  }

  /// Background revalidate: MediaStore sweep -> upsert new songs, drop deleted files -> refresh list.
  Future<void> refreshFromDevice() async {
    if (state.isRefreshing || !_native.isSupported) return;
    state = state.copyWith(isRefreshing: true, clearError: true);
    try {
      final scanned = await _native.scanAllTracks();
      final db = _db;
      if (db != null) {
        await db.syncTracks(scanned);
        _publishLibrary(await db.getTracks(sort: state.sortOrder));
      } else {
        final sorted = List<AudioTrack>.of(scanned)..sort(_comparatorFor(state.sortOrder));
        _publishLibrary(sorted);
      }
      state = state.copyWith(permissionDenied: false);
    } on PlatformException catch (error) {
      if (error.code == 'PERMISSION_DENIED') {
        state = state.copyWith(permissionDenied: true);
      } else {
        state = state.copyWith(errorMessage: error.message ?? 'Library scan failed');
      }
    } catch (error) {
      state = state.copyWith(errorMessage: 'Library scan failed: $error');
    } finally {
      state = state.copyWith(isRefreshing: false, hasLoaded: true);
    }
    unawaited(_restoreLastTrack());
  }

  /// Marks the permission gate as satisfied/denied without scanning.
  void setPermissionDenied(bool denied) {
    if (state.permissionDenied == denied) return;
    state = state.copyWith(permissionDenied: denied);
  }

  void clearError() {
    if (state.errorMessage == null) return;
    state = state.copyWith(clearError: true);
  }

  void _publishLibrary(List<AudioTrack> sortedTracks) {
    _searchKeys = <String>[
      for (final t in sortedTracks) '${t.title}\u0000${t.artist}'.toLowerCase(),
    ];
    final current = state.currentTrack;
    AudioTrack? refreshedCurrent;
    if (current != null) {
      for (final t in sortedTracks) {
        if (t.filePath == current.filePath) {
          refreshedCurrent = t;
          break;
        }
      }
    }
    state = state.copyWith(
      allTracks: sortedTracks,
      visibleTracks: _filter(sortedTracks, state.searchQuery),
      hasLoaded: true,
      currentTrack: refreshedCurrent,
    );
  }

  List<AudioTrack> _filter(List<AudioTrack> source, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return source;
    final keys = _searchKeys;
    if (keys.length != source.length) {
      return <AudioTrack>[
        for (final t in source)
          if (t.title.toLowerCase().contains(q) || t.artist.toLowerCase().contains(q)) t,
      ];
    }
    return <AudioTrack>[
      for (var i = 0; i < source.length; i++)
        if (keys[i].contains(q)) source[i],
    ];
  }

  // ------------------------------------------------------------------------------------------
  // Sort / search
  // ------------------------------------------------------------------------------------------

  void setSortOrder(TrackSortOrder order) {
    if (order == state.sortOrder) return;
    final sorted = List<AudioTrack>.of(state.allTracks)..sort(_comparatorFor(order));
    state = state.copyWith(sortOrder: order);
    _publishLibrary(sorted);
    _savePlaybackPrefs();
  }

  void setSearchQuery(String query) {
    if (query == state.searchQuery) return;
    state = state.copyWith(searchQuery: query, visibleTracks: _filter(state.allTracks, query));
  }

  // ------------------------------------------------------------------------------------------
  // Track actions (favorite / tags / delete / playlists)
  // ------------------------------------------------------------------------------------------

  Future<void> toggleFavorite(AudioTrack track) async {
    final updated = track.copyWith(isFavorite: !track.isFavorite);
    final id = track.id;
    if (id != null) {
      try {
        await _db?.setFavorite(id, updated.isFavorite);
      } catch (error) {
        state = state.copyWith(errorMessage: 'Could not save favorite: $error');
        return;
      }
    }
    _replaceTrack(updated);
  }

  Future<void> updateTags(AudioTrack track, {required String title, required String artist}) async {
    final cleanTitle = title.trim().isEmpty ? track.title : title.trim();
    final cleanArtist = artist.trim();
    final id = track.id;
    if (id != null) {
      try {
        await _db?.updateTags(id, title: cleanTitle, artist: cleanArtist);
      } catch (error) {
        state = state.copyWith(errorMessage: 'Could not save tags: $error');
        return;
      }
    }
    final updated = track.copyWith(title: cleanTitle, artist: cleanArtist);
    final resorted = List<AudioTrack>.of(state.allTracks);
    for (var i = 0; i < resorted.length; i++) {
      if (resorted[i].filePath == track.filePath) resorted[i] = updated;
    }
    resorted.sort(_comparatorFor(state.sortOrder));
    _publishLibrary(resorted);
    _replaceInQueue(updated);
    if (state.currentTrack?.filePath == track.filePath) {
      state = state.copyWith(currentTrack: updated);
      unawaited(_syncNotification());
      _syncOverlay();
    }
  }

  /// Removes a track from the library (the file itself stays on disk).
  Future<void> removeFromLibrary(AudioTrack track) async {
    final id = track.id;
    if (id != null) {
      try {
        await _db?.hideTrack(id);
      } catch (error) {
        state = state.copyWith(errorMessage: 'Could not remove track: $error');
        return;
      }
    }
    final wasCurrent = state.currentTrack?.filePath == track.filePath;
    final remaining = <AudioTrack>[
      for (final t in state.allTracks)
        if (t.filePath != track.filePath) t,
    ];
    final newQueue = <AudioTrack>[
      for (final t in state.queue)
        if (t.filePath != track.filePath) t,
    ];
    _publishLibrary(remaining);
    state = state.copyWith(queue: newQueue);
    if (wasCurrent) {
      _ffi?.pause();
      state = state.copyWith(isPlaying: false, clearCurrentTrack: true, positionMs: 0, durationMs: 0, queueIndex: -1);
      unawaited(_native.stopNotification());
    } else if (state.currentTrack != null) {
      final index = newQueue.indexWhere((t) => t.filePath == state.currentTrack!.filePath);
      state = state.copyWith(queueIndex: index);
    }
  }

  void _replaceTrack(AudioTrack updated) {
    AudioTrack swap(AudioTrack t) => t.filePath == updated.filePath ? updated : t;
    final all = <AudioTrack>[for (final t in state.allTracks) swap(t)];
    final visible = <AudioTrack>[for (final t in state.visibleTracks) swap(t)];
    final current = state.currentTrack;
    state = state.copyWith(
      allTracks: all,
      visibleTracks: visible,
      queue: <AudioTrack>[for (final t in state.queue) swap(t)],
      currentTrack: current != null && current.filePath == updated.filePath ? updated : current,
    );
  }

  void _replaceInQueue(AudioTrack updated) {
    state = state.copyWith(
      queue: <AudioTrack>[
        for (final t in state.queue) t.filePath == updated.filePath ? updated : t,
      ],
    );
  }

  /// Creates an empty playlist. Returns false when the name is blank or already used.
  bool createPlaylist(String name) {
    final clean = name.trim();
    if (clean.isEmpty || state.playlists.containsKey(clean)) return false;
    final next = <String, List<String>>{...state.playlists, clean: <String>[]};
    state = state.copyWith(playlists: next);
    unawaited(_prefs?.savePlaylists(next));
    return true;
  }

  /// Adds [track] to [playlistName] (created when missing). Returns false if it was already there.
  bool addToPlaylist(String playlistName, AudioTrack track) {
    final existing = List<String>.of(state.playlists[playlistName] ?? const <String>[]);
    if (existing.contains(track.filePath)) return false;
    existing.add(track.filePath);
    final next = <String, List<String>>{...state.playlists, playlistName: existing};
    state = state.copyWith(playlists: next);
    unawaited(_prefs?.savePlaylists(next));
    return true;
  }

  // ------------------------------------------------------------------------------------------
  // Queue & transport
  // ------------------------------------------------------------------------------------------

  /// Plays [track]. Pass [queue] (usually the visible list) to define what plays next.
  Future<void> playTrack(AudioTrack track, {List<AudioTrack>? queue}) async {
    var list = queue == null ? state.queue : List<AudioTrack>.of(queue);
    var index = list.indexWhere((t) => t.filePath == track.filePath);
    if (index < 0) {
      list = <AudioTrack>[track];
      index = 0;
    }
    if (queue != null) _history.clear();
    state = state.copyWith(queue: list);
    await _playIndex(index);
  }

  /// Starts the visible list from a random song with shuffle on.
  Future<void> shuffleAll() async {
    final list = state.visibleTracks;
    if (list.isEmpty) return;
    state = state.copyWith(isShuffle: true);
    _savePlaybackPrefs();
    await playTrack(list[_random.nextInt(list.length)], queue: list);
  }

  Future<void> playNext(AudioTrack track) async {
    if (state.currentTrack == null || state.queue.isEmpty) {
      await playTrack(track);
      return;
    }
    final queue = List<AudioTrack>.of(state.queue);
    var index = state.queueIndex;
    final existing = queue.indexWhere((t) => t.filePath == track.filePath);
    if (existing >= 0 && existing != index) {
      queue.removeAt(existing);
      if (existing < index) index--;
    }
    if (existing == index) return; // it is the track that is playing right now
    queue.insert(math.min(index + 1, queue.length), track);
    state = state.copyWith(queue: queue, queueIndex: index);
  }

  Future<void> addToQueue(AudioTrack track) async {
    if (state.currentTrack == null || state.queue.isEmpty) {
      await playTrack(track);
      return;
    }
    final queue = List<AudioTrack>.of(state.queue);
    if (queue.any((t) => t.filePath == track.filePath)) return;
    queue.add(track);
    state = state.copyWith(queue: queue);
  }

  Future<void> _playIndex(int index, {int attempts = 0}) async {
    final queue = state.queue;
    if (index < 0 || index >= queue.length) return;
    final track = queue[index];
    final ok = await _loadTrack(track, autoplay: true);
    if (ok) {
      state = state.copyWith(queueIndex: index);
      return;
    }
    // Unreadable file: skip forward, but never loop forever.
    if (attempts + 1 < queue.length && queue.length > 1) {
      await _playIndex((index + 1) % queue.length, attempts: attempts + 1);
    }
  }

  Future<bool> _loadTrack(AudioTrack track, {required bool autoplay, int startMs = 0}) async {
    final ffi = _ffi;
    if (ffi == null) {
      state = state.copyWith(errorMessage: 'The audio engine is not available on this device.');
      return false;
    }
    final ok = ffi.loadFile(track.filePath);
    if (!ok) {
      state = state.copyWith(errorMessage: 'Could not open "${track.title}".');
      return false;
    }
    _pushDspState();
    if (startMs > 0) ffi.seekMs(startMs);
    final nativeDuration = ffi.durationMs;
    _ignoreEndUntilMs = DateTime.now().millisecondsSinceEpoch + 1200;
    state = state.copyWith(
      currentTrack: track,
      positionMs: startMs,
      durationMs: nativeDuration > 0 ? nativeDuration : track.durationMs,
      isPlaying: autoplay,
    );
    if (autoplay) ffi.play();
    unawaited(_syncNotification(trackChanged: true));
    _syncOverlay();
    _savePlayback();
    return true;
  }

  Future<void> togglePlayPause() async {
    if (state.currentTrack == null) {
      final list = state.visibleTracks;
      if (list.isNotEmpty) await playTrack(list.first, queue: list);
      return;
    }
    if (state.isPlaying) {
      await pause();
    } else {
      await resume();
    }
  }

  Future<void> resume() async {
    final ffi = _ffi;
    if (state.currentTrack == null || ffi == null) return;
    _ignoreEndUntilMs = DateTime.now().millisecondsSinceEpoch + 600;
    ffi.play();
    state = state.copyWith(isPlaying: true);
    unawaited(_syncNotification());
    _syncOverlay();
  }

  Future<void> pause() async {
    final ffi = _ffi;
    if (ffi == null) return;
    ffi.pause();
    state = state.copyWith(isPlaying: false, positionMs: ffi.positionMs);
    unawaited(_syncNotification());
    _syncOverlay();
    _savePlayback();
  }

  Future<void> next({bool auto = false}) async {
    final queue = state.queue;
    if (queue.isEmpty) return;
    final current = state.queueIndex;
    int target;
    if (state.isShuffle && queue.length > 1) {
      do {
        target = _random.nextInt(queue.length);
      } while (target == current);
      if (current >= 0) _history.add(current);
    } else {
      target = current + 1;
      if (target >= queue.length) {
        if (auto && state.repeatMode != RepeatMode.all) {
          await _finishQueue();
          return;
        }
        target = 0;
      }
    }
    await _playIndex(target);
  }

  Future<void> previous() async {
    final queue = state.queue;
    if (queue.isEmpty) return;
    if (state.positionMs > 3000) {
      await seekMs(0);
      return;
    }
    int target;
    if (state.isShuffle && _history.isNotEmpty) {
      target = _history.removeLast();
    } else {
      target = state.queueIndex - 1;
      if (target < 0) target = queue.length - 1;
    }
    await _playIndex(target);
  }

  Future<void> _finishQueue() async {
    final ffi = _ffi;
    ffi?.pause();
    ffi?.seekMs(0);
    state = state.copyWith(isPlaying: false, positionMs: 0);
    unawaited(_syncNotification());
    _syncOverlay();
    _savePlayback();
  }

  Future<void> seekMs(int positionMs) async {
    final ffi = _ffi;
    if (ffi == null || state.currentTrack == null) return;
    final upper = state.durationMs > 0 ? state.durationMs : positionMs;
    final target = positionMs.clamp(0, upper).toInt();
    ffi.seekMs(target);
    _ignoreEndUntilMs = DateTime.now().millisecondsSinceEpoch + 500;
    state = state.copyWith(positionMs: target);
  }

  void toggleShuffle() {
    _history.clear();
    state = state.copyWith(isShuffle: !state.isShuffle);
    _savePlaybackPrefs();
  }

  void cycleRepeat() {
    final next = switch (state.repeatMode) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };
    state = state.copyWith(repeatMode: next);
    _savePlaybackPrefs();
  }

  // ------------------------------------------------------------------------------------------
  // DSP parameters (C++ engine + native overlay)
  // ------------------------------------------------------------------------------------------

  /// Quantises to 0.05 steps within 0.10 .. 1.00.
  static double quantiseSpeed(double value) {
    final stepped = (value / speedStep).round() * speedStep;
    return (stepped.clamp(minSpeed, maxSpeed).toDouble() * 100).round() / 100.0;
  }

  void setSpeed(double value, {bool fromOverlay = false}) {
    final speed = quantiseSpeed(value);
    if ((speed - state.speed).abs() < 0.0001) return;
    _ffi?.setSpeed(speed);
    final wasSlowed = state.isSlowed;
    state = state.copyWith(speed: speed);
    if (wasSlowed != state.isSlowed) unawaited(_syncNotification());
    _syncOverlay(includeSpeed: !fromOverlay);
    _savePlaybackPrefs();
  }

  void toggleSlow() => setSpeed(state.isSlowed ? 1.0 : slowToggleSpeed);

  void setReverbEnabled(bool enabled) {
    _ffi?.setReverbEnabled(enabled);
    state = state.copyWith(reverbEnabled: enabled);
    _syncOverlay();
    _savePlaybackPrefs();
  }

  void setRoomSpace(double value) {
    final room = value.clamp(0.0, 1.0).toDouble();
    _ffi?.setRoomSpace(room);
    state = state.copyWith(roomSpace: room);
    _savePlaybackPrefs();
  }

  void setUpscalerGainDb(double gainDb) {
    final gain = gainDb.clamp(0.0, maxUpscalerDb).toDouble();
    if (gain > 0.05) _lastBoostDb = gain;
    _ffi?.setVolumeUpscalerGain(gain);
    state = state.copyWith(upscalerGainDb: gain, limiterReductionDb: gain > 0.05 ? state.limiterReductionDb : 0.0);
    _syncOverlay();
    _savePlaybackPrefs();
  }

  void setUpscalerEnabled(bool enabled) => setUpscalerGainDb(enabled ? _lastBoostDb : 0.0);

  void setMasterVolume(double value) {
    final volume = value.clamp(0.0, 1.0).toDouble();
    _ffi?.setMasterVolume(volume);
    state = state.copyWith(masterVolume: volume);
    _savePlaybackPrefs();
  }

  /// Engages / releases Ronova Mode (crossfeed, 11.5 kHz air shelf, sub-bass punch, Bluetooth
  /// compensation, native sample-rate lock) calibrated to the connected headset.
  Future<void> setRonovaMode(bool enabled) async {
    final ffi = _ffi;
    if (ffi == null) {
      state = state.copyWith(ronovaModeActive: false, errorMessage: 'The audio engine is not available.');
      _syncOverlay();
      return;
    }
    if (enabled) {
      final info = await _native.analyzeHeadsetHardware();
      state = state.copyWith(outputRoute: info);
      ffi.setHardwareProfile(info.ronovaProfile);
    }
    final ok = ffi.engageRonovaMode(enabled);
    final active = enabled && ok;
    state = state.copyWith(
      ronovaModeActive: active,
      errorMessage: enabled && !ok ? 'Ronova Mode could not engage on this output.' : null,
    );
    _syncOverlay();
    _savePlaybackPrefs();
  }

  void _pushDspState() {
    final ffi = _ffi;
    if (ffi == null) return;
    ffi.setSpeed(state.speed);
    ffi.setReverbEnabled(state.reverbEnabled);
    ffi.setRoomSpace(state.roomSpace);
    ffi.setVolumeUpscalerGain(state.upscalerGainDb);
    ffi.setMasterVolume(state.masterVolume);
    ffi.setMonoMode(_ref.read(themeSettingsProvider).isMonoMode);
  }

  // ------------------------------------------------------------------------------------------
  // Output route (headphones / USB DAC / Bluetooth)
  // ------------------------------------------------------------------------------------------

  /// Re-queries the active headset / DAC / Bluetooth route (e.g. after Bluetooth permission).
  Future<void> refreshOutputRoute() async {
    final info = await _native.analyzeHeadsetHardware();
    _applyRoute(info);
  }

  void _applyRoute(HeadsetHardwareInfo info) {
    state = state.copyWith(outputRoute: info);
    final ffi = _ffi;
    if (ffi == null) return;
    ffi.setHardwareProfile(info.ronovaProfile);
    if (state.ronovaModeActive) {
      // Re-engage so the engine re-locks the new device's highest native sample rate.
      ffi.engageRonovaMode(true);
    }
  }

  // ------------------------------------------------------------------------------------------
  // Settings / theme reactions
  // ------------------------------------------------------------------------------------------

  /// Wired up in [audioLibraryProvider] with `ref.listen` on the theme settings.
  void onThemeConfigChanged(ThemeConfig? previous, ThemeConfig next) {
    if (previous == null || previous.isMonoMode != next.isMonoMode) {
      _ffi?.setMonoMode(next.isMonoMode);
    }
    if (previous != null &&
        next.overlayEnabled &&
        (previous.overlayScale != next.overlayScale ||
            previous.overlayOpacity != next.overlayOpacity ||
            previous.doubleTapToOpen != next.doubleTapToOpen)) {
      unawaited(
        _native.updateOverlayState(
          doubleTap: next.doubleTapToOpen,
          scale: next.overlayScale,
          opacity: next.overlayOpacity,
        ),
      );
    }
  }

  /// Starts the floating red "R" overlay. [OverlayStartResult.needsPermission] is true when the
  /// "Display over other apps" permission has to be granted first.
  Future<OverlayStartResult> enableOverlay() async {
    final theme = _ref.read(themeSettingsProvider);
    final result = await _native.startFloatingOverlay(
      doubleTap: theme.doubleTapToOpen,
      scale: theme.overlayScale,
      opacity: theme.overlayOpacity,
    );
    if (result.started) {
      _ref.read(themeSettingsProvider.notifier).setOverlayEnabled(true);
      _syncOverlay();
    }
    return result;
  }

  Future<void> disableOverlay() async {
    await _native.stopFloatingOverlay();
    _ref.read(themeSettingsProvider.notifier).setOverlayEnabled(false);
  }

  Future<void> _syncOverlayOnLaunch() async {
    final theme = _ref.read(themeSettingsProvider);
    if (!theme.overlayEnabled) return;
    if (await _native.canDrawOverlays()) {
      if (!await _native.isOverlayRunning()) {
        await _native.startFloatingOverlay(
          doubleTap: theme.doubleTapToOpen,
          scale: theme.overlayScale,
          opacity: theme.overlayOpacity,
        );
      }
      _syncOverlay();
    } else {
      _ref.read(themeSettingsProvider.notifier).setOverlayEnabled(false);
    }
  }

  void _syncOverlay({bool includeSpeed = true}) {
    if (!_ref.read(themeSettingsProvider).overlayEnabled) return;
    unawaited(
      _native.updateOverlayState(
        title: state.currentTrack?.title ?? '',
        isPlaying: state.isPlaying,
        speed: includeSpeed ? state.speed : null,
        reverbEnabled: state.reverbEnabled,
        upscalerEnabled: state.upscalerEnabled,
        ronovaEnabled: state.ronovaModeActive,
      ),
    );
  }

  // ------------------------------------------------------------------------------------------
  // Notification / lockscreen
  // ------------------------------------------------------------------------------------------

  Future<void> _syncNotification({bool trackChanged = false}) async {
    final track = state.currentTrack;
    if (track == null) {
      await _native.stopNotification();
      return;
    }
    Uint8List? art;
    if (trackChanged) {
      art = await _native.getAlbumArt(track.filePath);
      // A newer track may have started while the cover was loading.
      if (state.currentTrack?.filePath != track.filePath) return;
    }
    await _native.updateNotificationState(
      title: track.title,
      artist: track.artist,
      isPlaying: state.isPlaying,
      isSlowed: state.isSlowed,
      artBytes: art,
      keepArt: !trackChanged,
    );
  }

  // ------------------------------------------------------------------------------------------
  // Native control events (notification, lockscreen, headset buttons, gaming overlay)
  // ------------------------------------------------------------------------------------------

  void _onNativeEvent(NativeControlEvent event) {
    switch (event.action) {
      case NativeControlAction.next:
        unawaited(next());
      case NativeControlAction.previous:
        unawaited(previous());
      case NativeControlAction.playPause:
        final play = event.play ?? !state.isPlaying;
        unawaited(play ? resume() : pause());
      case NativeControlAction.toggleSlow:
        setSpeed(event.speed ?? (state.isSlowed ? 1.0 : slowToggleSpeed));
      case NativeControlAction.setSpeed:
        final speed = event.speed;
        if (speed != null) setSpeed(speed, fromOverlay: event.source == NativeControlSource.overlay);
      case NativeControlAction.toggleReverb:
        setReverbEnabled(event.enabled ?? !state.reverbEnabled);
      case NativeControlAction.toggleRonova:
        unawaited(setRonovaMode(event.enabled ?? !state.ronovaModeActive));
      case NativeControlAction.setUpscaler:
        setUpscalerEnabled(event.enabled ?? !state.upscalerEnabled);
      case NativeControlAction.overlayClosed:
        _ref.read(themeSettingsProvider.notifier).setOverlayEnabled(false);
      case NativeControlAction.notificationDismissed:
        break;
      case NativeControlAction.audioRouteChanged:
        final hardware = event.hardware;
        if (hardware != null) _applyRoute(hardware);
    }
  }

  // ------------------------------------------------------------------------------------------
  // Position ticker (250 ms)
  // ------------------------------------------------------------------------------------------

  void _tick() {
    final ffi = _ffi;
    if (ffi == null || state.currentTrack == null) return;
    _tickCount++;

    final engineIsPlaying = ffi.isPlaying;
    final position = ffi.positionMs;
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    if (state.isPlaying && !engineIsPlaying && nowMs >= _ignoreEndUntilMs) {
      final duration = state.durationMs;
      final atEnd = duration > 0 && position >= duration - 500;
      if (atEnd) {
        unawaited(_onTrackEnded());
        return;
      }
      // The engine stopped for some other reason: reflect it instead of showing a stuck "playing".
      state = state.copyWith(isPlaying: false, positionMs: position);
      unawaited(_syncNotification());
      _syncOverlay();
      return;
    }

    var limiter = state.limiterReductionDb;
    if (state.upscalerEnabled && engineIsPlaying) {
      final reading = ffi.peakReductionDb;
      limiter = reading.isNaN ? 0.0 : reading.clamp(0.0, 30.0).toDouble();
    } else if (limiter != 0.0) {
      limiter = 0.0;
    }

    state = state.copyWith(
      positionMs: position,
      limiterReductionDb: (limiter - state.limiterReductionDb).abs() > 0.15 ? limiter : null,
    );

    if (_tickCount % 40 == 0 && state.isPlaying) _savePlayback();
  }

  Future<void> _onTrackEnded() async {
    if (state.repeatMode == RepeatMode.one) {
      _ffi?.seekMs(0);
      _ignoreEndUntilMs = DateTime.now().millisecondsSinceEpoch + 800;
      _ffi?.play();
      state = state.copyWith(positionMs: 0, isPlaying: true);
      return;
    }
    await next(auto: true);
  }

  // ------------------------------------------------------------------------------------------
  // Persistence
  // ------------------------------------------------------------------------------------------

  void _restorePlaybackPrefs() {
    final prefs = _prefs;
    if (prefs == null) return;
    final raw = prefs.loadPlaybackPrefs();
    double dbl(String key, double fallback) => raw[key] is num ? (raw[key]! as num).toDouble() : fallback;
    final sortName = raw['sortOrder'];
    final repeatName = raw['repeatMode'];
    final upscaler = dbl('upscalerGainDb', 0.0).clamp(0.0, maxUpscalerDb).toDouble();
    if (upscaler > 0.05) _lastBoostDb = upscaler;
    _restoreRonovaMode = raw['ronovaMode'] == true;
    state = state.copyWith(
      sortOrder: TrackSortOrder.values.firstWhere(
        (o) => o.name == sortName,
        orElse: () => TrackSortOrder.downloadNewestFirst,
      ),
      isShuffle: raw['isShuffle'] == true,
      repeatMode: RepeatMode.values.firstWhere(
        (m) => m.name == repeatName,
        orElse: () => RepeatMode.off,
      ),
      speed: quantiseSpeed(dbl('speed', 1.0)),
      reverbEnabled: raw['reverbEnabled'] == true,
      roomSpace: dbl('roomSpace', 0.35).clamp(0.0, 1.0).toDouble(),
      upscalerGainDb: upscaler,
      masterVolume: dbl('masterVolume', 1.0).clamp(0.0, 1.0).toDouble(),
      playlists: prefs.loadPlaylists(),
    );
  }

  void _savePlaybackPrefs() {
    final prefs = _prefs;
    if (prefs == null) return;
    final existing = prefs.loadPlaybackPrefs();
    existing
      ..['sortOrder'] = state.sortOrder.name
      ..['isShuffle'] = state.isShuffle
      ..['repeatMode'] = state.repeatMode.name
      ..['speed'] = state.speed
      ..['ronovaMode'] = state.ronovaModeActive
      ..['reverbEnabled'] = state.reverbEnabled
      ..['roomSpace'] = state.roomSpace
      ..['upscalerGainDb'] = state.upscalerGainDb
      ..['masterVolume'] = state.masterVolume;
    unawaited(prefs.savePlaybackPrefs(existing));
  }

  /// Remembers the last track + position so the app reopens exactly where playback stopped.
  void _savePlayback() {
    final prefs = _prefs;
    final track = state.currentTrack;
    if (prefs == null || track == null) return;
    final existing = prefs.loadPlaybackPrefs();
    existing
      ..['lastTrackPath'] = track.filePath
      ..['lastPositionMs'] = _ffi?.positionMs ?? state.positionMs;
    unawaited(prefs.savePlaybackPrefs(existing));
  }

  Future<void> _restoreLastTrack() async {
    if (_restoredLastTrack || state.currentTrack != null || state.allTracks.isEmpty) return;
    final prefs = _prefs;
    if (prefs == null) return;
    final raw = prefs.loadPlaybackPrefs();
    final path = raw['lastTrackPath'];
    if (path is! String) {
      _restoredLastTrack = true;
      return;
    }
    final index = state.allTracks.indexWhere((t) => t.filePath == path);
    _restoredLastTrack = true;
    if (index < 0) return;
    final position = raw['lastPositionMs'] is num ? (raw['lastPositionMs']! as num).toInt() : 0;
    final track = state.allTracks[index];
    state = state.copyWith(queue: state.allTracks, queueIndex: index);
    await _loadTrack(track, autoplay: false, startMs: position);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _eventSub?.cancel();
    _savePlayback();
    super.dispose();
  }
}

/// Library + playback state, wired to the theme settings so mono mode and overlay options
/// propagate to the engine and the Kotlin overlay.
final audioLibraryProvider = StateNotifierProvider<AudioLibraryController, AudioLibraryState>((ref) {
  final controller = AudioLibraryController(ref);
  ref.listen<ThemeConfig>(themeSettingsProvider, controller.onThemeConfigChanged);
  return controller;
});

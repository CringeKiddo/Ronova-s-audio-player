import 'dart:async';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/audio_track.dart';

/// Library sort orders. [orderBy] is a fixed SQL fragment (never user input).
enum TrackSortOrder {
  downloadNewestFirst('Download Order (Newest First)', 'dateAdded DESC, id DESC'),
  downloadOldestFirst('Backwards Download (Oldest First)', 'dateAdded ASC, id ASC'),
  titleAscending('A - Z', 'title COLLATE NOCASE ASC, id ASC'),
  titleDescending('Z - A', 'title COLLATE NOCASE DESC, id DESC');

  const TrackSortOrder(this.label, this.orderBy);

  final String label;
  final String orderBy;

  // Spec-facing names (Batch 4 prompt) for the same four orders.
  static const TrackSortOrder newestDownloads = downloadNewestFirst;
  static const TrackSortOrder oldestDownloads = downloadOldestFirst;
  static const TrackSortOrder titleAZ = titleAscending;
  static const TrackSortOrder titleZA = titleDescending;
}

/// Result of a library sync.
class TrackSyncResult {
  const TrackSyncResult({
    required this.inserted,
    required this.updated,
    required this.removed,
  });

  final int inserted;
  final int updated;
  final int removed;

  int get total => inserted + updated;

  @override
  String toString() => 'TrackSyncResult(inserted: $inserted, updated: $updated, removed: $removed)';
}

/// Indexed SQLite cache of the on-device audio library for instant startup.
class LocalTrackDatabase {
  LocalTrackDatabase._(this._db, this.path, this.openElapsedMicros);

  static const String databaseFileName = 'ronova_tracks.db';
  static const int _schemaVersion = 2;
  static const int _deleteChunkSize = 500;

  final Database _db;
  final String path;

  /// Time taken by [open] in microseconds (startup metric).
  final int openElapsedMicros;

  /// Opens (creating if needed) the track cache.
  /// Pass [path] to open an alternate file (benchmarks, tests).
  static Future<LocalTrackDatabase> open({String? path}) async {
    final watch = Stopwatch()..start();
    final resolvedPath = path ?? p.join((await getApplicationSupportDirectory()).path, databaseFileName);
    final db = await openDatabase(
      resolvedPath,
      version: _schemaVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    watch.stop();
    return LocalTrackDatabase._(db, resolvedPath, watch.elapsedMicroseconds);
  }

  static Future<void> _onConfigure(Database db) async {
    try {
      await db.rawQuery('PRAGMA journal_mode=WAL');
    } catch (_) {
      // WAL is a performance optimisation only; continue with the default journal.
    }
    try {
      await db.execute('PRAGMA synchronous=NORMAL');
    } catch (_) {
      // Optional tuning; ignore if the platform rejects it.
    }
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE ${AudioTrackColumns.table} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        mediaStoreId INTEGER NOT NULL DEFAULT 0,
        title TEXT NOT NULL,
        artist TEXT NOT NULL DEFAULT '',
        album TEXT NOT NULL DEFAULT '',
        filePath TEXT NOT NULL UNIQUE,
        durationMs INTEGER NOT NULL DEFAULT 0,
        dateAdded INTEGER NOT NULL DEFAULT 0,
        dateModified INTEGER NOT NULL DEFAULT 0,
        fileSize INTEGER NOT NULL DEFAULT 0,
        sampleRate INTEGER NOT NULL DEFAULT 0,
        bitDepth INTEGER NOT NULL DEFAULT 0,
        isFavorite INTEGER NOT NULL DEFAULT 0,
        tagsLocked INTEGER NOT NULL DEFAULT 0,
        isHidden INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX idx_date_added ON ${AudioTrackColumns.table}(dateAdded)');
    await db.execute('CREATE INDEX idx_title ON ${AudioTrackColumns.table}(title COLLATE NOCASE)');
    await db.execute('CREATE INDEX idx_media_store_id ON ${AudioTrackColumns.table}(mediaStoreId)');
    await db.execute(
      'CREATE INDEX idx_favorite ON ${AudioTrackColumns.table}(isFavorite) WHERE isFavorite = 1',
    );
  }

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v2: user-edited tags survive re-scans; "Delete" hides a track from the library.
      await db.execute('ALTER TABLE ${AudioTrackColumns.table} ADD COLUMN tagsLocked INTEGER NOT NULL DEFAULT 0');
      await db.execute('ALTER TABLE ${AudioTrackColumns.table} ADD COLUMN isHidden INTEGER NOT NULL DEFAULT 0');
    }
  }

  // -------------------------------------------------------------------------
  // Sync
  // -------------------------------------------------------------------------

  /// Inserts new tracks and refreshes existing ones (matched by filePath),
  /// preserving each track's favorite flag. Returns the number inserted.
  Future<int> upsertTracks(List<AudioTrack> tracks) {
    return _db.transaction((txn) async {
      final existing = await _existingPaths(txn);
      final outcome = await _upsertInto(txn, tracks, existing);
      return outcome.inserted;
    });
  }

  /// Deletes every cached track whose path is not in [presentPaths].
  /// Returns the number of rows removed.
  Future<int> pruneMissing(Set<String> presentPaths) {
    return _db.transaction((txn) => _pruneInto(txn, presentPaths));
  }

  /// Full library sync in one transaction: upsert everything scanned, then
  /// prune anything no longer on disk.
  Future<TrackSyncResult> syncTracks(List<AudioTrack> scanned) {
    return _db.transaction((txn) async {
      final existing = await _existingPaths(txn);
      final outcome = await _upsertInto(txn, scanned, existing);
      final removed = await _pruneInto(txn, outcome.seen);
      return TrackSyncResult(
        inserted: outcome.inserted,
        updated: outcome.updated,
        removed: removed,
      );
    });
  }

  Future<Set<String>> _existingPaths(DatabaseExecutor executor) async {
    final rows = await executor.rawQuery('SELECT filePath FROM ${AudioTrackColumns.table}');
    return <String>{for (final row in rows) row[AudioTrackColumns.filePath]! as String};
  }

  Future<({int inserted, int updated, Set<String> seen})> _upsertInto(
    DatabaseExecutor executor,
    List<AudioTrack> tracks,
    Set<String> existing,
  ) async {
    final seen = <String>{};
    var inserted = 0;
    var updated = 0;
    final batch = executor.batch();
    for (final track in tracks) {
      if (!seen.add(track.filePath)) continue;
      if (existing.contains(track.filePath)) {
        updated++;
        batch.rawUpdate(
          'UPDATE ${AudioTrackColumns.table} SET '
          'mediaStoreId = ?, '
          'title = CASE WHEN tagsLocked = 1 THEN title ELSE ? END, '
          'artist = CASE WHEN tagsLocked = 1 THEN artist ELSE ? END, '
          'album = ?, durationMs = ?, dateAdded = ?, dateModified = ?, fileSize = ?, '
          'sampleRate = ?, bitDepth = ? '
          'WHERE filePath = ?',
          <Object?>[
            track.mediaStoreId,
            track.title,
            track.artist,
            track.album,
            track.durationMs,
            track.dateAdded,
            track.dateModified,
            track.fileSize,
            track.sampleRate,
            track.bitDepth,
            track.filePath,
          ],
        );
      } else {
        inserted++;
        batch.insert(
          AudioTrackColumns.table,
          track.toDbMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }
    await batch.commit(noResult: true);
    return (inserted: inserted, updated: updated, seen: seen);
  }

  Future<int> _pruneInto(DatabaseExecutor executor, Set<String> keep) async {
    final existing = await _existingPaths(executor);
    final stale = existing.difference(keep).toList(growable: false);
    var removed = 0;
    for (var i = 0; i < stale.length; i += _deleteChunkSize) {
      final chunk = stale.sublist(i, math.min(i + _deleteChunkSize, stale.length));
      final placeholders = List<String>.filled(chunk.length, '?').join(',');
      removed += await executor.delete(
        AudioTrackColumns.table,
        where: '${AudioTrackColumns.filePath} IN ($placeholders)',
        whereArgs: chunk,
      );
    }
    return removed;
  }

  // -------------------------------------------------------------------------
  // Queries
  // -------------------------------------------------------------------------

  Future<List<AudioTrack>> getTracks({
    TrackSortOrder sort = TrackSortOrder.downloadNewestFirst,
    int? limit,
    int? offset,
    bool favoritesOnly = false,
  }) async {
    final rows = await _db.query(
      AudioTrackColumns.table,
      where: favoritesOnly ? 'isHidden = 0 AND ${AudioTrackColumns.isFavorite} = 1' : 'isHidden = 0',
      orderBy: sort.orderBy,
      limit: limit ?? (offset != null ? -1 : null),
      offset: offset,
    );
    return rows.map(AudioTrack.fromDbMap).toList(growable: false);
  }

  /// Case-insensitive substring search across title, artist and album.
  Future<List<AudioTrack>> searchTracks(
    String query, {
    TrackSortOrder sort = TrackSortOrder.titleAscending,
    int? limit,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return getTracks(sort: sort, limit: limit);
    }
    final escaped = trimmed.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
    final pattern = '%$escaped%';
    final rows = await _db.query(
      AudioTrackColumns.table,
      where: r"isHidden = 0 AND (title LIKE ? ESCAPE '\' OR artist LIKE ? ESCAPE '\' OR album LIKE ? ESCAPE '\')",
      whereArgs: <Object?>[pattern, pattern, pattern],
      orderBy: sort.orderBy,
      limit: limit,
    );
    return rows.map(AudioTrack.fromDbMap).toList(growable: false);
  }

  Future<int> count() async {
    final result = await _db.rawQuery('SELECT COUNT(*) AS c FROM ${AudioTrackColumns.table} WHERE isHidden = 0');
    final value = result.first['c'];
    return value is int ? value : (value as num?)?.toInt() ?? 0;
  }

  Future<void> setFavorite(int trackId, bool isFavorite) async {
    await _db.update(
      AudioTrackColumns.table,
      <String, Object?>{AudioTrackColumns.isFavorite: isFavorite ? 1 : 0},
      where: '${AudioTrackColumns.id} = ?',
      whereArgs: <Object?>[trackId],
    );
  }

  /// Saves user-edited tags for one track and locks them so future MediaStore scans keep them.
  Future<void> updateTags(int trackId, {required String title, required String artist}) async {
    await _db.update(
      AudioTrackColumns.table,
      <String, Object?>{
        AudioTrackColumns.title: title,
        AudioTrackColumns.artist: artist,
        'tagsLocked': 1,
      },
      where: '${AudioTrackColumns.id} = ?',
      whereArgs: <Object?>[trackId],
    );
  }

  /// Removes a track from the library view. The file stays on disk; the row is kept (hidden)
  /// so the next scan does not bring it straight back.
  Future<void> hideTrack(int trackId) async {
    await _db.update(
      AudioTrackColumns.table,
      <String, Object?>{'isHidden': 1},
      where: '${AudioTrackColumns.id} = ?',
      whereArgs: <Object?>[trackId],
    );
  }

  Future<void> clear() async {
    await _db.delete(AudioTrackColumns.table);
  }

  Future<void> close() => _db.close();
}

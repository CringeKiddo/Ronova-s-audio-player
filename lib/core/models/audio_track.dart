import 'package:flutter/foundation.dart';

/// Column names for the `tracks` SQLite table.
abstract final class AudioTrackColumns {
  static const String table = 'tracks';
  static const String id = 'id';
  static const String mediaStoreId = 'mediaStoreId';
  static const String title = 'title';
  static const String artist = 'artist';
  static const String album = 'album';
  static const String filePath = 'filePath';
  static const String durationMs = 'durationMs';
  static const String dateAdded = 'dateAdded';
  static const String dateModified = 'dateModified';
  static const String fileSize = 'fileSize';
  static const String sampleRate = 'sampleRate';
  static const String bitDepth = 'bitDepth';
  static const String isFavorite = 'isFavorite';
}

int _asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? fallback;
}

String _asString(Object? value, [String fallback = '']) {
  return value == null ? fallback : '$value';
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  return value == 'true';
}

/// A single audio file known to the local library.
///
/// [dateAdded] and [dateModified] are Unix timestamps in seconds (MediaStore
/// convention); [dateAdded] drives the Newest / Oldest download sort orders.
@immutable
class AudioTrack {
  const AudioTrack({
    this.id,
    required this.mediaStoreId,
    required this.title,
    this.artist = '',
    this.album = '',
    required this.filePath,
    this.durationMs = 0,
    this.dateAdded = 0,
    this.dateModified = 0,
    this.fileSize = 0,
    this.sampleRate = 0,
    this.bitDepth = 0,
    this.isFavorite = false,
  });

  /// Local database row id (null until inserted).
  final int? id;
  final int mediaStoreId;
  final String title;
  final String artist;
  final String album;
  final String filePath;
  final int durationMs;
  final int dateAdded;
  final int dateModified;
  final int fileSize;
  final int sampleRate;
  final int bitDepth;
  final bool isFavorite;

  String get durationLabel {
    final totalSeconds = durationMs ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  AudioTrack copyWith({
    int? id,
    int? mediaStoreId,
    String? title,
    String? artist,
    String? album,
    String? filePath,
    int? durationMs,
    int? dateAdded,
    int? dateModified,
    int? fileSize,
    int? sampleRate,
    int? bitDepth,
    bool? isFavorite,
  }) {
    return AudioTrack(
      id: id ?? this.id,
      mediaStoreId: mediaStoreId ?? this.mediaStoreId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      filePath: filePath ?? this.filePath,
      durationMs: durationMs ?? this.durationMs,
      dateAdded: dateAdded ?? this.dateAdded,
      dateModified: dateModified ?? this.dateModified,
      fileSize: fileSize ?? this.fileSize,
      sampleRate: sampleRate ?? this.sampleRate,
      bitDepth: bitDepth ?? this.bitDepth,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }

  /// Full row map for INSERT. The autoincrement id is omitted unless requested.
  Map<String, Object?> toDbMap({bool includeId = false}) {
    return <String, Object?>{
      if (includeId && id != null) AudioTrackColumns.id: id,
      AudioTrackColumns.mediaStoreId: mediaStoreId,
      AudioTrackColumns.title: title,
      AudioTrackColumns.artist: artist,
      AudioTrackColumns.album: album,
      AudioTrackColumns.filePath: filePath,
      AudioTrackColumns.durationMs: durationMs,
      AudioTrackColumns.dateAdded: dateAdded,
      AudioTrackColumns.dateModified: dateModified,
      AudioTrackColumns.fileSize: fileSize,
      AudioTrackColumns.sampleRate: sampleRate,
      AudioTrackColumns.bitDepth: bitDepth,
      AudioTrackColumns.isFavorite: isFavorite ? 1 : 0,
    };
  }

  /// Columns refreshed by a library re-scan. Excludes the id and the
  /// user-owned [isFavorite] flag so favorites survive every sync.
  Map<String, Object?> toSyncUpdateMap() {
    return <String, Object?>{
      AudioTrackColumns.mediaStoreId: mediaStoreId,
      AudioTrackColumns.title: title,
      AudioTrackColumns.artist: artist,
      AudioTrackColumns.album: album,
      AudioTrackColumns.durationMs: durationMs,
      AudioTrackColumns.dateAdded: dateAdded,
      AudioTrackColumns.dateModified: dateModified,
      AudioTrackColumns.fileSize: fileSize,
      AudioTrackColumns.sampleRate: sampleRate,
      AudioTrackColumns.bitDepth: bitDepth,
    };
  }

  factory AudioTrack.fromDbMap(Map<String, Object?> map) {
    return AudioTrack(
      id: map[AudioTrackColumns.id] == null ? null : _asInt(map[AudioTrackColumns.id]),
      mediaStoreId: _asInt(map[AudioTrackColumns.mediaStoreId]),
      title: _asString(map[AudioTrackColumns.title]),
      artist: _asString(map[AudioTrackColumns.artist]),
      album: _asString(map[AudioTrackColumns.album]),
      filePath: _asString(map[AudioTrackColumns.filePath]),
      durationMs: _asInt(map[AudioTrackColumns.durationMs]),
      dateAdded: _asInt(map[AudioTrackColumns.dateAdded]),
      dateModified: _asInt(map[AudioTrackColumns.dateModified]),
      fileSize: _asInt(map[AudioTrackColumns.fileSize]),
      sampleRate: _asInt(map[AudioTrackColumns.sampleRate]),
      bitDepth: _asInt(map[AudioTrackColumns.bitDepth]),
      isFavorite: _asBool(map[AudioTrackColumns.isFavorite]),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'mediaStoreId': mediaStoreId,
      'title': title,
      'artist': artist,
      'album': album,
      'filePath': filePath,
      'durationMs': durationMs,
      'dateAdded': dateAdded,
      'dateModified': dateModified,
      'fileSize': fileSize,
      'sampleRate': sampleRate,
      'bitDepth': bitDepth,
      'isFavorite': isFavorite,
    };
  }

  factory AudioTrack.fromJson(Map<String, Object?> json) {
    return AudioTrack(
      id: json['id'] == null ? null : _asInt(json['id']),
      mediaStoreId: _asInt(json['mediaStoreId']),
      title: _asString(json['title']),
      artist: _asString(json['artist']),
      album: _asString(json['album']),
      filePath: _asString(json['filePath']),
      durationMs: _asInt(json['durationMs']),
      dateAdded: _asInt(json['dateAdded']),
      dateModified: _asInt(json['dateModified']),
      fileSize: _asInt(json['fileSize']),
      sampleRate: _asInt(json['sampleRate']),
      bitDepth: _asInt(json['bitDepth']),
      isFavorite: _asBool(json['isFavorite']),
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AudioTrack &&
            other.id == id &&
            other.mediaStoreId == mediaStoreId &&
            other.title == title &&
            other.artist == artist &&
            other.album == album &&
            other.filePath == filePath &&
            other.durationMs == durationMs &&
            other.dateAdded == dateAdded &&
            other.dateModified == dateModified &&
            other.fileSize == fileSize &&
            other.sampleRate == sampleRate &&
            other.bitDepth == bitDepth &&
            other.isFavorite == isFavorite;
  }

  @override
  int get hashCode => Object.hash(
        id,
        mediaStoreId,
        title,
        artist,
        album,
        filePath,
        durationMs,
        dateAdded,
        dateModified,
        fileSize,
        sampleRate,
        bitDepth,
        isFavorite,
      );

  @override
  String toString() => 'AudioTrack(id: $id, title: $title, artist: $artist, path: $filePath)';
}

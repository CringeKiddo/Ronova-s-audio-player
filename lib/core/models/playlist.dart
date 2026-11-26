import 'package:flutter/material.dart';

import 'audio_track.dart';

/// How a playlist orders its songs.
enum PlaylistSort {
  manual('Manual (drag to reorder)'),
  titleAsc('Title A-Z'),
  titleDesc('Title Z-A'),
  artistAsc('Artist A-Z'),
  newestAdded('Newest downloads first'),
  oldestAdded('Oldest downloads first'),
  longest('Longest first'),
  shortest('Shortest first');

  const PlaylistSort(this.label);
  final String label;
}

/// What the playlist does to the global repeat mode when it starts (null = leave it alone).
enum PlaylistRepeat {
  off('Off'),
  all('Repeat all'),
  one('Repeat one');

  const PlaylistRepeat(this.label);
  final String label;
}

/// Icons a playlist can wear. Stored by key so saved data survives icon-font changes.
const Map<String, IconData> kPlaylistIcons = <String, IconData>{
  'queue': Icons.queue_music_rounded,
  'heart': Icons.favorite_rounded,
  'star': Icons.star_rounded,
  'fire': Icons.local_fire_department_rounded,
  'bolt': Icons.bolt_rounded,
  'moon': Icons.nightlight_round,
  'sun': Icons.wb_sunny_rounded,
  'headphones': Icons.headphones_rounded,
  'car': Icons.directions_car_rounded,
  'run': Icons.directions_run_rounded,
  'gym': Icons.fitness_center_rounded,
  'game': Icons.sports_esports_rounded,
  'study': Icons.school_rounded,
  'sleep': Icons.bedtime_rounded,
  'party': Icons.celebration_rounded,
  'guitar': Icons.music_note_rounded,
  'mic': Icons.mic_rounded,
  'album': Icons.album_rounded,
  'cloud': Icons.cloud_rounded,
  'leaf': Icons.eco_rounded,
  'coffee': Icons.local_cafe_rounded,
  'beach': Icons.beach_access_rounded,
  'rocket': Icons.rocket_launch_rounded,
  'diamond': Icons.diamond_rounded,
};

/// Swatches offered in the colour picker (plus a free hue/saturation/brightness picker).
const List<int> kPlaylistSwatches = <int>[
  0xFFE53935, 0xFFFF7043, 0xFFFFB300, 0xFFFFEE58, 0xFF9CCC65, 0xFF26A69A,
  0xFF26C6DA, 0xFF42A5F5, 0xFF5C6BC0, 0xFF8E24AA, 0xFFEC407A, 0xFF8D6E63,
  0xFFB0BEC5, 0xFFFFFFFF, 0xFF212121, 0xFF5CE1E6,
];

/// A fully customisable playlist.
@immutable
class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    this.description = '',
    this.paths = const <String>[],
    this.colorValue,
    this.iconKey = 'queue',
    this.coverPath,
    this.sort = PlaylistSort.manual,
    this.autoShuffle = false,
    this.repeat,
    this.speedOverride,
    this.reverbOverride,
    this.pinned = false,
    this.compactRows = false,
    this.showArtwork = true,
    this.createdMs = 0,
  });

  final String id;
  final String name;
  final String description;

  /// Ordered file paths (manual order). Display order also depends on [sort].
  final List<String> paths;

  /// Custom accent colour (ARGB) or null to follow the app theme.
  final int? colorValue;
  final String iconKey;

  /// Custom cover image copied into app storage, or null to use the icon.
  final String? coverPath;
  final PlaylistSort sort;

  /// Start shuffled whenever this playlist is played.
  final bool autoShuffle;

  /// Repeat mode applied when this playlist starts (null = unchanged).
  final PlaylistRepeat? repeat;

  /// Speed applied when this playlist starts, 0.10 .. 1.50 (null = unchanged).
  final double? speedOverride;

  /// Reverb forced on/off when this playlist starts (null = unchanged).
  final bool? reverbOverride;
  final bool pinned;
  final bool compactRows;
  final bool showArtwork;
  final int createdMs;

  Color? get color => colorValue == null ? null : Color(colorValue!);
  IconData get icon => kPlaylistIcons[iconKey] ?? Icons.queue_music_rounded;

  /// Songs resolved against the library (missing files are skipped) and sorted per [sort].
  List<AudioTrack> resolve(Map<String, AudioTrack> byPath) {
    final tracks = <AudioTrack>[
      for (final path in paths)
        if (byPath[path] != null) byPath[path]!,
    ];
    int cmpStr(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
    switch (sort) {
      case PlaylistSort.manual:
        break;
      case PlaylistSort.titleAsc:
        tracks.sort((a, b) => cmpStr(a.title, b.title));
      case PlaylistSort.titleDesc:
        tracks.sort((a, b) => cmpStr(b.title, a.title));
      case PlaylistSort.artistAsc:
        tracks.sort((a, b) {
          final c = cmpStr(a.artist, b.artist);
          return c != 0 ? c : cmpStr(a.title, b.title);
        });
      case PlaylistSort.newestAdded:
        tracks.sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
      case PlaylistSort.oldestAdded:
        tracks.sort((a, b) => a.dateAdded.compareTo(b.dateAdded));
      case PlaylistSort.longest:
        tracks.sort((a, b) => b.durationMs.compareTo(a.durationMs));
      case PlaylistSort.shortest:
        tracks.sort((a, b) => a.durationMs.compareTo(b.durationMs));
    }
    return tracks;
  }

  Playlist copyWith({
    String? name,
    String? description,
    List<String>? paths,
    int? colorValue,
    bool clearColor = false,
    String? iconKey,
    String? coverPath,
    bool clearCover = false,
    PlaylistSort? sort,
    bool? autoShuffle,
    PlaylistRepeat? repeat,
    bool clearRepeat = false,
    double? speedOverride,
    bool clearSpeed = false,
    bool? reverbOverride,
    bool clearReverb = false,
    bool? pinned,
    bool? compactRows,
    bool? showArtwork,
  }) {
    return Playlist(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      paths: paths ?? this.paths,
      colorValue: clearColor ? null : (colorValue ?? this.colorValue),
      iconKey: iconKey ?? this.iconKey,
      coverPath: clearCover ? null : (coverPath ?? this.coverPath),
      sort: sort ?? this.sort,
      autoShuffle: autoShuffle ?? this.autoShuffle,
      repeat: clearRepeat ? null : (repeat ?? this.repeat),
      speedOverride: clearSpeed ? null : (speedOverride ?? this.speedOverride),
      reverbOverride: clearReverb ? null : (reverbOverride ?? this.reverbOverride),
      pinned: pinned ?? this.pinned,
      compactRows: compactRows ?? this.compactRows,
      showArtwork: showArtwork ?? this.showArtwork,
      createdMs: createdMs,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'description': description,
        'paths': paths,
        'colorValue': colorValue,
        'iconKey': iconKey,
        'coverPath': coverPath,
        'sort': sort.name,
        'autoShuffle': autoShuffle,
        'repeat': repeat?.name,
        'speedOverride': speedOverride,
        'reverbOverride': reverbOverride,
        'pinned': pinned,
        'compactRows': compactRows,
        'showArtwork': showArtwork,
        'createdMs': createdMs,
      };

  factory Playlist.fromJson(Map<String, Object?> json) {
    final rawPaths = json['paths'];
    final sortName = json['sort'];
    final repeatName = json['repeat'];
    final speed = json['speedOverride'];
    final color = json['colorValue'];
    final cover = json['coverPath'];
    return Playlist(
      id: '${json['id'] ?? DateTime.now().microsecondsSinceEpoch}',
      name: '${json['name'] ?? 'Playlist'}',
      description: '${json['description'] ?? ''}',
      paths: <String>[
        if (rawPaths is List)
          for (final p in rawPaths) '$p',
      ],
      colorValue: color is num ? color.toInt() : null,
      iconKey: kPlaylistIcons.containsKey(json['iconKey']) ? '${json['iconKey']}' : 'queue',
      coverPath: cover is String && cover.isNotEmpty ? cover : null,
      sort: PlaylistSort.values.firstWhere((s) => s.name == sortName, orElse: () => PlaylistSort.manual),
      autoShuffle: json['autoShuffle'] == true,
      repeat: PlaylistRepeat.values.where((r) => r.name == repeatName).firstOrNull,
      speedOverride: speed is num ? speed.toDouble().clamp(0.10, 1.50).toDouble() : null,
      reverbOverride: json['reverbOverride'] is bool ? json['reverbOverride']! as bool : null,
      pinned: json['pinned'] == true,
      compactRows: json['compactRows'] == true,
      showArtwork: json['showArtwork'] != false,
      createdMs: json['createdMs'] is num ? (json['createdMs']! as num).toInt() : 0,
    );
  }
}

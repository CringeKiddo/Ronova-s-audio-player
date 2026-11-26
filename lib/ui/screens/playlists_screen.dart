import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/models/audio_track.dart';
import '../../core/models/playlist.dart';
import '../../core/providers/audio_library_provider.dart';
import '../../core/providers/playlist_provider.dart';
import '../../core/providers/theme_settings_provider.dart';
import '../../core/theme/ronova_palette.dart';
import '../widgets/ronova_widgets.dart';

Future<void> openPlaylistsScreen(BuildContext context) {
  return Navigator.of(context).push<void>(ronovaRoute<void>((_) => const PlaylistsScreen()));
}

Future<void> _openPlaylistDetail(BuildContext context, String id) {
  return Navigator.of(context).push<void>(ronovaRoute<void>((_) => PlaylistDetailScreen(playlistId: id)));
}

String _summary(Playlist playlist, Map<String, AudioTrack> byPath) {
  final tracks = playlist.resolve(byPath);
  var ms = 0;
  for (final t in tracks) {
    ms += t.durationMs;
  }
  final hours = ms ~/ 3600000;
  final minutes = (ms % 3600000) ~/ 60000;
  final time = hours > 0 ? '${hours}h ${minutes}m' : '${minutes}m';
  return '${tracks.length} song${tracks.length == 1 ? '' : 's'} · $time';
}

Map<String, AudioTrack> _byPath(List<AudioTrack> all) => <String, AudioTrack>{for (final t in all) t.filePath: t};

// ---------------------------------------------------------------------------------------------
// Cover (custom image, or colour + icon)
// ---------------------------------------------------------------------------------------------

class _PlaylistCover extends StatelessWidget {
  const _PlaylistCover({required this.playlist, required this.palette, required this.size, this.radius = 16});

  final Playlist playlist;
  final RonovaPalette palette;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final accent = playlist.color ?? palette.primary;
    final cover = playlist.coverPath;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[accent.withValues(alpha: 0.85), accent.withValues(alpha: 0.35)],
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: cover != null && File(cover).existsSync()
            ? Image.file(
                File(cover),
                fit: BoxFit.cover,
                cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
                errorBuilder: (c, e, s) => Icon(playlist.icon, color: Colors.white, size: size * 0.46),
              )
            : Icon(playlist.icon, color: Colors.white, size: size * 0.46),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Playlists list
// ---------------------------------------------------------------------------------------------

class PlaylistsScreen extends ConsumerWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(ronovaPaletteProvider);
    final playlists = ref.watch(playlistsProvider);
    final all = ref.watch(audioLibraryProvider.select((s) => s.allTracks));
    final byPath = _byPath(all);
    final sorted = <Playlist>[
      ...playlists.where((p) => p.pinned),
      ...playlists.where((p) => !p.pinned),
    ];

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: RonovaBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 14, 8),
                child: Row(
                  children: <Widget>[
                    GlowIconButton(icon: Icons.arrow_back_rounded, onPressed: () => Navigator.of(context).maybePop()),
                    const SizedBox(width: 12),
                    Expanded(child: Text('Playlists', style: RonovaFonts.display(size: 26, color: palette.textPrimary))),
                    GlowIconButton(
                      icon: Icons.add_rounded,
                      filled: true,
                      tooltip: 'New playlist',
                      onPressed: () => showPlaylistEditor(context, ref),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: sorted.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              GradientIcon(Icons.queue_music_rounded, gradient: palette.accentGradient, size: 56),
                              const SizedBox(height: 14),
                              Text('No playlists yet', style: RonovaFonts.display(size: 20, color: palette.textPrimary)),
                              const SizedBox(height: 6),
                              Text(
                                'Tap + to build one. Give it its own colour, cover, order, speed, reverb and more.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: palette.textMuted, height: 1.35),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: EdgeInsets.fromLTRB(12, 4, 12, 24 + MediaQuery.paddingOf(context).bottom),
                        itemCount: sorted.length,
                        itemBuilder: (context, i) => _PlaylistCard(playlist: sorted[i], summary: _summary(sorted[i], byPath), byPath: byPath),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaylistCard extends ConsumerWidget {
  const _PlaylistCard({required this.playlist, required this.summary, required this.byPath});

  final Playlist playlist;
  final String summary;
  final Map<String, AudioTrack> byPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(ronovaPaletteProvider);
    final accent = playlist.color ?? palette.primary;
    final tags = <String>[
      if (playlist.autoShuffle) 'Shuffle',
      if (playlist.repeat != null) playlist.repeat!.label,
      if (playlist.speedOverride != null) '${playlist.speedOverride!.toStringAsFixed(2)}x',
      if (playlist.reverbOverride == true) 'Reverb',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: PressableScale(
        scale: 0.98,
        onTap: () => unawaited(_openPlaylistDetail(context, playlist.id)),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            color: palette.surfaceStrong,
            border: Border.all(color: accent.withValues(alpha: 0.55), width: 1.2),
          ),
          child: Row(
            children: <Widget>[
              _PlaylistCover(playlist: playlist, palette: palette, size: 62),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        if (playlist.pinned) ...<Widget>[
                          Icon(Icons.push_pin_rounded, size: 14, color: accent),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            playlist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: palette.textPrimary),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(summary, style: TextStyle(fontSize: 12.5, color: palette.textSecondary)),
                    if (tags.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(tags.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: accent)),
                    ],
                  ],
                ),
              ),
              GlowIconButton(
                icon: Icons.play_arrow_rounded,
                size: 42,
                filled: true,
                onPressed: () => unawaited(_playPlaylist(ref, playlist, byPath)),
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert_rounded, color: palette.textSecondary),
                onSelected: (value) => _onMenu(context, ref, value),
                itemBuilder: (context) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(value: 'shuffle', child: Text('Shuffle play')),
                  PopupMenuItem<String>(value: 'pin', child: Text(playlist.pinned ? 'Unpin' : 'Pin to top')),
                  const PopupMenuItem<String>(value: 'edit', child: Text('Customize')),
                  const PopupMenuItem<String>(value: 'dup', child: Text('Duplicate')),
                  const PopupMenuItem<String>(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onMenu(BuildContext context, WidgetRef ref, String value) async {
    final controller = ref.read(playlistsProvider.notifier);
    switch (value) {
      case 'shuffle':
        await _playPlaylist(ref, playlist, byPath, forceShuffle: true);
      case 'pin':
        controller.togglePinned(playlist.id);
      case 'edit':
        await showPlaylistEditor(context, ref, existing: playlist);
      case 'dup':
        controller.duplicate(playlist.id);
        if (context.mounted) showRonovaSnack(context, 'Duplicated "${playlist.name}"');
      case 'delete':
        final ok = await _confirmDelete(context, playlist.name);
        if (ok) controller.delete(playlist.id);
    }
  }
}

Future<bool> _confirmDelete(BuildContext context, String name) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete playlist?'),
      content: Text('"$name" will be removed. Your songs stay on the phone.'),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete')),
      ],
    ),
  );
  return result ?? false;
}

Future<void> _playPlaylist(
  WidgetRef ref,
  Playlist playlist,
  Map<String, AudioTrack> byPath, {
  bool forceShuffle = false,
  int? startIndex,
}) async {
  final tracks = playlist.resolve(byPath);
  await ref.read(audioLibraryProvider.notifier).playPlaylistTracks(
        tracks,
        startIndex: startIndex,
        shuffle: forceShuffle || playlist.autoShuffle,
        repeat: playlist.repeat,
        speed: playlist.speedOverride,
        reverb: playlist.reverbOverride,
      );
}

// ---------------------------------------------------------------------------------------------
// Playlist detail
// ---------------------------------------------------------------------------------------------

class PlaylistDetailScreen extends ConsumerWidget {
  const PlaylistDetailScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(ronovaPaletteProvider);
    final playlist = ref.watch(playlistsProvider.select((list) {
      for (final p in list) {
        if (p.id == playlistId) return p;
      }
      return null;
    }));
    final all = ref.watch(audioLibraryProvider.select((s) => s.allTracks));
    final currentPath = ref.watch(audioLibraryProvider.select((s) => s.currentTrack?.filePath));
    if (playlist == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).maybePop();
      });
      return const SizedBox.shrink();
    }
    final byPath = _byPath(all);
    final tracks = playlist.resolve(byPath);
    final accent = playlist.color ?? palette.primary;
    final manual = playlist.sort == PlaylistSort.manual;
    final missing = playlist.paths.length - tracks.length;
    final controller = ref.read(playlistsProvider.notifier);

    Widget rowFor(int index, AudioTrack track) {
      final isCurrent = track.filePath == currentPath;
      return Container(
        key: ValueKey<String>(track.filePath),
        height: playlist.compactRows ? 52 : 68,
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.only(left: 8, right: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: isCurrent ? accent.withValues(alpha: 0.18) : Colors.transparent,
          border: isCurrent ? Border.all(color: accent.withValues(alpha: 0.6)) : null,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => unawaited(_playPlaylist(ref, playlist, byPath, startIndex: index)),
          child: Row(
            children: <Widget>[
              if (playlist.showArtwork) ...<Widget>[
                TrackArtwork(filePath: track.filePath, size: playlist.compactRows ? 38 : 50, radius: 13),
                const SizedBox(width: 12),
              ] else
                SizedBox(width: 26, child: Text('${index + 1}', style: TextStyle(color: palette.textMuted))),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isCurrent ? accent : palette.textPrimary),
                    ),
                    if (!playlist.compactRows)
                      Text(
                        track.artist.isEmpty ? 'Unknown artist' : track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: palette.textSecondary),
                      ),
                  ],
                ),
              ),
              Text(formatDurationMs(track.durationMs), style: TextStyle(fontSize: 11.5, color: palette.textMuted)),
              IconButton(
                tooltip: 'Remove',
                icon: Icon(Icons.remove_circle_outline_rounded, color: palette.textMuted, size: 20),
                onPressed: () => controller.removeTrack(playlist.id, track.filePath),
              ),
              if (manual)
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Icon(Icons.drag_handle_rounded, color: palette.textSecondary),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _PlaylistCover(playlist: playlist, palette: palette, size: 112, radius: 24),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(playlist.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: RonovaFonts.display(size: 24, color: palette.textPrimary)),
                    const SizedBox(height: 4),
                    Text(_summary(playlist, byPath), style: TextStyle(color: accent, fontWeight: FontWeight.w600, fontSize: 13)),
                    if (playlist.description.trim().isNotEmpty) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(playlist.description, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: palette.textSecondary, fontSize: 12.5, height: 1.3)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: _ActionButton(
                  label: 'Play',
                  icon: Icons.play_arrow_rounded,
                  color: accent,
                  filled: true,
                  onTap: tracks.isEmpty ? null : () => unawaited(_playPlaylist(ref, playlist, byPath)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ActionButton(
                  label: 'Shuffle',
                  icon: Icons.shuffle_rounded,
                  color: accent,
                  onTap: tracks.isEmpty ? null : () => unawaited(_playPlaylist(ref, playlist, byPath, forceShuffle: true)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ActionButton(
                  label: 'Add',
                  icon: Icons.playlist_add_rounded,
                  color: accent,
                  onTap: () => unawaited(_pickTracks(context, ref, playlist)),
                ),
              ),
            ],
          ),
          if (missing > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: GestureDetector(
                onTap: () => controller.clearMissing(playlist.id, all.map((t) => t.filePath).toSet()),
                child: Text(
                  '$missing song${missing == 1 ? '' : 's'} no longer on this phone — tap to clean up',
                  style: TextStyle(color: palette.textMuted, fontSize: 12, decoration: TextDecoration.underline),
                ),
              ),
            ),
          if (!manual)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Sorted by ${playlist.sort.label}. Switch to Manual in Customize to drag songs around.',
                style: TextStyle(color: palette.textMuted, fontSize: 12),
              ),
            ),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: RonovaBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                child: Row(
                  children: <Widget>[
                    GlowIconButton(icon: Icons.arrow_back_rounded, onPressed: () => Navigator.of(context).maybePop()),
                    const Spacer(),
                    GlowIconButton(
                      icon: playlist.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                      tooltip: 'Pin',
                      onPressed: () => controller.togglePinned(playlist.id),
                    ),
                    const SizedBox(width: 8),
                    GlowIconButton(
                      icon: Icons.tune_rounded,
                      glow: true,
                      tooltip: 'Customize',
                      onPressed: () => unawaited(showPlaylistEditor(context, ref, existing: playlist)),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: manual
                    ? ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        header: header,
                        padding: EdgeInsets.fromLTRB(10, 0, 10, 30 + MediaQuery.paddingOf(context).bottom),
                        itemCount: tracks.length,
                        onReorder: (oldIndex, newIndex) {
                          // Display order == playlist.paths order, minus missing files.
                          final from = playlist.paths.indexOf(tracks[oldIndex].filePath);
                          final beforeIdx = newIndex >= tracks.length ? playlist.paths.length : playlist.paths.indexOf(tracks[newIndex].filePath);
                          controller.reorder(playlist.id, from, beforeIdx);
                        },
                        itemBuilder: (context, index) => rowFor(index, tracks[index]),
                      )
                    : ListView.builder(
                        padding: EdgeInsets.fromLTRB(10, 0, 10, 30 + MediaQuery.paddingOf(context).bottom),
                        itemCount: tracks.length + 1,
                        itemBuilder: (context, index) => index == 0 ? header : rowFor(index - 1, tracks[index - 1]),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.label, required this.icon, required this.color, required this.onTap, this.filled = false});

  final String label;
  final IconData icon;
  final Color color;
  final bool filled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return PressableScale(
      scale: 0.96,
      onTap: onTap,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Container(
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(23),
            color: filled ? color : Colors.transparent,
            border: Border.all(color: color, width: 1.4),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 20, color: filled ? (color.computeLuminance() > 0.55 ? Colors.black : Colors.white) : color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(fontWeight: FontWeight.w700, color: filled ? (color.computeLuminance() > 0.55 ? Colors.black : Colors.white) : color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Song picker (multi-select + search)
// ---------------------------------------------------------------------------------------------

Future<void> _pickTracks(BuildContext context, WidgetRef ref, Playlist playlist) async {
  final picked = await showModalBottomSheet<Set<String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _TrackPickerSheet(already: playlist.paths.toSet()),
  );
  if (picked == null || picked.isEmpty) return;
  final added = ref.read(playlistsProvider.notifier).addTracks(playlist.id, picked);
  if (context.mounted) showRonovaSnack(context, 'Added $added song${added == 1 ? '' : 's'} to "${playlist.name}"');
}

class _TrackPickerSheet extends ConsumerStatefulWidget {
  const _TrackPickerSheet({required this.already});

  final Set<String> already;

  @override
  ConsumerState<_TrackPickerSheet> createState() => _TrackPickerSheetState();
}

class _TrackPickerSheetState extends ConsumerState<_TrackPickerSheet> {
  final Set<String> _selected = <String>{};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final palette = ref.watch(ronovaPaletteProvider);
    final all = ref.watch(audioLibraryProvider.select((s) => s.allTracks));
    final q = _query.trim().toLowerCase();
    final tracks = <AudioTrack>[
      for (final t in all)
        if (q.isEmpty || t.title.toLowerCase().contains(q) || t.artist.toLowerCase().contains(q)) t,
    ];
    final height = MediaQuery.sizeOf(context).height * 0.88;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: palette.isAbyss ? const Color(0xFF0E1220) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: <Widget>[
            const SizedBox(height: 12),
            Container(width: 42, height: 4, decoration: BoxDecoration(color: palette.textMuted.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
              child: Row(
                children: <Widget>[
                  Expanded(child: Text('Add songs', style: RonovaFonts.display(size: 20, color: palette.textPrimary))),
                  TextButton(
                    onPressed: () => setState(() => _selected.addAll(<String>[
                          for (final t in tracks)
                            if (!widget.already.contains(t.filePath)) t.filePath,
                        ])),
                    child: Text('Select all', style: TextStyle(color: palette.accentText)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                style: TextStyle(color: palette.textPrimary),
                cursorColor: palette.primary,
                decoration: InputDecoration(
                  hintText: 'Search title or artist',
                  hintStyle: TextStyle(color: palette.textMuted),
                  prefixIcon: Icon(Icons.search_rounded, color: palette.textSecondary),
                  filled: true,
                  fillColor: palette.surface,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
                  isDense: true,
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: tracks.length,
                itemBuilder: (context, i) {
                  final t = tracks[i];
                  final inside = widget.already.contains(t.filePath);
                  final checked = inside || _selected.contains(t.filePath);
                  return CheckboxListTile(
                    value: checked,
                    onChanged: inside
                        ? null
                        : (v) => setState(() {
                              if (v == true) {
                                _selected.add(t.filePath);
                              } else {
                                _selected.remove(t.filePath);
                              }
                            }),
                    activeColor: palette.primary,
                    checkColor: palette.onAccent,
                    controlAffinity: ListTileControlAffinity.trailing,
                    title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: palette.textPrimary, fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      inside ? 'Already in playlist' : (t.artist.isEmpty ? 'Unknown artist' : t.artist),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.textMuted),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(18, 8, 18, 14 + MediaQuery.paddingOf(context).bottom),
              child: SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: palette.primary, foregroundColor: palette.onAccent),
                  onPressed: _selected.isEmpty ? null : () => Navigator.of(context).pop(_selected),
                  child: Text('Add ${_selected.length} song${_selected.length == 1 ? '' : 's'}'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// "Add this song to a playlist" sheet (used by the library's song menu)
// ---------------------------------------------------------------------------------------------

Future<void> showAddToPlaylistSheet(BuildContext context, WidgetRef ref, AudioTrack track) async {
  final result = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _AddToPlaylistSheet(track: track),
  );
  if (result == null || !context.mounted) return;
  final controller = ref.read(playlistsProvider.notifier);
  Playlist? target = controller.byId(result);
  target ??= controller.create(result);
  final added = controller.addTracks(target.id, <String>[track.filePath]);
  if (context.mounted) showRonovaSnack(context, added > 0 ? 'Added to "${target.name}"' : 'Already in "${target.name}"');
}

class _AddToPlaylistSheet extends ConsumerStatefulWidget {
  const _AddToPlaylistSheet({required this.track});

  final AudioTrack track;

  @override
  ConsumerState<_AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends ConsumerState<_AddToPlaylistSheet> {
  final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = ref.watch(ronovaPaletteProvider);
    final playlists = ref.watch(playlistsProvider);
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12, 12 + MediaQuery.viewInsetsOf(context).bottom + MediaQuery.paddingOf(context).bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
        decoration: BoxDecoration(
          color: palette.isAbyss ? const Color(0xFF12172A) : Colors.white,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: palette.primary.withValues(alpha: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
              child: Text('Add to playlist', style: RonovaFonts.display(size: 19, color: palette.textPrimary)),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: playlists.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text('No playlists yet — create your first one below.', style: TextStyle(color: palette.textMuted)),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: <Widget>[
                        for (final pl in playlists)
                          ListTile(
                            leading: _PlaylistCover(playlist: pl, palette: palette, size: 40, radius: 12),
                            title: Text(pl.name, style: TextStyle(color: palette.textPrimary, fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              pl.paths.contains(widget.track.filePath) ? 'Already added' : '${pl.paths.length} songs',
                              style: TextStyle(color: palette.textMuted),
                            ),
                            onTap: () {
                              HapticFeedback.selectionClick();
                              Navigator.of(context).pop(pl.id);
                            },
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.sentences,
                    cursorColor: palette.primary,
                    style: TextStyle(color: palette.textPrimary),
                    onSubmitted: (_) => _create(),
                    decoration: InputDecoration(
                      labelText: 'New playlist',
                      labelStyle: TextStyle(color: palette.textMuted),
                      filled: true,
                      fillColor: palette.surface,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                GlowIconButton(icon: Icons.add_rounded, filled: true, onPressed: _create),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _create() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    // A name (not an id) tells the caller to create it first.
    Navigator.of(context).pop(name);
  }
}

// ---------------------------------------------------------------------------------------------
// The customizer
// ---------------------------------------------------------------------------------------------

Future<void> showPlaylistEditor(BuildContext context, WidgetRef ref, {Playlist? existing}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _PlaylistEditor(existing: existing),
  );
}

class _PlaylistEditor extends ConsumerStatefulWidget {
  const _PlaylistEditor({this.existing});

  final Playlist? existing;

  @override
  ConsumerState<_PlaylistEditor> createState() => _PlaylistEditorState();
}

class _PlaylistEditorState extends ConsumerState<_PlaylistEditor> {
  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _desc = TextEditingController(text: widget.existing?.description ?? '');

  late int? _color = widget.existing?.colorValue;
  late String _icon = widget.existing?.iconKey ?? 'queue';
  late String? _cover = widget.existing?.coverPath;
  late PlaylistSort _sort = widget.existing?.sort ?? PlaylistSort.manual;
  late bool _autoShuffle = widget.existing?.autoShuffle ?? false;
  late PlaylistRepeat? _repeat = widget.existing?.repeat;
  late double? _speed = widget.existing?.speedOverride;
  late bool? _reverb = widget.existing?.reverbOverride;
  late bool _compact = widget.existing?.compactRows ?? false;
  late bool _artwork = widget.existing?.showArtwork ?? true;
  bool _pickingCover = false;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _pickCover() async {
    if (_pickingCover) return;
    setState(() => _pickingCover = true);
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 900, maxHeight: 900, imageQuality: 88);
      if (picked == null) return;
      final dir = await getApplicationSupportDirectory();
      final ext = p.extension(picked.path).isEmpty ? '.jpg' : p.extension(picked.path);
      final target = p.join(dir.path, 'playlist_cover_${DateTime.now().millisecondsSinceEpoch}$ext');
      await File(picked.path).copy(target);
      if (mounted) setState(() => _cover = target);
    } catch (error) {
      if (mounted) showRonovaSnack(context, 'Could not use that photo: $error');
    } finally {
      if (mounted) setState(() => _pickingCover = false);
    }
  }

  void _save() {
    final controller = ref.read(playlistsProvider.notifier);
    final name = _name.text.trim().isEmpty ? 'New playlist' : _name.text.trim();
    final base = widget.existing ?? controller.create(name);
    controller.update(
      Playlist(
        id: base.id,
        name: name,
        description: _desc.text.trim(),
        paths: base.paths,
        colorValue: _color,
        iconKey: _icon,
        coverPath: _cover,
        sort: _sort,
        autoShuffle: _autoShuffle,
        repeat: _repeat,
        speedOverride: _speed,
        reverbOverride: _reverb,
        pinned: base.pinned,
        compactRows: _compact,
        showArtwork: _artwork,
        createdMs: base.createdMs,
      ),
    );
    Navigator.of(context).pop();
  }

  Widget _section(RonovaPalette palette, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(title.toUpperCase(), style: TextStyle(fontSize: 11.5, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: palette.textMuted)),
      );

  Widget _chips<T>(RonovaPalette palette, List<T> values, T? selected, String Function(T) label, ValueChanged<T> onTap, {Color? accent}) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final v in values)
          ChoiceChip(
            label: Text(label(v)),
            selected: v == selected,
            onSelected: (_) => onTap(v),
            selectedColor: (accent ?? palette.primary).withValues(alpha: 0.35),
            labelStyle: TextStyle(color: palette.textPrimary, fontSize: 12.5),
            side: BorderSide(color: (accent ?? palette.primary).withValues(alpha: 0.5)),
            backgroundColor: Colors.transparent,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = ref.watch(ronovaPaletteProvider);
    final accent = _color == null ? palette.primary : Color(_color!);
    final preview = Playlist(id: 'preview', name: _name.text, colorValue: _color, iconKey: _icon, coverPath: _cover);
    final hsv = HSVColor.fromColor(accent);
    final height = MediaQuery.sizeOf(context).height * 0.92;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: palette.isAbyss ? const Color(0xFF0E1220) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: <Widget>[
            const SizedBox(height: 12),
            Container(width: 42, height: 4, decoration: BoxDecoration(color: palette.textMuted.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 12, 0),
              child: Row(
                children: <Widget>[
                  Expanded(child: Text(widget.existing == null ? 'New playlist' : 'Customize playlist', style: RonovaFonts.display(size: 20, color: palette.textPrimary))),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: accent.computeLuminance() > 0.55 ? Colors.black : Colors.white),
                    onPressed: _save,
                    child: Text(widget.existing == null ? 'Create' : 'Save'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
                children: <Widget>[
                  // ---- Identity
                  _section(palette, 'Identity'),
                  Row(
                    children: <Widget>[
                      _PlaylistCover(playlist: preview, palette: palette, size: 84, radius: 22),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          children: <Widget>[
                            TextField(
                              controller: _name,
                              onChanged: (_) => setState(() {}),
                              textCapitalization: TextCapitalization.sentences,
                              style: TextStyle(color: palette.textPrimary),
                              cursorColor: accent,
                              decoration: InputDecoration(labelText: 'Name', labelStyle: TextStyle(color: palette.textMuted), filled: true, fillColor: palette.surface, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none)),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _pickingCover ? null : _pickCover,
                                    icon: const Icon(Icons.image_rounded, size: 18),
                                    label: Text(_cover == null ? 'Cover photo' : 'Change cover'),
                                    style: OutlinedButton.styleFrom(foregroundColor: accent, side: BorderSide(color: accent)),
                                  ),
                                ),
                                if (_cover != null)
                                  IconButton(onPressed: () => setState(() => _cover = null), icon: Icon(Icons.close_rounded, color: palette.textSecondary)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _desc,
                    maxLines: 3,
                    minLines: 2,
                    style: TextStyle(color: palette.textPrimary),
                    cursorColor: accent,
                    decoration: InputDecoration(labelText: 'Description (optional)', labelStyle: TextStyle(color: palette.textMuted), filled: true, fillColor: palette.surface, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none)),
                  ),

                  // ---- Icon
                  _section(palette, 'Icon'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final entry in kPlaylistIcons.entries)
                        GestureDetector(
                          onTap: () => setState(() => _icon = entry.key),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _icon == entry.key ? accent.withValues(alpha: 0.30) : palette.surface,
                              border: Border.all(color: _icon == entry.key ? accent : Colors.transparent, width: 1.6),
                            ),
                            child: Icon(entry.value, color: _icon == entry.key ? accent : palette.textSecondary, size: 22),
                          ),
                        ),
                    ],
                  ),

                  // ---- Colour
                  _section(palette, 'Colour'),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: <Widget>[
                      GestureDetector(
                        onTap: () => setState(() => _color = null),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: palette.accentGradient,
                            border: Border.all(color: _color == null ? Colors.white : Colors.transparent, width: 2.4),
                          ),
                          child: const Icon(Icons.auto_awesome_rounded, size: 16, color: Colors.white),
                        ),
                      ),
                      for (final value in kPlaylistSwatches)
                        GestureDetector(
                          onTap: () => setState(() => _color = value),
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(value),
                              border: Border.all(color: _color == value ? Colors.white : palette.border, width: _color == value ? 2.4 : 1),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _hsvSlider(palette, 'Hue', hsv.hue, 0, 360, accent, (v) => setState(() => _color = HSVColor.fromAHSV(1, v, hsv.saturation < 0.05 ? 0.8 : hsv.saturation, hsv.value < 0.2 ? 0.9 : hsv.value).toColor().toARGB32())),
                  _hsvSlider(palette, 'Saturation', hsv.saturation, 0, 1, accent, (v) => setState(() => _color = HSVColor.fromAHSV(1, hsv.hue, v, hsv.value).toColor().toARGB32())),
                  _hsvSlider(palette, 'Brightness', hsv.value, 0.2, 1, accent, (v) => setState(() => _color = HSVColor.fromAHSV(1, hsv.hue, hsv.saturation, v).toColor().toARGB32())),

                  // ---- Order
                  _section(palette, 'Song order'),
                  _chips<PlaylistSort>(palette, PlaylistSort.values, _sort, (s) => s.label, (v) => setState(() => _sort = v), accent: accent),

                  // ---- Behaviour
                  _section(palette, 'When this playlist plays'),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Always start shuffled', style: TextStyle(color: palette.textPrimary)),
                    value: _autoShuffle,
                    activeThumbColor: accent,
                    onChanged: (v) => setState(() => _autoShuffle = v),
                  ),
                  Text('Repeat', style: TextStyle(color: palette.textSecondary, fontSize: 13)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: <Widget>[
                      ChoiceChip(
                        label: const Text('Leave as is'),
                        selected: _repeat == null,
                        onSelected: (_) => setState(() => _repeat = null),
                        selectedColor: accent.withValues(alpha: 0.35),
                        labelStyle: TextStyle(color: palette.textPrimary, fontSize: 12.5),
                        backgroundColor: Colors.transparent,
                        side: BorderSide(color: accent.withValues(alpha: 0.5)),
                      ),
                      for (final r in PlaylistRepeat.values)
                        ChoiceChip(
                          label: Text(r.label),
                          selected: _repeat == r,
                          onSelected: (_) => setState(() => _repeat = r),
                          selectedColor: accent.withValues(alpha: 0.35),
                          labelStyle: TextStyle(color: palette.textPrimary, fontSize: 12.5),
                          backgroundColor: Colors.transparent,
                          side: BorderSide(color: accent.withValues(alpha: 0.5)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Set its own speed', style: TextStyle(color: palette.textPrimary)),
                    subtitle: Text(_speed == null ? 'Uses whatever speed you had' : '${_speed!.toStringAsFixed(2)}x applied on play', style: TextStyle(color: palette.textMuted)),
                    value: _speed != null,
                    activeThumbColor: accent,
                    onChanged: (v) => setState(() => _speed = v ? 1.0 : null),
                  ),
                  if (_speed != null)
                    Slider(
                      value: _speed!,
                      min: 0.10,
                      max: 1.50,
                      divisions: 28,
                      label: '${_speed!.toStringAsFixed(2)}x',
                      activeColor: accent,
                      onChanged: (v) => setState(() => _speed = (v * 20).round() / 20),
                    ),
                  Text('Reverb', style: TextStyle(color: palette.textSecondary, fontSize: 13)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: <Widget>[
                      for (final entry in <(String, bool?)>[('Leave as is', null), ('Force on', true), ('Force off', false)])
                        ChoiceChip(
                          label: Text(entry.$1),
                          selected: _reverb == entry.$2,
                          onSelected: (_) => setState(() => _reverb = entry.$2),
                          selectedColor: accent.withValues(alpha: 0.35),
                          labelStyle: TextStyle(color: palette.textPrimary, fontSize: 12.5),
                          backgroundColor: Colors.transparent,
                          side: BorderSide(color: accent.withValues(alpha: 0.5)),
                        ),
                    ],
                  ),

                  // ---- Look
                  _section(palette, 'Song rows'),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Show album art', style: TextStyle(color: palette.textPrimary)),
                    value: _artwork,
                    activeThumbColor: accent,
                    onChanged: (v) => setState(() => _artwork = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Compact rows', style: TextStyle(color: palette.textPrimary)),
                    value: _compact,
                    activeThumbColor: accent,
                    onChanged: (v) => setState(() => _compact = v),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hsvSlider(RonovaPalette palette, String label, double value, double min, double max, Color accent, ValueChanged<double> onChanged) {
    return Row(
      children: <Widget>[
        SizedBox(width: 86, child: Text(label, style: TextStyle(color: palette.textSecondary, fontSize: 12.5))),
        Expanded(
          child: Slider(value: value.clamp(min, max).toDouble(), min: min, max: max, activeColor: accent, onChanged: onChanged),
        ),
      ],
    );
  }
}

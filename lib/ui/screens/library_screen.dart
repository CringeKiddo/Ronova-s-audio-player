import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../../core/database/local_track_database.dart';
import '../../core/models/audio_track.dart';
import '../../core/providers/album_art_color_provider.dart';
import '../../core/providers/audio_library_provider.dart';
import '../../core/providers/theme_settings_provider.dart';
import '../../core/services/native_platform_service.dart';
import '../../core/theme/ronova_palette.dart';
import '../widgets/genshin_motif_menu.dart';
import '../widgets/ronova_widgets.dart';
import '../widgets/center_player_box.dart';
import 'playlists_screen.dart';
import 'settings_screen.dart';

const String kCommercialLicenseNotice =
    '© 2026 Ronova Audio Labs. Commercial License — All Rights Reserved. Powered by 32-Bit IEEE Float DSP.';

enum _PermissionState { unknown, granted, denied }

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  bool _searchOpen = false;
  _PermissionState _permission = _PermissionState.unknown;
  bool _requesting = false;
  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_bootstrapPermissions()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_permission == _PermissionState.denied) {
      unawaited(_recheckPermission());
    } else if (_permission == _PermissionState.granted &&
        DateTime.now().difference(_lastRefresh) > const Duration(seconds: 30)) {
      // Stale-while-revalidate again whenever the user returns (new downloads show up on their own).
      _revalidate();
    }
  }

  // ---- Permission gate -----------------------------------------------------------------------

  Future<bool> _audioGranted() async {
    final audio = await Permission.audio.status;
    final storage = await Permission.storage.status;
    return audio.isGranted || audio.isLimited || storage.isGranted || storage.isLimited;
  }

  Future<void> _bootstrapPermissions() async {
    if (await _audioGranted()) {
      _onPermissionGranted();
      return;
    }
    // First open: ask straight away instead of making the user hunt for a button.
    await _requestPermissions();
  }

  Future<void> _recheckPermission() async {
    if (await _audioGranted()) _onPermissionGranted();
  }

  Future<void> _requestPermissions() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    try {
      final statuses = await <Permission>[Permission.audio, Permission.storage, Permission.notification].request();
      final granted = (statuses[Permission.audio]?.isGranted ?? false) ||
          (statuses[Permission.storage]?.isGranted ?? false) ||
          (statuses[Permission.audio]?.isLimited ?? false);
      if (!mounted) return;
      if (granted) {
        _onPermissionGranted();
      } else {
        setState(() => _permission = _PermissionState.denied);
        ref.read(audioLibraryProvider.notifier).setPermissionDenied(true);
      }
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  void _onPermissionGranted() {
    if (!mounted) return;
    setState(() => _permission = _PermissionState.granted);
    ref.read(audioLibraryProvider.notifier).setPermissionDenied(false);
    _revalidate();
    // Best effort: lets Android hand us the Bluetooth headset's real name (e.g. Arctis Nova 5).
    unawaited(_requestBluetoothName());
  }

  Future<void> _requestBluetoothName() async {
    try {
      final status = await Permission.bluetoothConnect.request();
      if (status.isGranted && mounted) {
        await ref.read(audioLibraryProvider.notifier).refreshOutputRoute();
      }
    } catch (_) {
      // Older Android versions have no such runtime permission.
    }
  }

  void _revalidate() {
    _lastRefresh = DateTime.now();
    unawaited(ref.read(audioLibraryProvider.notifier).refreshFromDevice());
  }

  // ---- Search ----------------------------------------------------------------------------------

  void _openSearch() {
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
  }

  void _closeSearch() {
    _searchController.clear();
    ref.read(audioLibraryProvider.notifier).setSearchQuery('');
    _searchFocus.unfocus();
    setState(() => _searchOpen = false);
  }

  // ---- Sort ------------------------------------------------------------------------------------

  Future<void> _openSortSheet(TrackSortOrder current) async {
    final palette = ref.read(ronovaPaletteProvider);
    final chosen = await showModalBottomSheet<TrackSortOrder>(
      context: context,
      backgroundColor: Colors.transparent,
      elevation: 0,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, 12 + MediaQuery.paddingOf(context).bottom),
        child: FrostedCard(
          blur: true,
          strong: true,
          glow: true,
          radius: 28,
          borderAlpha: 0.7,
          padding: const EdgeInsets.fromLTRB(10, 16, 10, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Text('Sort songs', style: RonovaFonts.display(size: 19, color: palette.textPrimary)),
              ),
              for (final order in TrackSortOrder.values)
                _SortOption(palette: palette, order: order, selected: order == current),
            ],
          ),
        ),
      ),
    );
    if (chosen != null && mounted) {
      ref.read(audioLibraryProvider.notifier).setSortOrder(chosen);
    }
  }

  // ---- Track actions ---------------------------------------------------------------------------

  AudioTrack _latest(AudioTrack track) {
    for (final t in ref.read(audioLibraryProvider).allTracks) {
      if (t.filePath == track.filePath) return t;
    }
    return track;
  }

  Future<void> _handleTrackAction(AudioTrack captured, TrackMenuAction action) async {
    final controller = ref.read(audioLibraryProvider.notifier);
    final track = _latest(captured);
    switch (action) {
      case TrackMenuAction.favorite:
        await controller.toggleFavorite(track);
      case TrackMenuAction.play:
        await controller.playTrack(track, queue: ref.read(audioLibraryProvider).visibleTracks);
      case TrackMenuAction.playNext:
        await controller.playNext(track);
        if (mounted) showRonovaSnack(context, 'Playing next: ${track.title}');
      case TrackMenuAction.addToQueue:
        await controller.addToQueue(track);
        if (mounted) showRonovaSnack(context, 'Added to queue: ${track.title}');
      case TrackMenuAction.addToPlaylist:
        await _addToPlaylistFlow(track);
      case TrackMenuAction.editTags:
        await _editTagsFlow(track);
      case TrackMenuAction.showInFolders:
        await _showFolderDialog(track);
      case TrackMenuAction.share:
        await _shareFlow(track);
      case TrackMenuAction.delete:
        await _deleteFlow(track);
    }
  }

  Future<void> _addToPlaylistFlow(AudioTrack track) => showAddToPlaylistSheet(context, ref, track);

  Future<void> _editTagsFlow(AudioTrack track) async {
    final result = await showDialog<({String title, String artist})>(
      context: context,
      builder: (context) => _EditTagsDialog(track: track),
    );
    if (result == null || !mounted) return;
    await ref.read(audioLibraryProvider.notifier).updateTags(track, title: result.title, artist: result.artist);
    if (mounted) showRonovaSnack(context, 'Tags updated');
  }

  Future<void> _showFolderDialog(AudioTrack track) {
    return showDialog<void>(context: context, builder: (context) => _FolderDialog(track: track));
  }

  Future<void> _shareFlow(AudioTrack track) async {
    final id = track.mediaStoreId;
    if (id <= 0) {
      showRonovaSnack(context, 'This song cannot be shared yet — pull down to refresh the library.');
      return;
    }
    final ok = await NativePlatformService.instance.shareTrack(mediaStoreId: id, title: track.title);
    if (!ok && mounted) showRonovaSnack(context, 'Sharing is not available for this song.');
  }

  Future<void> _deleteFlow(AudioTrack track) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _ConfirmDeleteDialog(track: track),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(audioLibraryProvider.notifier).removeFromLibrary(track);
    if (mounted) showRonovaSnack(context, 'Removed "${track.title}" from your library');
  }

  // ---- Build -----------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final palette = ref.watch(ronovaPaletteProvider);
    final controller = ref.read(audioLibraryProvider.notifier);
    final view = ref.watch(
      audioLibraryProvider.select(
        (s) => (
          all: s.allTracks,
          visible: s.visibleTracks,
          sort: s.sortOrder,
          refreshing: s.isRefreshing,
          loaded: s.hasLoaded,
          query: s.searchQuery,
          currentPath: s.currentTrack?.filePath,
          playing: s.isPlaying,
        ),
      ),
    );
    ref.listen<String?>(audioLibraryProvider.select((s) => s.errorMessage), (previous, next) {
      if (next != null) {
        showRonovaSnack(context, next);
        controller.clearError();
      }
    });

    final hasCurrent = view.currentPath != null;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final listBottomPadding = (hasCurrent ? 104.0 : 20.0) + bottomInset;
    final gateVisible = _permission == _PermissionState.denied && view.all.isEmpty;

    return PopScope(
      canPop: !_searchOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _searchOpen) _closeSearch();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: RonovaBackground(
          child: SafeArea(
            bottom: false,
            child: Stack(
              children: <Widget>[
                Column(
                  children: <Widget>[
                    _buildHeader(palette, view.all, view.sort),
                    // Only exists while scanning: an indeterminate bar keeps animating (and forcing
                    // frames) even at opacity 0.
                    SizedBox(
                      height: 2.5,
                      child: view.refreshing
                          ? LinearProgressIndicator(
                              minHeight: 2.5,
                              backgroundColor: Colors.transparent,
                              color: palette.primary,
                            )
                          : null,
                    ),
                    Expanded(
                      child: gateVisible
                          ? _PermissionCard(
                              palette: palette,
                              requesting: _requesting,
                              onAllow: _requestPermissions,
                              onOpenSettings: () => openAppSettings(),
                            )
                          : RefreshIndicator(
                              color: palette.primary,
                              backgroundColor: palette.isAbyss ? const Color(0xFF181C28) : Colors.white,
                              onRefresh: () async {
                                _lastRefresh = DateTime.now();
                                await controller.refreshFromDevice();
                              },
                              child: _buildList(palette, view.visible, view.all.isEmpty, view.query, view.currentPath, view.playing, view.loaded, listBottomPadding),
                            ),
                    ),
                  ],
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 420),
                    switchInCurve: Curves.easeOutBack,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(begin: const Offset(0, 0.8), end: Offset.zero).animate(animation),
                        child: child,
                      ),
                    ),
                    child: hasCurrent
                        ? _MiniPlayer(key: const ValueKey<String>('mini-player'), bottomInset: bottomInset)
                        : const SizedBox.shrink(key: ValueKey<String>('no-mini-player')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(RonovaPalette palette, List<AudioTrack> all, TrackSortOrder sort) {
    var totalMs = 0;
    for (final t in all) {
      totalMs += t.durationMs;
    }
    final hours = totalMs ~/ 3600000;
    final minutes = (totalMs % 3600000) ~/ 60000;
    final subtitle = all.isEmpty
        ? 'Your music, in 32-bit float'
        : '${all.length} songs · ${hours > 0 ? '${hours}h ' : ''}${minutes}m';

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 14, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SizeTransition(sizeFactor: animation, axis: Axis.horizontal, axisAlignment: -1, child: child),
              ),
              child: _searchOpen
                  ? _SearchPill(
                      key: const ValueKey<String>('search'),
                      palette: palette,
                      controller: _searchController,
                      focusNode: _searchFocus,
                      onChanged: ref.read(audioLibraryProvider.notifier).setSearchQuery,
                      onClose: _closeSearch,
                    )
                  : _TitleBlock(key: const ValueKey<String>('title'), palette: palette, subtitle: subtitle),
            ),
          ),
          const SizedBox(width: 10),
          if (!_searchOpen) ...<Widget>[
            GlowIconButton(icon: Icons.search_rounded, tooltip: 'Search', onPressed: _openSearch),
            const SizedBox(width: 8),
          ],
          GlowIconButton(
            icon: Icons.queue_music_rounded,
            tooltip: 'Playlists',
            onPressed: () => unawaited(openPlaylistsScreen(context)),
          ),
          const SizedBox(width: 8),
          GlowIconButton(icon: Icons.sort_rounded, tooltip: 'Sort', onPressed: () => _openSortSheet(sort)),
          const SizedBox(width: 8),
          GlowIconButton(
            icon: Icons.settings_rounded,
            tooltip: 'Settings',
            glow: true,
            onPressed: () => openSettingsScreen(context),
          ),
        ],
      ),
    );
  }

  Widget _buildList(
    RonovaPalette palette,
    List<AudioTrack> tracks,
    bool libraryEmpty,
    String query,
    String? currentPath,
    bool playing,
    bool loaded,
    double bottomPadding,
  ) {
    final controller = ref.read(audioLibraryProvider.notifier);
    final hasActions = tracks.isNotEmpty;
    // Rows: [actions row] + tracks + [license footer].
    final itemCount = (hasActions ? 1 : 0) + tracks.length + 1;

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      padding: EdgeInsets.only(bottom: bottomPadding),
      cacheExtent: 700,
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (hasActions && index == 0) {
          return _ListActions(
            palette: palette,
            onShuffle: () => unawaited(controller.shuffleAll()),
            onPlayAll: () => unawaited(controller.playTrack(tracks.first, queue: tracks)),
          );
        }
        final trackIndex = index - (hasActions ? 1 : 0);
        if (trackIndex >= tracks.length) {
          return Column(
            children: <Widget>[
              if (tracks.isEmpty && loaded)
                _EmptyState(palette: palette, searching: query.trim().isNotEmpty, libraryEmpty: libraryEmpty, query: query),
              _LicenseFooter(palette: palette),
            ],
          );
        }
        final track = tracks[trackIndex];
        final isCurrent = track.filePath == currentPath;
        return _TrackRow(
          key: ValueKey<String>(track.filePath),
          track: track,
          isCurrent: isCurrent,
          isPlaying: isCurrent && playing,
          onTap: () {
            if (isCurrent) {
              unawaited(controller.togglePlayPause());
            } else {
              unawaited(controller.playTrack(track, queue: tracks));
            }
          },
          onAction: (action) => unawaited(_handleTrackAction(track, action)),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Header pieces
// ---------------------------------------------------------------------------------------------

class _TitleBlock extends StatelessWidget {
  const _TitleBlock({super.key, required this.palette, required this.subtitle});

  final RonovaPalette palette;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final style = RonovaFonts.display(size: 31, weight: FontWeight.w800, letterSpacing: 0.4, height: 1.05);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Stack(
          children: <Widget>[
            // Ambient glow behind the wordmark.
            ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 9, sigmaY: 9),
              child: Text('Ronova', style: style.copyWith(color: palette.primary.withValues(alpha: 0.65))),
            ),
            GradientText('Ronova', gradient: palette.accentGradient, style: style),
          ],
        ),
        const SizedBox(height: 1),
        Text(subtitle, style: TextStyle(fontSize: 12.5, color: palette.textMuted)),
      ],
    );
  }
}

class _SearchPill extends StatelessWidget {
  const _SearchPill({
    super.key,
    required this.palette,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClose,
  });

  final RonovaPalette palette;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return FrostedCard(
      radius: 26,
      glow: true,
      strong: true,
      borderAlpha: 0.7,
      padding: const EdgeInsets.only(left: 14),
      child: SizedBox(
        height: 46,
        child: Row(
          children: <Widget>[
            GradientIcon(Icons.search_rounded, gradient: palette.accentGradient, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                onChanged: onChanged,
                textInputAction: TextInputAction.search,
                cursorColor: palette.primary,
                style: TextStyle(color: palette.textPrimary, fontSize: 16),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isCollapsed: true,
                  hintText: 'Search title or artist',
                  hintStyle: TextStyle(color: palette.textMuted),
                ),
              ),
            ),
            IconButton(
              onPressed: onClose,
              icon: Icon(Icons.close_rounded, color: palette.textSecondary),
              tooltip: 'Close search',
            ),
          ],
        ),
      ),
    );
  }
}

class _SortOption extends StatelessWidget {
  const _SortOption({required this.palette, required this.order, required this.selected});

  final RonovaPalette palette;
  final TrackSortOrder order;
  final bool selected;

  IconData get _icon {
    switch (order) {
      case TrackSortOrder.downloadNewestFirst:
        return Icons.south_rounded;
      case TrackSortOrder.downloadOldestFirst:
        return Icons.north_rounded;
      case TrackSortOrder.titleAscending:
        return Icons.sort_by_alpha_rounded;
      case TrackSortOrder.titleDescending:
        return Icons.sort_rounded;
    }
  }

  String get _hint {
    switch (order) {
      case TrackSortOrder.downloadNewestFirst:
        return 'Latest download at the top';
      case TrackSortOrder.downloadOldestFirst:
        return 'Earliest download at the top';
      case TrackSortOrder.titleAscending:
        return 'Title A to Z';
      case TrackSortOrder.titleDescending:
        return 'Title Z to A';
    }
  }

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      scale: 0.98,
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(context).pop(order);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: selected ? palette.gradient(begin: Alignment.centerLeft, end: Alignment.centerRight, alpha: 0.18) : null,
        ),
        child: Row(
          children: <Widget>[
            GradientIcon(_icon, gradient: palette.accentGradient, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(order.label, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: palette.textPrimary)),
                  Text(_hint, style: TextStyle(fontSize: 12, color: palette.textMuted)),
                ],
              ),
            ),
            if (selected) Icon(Icons.check_circle_rounded, color: palette.accentText, size: 22),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Track list pieces
// ---------------------------------------------------------------------------------------------

class _ListActions extends StatelessWidget {
  const _ListActions({required this.palette, required this.onShuffle, required this.onPlayAll});

  final RonovaPalette palette;
  final VoidCallback onShuffle;
  final VoidCallback onPlayAll;

  @override
  Widget build(BuildContext context) {
    Widget pill(IconData icon, String label, VoidCallback onTap, {required bool filled}) {
      return Expanded(
        child: PressableScale(
          scale: 0.96,
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: filled ? palette.accentGradient : null,
              color: filled ? null : palette.surface,
              border: filled ? null : Border.all(color: palette.border),
              boxShadow: filled ? palette.glowShadows(strength: 0.6, blur: 14) : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                filled
                    ? Icon(icon, size: 20, color: palette.onAccent)
                    : GradientIcon(icon, gradient: palette.accentGradient, size: 20),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: filled ? palette.onAccent : palette.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        children: <Widget>[
          pill(Icons.play_arrow_rounded, 'Play all', onPlayAll, filled: true),
          const SizedBox(width: 10),
          pill(Icons.shuffle_rounded, 'Shuffle', onShuffle, filled: false),
        ],
      ),
    );
  }
}

class _TrackRow extends ConsumerWidget {
  const _TrackRow({
    super.key,
    required this.track,
    required this.isCurrent,
    required this.isPlaying,
    required this.onTap,
    required this.onAction,
  });

  final AudioTrack track;
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback onTap;
  final void Function(TrackMenuAction action) onAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(ronovaPaletteProvider);
    const radius = 20.0;
    final subtitle = <String>[
      if (track.artist.trim().isNotEmpty) track.artist.trim(),
      if (track.album.trim().isNotEmpty) track.album.trim(),
    ].join(' · ');

    Widget row = AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      height: 68,
      padding: const EdgeInsets.only(left: 8, right: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: isCurrent
            ? palette.gradient(begin: Alignment.centerLeft, end: Alignment.centerRight, alpha: palette.isAbyss ? 0.16 : 0.20)
            : null,
        boxShadow: isCurrent ? palette.glowShadows(strength: 0.45, blur: 20) : null,
      ),
      child: Row(
        children: <Widget>[
          TrackArtwork(filePath: track.filePath, size: 52, radius: 15, glow: isCurrent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: isCurrent ? palette.accentText : palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle.isEmpty ? 'Unknown artist' : subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: palette.textSecondary),
                ),
              ],
            ),
          ),
          if (isCurrent) ...<Widget>[
            const SizedBox(width: 8),
            EqualizerBars(active: isPlaying, gradient: palette.accentGradient),
          ],
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: palette.border),
            ),
            child: Text(
              formatDurationMs(track.durationMs),
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: palette.textSecondary),
            ),
          ),
          GenshinMotifButton(track: track, onAction: onAction),
        ],
      ),
    );

    // Always wrapped so the highlight can animate in/out without rebuilding the row's state.
    row = CustomPaint(
      foregroundPainter: GradientBorderPainter(
        gradient: palette.gradient(alpha: isCurrent ? 0.55 : 0.0),
        radius: radius,
        width: 1.2,
      ),
      child: row,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: PressableScale(scale: 0.985, onTap: onTap, child: row),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.palette,
    required this.searching,
    required this.libraryEmpty,
    required this.query,
  });

  final RonovaPalette palette;
  final bool searching;
  final bool libraryEmpty;
  final String query;

  @override
  Widget build(BuildContext context) {
    final title = searching ? 'No matches for "${query.trim()}"' : 'No music found yet';
    final detail = searching
        ? 'Try another title or artist.'
        : (libraryEmpty
            ? 'Add songs to your phone, then pull down to scan again.'
            : 'Nothing to show right now.');
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 60, 32, 24),
      child: Column(
        children: <Widget>[
          GradientIcon(searching ? Icons.search_off_rounded : Icons.library_music_rounded, gradient: palette.accentGradient, size: 54),
          const SizedBox(height: 16),
          Text(title, textAlign: TextAlign.center, style: RonovaFonts.display(size: 19, color: palette.textPrimary)),
          const SizedBox(height: 6),
          Text(detail, textAlign: TextAlign.center, style: TextStyle(color: palette.textMuted, fontSize: 13.5, height: 1.35)),
        ],
      ),
    );
  }
}

class _LicenseFooter extends StatelessWidget {
  const _LicenseFooter({required this.palette});

  final RonovaPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 26, 28, 12),
      child: Column(
        children: <Widget>[
          Container(
            height: 1,
            margin: const EdgeInsets.symmetric(horizontal: 40),
            decoration: BoxDecoration(
              gradient: palette.gradient(begin: Alignment.centerLeft, end: Alignment.centerRight, alpha: 0.4),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            kCommercialLicenseNotice,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, height: 1.45, color: palette.textMuted),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Permission gate
// ---------------------------------------------------------------------------------------------

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.palette,
    required this.requesting,
    required this.onAllow,
    required this.onOpenSettings,
  });

  final RonovaPalette palette;
  final bool requesting;
  final VoidCallback onAllow;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: FrostedCard(
          blur: true,
          glow: true,
          strong: true,
          radius: 32,
          borderAlpha: 0.7,
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              GradientIcon(Icons.headphones_rounded, gradient: palette.accentGradient, size: 58),
              const SizedBox(height: 16),
              Text('Let Ronova find your music', textAlign: TextAlign.center, style: RonovaFonts.display(size: 21, color: palette.textPrimary)),
              const SizedBox(height: 8),
              Text(
                'Ronova needs access to the audio on your device to build your library, and notification access for the lock-screen player. Nothing ever leaves your phone.',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textSecondary, fontSize: 13.5, height: 1.4),
              ),
              const SizedBox(height: 20),
              PressableScale(
                scale: 0.97,
                onTap: requesting ? null : onAllow,
                child: Container(
                  height: 50,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(25),
                    gradient: palette.accentGradient,
                    boxShadow: palette.glowShadows(strength: 0.8, blur: 18),
                  ),
                  child: Text(
                    requesting ? 'Waiting...' : 'Allow access',
                    style: TextStyle(color: palette.onAccent, fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
              ),
              TextButton(
                onPressed: onOpenSettings,
                child: Text('Open app settings', style: TextStyle(color: palette.accentText)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Docked mini-player
// ---------------------------------------------------------------------------------------------

class _MiniPlayer extends ConsumerWidget {
  const _MiniPlayer({super.key, required this.bottomInset});

  final double bottomInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(ronovaPaletteProvider);
    final controller = ref.read(audioLibraryProvider.notifier);
    final view = ref.watch(audioLibraryProvider.select((s) => (track: s.currentTrack, playing: s.isPlaying)));
    final track = view.track;
    if (track == null) return const SizedBox.shrink();

    final artColors = ref.watch(albumArtColorsProvider(track.filePath)).valueOrNull;
    final glow1 = artColors != null && artColors.isNotEmpty ? artColors[0] : palette.accent1;
    final glow2 = artColors != null && artColors.length > 1 ? artColors[1] : palette.accent2;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showCenterPlayerBox(context),
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) < -350) showCenterPlayerBox(context);
      },
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v < -380) {
          HapticFeedback.selectionClick();
          unawaited(controller.next());
        } else if (v > 380) {
          HapticFeedback.selectionClick();
          unawaited(controller.previous());
        }
      },
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, 10 + bottomInset),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            boxShadow: <BoxShadow>[
              BoxShadow(color: glow1.withValues(alpha: 0.32), blurRadius: 24, offset: const Offset(-3, 4)),
              BoxShadow(color: glow2.withValues(alpha: 0.28), blurRadius: 24, offset: const Offset(3, 4)),
            ],
          ),
          child: FrostedCard(
            blur: true,
            strong: true,
            radius: 28,
            borderAlpha: 0.65,
            child: Stack(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 9, 10, 11),
                  child: Row(
                    children: <Widget>[
                      TrackArtwork(filePath: track.filePath, size: 48, radius: 15),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            AutoMarquee(
                              text: track.title,
                              height: 21,
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: palette.textPrimary),
                            ),
                            Text(
                              track.artist.isEmpty ? 'Unknown artist' : track.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5, color: palette.textSecondary),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      GlowIconButton(
                        icon: view.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        size: 44,
                        iconSize: 26,
                        filled: true,
                        onPressed: () => unawaited(controller.togglePlayPause()),
                      ),
                      const SizedBox(width: 6),
                      GlowIconButton(
                        icon: Icons.skip_next_rounded,
                        size: 40,
                        iconSize: 24,
                        onPressed: () => unawaited(controller.next()),
                      ),
                    ],
                  ),
                ),
                const Positioned(left: 22, right: 22, bottom: 4, child: _MiniProgress()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Hairline progress under the mini-player (rebuilds on its own, not with the whole bar).
class _MiniProgress extends ConsumerWidget {
  const _MiniProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(ronovaPaletteProvider);
    final progress = ref.watch(audioLibraryProvider.select((s) => s.progress));
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 3,
        child: Stack(
          children: <Widget>[
            Container(color: palette.textMuted.withValues(alpha: 0.22)),
            FractionallySizedBox(
              widthFactor: progress,
              alignment: Alignment.centerLeft,
              child: DecoratedBox(decoration: BoxDecoration(gradient: palette.accentGradient)),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Dialogs & sheets
// ---------------------------------------------------------------------------------------------

InputDecoration _fieldDecoration(RonovaPalette palette, String label) {
  OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: color, width: width),
      );
  return InputDecoration(
    labelText: label,
    labelStyle: TextStyle(color: palette.textMuted),
    floatingLabelStyle: TextStyle(color: palette.accentText),
    filled: true,
    fillColor: palette.surface,
    enabledBorder: border(palette.border, 1),
    focusedBorder: border(palette.primary, 1.6),
  );
}

class _GlassDialog extends ConsumerWidget {
  const _GlassDialog({required this.title, required this.content, required this.actions});

  final String title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(ronovaPaletteProvider);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
      child: FrostedCard(
        blur: true,
        strong: true,
        glow: true,
        radius: 28,
        borderAlpha: 0.7,
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: RonovaFonts.display(size: 20, color: palette.textPrimary)),
            const SizedBox(height: 14),
            content,
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
          ],
        ),
      ),
    );
  }
}

class _EditTagsDialog extends ConsumerStatefulWidget {
  const _EditTagsDialog({required this.track});

  final AudioTrack track;

  @override
  ConsumerState<_EditTagsDialog> createState() => _EditTagsDialogState();
}

class _EditTagsDialogState extends ConsumerState<_EditTagsDialog> {
  late final TextEditingController _title = TextEditingController(text: widget.track.title);
  late final TextEditingController _artist = TextEditingController(text: widget.track.artist);

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = ref.watch(ronovaPaletteProvider);
    return _GlassDialog(
      title: 'Edit tags',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.words,
            cursorColor: palette.primary,
            style: TextStyle(color: palette.textPrimary),
            decoration: _fieldDecoration(palette, 'Title'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _artist,
            textCapitalization: TextCapitalization.words,
            cursorColor: palette.primary,
            style: TextStyle(color: palette.textPrimary),
            decoration: _fieldDecoration(palette, 'Artist'),
          ),
          const SizedBox(height: 8),
          Text(
            'Saved in your Ronova library only; the audio file is never modified.',
            style: TextStyle(color: palette.textMuted, fontSize: 12),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: palette.textSecondary)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop((title: _title.text, artist: _artist.text)),
          child: Text('Save', style: TextStyle(color: palette.accentText, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

class _FolderDialog extends ConsumerWidget {
  const _FolderDialog({required this.track});

  final AudioTrack track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(ronovaPaletteProvider);
    final directory = p.dirname(track.filePath);
    return _GlassDialog(
      title: 'Show in folders',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('Folder', style: TextStyle(color: palette.textMuted, fontSize: 12)),
          const SizedBox(height: 4),
          SelectableText(directory, style: TextStyle(color: palette.textPrimary, fontSize: 14.5, height: 1.35)),
          const SizedBox(height: 12),
          Text('File', style: TextStyle(color: palette.textMuted, fontSize: 12)),
          const SizedBox(height: 4),
          SelectableText(p.basename(track.filePath), style: TextStyle(color: palette.textSecondary, fontSize: 13.5)),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: directory));
            if (context.mounted) {
              showRonovaSnack(context, 'Folder path copied');
              Navigator.of(context).pop();
            }
          },
          child: Text('Copy path', style: TextStyle(color: palette.accentText)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Close', style: TextStyle(color: palette.textSecondary)),
        ),
      ],
    );
  }
}

class _ConfirmDeleteDialog extends ConsumerWidget {
  const _ConfirmDeleteDialog({required this.track});

  final AudioTrack track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(ronovaPaletteProvider);
    return _GlassDialog(
      title: 'Remove from library?',
      content: Text(
        '"${track.title}" will disappear from your Ronova library. The audio file itself stays on your device.',
        style: TextStyle(color: palette.textSecondary, fontSize: 14.5, height: 1.4),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Cancel', style: TextStyle(color: palette.textSecondary)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Remove', style: TextStyle(color: Color(0xFFFF5A6E), fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

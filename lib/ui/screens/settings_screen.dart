import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/models/theme_config.dart';
import '../../core/providers/app_providers.dart';
import '../../core/providers/audio_library_provider.dart';
import '../../core/providers/theme_settings_provider.dart';
import '../../core/services/native_platform_service.dart';
import '../../core/theme/ronova_palette.dart';
import '../widgets/hsv_color_wheel.dart';
import '../widgets/ronova_widgets.dart';
import '../widgets/video_background.dart';
import 'equalizer_screen.dart';

Future<void> openSettingsScreen(BuildContext context) {
  return Navigator.of(context).push<void>(ronovaRoute<void>((_) => const SettingsScreen()));
}

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> with WidgetsBindingObserver {
  bool _awaitingOverlayPermission = false;
  bool _pickingWallpaper = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _awaitingOverlayPermission) {
      _awaitingOverlayPermission = false;
      unawaited(_finishOverlayPermissionFlow());
    }
  }

  Future<void> _finishOverlayPermissionFlow() async {
    final granted = await NativePlatformService.instance.canDrawOverlays();
    if (!mounted) return;
    if (!granted) {
      await _showRestrictedHelp();
      return;
    }
    final result = await ref.read(audioLibraryProvider.notifier).enableOverlay();
    if (!mounted) return;
    if (!result.started) {
      showRonovaSnack(context, 'The floating "R" could not start.');
    }
  }

  /// Shown when the user comes back from Android's settings without the permission. On Android 13+
  /// a sideloaded APK has "restricted settings", which greys the toggle out until it is allowed
  /// from the App info page.
  Future<void> _showRestrictedHelp() async {
    final open = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Toggle greyed out?'),
        content: const Text(
          'Android blocks some permissions for apps installed from an APK file.\n\n'
          '1. Tap "Open app info"\n'
          '2. Tap the \u22EE menu (top right)\n'
          '3. Choose "Allow restricted settings"\n'
          '4. Go back and enable "Display over other apps" for Ronova Audio.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Later')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Open app info')),
        ],
      ),
    );
    if (open == true) {
      _awaitingOverlayPermission = true;
      await NativePlatformService.instance.openAppDetails();
    }
  }

  Future<void> _setOverlay(bool enabled) async {
    final audio = ref.read(audioLibraryProvider.notifier);
    if (!enabled) {
      await audio.disableOverlay();
      return;
    }
    final result = await audio.enableOverlay();
    if (!mounted || result.started) return;
    if (result.needsPermission) {
      _awaitingOverlayPermission = true;
      showRonovaSnack(context, 'Allow "Display over other apps" for Ronova, then return here.');
      await NativePlatformService.instance.openOverlaySettings();
    } else {
      showRonovaSnack(context, 'The floating "R" could not start.');
    }
  }

  Future<void> _pickWallpaper({bool video = false}) async {
    if (_pickingWallpaper) return;
    setState(() => _pickingWallpaper = true);
    try {
      final picker = ImagePicker();
      final XFile? picked = video
          ? await picker.pickVideo(source: ImageSource.gallery)
          : await picker.pickImage(
              source: ImageSource.gallery,
              maxWidth: 2160,
              maxHeight: 2160,
              imageQuality: 92,
            );
      if (picked == null) return;
      final dir = await getApplicationSupportDirectory();
      final extension = p.extension(picked.path).isEmpty ? (video ? '.mp4' : '.jpg') : p.extension(picked.path);
      final target = p.join(dir.path, 'wallpaper_${DateTime.now().millisecondsSinceEpoch}$extension');
      await File(picked.path).copy(target);
      if (!mounted) return;
      await _deleteStoredWallpaper(ref.read(themeSettingsProvider).backgroundImagePath);
      ref.read(themeSettingsProvider.notifier).setBackgroundImage(target);
    } catch (error) {
      if (mounted) showRonovaSnack(context, 'Could not use that photo: $error');
    } finally {
      if (mounted) setState(() => _pickingWallpaper = false);
    }
  }

  Future<void> _resetWallpaper() async {
    final old = ref.read(themeSettingsProvider).backgroundImagePath;
    ref.read(themeSettingsProvider.notifier).clearBackgroundImage();
    await _deleteStoredWallpaper(old);
  }

  Future<void> _deleteStoredWallpaper(String? path) async {
    if (path == null) return;
    try {
      final dir = await getApplicationSupportDirectory();
      if (p.isWithin(dir.path, path)) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    } catch (_) {
      // Best effort: a leftover wallpaper file is harmless.
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(themeSettingsProvider);
    final palette = ref.watch(ronovaPaletteProvider);
    final audio = ref.watch(
      audioLibraryProvider.select(
        (s) => (route: s.outputRoute, ronova: s.ronovaModeActive, gain: s.upscalerGainDb, limiter: s.limiterReductionDb),
      ),
    );
    final upscalerOn = audio.gain > 0.05;
    final audioController = ref.read(audioLibraryProvider.notifier);
    final theme = ref.read(themeSettingsProvider.notifier);
    final boot = ref.watch(bootReportProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: RonovaBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: Row(
                  children: <Widget>[
                    GlowIconButton(
                      icon: Icons.arrow_back_rounded,
                      tooltip: 'Back',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text('Settings', style: RonovaFonts.display(size: 26, color: palette.textPrimary)),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
                  children: <Widget>[
                    // ---- Aether / Abyss ----------------------------------------------------
                    const _SectionTitle('Appearance', Icons.auto_awesome_rounded),
                    FrostedCard(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text('Base mode', style: TextStyle(color: palette.textSecondary, fontSize: 13)),
                          const SizedBox(height: 10),
                          _SegmentPill(
                            palette: palette,
                            labels: const <String>['Aether', 'Abyss'],
                            icons: const <IconData>[Icons.wb_sunny_rounded, Icons.nightlight_round],
                            selected: config.isAbyssMode ? 1 : 0,
                            onChanged: (index) => theme.setAbyssMode(index == 1),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            config.isAbyssMode
                                ? 'Abyss: dark obsidian base with glowing accents.'
                                : 'Aether: soft celestial light base.',
                            style: TextStyle(color: palette.textMuted, fontSize: 12.5),
                          ),
                        ],
                      ),
                    ),

                    // ---- Theme & dual colour wheels -------------------------------------------
                    const _SectionTitle('Theme & Dual Color Wheels', Icons.palette_rounded),
                    _PresetStrip(palette: palette, config: config, onSelected: theme.applyPreset),
                    const SizedBox(height: 12),
                    _AccentPreview(palette: palette),
                    const SizedBox(height: 12),
                    _WheelCard(
                      title: 'Color wheel 1',
                      palette: palette,
                      enabled: config.wheel1Enabled,
                      color: config.wheel1Color,
                      onEnabled: (value) => theme.setWheelEnabled(1, value),
                      onColor: (color) => theme.setWheelColor(1, color),
                    ),
                    const SizedBox(height: 12),
                    _WheelCard(
                      title: 'Color wheel 2',
                      palette: palette,
                      enabled: config.wheel2Enabled,
                      color: config.wheel2Color,
                      onEnabled: (value) => theme.setWheelEnabled(2, value),
                      onColor: (color) => theme.setWheelColor(2, color),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
                      child: Text(
                        'One wheel on: its colour tints the whole app. Both on: the UI blends them in a '
                        'split gradient across borders, glows, icons and buttons.',
                        style: TextStyle(color: palette.textMuted, fontSize: 12.5, height: 1.35),
                      ),
                    ),

                    // ---- Wallpaper & album art ------------------------------------------------
                    const _SectionTitle('Wallpaper & Album Art', Icons.wallpaper_rounded),
                    FrostedCard(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _WallpaperPreview(palette: palette, config: config),
                          const SizedBox(height: 12),
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: _GradientButton(
                                  palette: palette,
                                  icon: Icons.photo_library_rounded,
                                  label: _pickingWallpaper ? 'Opening...' : 'Photo',
                                  onPressed: _pickingWallpaper ? null : () => _pickWallpaper(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _GradientButton(
                                  palette: palette,
                                  icon: Icons.video_library_rounded,
                                  label: _pickingWallpaper ? 'Opening...' : 'Video',
                                  onPressed: _pickingWallpaper ? null : () => _pickWallpaper(video: true),
                                ),
                              ),
                              const SizedBox(width: 6),
                              TextButton(
                                onPressed: config.backgroundImagePath == null ? null : _resetWallpaper,
                                child: Text(
                                  'Reset',
                                  style: TextStyle(
                                    color: config.backgroundImagePath == null ? palette.textMuted : palette.accentText,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          _LabeledSlider(
                            palette: palette,
                            label: 'Background dim',
                            valueLabel: '${(config.backgroundDimOpacity * 100).round()}%',
                            value: config.backgroundDimOpacity,
                            min: 0.0,
                            max: ThemeConfig.maxBackgroundDim,
                            onChanged: config.backgroundImagePath == null ? null : theme.setBackgroundDim,
                          ),
                          const SizedBox(height: 6),
                          Text('Album art', style: TextStyle(color: palette.textSecondary, fontSize: 13)),
                          const SizedBox(height: 10),
                          _SegmentPill(
                            palette: palette,
                            labels: const <String>['Normal', 'Dimmed', 'Hidden'],
                            icons: const <IconData>[
                              Icons.image_rounded,
                              Icons.contrast_rounded,
                              Icons.hide_image_rounded,
                            ],
                            selected: config.artDimLevel >= 1.0 ? 2 : (config.artDimLevel >= 0.5 ? 1 : 0),
                            onChanged: (index) => theme.setArtDimLevel(const <double>[0.0, 0.5, 1.0][index]),
                          ),
                        ],
                      ),
                    ),

                    // ---- Audio ----------------------------------------------------------------
                    const _SectionTitle('Audio Engine', Icons.graphic_eq_rounded),
                    FrostedCard(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _OutputRouteTile(palette: palette, info: audio.route),
                          const SizedBox(height: 14),
                          Text('Channels', style: TextStyle(color: palette.textSecondary, fontSize: 13)),
                          const SizedBox(height: 10),
                          _SegmentPill(
                            palette: palette,
                            labels: const <String>['Stereo', 'Mono'],
                            icons: const <IconData>[Icons.speaker_group_rounded, Icons.speaker_rounded],
                            selected: config.isMonoMode ? 1 : 0,
                            onChanged: (index) => theme.setMonoMode(index == 1),
                          ),
                          const SizedBox(height: 6),
                          _SwitchRow(
                            palette: palette,
                            title: 'Ronova Mode',
                            subtitle: 'Crossfeed, 11.5 kHz air, sub-bass punch and headset calibration',
                            value: audio.ronova,
                            onChanged: audioController.setRonovaMode,
                          ),
                          const SizedBox(height: 4),
                          _LabeledSlider(
                            palette: palette,
                            label: 'Volume upscaler',
                            valueLabel: upscalerOn ? '+${audio.gain.toStringAsFixed(1)} dB' : 'Off',
                            value: audio.gain,
                            min: 0.0,
                            max: AudioLibraryController.maxUpscalerDb,
                            onChanged: audioController.setUpscalerGainDb,
                          ),
                          _LimiterMeter(palette: palette, reductionDb: audio.limiter, active: upscalerOn),
                          const SizedBox(height: 12),
                          _GradientButton(
                            palette: palette,
                            icon: Icons.equalizer_rounded,
                            label: '16-Band Rotary Equalizer & 40 Presets',
                            onPressed: () => showEqualizerScreen(context),
                          ),
                        ],
                      ),
                    ),

                    // ---- Gaming overlay -------------------------------------------------------
                    const _SectionTitle('Gaming Overlay', Icons.sports_esports_rounded),
                    FrostedCard(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        children: <Widget>[
                          _SwitchRow(
                            palette: palette,
                            title: 'Floating red "R"',
                            subtitle: 'A draggable music-note button that floats over your games',
                            value: config.overlayEnabled,
                            onChanged: _setOverlay,
                          ),
                          AnimatedOpacity(
                            duration: const Duration(milliseconds: 220),
                            opacity: config.overlayEnabled ? 1.0 : 0.45,
                            child: IgnorePointer(
                              ignoring: !config.overlayEnabled,
                              child: Column(
                                children: <Widget>[
                                  _SwitchRow(
                                    palette: palette,
                                    title: 'Double-tap to open',
                                    subtitle: 'Prevents accidental taps while gaming',
                                    value: config.doubleTapToOpen,
                                    onChanged: theme.setOverlayDoubleTap,
                                  ),
                                  _LabeledSlider(
                                    palette: palette,
                                    label: 'Size',
                                    valueLabel: '${config.overlayScale.toStringAsFixed(2)}x',
                                    value: config.overlayScale,
                                    min: 0.5,
                                    max: 2.0,
                                    onChanged: theme.setOverlayScale,
                                  ),
                                  _LabeledSlider(
                                    palette: palette,
                                    label: 'Opacity',
                                    valueLabel: '${(config.overlayOpacity * 100).round()}%',
                                    value: config.overlayOpacity,
                                    min: 0.2,
                                    max: 1.0,
                                    onChanged: theme.setOverlayOpacity,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // ---- System status --------------------------------------------------------
                    const _SectionTitle('System', Icons.memory_rounded),
                    FrostedCard(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        children: <Widget>[
                          _StatusRow(
                            palette: palette,
                            ok: boot.ffiLinked && boot.engineInitOk,
                            title: '32-bit float DSP engine',
                            detail: boot.ffiLinked
                                ? (boot.engineInitOk ? boot.nativeDiagnostics : 'Engine did not initialise')
                                : 'Native library not loaded',
                          ),
                          _StatusRow(
                            palette: palette,
                            ok: boot.sqliteReady,
                            title: 'Instant library cache',
                            detail: boot.sqliteReady
                                ? 'Opened in ${boot.sqliteOpenMs.toStringAsFixed(1)} ms'
                                : 'SQLite unavailable',
                          ),
                          _StatusRow(
                            palette: palette,
                            ok: boot.prefsReady,
                            title: 'Settings storage',
                            detail: boot.prefsReady ? 'Launch #${boot.bootCount}' : 'Preferences unavailable',
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 22, 8, 0),
                      child: Text(
                        '© 2026 Ronova Audio Labs. Commercial License — All Rights Reserved. '
                        'Powered by 32-Bit IEEE Float DSP.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: palette.textMuted, fontSize: 11.5, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Building blocks
// ---------------------------------------------------------------------------------------------

class _SectionTitle extends ConsumerWidget {
  const _SectionTitle(this.text, this.icon);

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(ronovaPaletteProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 26, 6, 12),
      child: Row(
        children: <Widget>[
          GradientIcon(icon, gradient: palette.accentGradient, size: 20),
          const SizedBox(width: 10),
          Text(text, style: RonovaFonts.display(size: 18, color: palette.textPrimary)),
        ],
      ),
    );
  }
}

/// Pill selector with a sliding gradient highlight (Aether/Abyss, Stereo/Mono, art visibility).
class _SegmentPill extends StatelessWidget {
  const _SegmentPill({
    required this.palette,
    required this.labels,
    required this.icons,
    required this.selected,
    required this.onChanged,
  });

  final RonovaPalette palette;
  final List<String> labels;
  final List<IconData> icons;
  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final count = labels.length;
    return Container(
      height: 50,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: palette.isAbyss ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: palette.border),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segment = constraints.maxWidth / count;
          return Stack(
            children: <Widget>[
              AnimatedPositioned(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutBack,
                left: segment * selected,
                top: 0,
                bottom: 0,
                width: segment,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(21),
                    gradient: palette.accentGradient,
                    boxShadow: palette.glowShadows(strength: 0.7, blur: 14),
                  ),
                ),
              ),
              Row(
                children: <Widget>[
                  for (var i = 0; i < count; i++)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onChanged(i);
                        },
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                icons[i],
                                size: 18,
                                color: i == selected ? palette.onAccent : palette.textSecondary,
                              ),
                              const SizedBox(width: 7),
                              Text(
                                labels[i],
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: i == selected ? palette.onAccent : palette.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PresetStrip extends StatelessWidget {
  const _PresetStrip({required this.palette, required this.config, required this.onSelected});

  final RonovaPalette palette;
  final ThemeConfig config;
  final ValueChanged<ThemePreset> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        for (final preset in ThemeConfig.presets)
          _PresetChip(
            palette: palette,
            preset: preset,
            selected: config.presetName == preset.name,
            onTap: () {
              HapticFeedback.mediumImpact();
              onSelected(preset);
            },
          ),
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.palette,
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final RonovaPalette palette;
  final ThemePreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final gradient = LinearGradient(colors: <Color>[preset.color1, preset.color2]);
    return PressableScale(
      onTap: onTap,
      scale: 0.94,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        padding: const EdgeInsets.fromLTRB(8, 8, 14, 8),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: selected ? preset.color1 : palette.border,
            width: selected ? 1.6 : 1.0,
          ),
          boxShadow: selected
              ? <BoxShadow>[
                  BoxShadow(color: preset.color1.withValues(alpha: 0.35), blurRadius: 14),
                  BoxShadow(color: preset.color2.withValues(alpha: 0.30), blurRadius: 14, offset: const Offset(3, 0)),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(shape: BoxShape.circle, gradient: gradient),
            ),
            const SizedBox(width: 9),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  preset.name,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: palette.textPrimary),
                ),
                Text(preset.subtitle, style: TextStyle(fontSize: 10.5, color: palette.textMuted)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Live preview of the resulting accent: a single flat colour or the split gradient.
class _AccentPreview extends StatelessWidget {
  const _AccentPreview({required this.palette});

  final RonovaPalette palette;

  @override
  Widget build(BuildContext context) {
    return FrostedCard(
      padding: const EdgeInsets.all(14),
      glow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            palette.dual ? 'Split-gradient accent' : 'Uniform accent',
            style: TextStyle(color: palette.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 10),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            height: 14,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              gradient: palette.accentGradient,
              boxShadow: palette.glowShadows(strength: 0.9, blur: 16),
            ),
          ),
        ],
      ),
    );
  }
}

class _WheelCard extends StatelessWidget {
  const _WheelCard({
    required this.title,
    required this.palette,
    required this.enabled,
    required this.color,
    required this.onEnabled,
    required this.onColor,
  });

  final String title;
  final RonovaPalette palette;
  final bool enabled;
  final Color color;
  final ValueChanged<bool> onEnabled;
  final ValueChanged<Color> onColor;

  String get _hex => '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  @override
  Widget build(BuildContext context) {
    return FrostedCard(
      padding: const EdgeInsets.all(14),
      borderAlpha: enabled ? 0.6 : 0.2,
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              AnimatedContainer(
                duration: const Duration(milliseconds: 240),
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  boxShadow: enabled ? <BoxShadow>[BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: 12)] : null,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.7), width: 1.5),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: palette.textPrimary)),
                    Text(_hex, style: TextStyle(fontSize: 12, color: palette.textMuted, letterSpacing: 0.6)),
                  ],
                ),
              ),
              RonovaSwitch(value: enabled, onChanged: onEnabled),
            ],
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: enabled
                ? Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: HsvColorWheel(color: color, onChanged: onColor),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _WallpaperPreview extends StatelessWidget {
  const _WallpaperPreview({required this.palette, required this.config});

  final RonovaPalette palette;
  final ThemeConfig config;

  @override
  Widget build(BuildContext context) {
    final path = config.backgroundImagePath;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        height: 170,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ColoredBox(color: palette.bg),
            if (path != null && isVideoPath(path)) ...<Widget>[
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.movie_rounded, color: palette.accentText, size: 34),
                    const SizedBox(height: 6),
                    Text('Video wallpaper (muted, looping)', style: TextStyle(color: palette.textSecondary, fontSize: 12.5)),
                  ],
                ),
              ),
              ColoredBox(
                color: (palette.isAbyss ? Colors.black : Colors.white).withValues(alpha: config.backgroundDimOpacity * 0.5),
              ),
            ] else if (path != null) ...<Widget>[
              Image.file(
                File(path),
                fit: BoxFit.cover,
                alignment: Alignment.center,
                errorBuilder: (context, error, stack) => const SizedBox.shrink(),
              ),
              ColoredBox(
                color: (palette.isAbyss ? Colors.black : Colors.white).withValues(alpha: config.backgroundDimOpacity),
              ),
            ] else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.wallpaper_rounded, color: palette.textMuted, size: 30),
                    const SizedBox(height: 6),
                    Text('No wallpaper — aurora background is active', style: TextStyle(color: palette.textMuted, fontSize: 12.5)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GradientButton extends StatelessWidget {
  const _GradientButton({
    required this.palette,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final RonovaPalette palette;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    return PressableScale(
      scale: 0.97,
      onTap: onPressed == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onPressed!();
            },
      child: Opacity(
        opacity: disabled ? 0.5 : 1.0,
        child: Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(25),
            gradient: palette.accentGradient,
            boxShadow: palette.glowShadows(strength: 0.7, blur: 16),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, color: palette.onAccent, size: 20),
              const SizedBox(width: 9),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.onAccent, fontSize: 14.5, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.palette,
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final RonovaPalette palette;
  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(label, style: TextStyle(color: palette.textSecondary, fontSize: 13.5))),
            Text(valueLabel, style: TextStyle(color: palette.accentText, fontSize: 13.5, fontWeight: FontWeight.w700)),
          ],
        ),
        SliderTheme(
          data: ronovaSliderTheme(palette),
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.palette,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final RonovaPalette palette;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: palette.textPrimary)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 12.5, color: palette.textMuted, height: 1.3)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          RonovaSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _OutputRouteTile extends StatelessWidget {
  const _OutputRouteTile({required this.palette, required this.info});

  final RonovaPalette palette;
  final HeadsetHardwareInfo info;

  @override
  Widget build(BuildContext context) {
    final icon = info.isBluetooth
        ? Icons.bluetooth_audio_rounded
        : (info.isWired ? Icons.headphones_rounded : Icons.speaker_phone_rounded);
    final kind = info.isBluetooth ? 'Bluetooth' : (info.transport == 'usb' ? 'USB-C DAC' : (info.isWired ? 'Wired' : 'Speaker'));
    return Row(
      children: <Widget>[
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: palette.surfaceStrong,
            boxShadow: palette.glowShadows(strength: 0.5, blur: 12),
          ),
          child: Center(child: GradientIcon(icon, gradient: palette.accentGradient, size: 22)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(info.deviceName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: palette.textPrimary)),
              Text(
                '$kind · up to ${(info.maxSampleRate / 1000).toStringAsFixed(info.maxSampleRate % 1000 == 0 ? 0 : 1)} kHz',
                style: TextStyle(fontSize: 12.5, color: palette.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Live gain-reduction readout straight from the C++ brickwall limiter.
class _LimiterMeter extends StatelessWidget {
  const _LimiterMeter({required this.palette, required this.reductionDb, required this.active});

  final RonovaPalette palette;
  final double reductionDb;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final fill = (reductionDb / 24.0).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: <Widget>[
          Text('Limiter', style: TextStyle(color: palette.textMuted, fontSize: 12)),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Stack(
                children: <Widget>[
                  Container(height: 6, color: palette.textMuted.withValues(alpha: 0.2)),
                  AnimatedFractionallySizedBox(
                    duration: const Duration(milliseconds: 200),
                    widthFactor: active ? fill : 0.0,
                    alignment: Alignment.centerLeft,
                    child: Container(height: 6, decoration: BoxDecoration(gradient: palette.accentGradient)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 58,
            child: Text(
              active ? '-${reductionDb.toStringAsFixed(1)} dB' : 'idle',
              textAlign: TextAlign.right,
              style: TextStyle(color: palette.textSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.palette, required this.ok, required this.title, required this.detail});

  final RonovaPalette palette;
  final bool ok;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            ok ? Icons.check_circle_rounded : Icons.error_rounded,
            size: 20,
            color: ok ? const Color(0xFF3DDC97) : const Color(0xFFFF5A6E),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: palette.textPrimary)),
                Text(detail, style: TextStyle(fontSize: 12, color: palette.textMuted, height: 1.3)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

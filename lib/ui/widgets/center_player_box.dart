import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/audio_track.dart';
import '../../core/providers/album_art_color_provider.dart';
import '../../core/providers/audio_library_provider.dart';
import '../../core/providers/theme_settings_provider.dart';
import '../../core/services/native_platform_service.dart';
import '../../core/theme/ronova_palette.dart';
import 'glass_sheet.dart';
import 'info_badge_tooltip.dart';
import 'ronova_widgets.dart';

/// Signature Ronova Mode colours: crimson core, celestial blue halo.
const Color _ronovaCrimson = Color(0xFFFF3B5C);
const Color _ronovaCelestial = Color(0xFF7FB2FF);
const Color _okGreen = Color(0xFF4ADE80);

// ---------------------------------------------------------------------------------------------
// Entry point: spring / scale dialog
// ---------------------------------------------------------------------------------------------

/// Opens the detached center player box with a springy scale-in rising from the mini-player.
Future<void> showCenterPlayerBox(BuildContext context) {
  HapticFeedback.lightImpact();
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close player',
    barrierColor: Colors.black.withValues(alpha: 0.58),
    transitionDuration: const Duration(milliseconds: 520),
    pageBuilder: (context, animation, secondaryAnimation) {
      return const SafeArea(child: Center(child: CenterPlayerBox()));
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final closing = animation.status == AnimationStatus.reverse;
      final scale = CurveTween(curve: closing ? Curves.easeInCubic : const _SpringCurve()).animate(animation);
      final fade = CurveTween(
        curve: closing ? const Interval(0.35, 1.0, curve: Curves.easeIn) : const Interval(0.0, 0.55, curve: Curves.easeOut),
      ).animate(animation);
      return FadeTransition(
        opacity: fade,
        child: ScaleTransition(
          alignment: const Alignment(0, 1.05),
          scale: Tween<double>(begin: 0.78, end: 1.0).animate(scale),
          child: child,
        ),
      );
    },
  );
}

/// Damped spring: overshoots by a few percent, then settles.
class _SpringCurve extends Curve {
  const _SpringCurve();

  @override
  double transformInternal(double t) {
    return 1.0 - math.exp(-5.4 * t) * math.cos(2 * math.pi * 2.2 * t);
  }
}

// ---------------------------------------------------------------------------------------------
// Colours
// ---------------------------------------------------------------------------------------------

@immutable
class _BoxColors {
  const _BoxColors({required this.a, required this.b, required this.deep});

  /// Primary glow / accent (vibrant cover colour, or colour wheel 1).
  final Color a;

  /// Secondary glow (dominant cover colour, or colour wheel 2).
  final Color b;

  /// Shadowed corner of the background gradient.
  final Color deep;

  Gradient get gradient => LinearGradient(colors: <Color>[a, b]);

  static _BoxColors lerp(_BoxColors x, _BoxColors y, double t) {
    return _BoxColors(
      a: Color.lerp(x.a, y.a, t) ?? y.a,
      b: Color.lerp(x.b, y.b, t) ?? y.b,
      deep: Color.lerp(x.deep, y.deep, t) ?? y.deep,
    );
  }
}

class _BoxColorsTween extends Tween<_BoxColors> {
  _BoxColorsTween({super.begin, super.end});

  @override
  _BoxColors lerp(double t) => _BoxColors.lerp(begin!, end!, t);
}

/// Lifts dull cover colours so the glow stays clearly visible.
Color _vivid(Color color) {
  final hsl = HSLColor.fromColor(color);
  return hsl
      .withSaturation(math.max(hsl.saturation, 0.5))
      .withLightness(hsl.lightness.clamp(0.46, 0.74).toDouble())
      .toColor();
}

Color _onColor(Color color) => color.computeLuminance() > 0.5 ? const Color(0xFF10131C) : Colors.white;

_BoxColors _resolveColors(RonovaPalette p, AlbumArtPalette? art) {
  if (art == null) {
    // No cover art: fall back to the active colour wheel(s).
    return _BoxColors(a: p.accent1, b: p.accent2, deep: Color.lerp(p.accent1, p.accent2, 0.5) ?? p.accent1);
  }
  return _BoxColors(a: _vivid(art.vibrant), b: _vivid(art.dominant), deep: art.deep);
}

String _clock(int ms) {
  final total = math.max(0, ms) ~/ 1000;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}

Rect? _rectOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

// ---------------------------------------------------------------------------------------------
// The box
// ---------------------------------------------------------------------------------------------

/// Floating, detached, frosted player: album-art gradient + luminous edge glow, spinning note
/// badge, speed / reverb / room-space controls, seek bar, full transport, volume upscaler with a
/// live limiter meter and the Ronova Mode calibration sequence.
class CenterPlayerBox extends ConsumerStatefulWidget {
  const CenterPlayerBox({super.key});

  @override
  ConsumerState<CenterPlayerBox> createState() => _CenterPlayerBoxState();
}

class _CenterPlayerBoxState extends ConsumerState<CenterPlayerBox> with TickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 5200));
  late final AnimationController _edge = AnimationController(vsync: this, duration: const Duration(seconds: 12))
    ..repeat();
  late final AnimationController _breathe = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200))
    ..repeat(reverse: true);
  late final AnimationController _calib = AnimationController(vsync: this, duration: const Duration(milliseconds: 2500));
  final ValueNotifier<double?> _seekDrag = ValueNotifier<double?>(null);

  bool _speedOpen = false;
  bool _roomOpen = false;
  bool _calibrating = false;
  HeadsetHardwareInfo? _scan;

  @override
  void initState() {
    super.initState();
    ref.listenManual<bool>(
      audioLibraryProvider.select((s) => s.isPlaying),
      (previous, next) => _syncSpin(next),
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _spin.dispose();
    _edge.dispose();
    _breathe.dispose();
    _calib.dispose();
    _seekDrag.dispose();
    super.dispose();
  }

  void _syncSpin(bool playing) {
    if (playing) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  // ---- Build -------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(ronovaPaletteProvider);
    final track = ref.watch(audioLibraryProvider.select((s) => s.currentTrack));
    if (track == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return const SizedBox.shrink();
    }
    final art = ref.watch(albumArtPaletteProvider(track.filePath)).valueOrNull;
    final target = _resolveColors(p, art);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.94;

    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 460, maxHeight: maxHeight),
          child: TweenAnimationBuilder<_BoxColors>(
            tween: _BoxColorsTween(end: target),
            duration: const Duration(milliseconds: 620),
            curve: Curves.easeOutCubic,
            builder: (context, colors, _) => _buildBox(context, p, track, colors),
          ),
        ),
      ),
    );
  }

  Widget _buildBox(BuildContext context, RonovaPalette p, AudioTrack track, _BoxColors c) {
    const radius = 34.0;
    final base = p.isAbyss ? const Color(0xFF0D1120) : Colors.white;
    final baseColor = base.withValues(alpha: kUseBackdropBlur ? (p.isAbyss ? 0.80 : 0.82) : 0.94);

    return Stack(
      children: <Widget>[
        RepaintBoundary(
          child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: <BoxShadow>[
            BoxShadow(color: c.a.withValues(alpha: 0.34), blurRadius: 42, spreadRadius: 1, offset: const Offset(-4, 6)),
            BoxShadow(color: c.b.withValues(alpha: 0.30), blurRadius: 42, spreadRadius: 1, offset: const Offset(4, 6)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: maybeBackdropBlur(
            sigma: 26,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[
                    Color.alphaBlend(c.a.withValues(alpha: 0.32), baseColor),
                    Color.alphaBlend(c.deep.withValues(alpha: 0.30), baseColor),
                    Color.alphaBlend(c.b.withValues(alpha: 0.26), baseColor),
                  ],
                ),
              ),
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: const Alignment(-0.7, -1.15),
                            radius: 1.25,
                            colors: <Color>[Colors.white.withValues(alpha: p.isAbyss ? 0.10 : 0.35), Colors.transparent],
                          ),
                        ),
                      ),
                    ),
                  ),
                  SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _handle(p),
                        _topControls(p, c),
                        _panels(p, c),
                        const SizedBox(height: 16),
                        _artSection(p, c, track),
                        const SizedBox(height: 18),
                        _titleBlock(p, track),
                        const SizedBox(height: 4),
                        _timeline(p, c),
                        const SizedBox(height: 6),
                        _transport(p, c),
                        const SizedBox(height: 10),
                        _queueChip(p, c),
                        _calibrationPanel(p),
                        const SizedBox(height: 14),
                        _bottomBar(p, c),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
        ),
        // Animated glow lives on its OWN layer: only this thin ring repaints each frame, not the
        // whole player (shadows, gradients, text, sliders).
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _EdgeGlowPainter(
                  a: c.a,
                  b: c.b,
                  radius: radius,
                  spin: _edge,
                  breathe: _breathe,
                  edgeWidth: 1.8,
                  haloWidth: 9,
                  haloBlur: 7,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---- Handle ----------------------------------------------------------------------------------------

  Widget _handle(RonovaPalette p) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).maybePop(),
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) > 500) Navigator.of(context).maybePop();
      },
      child: SizedBox(
        height: 30,
        child: Center(
          child: Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: p.textMuted.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  // ---- Shared small pieces -----------------------------------------------------------------------

  Widget _circleButton({
    required RonovaPalette p,
    required _BoxColors c,
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
    double size = 44,
    String? tooltip,
  }) {
    final button = PressableScale(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: active ? c.gradient : null,
          color: active ? null : p.surface,
          border: Border.all(color: active ? Colors.transparent : c.a.withValues(alpha: 0.35)),
          boxShadow: active
              ? <BoxShadow>[BoxShadow(color: c.a.withValues(alpha: 0.5), blurRadius: 16)]
              : null,
        ),
        child: Icon(icon, size: size * 0.5, color: active ? _onColor(c.a) : p.textPrimary),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }

  Widget _pill({
    required RonovaPalette p,
    required _BoxColors c,
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return PressableScale(
      scale: 0.94,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: active ? c.gradient : null,
          color: active ? null : p.surface,
          border: Border.all(color: active ? Colors.transparent : c.a.withValues(alpha: 0.35)),
          boxShadow: active ? <BoxShadow>[BoxShadow(color: c.a.withValues(alpha: 0.45), blurRadius: 16)] : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 18, color: active ? _onColor(c.a) : p.textPrimary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: active ? _onColor(c.a) : p.textPrimary,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  SliderThemeData _sliderTheme(RonovaPalette p, _BoxColors c, {double track = 5, double thumb = 8}) {
    return SliderThemeData(
      trackHeight: track,
      trackShape: GradientSliderTrackShape(c.gradient),
      activeTrackColor: c.a,
      inactiveTrackColor: p.textMuted.withValues(alpha: 0.28),
      thumbColor: p.isAbyss ? Colors.white : c.a,
      overlayColor: c.a.withValues(alpha: 0.18),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: thumb, elevation: 3),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
    );
  }

  BoxDecoration _panelDecoration(RonovaPalette p, _BoxColors c) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(22),
      color: p.isAbyss ? Colors.white.withValues(alpha: 0.05) : Colors.white.withValues(alpha: 0.5),
      border: Border.all(color: c.a.withValues(alpha: 0.3)),
    );
  }

  // ---- Top row: volume | speed + reverb (+ room space drawer) ---------------------------------------

  Widget _topControls(RonovaPalette p, _BoxColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Consumer(
              builder: (context, ref, _) {
                final volume = ref.watch(audioLibraryProvider.select((s) => s.masterVolume));
                final icon = volume <= 0.001
                    ? Icons.volume_off_rounded
                    : (volume < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded);
                return Builder(
                  builder: (buttonContext) => _circleButton(
                    p: p,
                    c: c,
                    icon: icon,
                    tooltip: 'Volume',
                    onTap: () {
                      final anchor = _rectOf(buttonContext);
                      if (anchor != null) _openVolume(anchor, c);
                    },
                  ),
                );
              },
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Consumer(
                    builder: (context, ref, _) {
                      final view = ref.watch(audioLibraryProvider.select((s) => (s.speed, s.reverbEnabled)));
                      final controller = ref.read(audioLibraryProvider.notifier);
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          _pill(
                            p: p,
                            c: c,
                            icon: Icons.speed_rounded,
                            label: '${view.$1.toStringAsFixed(2)}x',
                            active: _speedOpen || (view.$1 - 1.0).abs() > 0.001,
                            onTap: () => setState(() => _speedOpen = !_speedOpen),
                          ),
                          InfoBadge(topic: InfoTopic.speed, size: 14, tint: c.a),
                          const SizedBox(width: 2),
                          _pill(
                            p: p,
                            c: c,
                            icon: Icons.blur_on_rounded,
                            label: 'Reverb',
                            active: view.$2,
                            onTap: () => controller.setReverbEnabled(!view.$2),
                          ),
                          InfoBadge(topic: InfoTopic.pitchLinkedReverb, size: 14, tint: c.a),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              PressableScale(
                scale: 0.95,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _roomOpen = !_roomOpen);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        'Room Space',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _roomOpen ? c.a : p.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 2),
                      AnimatedRotation(
                        turns: _roomOpen ? 0.5 : 0.0,
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutBack,
                        child: Icon(Icons.keyboard_arrow_down_rounded, size: 22, color: _roomOpen ? c.a : p.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
              InfoBadge(topic: InfoTopic.roomSpace, size: 14, tint: c.a),
            ],
          ),
        ),
      ],
    );
  }

  Widget _panels(RonovaPalette p, _BoxColors c) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_speedOpen) _speedPanel(p, c),
          if (_roomOpen) _roomPanel(p, c),
        ],
      ),
    );
  }

  Widget _speedPanel(RonovaPalette p, _BoxColors c) {
    return Consumer(
      builder: (context, ref, _) {
        final speed = ref.watch(audioLibraryProvider.select((s) => s.speed));
        final controller = ref.read(audioLibraryProvider.notifier);
        void setSpeed(double value) {
          final next = AudioLibraryController.quantiseSpeed(value);
          if ((next - speed).abs() < 0.0001) return;
          HapticFeedback.selectionClick();
          controller.setSpeed(next);
        }

        return Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          decoration: _panelDecoration(p, c),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text('Speed', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: p.textPrimary)),
                  const Spacer(),
                  Text(
                    '${speed.toStringAsFixed(2)}x',
                    style: RonovaFonts.display(size: 18, color: c.a),
                  ),
                  const SizedBox(width: 10),
                  PressableScale(
                    scale: 0.92,
                    onTap: () => setSpeed(1.0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: c.a.withValues(alpha: 0.6)),
                        color: (speed - 1.0).abs() < 0.001 ? c.a.withValues(alpha: 0.2) : Colors.transparent,
                      ),
                      child: Text('1.0x', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: c.a)),
                    ),
                  ),
                ],
              ),
              _SpeedRuler(
                speed: speed,
                colorA: c.a,
                colorB: c.b,
                mutedColor: p.textMuted,
                textColor: p.textPrimary,
                onChanged: setSpeed,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _roomPanel(RonovaPalette p, _BoxColors c) {
    return Consumer(
      builder: (context, ref, _) {
        final view = ref.watch(audioLibraryProvider.select((s) => (s.roomSpace, s.reverbEnabled)));
        final controller = ref.read(audioLibraryProvider.notifier);
        return Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          decoration: _panelDecoration(p, c),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text('Room Space', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: p.textPrimary)),
                  const Spacer(),
                  Text('${(view.$1 * 100).round()}%', style: RonovaFonts.display(size: 18, color: c.a)),
                ],
              ),
              SliderTheme(
                data: _sliderTheme(p, c),
                child: Slider(value: view.$1, onChanged: controller.setRoomSpace),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text('Normal', style: TextStyle(fontSize: 11, color: p.textMuted)),
                    if (!view.$2)
                      Text('Turn Reverb on to hear this', style: TextStyle(fontSize: 11, color: c.a)),
                    Text('Vast empty room', style: TextStyle(fontSize: 11, color: p.textMuted)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---- Album art ---------------------------------------------------------------------------------------

  Widget _artSection(RonovaPalette p, _BoxColors c, AudioTrack track) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenHeight = MediaQuery.sizeOf(context).height;
        final wanted = screenHeight < 700 ? 176.0 : (screenHeight < 800 ? 204.0 : 232.0);
        final size = math.min(wanted, constraints.maxWidth - 8);
        return Center(
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Positioned.fill(
                  child: RepaintBoundary(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: <BoxShadow>[
                          BoxShadow(color: c.a.withValues(alpha: 0.5), blurRadius: 30, offset: const Offset(-5, 8)),
                          BoxShadow(color: c.b.withValues(alpha: 0.45), blurRadius: 30, offset: const Offset(5, 8)),
                        ],
                      ),
                      child: TrackArtwork(filePath: track.filePath, size: size, radius: 28),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _EdgeGlowPainter(
                          a: c.a,
                          b: c.b,
                          radius: 28,
                          spin: _edge,
                          breathe: _breathe,
                          edgeWidth: 1.7,
                          haloWidth: 6,
                          haloBlur: 5,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(top: -12, right: -12, child: _noteBadge(c)),
                Positioned(left: 10, bottom: 10, child: _dimPill()),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _noteBadge(_BoxColors c) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: RotationTransition(
        turns: _spin,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(colors: <Color>[c.a, c.b, c.a]),
            border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 1.4),
            boxShadow: <BoxShadow>[
              BoxShadow(color: c.a.withValues(alpha: 0.7), blurRadius: 18),
              BoxShadow(color: c.b.withValues(alpha: 0.5), blurRadius: 24),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Icon(Icons.music_note_rounded, size: 26, color: _onColor(c.a)),
              Positioned(
                top: 5,
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    boxShadow: <BoxShadow>[BoxShadow(color: Colors.white.withValues(alpha: 0.9), blurRadius: 6)],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  /// Normal -> Dimmed -> Hidden, saved with the theme settings.
  Widget _dimPill() {
    return Consumer(
      builder: (context, ref, _) {
        final level = ref.watch(themeSettingsProvider.select((t) => t.artDimLevel));
        final index = level >= 0.75 ? 2 : (level >= 0.25 ? 1 : 0);
        const labels = <String>['Normal', 'Dimmed', 'Hidden'];
        const icons = <IconData>[Icons.visibility_rounded, Icons.brightness_low_rounded, Icons.visibility_off_rounded];
        return PressableScale(
          scale: 0.92,
          onTap: () {
            HapticFeedback.selectionClick();
            const next = <double>[0.5, 1.0, 0.0];
            ref.read(themeSettingsProvider.notifier).setArtDimLevel(next[index]);
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: maybeBackdropBlur(
              sigma: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                color: Colors.black.withValues(alpha: kUseBackdropBlur ? 0.46 : 0.66),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(icons[index], size: 15, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(
                      'Art \u00B7 ${labels[index]}',
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ---- Title + timeline ---------------------------------------------------------------------------------

  Widget _titleBlock(RonovaPalette p, AudioTrack track) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AutoMarquee(
          text: track.title,
          height: 30,
          style: RonovaFonts.display(size: 22, color: p.textPrimary),
        ),
        const SizedBox(height: 2),
        Text(
          track.artist.isEmpty ? 'Unknown artist' : track.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14.5, color: p.textSecondary),
        ),
      ],
    );
  }

  Widget _timeline(RonovaPalette p, _BoxColors c) {
    return Consumer(
      builder: (context, ref, _) {
        final view = ref.watch(audioLibraryProvider.select((s) => (s.positionMs, s.durationMs)));
        final controller = ref.read(audioLibraryProvider.notifier);
        final duration = view.$2 <= 0 ? 1.0 : view.$2.toDouble();
        return ValueListenableBuilder<double?>(
          valueListenable: _seekDrag,
          builder: (context, drag, _) {
            final position = (drag ?? view.$1.toDouble()).clamp(0.0, duration).toDouble();
            final timeStyle = TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: p.textMuted,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            );
            return Column(
              children: <Widget>[
                SliderTheme(
                  data: _sliderTheme(p, c),
                  child: Slider(
                    value: position,
                    max: duration,
                    onChangeStart: (value) => _seekDrag.value = value,
                    onChanged: (value) => _seekDrag.value = value,
                    onChangeEnd: (value) {
                      controller.seekMs(value.round());
                      _seekDrag.value = null;
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Text(_clock(position.round()), style: timeStyle),
                      Text(_clock(view.$2), style: timeStyle),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ---- Transport ----------------------------------------------------------------------------------------

  Widget _transport(RonovaPalette p, _BoxColors c) {
    return Consumer(
      builder: (context, ref, _) {
        final view = ref.watch(audioLibraryProvider.select((s) => (s.isPlaying, s.isShuffle, s.repeatMode)));
        final controller = ref.read(audioLibraryProvider.notifier);

        void skip(int deltaMs) {
          final state = ref.read(audioLibraryProvider);
          unawaited(controller.seekMs(state.positionMs + deltaMs));
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final small = (w * 0.115).clamp(30.0, 46.0).toDouble();
            final play = (w * 0.20).clamp(50.0, 72.0).toDouble();

            Widget icon(IconData data, VoidCallback onTap, {bool active = false, InfoTopic? badge}) {
              return SizedBox(
                width: small,
                height: small,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Positioned.fill(
                      child: PressableScale(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onTap();
                        },
                        child: Center(
                          child: Icon(data, size: small * 0.64, color: active ? c.a : p.textPrimary),
                        ),
                      ),
                    ),
                    if (badge != null) Positioned(top: -8, right: -9, child: InfoBadge(topic: badge, size: 13, tint: c.a)),
                  ],
                ),
              );
            }

            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                icon(Icons.shuffle_rounded, controller.toggleShuffle, active: view.$2, badge: InfoTopic.shuffle),
                icon(Icons.skip_previous_rounded, () => unawaited(controller.previous())),
                icon(Icons.replay_10_rounded, () => skip(-10000)),
                PressableScale(
                  scale: 0.9,
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    unawaited(controller.togglePlayPause());
                  },
                  child: Container(
                    width: play,
                    height: play,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: c.gradient,
                      boxShadow: <BoxShadow>[
                        BoxShadow(color: c.a.withValues(alpha: 0.6), blurRadius: 24, offset: const Offset(-2, 2)),
                        BoxShadow(color: c.b.withValues(alpha: 0.5), blurRadius: 24, offset: const Offset(2, 2)),
                      ],
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, animation) => ScaleTransition(scale: animation, child: child),
                      child: Icon(
                        view.$1 ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        key: ValueKey<bool>(view.$1),
                        size: play * 0.56,
                        color: _onColor(Color.lerp(c.a, c.b, 0.5) ?? c.a),
                      ),
                    ),
                  ),
                ),
                icon(Icons.forward_10_rounded, () => skip(10000)),
                icon(Icons.skip_next_rounded, () => unawaited(controller.next())),
                icon(
                  view.$3 == RepeatMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                  controller.cycleRepeat,
                  active: view.$3 != RepeatMode.off,
                  badge: InfoTopic.repeat,
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _queueChip(RonovaPalette p, _BoxColors c) {
    return Consumer(
      builder: (context, ref, _) {
        final view = ref.watch(audioLibraryProvider.select((s) => (s.queue.length, s.queueIndex)));
        final upNext = view.$1 == 0 ? 0 : math.max(0, view.$1 - view.$2 - 1);
        final label = view.$1 == 0 ? 'Queue' : 'Queue \u00B7 ${view.$1} songs \u00B7 $upNext up next';
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            PressableScale(
              scale: 0.95,
              onTap: () {
                HapticFeedback.selectionClick();
                _openQueue();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: p.surface,
                  border: Border.all(color: c.a.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.queue_music_rounded, size: 18, color: c.a),
                    const SizedBox(width: 7),
                    Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: p.textSecondary)),
                  ],
                ),
              ),
            ),
            InfoBadge(topic: InfoTopic.queue, size: 14, tint: c.a),
          ],
        );
      },
    );
  }

  // ---- Ronova calibration sequence -----------------------------------------------------------------------

  Widget _calibrationPanel(RonovaPalette p) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: !_calibrating
          ? const SizedBox(width: double.infinity)
          : Container(
              margin: const EdgeInsets.only(top: 14),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: LinearGradient(
                  colors: <Color>[_ronovaCrimson.withValues(alpha: 0.18), _ronovaCelestial.withValues(alpha: 0.16)],
                ),
                border: Border.all(color: _ronovaCrimson.withValues(alpha: 0.5)),
                boxShadow: <BoxShadow>[
                  BoxShadow(color: _ronovaCrimson.withValues(alpha: 0.28), blurRadius: 22),
                  BoxShadow(color: _ronovaCelestial.withValues(alpha: 0.2), blurRadius: 26),
                ],
              ),
              child: AnimatedBuilder(
                animation: _calib,
                builder: (context, _) {
                  final t = _calib.value;
                  final stage = t < 0.34 ? 0 : (t < 0.67 ? 1 : 2);
                  const stages = <String>[
                    'Scanning Headset Acoustic Profile',
                    'Locking 32-Bit Float Stream',
                    'Calibrating 808 Sub-Harmonics & Stereo Stage',
                  ];
                  final scan = _scan;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              valueColor: const AlwaysStoppedAnimation<Color>(_ronovaCelestial),
                              backgroundColor: _ronovaCrimson.withValues(alpha: 0.3),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 240),
                              child: Align(
                                key: ValueKey<int>(stage),
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  '${stages[stage]}\u2026',
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.textPrimary),
                                ),
                              ),
                            ),
                          ),
                          Text(
                            '${(t * 100).round()}%',
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: _ronovaCelestial,
                              fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          height: 8,
                          child: Stack(
                            children: <Widget>[
                              Positioned.fill(child: ColoredBox(color: p.textMuted.withValues(alpha: 0.25))),
                              FractionallySizedBox(
                                widthFactor: t.clamp(0.0, 1.0).toDouble(),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(colors: <Color>[_ronovaCrimson, _ronovaCelestial]),
                                    boxShadow: <BoxShadow>[
                                      BoxShadow(color: _ronovaCelestial.withValues(alpha: 0.8), blurRadius: 10),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (scan != null) ...<Widget>[
                        const SizedBox(height: 10),
                        Text(
                          '${scan.deviceName} \u00B7 ${_transportLabel(scan)} \u00B7 up to ${_khz(scan.maxSampleRate)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: p.textSecondary),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
    );
  }

  String _transportLabel(HeadsetHardwareInfo info) {
    if (info.isBluetooth) return 'Bluetooth';
    if (info.isWired) return info.transport == 'usb' ? 'USB-C / DAC' : 'Wired';
    return 'Speaker';
  }

  String _khz(int hz) {
    final khz = hz / 1000.0;
    return '${khz.toStringAsFixed(khz == khz.roundToDouble() ? 0 : 1)} kHz';
  }

  Future<void> _toggleRonova() async {
    if (_calibrating) return;
    final controller = ref.read(audioLibraryProvider.notifier);
    if (controller.state.ronovaModeActive) {
      HapticFeedback.selectionClick();
      await controller.setRonovaMode(false);
      return;
    }

    HapticFeedback.mediumImpact();
    setState(() {
      _calibrating = true;
      _scan = null;
    });
    final clock = Stopwatch()..start();
    final finished = _calib.forward(from: 0.0);

    // Stage 1: really scan the output route (headset / DAC / Bluetooth).
    final info = await NativePlatformService.instance.analyzeHeadsetHardware();
    if (mounted) setState(() => _scan = info);

    // Stage 2: lock the stream and engage the engine once the second stage begins.
    final stageTwoAt = const Duration(milliseconds: 850);
    if (clock.elapsed < stageTwoAt) await Future<void>.delayed(stageTwoAt - clock.elapsed);
    await controller.setRonovaMode(true);

    // Stage 3 plays out the rest of the 2.5 s sequence.
    await finished;
    if (!mounted) return;
    setState(() => _calibrating = false);
    if (controller.state.ronovaModeActive) {
      HapticFeedback.heavyImpact();
    } else {
      showRonovaSnack(context, 'Ronova Mode could not engage on this output.');
    }
  }

  // ---- Bottom action bar --------------------------------------------------------------------------------

  Widget _bottomBar(RonovaPalette p, _BoxColors c) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Consumer(
            builder: (context, ref, _) {
              final gain = ref.watch(audioLibraryProvider.select((s) => s.upscalerGainDb));
              final on = gain > 0.05;
              return Builder(
                builder: (tileContext) => _actionTile(
                  p: p,
                  icon: Icons.graphic_eq_rounded,
                  title: 'Volume Upscaler',
                  subtitle: on ? '+${gain.toStringAsFixed(1)} dB \u00B7 limiter on' : 'Off',
                  active: on,
                  glowA: c.a,
                  glowB: c.b,
                  badge: InfoTopic.volumeUpscaler,
                  badgeTint: c.a,
                  onTap: () {
                    final anchor = _rectOf(tileContext);
                    if (anchor != null) _openUpscaler(anchor, c);
                  },
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Consumer(
            builder: (context, ref, _) {
              final view = ref.watch(audioLibraryProvider.select((s) => (s.ronovaModeActive, s.outputRoute.deviceName)));
              final subtitle = _calibrating ? 'Calibrating\u2026' : (view.$1 ? view.$2 : 'Tap to calibrate');
              return AnimatedBuilder(
                animation: _breathe,
                builder: (context, _) {
                  return _actionTile(
                    p: p,
                    icon: Icons.auto_awesome_rounded,
                    title: 'Ronova Mode',
                    subtitle: subtitle,
                    active: view.$1 || _calibrating,
                    glowA: _ronovaCrimson,
                    glowB: _ronovaCelestial,
                    pulse: 0.78 + 0.22 * _breathe.value,
                    badge: InfoTopic.ronovaMode,
                    badgeTint: view.$1 ? _ronovaCrimson : c.a,
                    onTap: () => unawaited(_toggleRonova()),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _actionTile({
    required RonovaPalette p,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool active,
    required Color glowA,
    required Color glowB,
    required InfoTopic badge,
    required Color badgeTint,
    required VoidCallback onTap,
    double pulse = 1.0,
  }) {
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        PressableScale(
          scale: 0.96,
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            height: 66,
            padding: const EdgeInsets.fromLTRB(10, 0, 12, 0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: active
                  ? LinearGradient(colors: <Color>[glowA.withValues(alpha: 0.30), glowB.withValues(alpha: 0.24)])
                  : null,
              color: active ? null : p.surface,
              border: Border.all(
                color: active ? glowA.withValues(alpha: 0.9) : p.border,
                width: active ? 1.5 : 1.0,
              ),
              boxShadow: active
                  ? <BoxShadow>[
                      BoxShadow(color: glowA.withValues(alpha: 0.46 * pulse), blurRadius: 24, offset: const Offset(-3, 2)),
                      BoxShadow(color: glowB.withValues(alpha: 0.40 * pulse), blurRadius: 24, offset: const Offset(3, 2)),
                    ]
                  : null,
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: active ? LinearGradient(colors: <Color>[glowA, glowB]) : null,
                    color: active ? null : p.surfaceStrong,
                  ),
                  child: Icon(icon, size: 20, color: active ? _onColor(glowA) : p.textPrimary),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: p.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: active ? glowA : p.textMuted, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(top: -8, right: -6, child: InfoBadge(topic: badge, size: 14, tint: badgeTint)),
      ],
    );
  }

  // ---- Popovers + queue ---------------------------------------------------------------------------------

  void _openVolume(Rect anchor, _BoxColors c) {
    showRonovaPopover(
      context,
      anchor: anchor,
      width: 292,
      tint: c.a,
      builder: (_) => _VolumePanel(colors: c),
    );
  }

  void _openUpscaler(Rect anchor, _BoxColors c) {
    showRonovaPopover(
      context,
      anchor: anchor,
      width: 340,
      tint: c.a,
      builder: (_) => _UpscalerPanel(colors: c),
    );
  }

  void _openQueue() {
    showGlassSheet(context, heightFactor: 0.74, builder: (_) => const _QueueSheet());
  }
}

// ---------------------------------------------------------------------------------------------
// Edge glow painter (box perimeter + album artwork)
// ---------------------------------------------------------------------------------------------

/// A clean, crisp gradient outline with a soft halo. The two colours slowly orbit the edge and the
/// halo breathes, so the glow reads as luminous without ever hiding the content.
class _EdgeGlowPainter extends CustomPainter {
  _EdgeGlowPainter({
    required this.a,
    required this.b,
    required this.radius,
    required this.spin,
    required this.breathe,
    required this.edgeWidth,
    required this.haloWidth,
    required this.haloBlur,
  }) : super(repaint: Listenable.merge(<Listenable>[spin, breathe]));

  final Color a;
  final Color b;
  final double radius;
  final Animation<double> spin;
  final Animation<double> breathe;
  final double edgeWidth;
  final double haloWidth;
  final double haloBlur;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius)).deflate(edgeWidth / 2);
    final shader = SweepGradient(
      colors: <Color>[a, b, a],
      transform: GradientRotation(spin.value * 2 * math.pi),
    ).createShader(rect);
    final pulse = 0.78 + 0.22 * breathe.value;

    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = haloWidth
        ..shader = shader
        ..color = Colors.white.withValues(alpha: 0.55 * pulse)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, haloBlur),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = edgeWidth
        ..shader = shader,
    );
  }

  @override
  bool shouldRepaint(_EdgeGlowPainter old) {
    return old.a != a ||
        old.b != b ||
        old.radius != radius ||
        old.edgeWidth != edgeWidth ||
        old.haloWidth != haloWidth ||
        old.haloBlur != haloBlur;
  }
}

// ---------------------------------------------------------------------------------------------
// Speed ruler: calibrated tick marks, 0.05 steps, 0.10 .. 1.50 (slower AND faster than normal)
// ---------------------------------------------------------------------------------------------

class _SpeedRuler extends StatelessWidget {
  const _SpeedRuler({
    required this.speed,
    required this.colorA,
    required this.colorB,
    required this.mutedColor,
    required this.textColor,
    required this.onChanged,
  });

  final double speed;
  final Color colorA;
  final Color colorB;
  final Color mutedColor;
  final Color textColor;
  final ValueChanged<double> onChanged;

  static const double _pad = 14.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackWidth = math.max(1.0, constraints.maxWidth - _pad * 2);
        double speedAt(double dx) {
          final t = ((dx - _pad) / trackWidth).clamp(0.0, 1.0).toDouble();
          return 0.10 + t * 1.40;
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => onChanged(speedAt(details.localPosition.dx)),
          onHorizontalDragUpdate: (details) => onChanged(speedAt(details.localPosition.dx)),
          child: SizedBox(
            height: 74,
            width: double.infinity,
            child: CustomPaint(
              painter: _RulerPainter(
                speed: speed,
                colorA: colorA,
                colorB: colorB,
                mutedColor: mutedColor,
                textColor: textColor,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RulerPainter extends CustomPainter {
  const _RulerPainter({
    required this.speed,
    required this.colorA,
    required this.colorB,
    required this.mutedColor,
    required this.textColor,
  });

  final double speed;
  final Color colorA;
  final Color colorB;
  final Color mutedColor;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = _SpeedRuler._pad;
    final trackWidth = size.width - pad * 2;
    if (trackWidth <= 0) return;
    double xFor(double s) => pad + (s - 0.10) / 1.40 * trackWidth;

    const tickTop = 24.0;
    final shader = LinearGradient(colors: <Color>[colorA, colorB]).createShader(Rect.fromLTWH(pad, 0, trackWidth, size.height));
    final tickPaint = Paint()..strokeCap = StrokeCap.round;

    final litLow = math.min(speed, 1.0) - 0.0001;
    final litHigh = math.max(speed, 1.0) + 0.0001;
    for (var i = 0; i <= 28; i++) {
      final s = 0.10 + 0.05 * i;
      final x = xFor(s);
      final major = i.isEven;
      final isNormal = (s - 1.0).abs() < 0.001;
      final height = isNormal ? 26.0 : (major ? 20.0 : 11.0);
      // The stretch between the current speed and normal (1.0x) speed lights up.
      final lit = s >= litLow && s <= litHigh;
      tickPaint
        ..strokeWidth = major ? 2.3 : 1.6
        ..shader = lit ? shader : null
        ..color = lit ? Colors.white : mutedColor.withValues(alpha: 0.5);
      canvas.drawLine(Offset(x, tickTop), Offset(x, tickTop + height), tickPaint);

      if (((s * 100).round() % 20 == 0) || isNormal) {
        final current = (s - speed).abs() < 0.026;
        final painter = TextPainter(
          text: TextSpan(
            text: s.toStringAsFixed(1),
            style: TextStyle(
              fontSize: 10,
              fontWeight: current ? FontWeight.w800 : FontWeight.w600,
              color: current ? textColor : mutedColor,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        painter.paint(canvas, Offset(x - painter.width / 2, tickTop + 26));
        painter.dispose();
      }
    }

    // Thumb: glowing needle that sits on the current step.
    final tx = xFor(speed.clamp(0.10, 1.5).toDouble());
    final needle = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(tx, tickTop + 10), width: 5, height: 40),
      const Radius.circular(3),
    );
    canvas.drawRRect(
      needle.inflate(2),
      Paint()
        ..color = colorA.withValues(alpha: 0.7)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawRRect(needle, Paint()..color = Colors.white);
    canvas.drawCircle(Offset(tx, tickTop - 8), 4.5, Paint()..color = colorA);
    canvas.drawCircle(
      Offset(tx, tickTop - 8),
      4.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_RulerPainter old) {
    return old.speed != speed ||
        old.colorA != colorA ||
        old.colorB != colorB ||
        old.mutedColor != mutedColor ||
        old.textColor != textColor;
  }
}

// ---------------------------------------------------------------------------------------------
// Popover panels
// ---------------------------------------------------------------------------------------------

SliderThemeData _panelSliderTheme(RonovaPalette p, _BoxColors c) {
  return SliderThemeData(
    trackHeight: 5,
    trackShape: GradientSliderTrackShape(c.gradient),
    activeTrackColor: c.a,
    inactiveTrackColor: p.textMuted.withValues(alpha: 0.3),
    thumbColor: p.isAbyss ? Colors.white : c.a,
    overlayColor: c.a.withValues(alpha: 0.18),
    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9, elevation: 3),
    overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
  );
}

class _VolumePanel extends ConsumerWidget {
  const _VolumePanel({required this.colors});

  final _BoxColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    final volume = ref.watch(audioLibraryProvider.select((s) => s.masterVolume));
    final controller = ref.read(audioLibraryProvider.notifier);
    final icon = volume <= 0.001
        ? Icons.volume_off_rounded
        : (volume < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Master volume', style: RonovaFonts.display(size: 16, color: p.textPrimary)),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            Icon(icon, size: 22, color: colors.a),
            Expanded(
              child: SliderTheme(
                data: _panelSliderTheme(p, colors),
                child: Slider(value: volume, onChanged: controller.setMasterVolume),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                '${(volume * 100).round()}%',
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: colors.a),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _UpscalerPanel extends ConsumerWidget {
  const _UpscalerPanel({required this.colors});

  final _BoxColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    final view = ref.watch(audioLibraryProvider.select((s) => (s.upscalerGainDb, s.limiterReductionDb)));
    final controller = ref.read(audioLibraryProvider.notifier);
    final gain = view.$1;
    final on = gain > 0.05;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.graphic_eq_rounded, size: 22, color: colors.a),
            const SizedBox(width: 8),
            Text('Volume Upscaler', style: RonovaFonts.display(size: 17, color: p.textPrimary)),
            InfoBadge(topic: InfoTopic.volumeUpscaler, size: 14, tint: colors.a),
            const Spacer(),
            Text(
              on ? '+${gain.toStringAsFixed(1)} dB' : 'Off',
              style: RonovaFonts.display(size: 20, color: colors.a),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SliderTheme(
          data: _panelSliderTheme(p, colors),
          child: Slider(
            value: gain.clamp(0.0, AudioLibraryController.maxUpscalerDb).toDouble(),
            max: AudioLibraryController.maxUpscalerDb,
            divisions: 48,
            onChanged: controller.setUpscalerGainDb,
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final db in const <double>[0, 3, 6, 12, 18, 24])
              _GainChip(
                label: db == 0 ? 'Off' : '+${db.round()}',
                selected: db == 0 ? !on : (gain - db).abs() < 0.26,
                colors: colors,
                palette: p,
                onTap: () => controller.setUpscalerGainDb(db),
              ),
          ],
        ),
        const SizedBox(height: 16),
        _LimiterMeter(reductionDb: view.$2, active: on, colors: colors, palette: p),
      ],
    );
  }
}

class _GainChip extends StatelessWidget {
  const _GainChip({
    required this.label,
    required this.selected,
    required this.colors,
    required this.palette,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final _BoxColors colors;
  final RonovaPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      scale: 0.92,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: selected ? colors.gradient : null,
          color: selected ? null : palette.surface,
          border: Border.all(color: selected ? Colors.transparent : colors.a.withValues(alpha: 0.35)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            color: selected ? _onColor(colors.a) : palette.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// Live brickwall-limiter gain-reduction meter: shows how many dB of peaks are being caught so the
/// loudness boost never turns into clipping.
class _LimiterMeter extends StatelessWidget {
  const _LimiterMeter({
    required this.reductionDb,
    required this.active,
    required this.colors,
    required this.palette,
  });

  final double reductionDb;
  final bool active;
  final _BoxColors colors;
  final RonovaPalette palette;

  static const double _scaleDb = 12.0;

  @override
  Widget build(BuildContext context) {
    final fraction = active ? (reductionDb / _scaleDb).clamp(0.0, 1.0).toDouble() : 0.0;
    final labelStyle = TextStyle(fontSize: 10.5, color: palette.textMuted, fontWeight: FontWeight.w600);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('Peak limiter \u00B7 gain reduction',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: palette.textPrimary)),
            const Spacer(),
            Text(
              active ? '\u2212${reductionDb.toStringAsFixed(1)} dB' : 'idle',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: colors.a),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: SizedBox(
            height: 12,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  children: <Widget>[
                    Positioned.fill(child: ColoredBox(color: palette.textMuted.withValues(alpha: 0.25))),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      width: constraints.maxWidth * fraction,
                      decoration: BoxDecoration(
                        gradient: colors.gradient,
                        boxShadow: <BoxShadow>[BoxShadow(color: colors.a.withValues(alpha: 0.7), blurRadius: 8)],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text('0', style: labelStyle),
            Text('3', style: labelStyle),
            Text('6', style: labelStyle),
            Text('9', style: labelStyle),
            Text('12 dB', style: labelStyle),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _okGreen,
                boxShadow: <BoxShadow>[BoxShadow(color: _okGreen.withValues(alpha: 0.8), blurRadius: 6)],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Output ceiling \u22120.1 dBFS \u00B7 zero clipping distortion',
                style: TextStyle(fontSize: 11.5, color: palette.textSecondary),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Queue sheet
// ---------------------------------------------------------------------------------------------

class _QueueSheet extends ConsumerStatefulWidget {
  const _QueueSheet();

  @override
  ConsumerState<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends ConsumerState<_QueueSheet> {
  static const double _rowExtent = 66.0;
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    final index = ref.read(audioLibraryProvider).queueIndex;
    _scroll = ScrollController(initialScrollOffset: math.max(0.0, (index - 2) * _rowExtent));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(ronovaPaletteProvider);
    final view = ref.watch(audioLibraryProvider.select((s) => (s.queue, s.queueIndex, s.isPlaying)));
    final controller = ref.read(audioLibraryProvider.notifier);
    final queue = view.$1;

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Row(
            children: <Widget>[
              Expanded(child: Text('Queue', style: RonovaFonts.display(size: 24, color: p.textPrimary))),
              Text('${queue.length} songs', style: TextStyle(fontSize: 12.5, color: p.textMuted)),
            ],
          ),
        ),
        Expanded(
          child: queue.isEmpty
              ? Center(
                  child: Text('Nothing queued yet.', style: TextStyle(fontSize: 14, color: p.textMuted)),
                )
              : ListView.builder(
                  controller: _scroll,
                  physics: const BouncingScrollPhysics(),
                  itemExtent: _rowExtent,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: queue.length,
                  itemBuilder: (context, index) {
                    final track = queue[index];
                    final current = index == view.$2;
                    return PressableScale(
                      scale: 0.98,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        unawaited(controller.playTrack(track));
                      },
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: current ? p.primary.withValues(alpha: 0.14) : Colors.transparent,
                          border: current ? Border.all(color: p.primary.withValues(alpha: 0.55)) : null,
                        ),
                        child: Row(
                          children: <Widget>[
                            TrackArtwork(filePath: track.filePath, size: 42, radius: 12),
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
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w700,
                                      color: current ? p.accentText : p.textPrimary,
                                    ),
                                  ),
                                  Text(
                                    track.artist.isEmpty ? 'Unknown artist' : track.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 12, color: p.textMuted),
                                  ),
                                ],
                              ),
                            ),
                            if (current)
                              EqualizerBars(active: view.$3, gradient: p.accentGradient, size: 18)
                            else
                              Text('${index + 1}', style: TextStyle(fontSize: 12, color: p.textMuted)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

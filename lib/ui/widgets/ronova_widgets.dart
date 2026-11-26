import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:marquee/marquee.dart';

import '../../core/providers/theme_settings_provider.dart';
import '../../core/services/native_platform_service.dart';
import '../../core/theme/ronova_palette.dart';
import 'video_background.dart';

/// Typography helpers. Display text uses Outfit through google_fonts; if the font cannot be
/// fetched (first launch while offline) Flutter's default font is used instead.
abstract final class RonovaFonts {
  static TextStyle display({
    double size = 22,
    FontWeight weight = FontWeight.w700,
    Color? color,
    double letterSpacing = 0,
    double? height,
  }) {
    try {
      return GoogleFonts.outfit(
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing,
        height: height,
      );
    } catch (_) {
      return TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing,
        height: height,
      );
    }
  }
}

/// Real-time backdrop blur re-blurs everything behind it on EVERY frame (scrolling lists, the
/// animated player box ...), which is by far the most expensive thing on mid-range GPUs.
/// Surfaces are drawn with a near-opaque "frosted" fill instead. Flip this to `true` to get the
/// true glass blur back (at the cost of FPS).
const bool kUseBackdropBlur = false;

Widget maybeBackdropBlur({required double sigma, required Widget child}) {
  if (!kUseBackdropBlur) return child;
  return BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma), child: child);
}

String formatDurationMs(int ms) {
  final totalSeconds = math.max(0, ms) ~/ 1000;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  if (hours > 0) return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
  return '$minutes:$seconds';
}

void showRonovaSnack(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 2400),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
}

// ---------------------------------------------------------------------------------------------
// Borders, gradients, icons
// ---------------------------------------------------------------------------------------------

/// Paints a gradient outline (used for the glowing split-gradient borders).
class GradientBorderPainter extends CustomPainter {
  const GradientBorderPainter({required this.gradient, required this.radius, this.width = 1.2});

  final Gradient gradient;
  final double radius;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect.deflate(width / 2), Radius.circular(radius));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..shader = gradient.createShader(rect);
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(GradientBorderPainter oldDelegate) {
    return oldDelegate.gradient != gradient || oldDelegate.radius != radius || oldDelegate.width != width;
  }
}

class GradientIcon extends StatelessWidget {
  const GradientIcon(this.icon, {super.key, required this.gradient, this.size = 24});

  final IconData icon;
  final Gradient gradient;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => gradient.createShader(Rect.fromLTWH(0, 0, bounds.width, bounds.height)),
      child: Icon(icon, size: size, color: Colors.white),
    );
  }
}

class GradientText extends StatelessWidget {
  const GradientText(this.text, {super.key, required this.gradient, required this.style});

  final String text;
  final Gradient gradient;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => gradient.createShader(Rect.fromLTWH(0, 0, bounds.width, bounds.height)),
      child: Text(text, style: style.copyWith(color: Colors.white)),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Press feedback + buttons
// ---------------------------------------------------------------------------------------------

/// Gives any child a springy press-down scale (the premium "tactile" feel).
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.92,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  void _set(bool value) {
    if (_down != value && mounted) setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

/// Round frosted icon button with a gradient rim and an optional accent glow.
class GlowIconButton extends ConsumerWidget {
  const GlowIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.size = 44,
    this.iconSize = 22,
    this.glow = false,
    this.filled = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final bool glow;

  /// Fills the circle with the accent gradient (primary actions such as play / pause).
  final bool filled;
  final String? tooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    final button = PressableScale(
      onTap: onPressed == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onPressed!.call();
            },
      child: CustomPaint(
        foregroundPainter: GradientBorderPainter(
          gradient: p.gradient(alpha: filled ? 0.0 : 0.65),
          radius: size / 2,
          width: 1.2,
        ),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? null : p.surface,
            gradient: filled ? p.accentGradient : null,
            boxShadow: glow || filled ? p.glowShadows(strength: filled ? 0.9 : 0.6, blur: 16) : null,
          ),
          child: Center(
            child: filled
                ? Icon(icon, size: iconSize, color: p.onAccent)
                : GradientIcon(icon, gradient: p.accentGradient, size: iconSize),
          ),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

// ---------------------------------------------------------------------------------------------
// Cards, sliders, switches
// ---------------------------------------------------------------------------------------------

class FrostedCard extends ConsumerWidget {
  const FrostedCard({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.margin = EdgeInsets.zero,
    this.radius = 22,
    this.blur = false,
    this.glow = false,
    this.strong = false,
    this.borderAlpha = 0.35,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double radius;

  /// Real backdrop blur (use sparingly: mini-player, header, popups).
  final bool blur;
  final bool glow;
  final bool strong;
  final double borderAlpha;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    final borderRadius = BorderRadius.circular(radius);
    // With real blur off, blur-flagged cards get a near-opaque fill so list rows scrolling behind
    // them (e.g. the docked mini-player) stay unreadable-through, like frosted glass.
    final glassFill = Color.alphaBlend(strong ? p.surfaceStrong : p.surface, p.bg).withValues(alpha: 0.95);
    Widget box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: (blur && !kUseBackdropBlur) ? glassFill : (strong ? p.surfaceStrong : p.surface),
        borderRadius: borderRadius,
      ),
      child: child,
    );
    if (blur && kUseBackdropBlur) {
      box = ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: box,
        ),
      );
    }
    box = CustomPaint(
      foregroundPainter: GradientBorderPainter(
        gradient: p.gradient(alpha: borderAlpha),
        radius: radius,
        width: 1.1,
      ),
      child: box,
    );
    if (glow) {
      box = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: p.glowShadows(strength: 0.55, blur: 22),
        ),
        child: box,
      );
    }
    return Padding(padding: margin, child: box);
  }
}

/// Slider track painted with the accent gradient (split gradient when both wheels are on).
class GradientSliderTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const GradientSliderTrackShape(this.gradient);

  final Gradient gradient;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final radius = Radius.circular(trackRect.height / 2);
    final inactivePaint = Paint()..color = sliderTheme.inactiveTrackColor ?? const Color(0x33FFFFFF);
    context.canvas.drawRRect(RRect.fromRectAndRadius(trackRect, radius), inactivePaint);

    final activeRight = math.max(trackRect.left, math.min(thumbCenter.dx, trackRect.right));
    final activeRect = Rect.fromLTRB(trackRect.left, trackRect.top, activeRight, trackRect.bottom);
    if (activeRect.width <= 0) return;
    final activePaint = Paint()..shader = gradient.createShader(trackRect);
    context.canvas.drawRRect(RRect.fromRectAndRadius(activeRect, radius), activePaint);
  }
}

SliderThemeData ronovaSliderTheme(RonovaPalette p, {double trackHeight = 4, double thumbRadius = 7}) {
  return SliderThemeData(
    trackHeight: trackHeight,
    trackShape: GradientSliderTrackShape(p.accentGradient),
    activeTrackColor: p.primary,
    inactiveTrackColor: p.textMuted.withValues(alpha: 0.28),
    thumbColor: p.isAbyss ? Colors.white : p.primary,
    overlayColor: p.primary.withValues(alpha: 0.16),
    thumbShape: RoundSliderThumbShape(enabledThumbRadius: thumbRadius, elevation: 2),
    overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
    valueIndicatorColor: p.primary,
  );
}

class RonovaSwitch extends ConsumerWidget {
  const RonovaSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    return Switch(
      value: value,
      onChanged: onChanged == null
          ? null
          : (next) {
              HapticFeedback.selectionClick();
              onChanged!(next);
            },
      thumbColor: WidgetStateProperty.resolveWith<Color?>(
        (states) => states.contains(WidgetState.selected) ? p.accentText : p.textSecondary,
      ),
      trackColor: WidgetStateProperty.resolveWith<Color?>(
        (states) => states.contains(WidgetState.selected)
            ? p.primary.withValues(alpha: 0.42)
            : p.textMuted.withValues(alpha: 0.22),
      ),
      trackOutlineColor: WidgetStateProperty.all<Color?>(Colors.transparent),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Text, artwork, visualiser
// ---------------------------------------------------------------------------------------------

/// Shows static text when it fits and a smooth marquee when it overflows.
class AutoMarquee extends StatelessWidget {
  const AutoMarquee({super.key, required this.text, required this.style, this.height = 22});

  final String text;
  final TextStyle style;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            maxLines: 1,
            textDirection: Directionality.of(context),
          )..layout();
          final overflows = painter.width > constraints.maxWidth;
          painter.dispose();
          if (!overflows) {
            return Align(
              alignment: Alignment.centerLeft,
              child: Text(text, style: style, maxLines: 1, overflow: TextOverflow.clip),
            );
          }
          return Marquee(
            text: text,
            style: style,
            scrollAxis: Axis.horizontal,
            blankSpace: 42,
            velocity: 28,
            pauseAfterRound: const Duration(milliseconds: 1400),
            startAfter: const Duration(milliseconds: 900),
            fadingEdgeStartFraction: 0.08,
            fadingEdgeEndFraction: 0.12,
            showFadingOnlyWhenScrolling: true,
          );
        },
      ),
    );
  }
}

/// Lazy, cached cover-art thumbnail honouring the album-art visibility setting.
class TrackArtwork extends ConsumerStatefulWidget {
  const TrackArtwork({
    super.key,
    required this.filePath,
    this.size = 52,
    this.radius = 14,
    this.glow = false,
  });

  final String filePath;
  final double size;
  final double radius;
  final bool glow;

  @override
  ConsumerState<TrackArtwork> createState() => _TrackArtworkState();
}

class _TrackArtworkState extends ConsumerState<TrackArtwork> {
  late Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future = NativePlatformService.instance.getAlbumArt(widget.filePath);
  }

  @override
  void didUpdateWidget(TrackArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _future = NativePlatformService.instance.getAlbumArt(widget.filePath);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(ronovaPaletteProvider);
    final artDim = ref.watch(themeSettingsProvider.select((c) => c.artDimLevel));
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final pixelSize = (widget.size * dpr).round();
    final radius = BorderRadius.circular(widget.radius);

    Widget placeholder() {
      return DecoratedBox(
        decoration: BoxDecoration(gradient: p.gradient(alpha: 0.28)),
        child: Center(
          child: Icon(Icons.music_note_rounded, size: widget.size * 0.46, color: p.accentText),
        ),
      );
    }

    Widget content;
    if (artDim >= 1.0) {
      content = placeholder();
    } else {
      content = FutureBuilder<Uint8List?>(
        future: _future,
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null || bytes.isEmpty) return placeholder();
          return Opacity(
            opacity: (1.0 - artDim).clamp(0.0, 1.0).toDouble(),
            child: Image.memory(
              bytes,
              fit: BoxFit.cover,
              cacheWidth: pixelSize,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (context, error, stack) => placeholder(),
            ),
          );
        },
      );
    }

    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: widget.glow ? p.glowShadows(strength: 0.8, blur: 16) : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          child: KeyedSubtree(key: ValueKey<String>('${widget.filePath}|$artDim'), child: content),
        ),
      ),
    );
  }
}

/// Four dancing bars shown beside the track that is currently playing.
class EqualizerBars extends StatefulWidget {
  const EqualizerBars({super.key, required this.active, required this.gradient, this.size = 18});

  final bool active;
  final Gradient gradient;
  final double size;

  @override
  State<EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<EqualizerBars> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(EqualizerBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(widget.size, widget.size),
        painter: _BarsPainter(_controller, widget.gradient, widget.active),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.animation, this.gradient, this.active) : super(repaint: animation);

  final Animation<double> animation;
  final Gradient gradient;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()..shader = gradient.createShader(rect);
    const bars = 4;
    final gap = size.width * 0.12;
    final barWidth = (size.width - gap * (bars - 1)) / bars;
    for (var i = 0; i < bars; i++) {
      final phase = animation.value * 2 * math.pi + i * 1.35;
      final level = active ? 0.30 + 0.70 * (0.5 + 0.5 * math.sin(phase * (1 + i * 0.23))) : 0.28;
      final h = size.height * level;
      final left = i * (barWidth + gap);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, size.height - h, barWidth, h),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter oldDelegate) => oldDelegate.active != active || oldDelegate.gradient != gradient;
}

// ---------------------------------------------------------------------------------------------
// Background: custom wallpaper (BoxFit.cover) or the living aurora
// ---------------------------------------------------------------------------------------------

/// Scaffold backdrop. A user wallpaper is drawn with `BoxFit.cover` (centered, filled, never
/// stretched) behind the translucent frosted cards; with no wallpaper a slow aurora in the
/// accent colours drifts over the Aether / Abyss base.
class RonovaBackground extends ConsumerStatefulWidget {
  const RonovaBackground({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<RonovaBackground> createState() => _RonovaBackgroundState();
}

class _RonovaBackgroundState extends ConsumerState<RonovaBackground> {
  // The aurora used to drift forever, repainting the whole screen 60x/s. It is now painted once
  // (static) which removes a constant full-screen raster cost.
  static const Animation<double> _drift = AlwaysStoppedAnimation<double>(0.12);

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(themeSettingsProvider);
    final p = ref.watch(ronovaPaletteProvider);
    final wallpaper = config.backgroundImagePath;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ColoredBox(color: p.bg),
        if (wallpaper != null) ...<Widget>[
          Positioned.fill(
            child: isVideoPath(wallpaper)
                ? VideoBackground(path: wallpaper)
                : Image.file(
                    File(wallpaper),
                    fit: BoxFit.cover,
                    alignment: Alignment.center,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stack) => const SizedBox.shrink(),
                  ),
          ),
          Positioned.fill(
            child: ColoredBox(
              color: (p.isAbyss ? Colors.black : Colors.white).withValues(alpha: config.backgroundDimOpacity),
            ),
          ),
        ] else
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _AuroraPainter(
                  animation: _drift,
                  color1: p.accent1,
                  color2: p.accent2,
                  strength: p.isAbyss ? 0.20 : 0.16,
                ),
              ),
            ),
          ),
        widget.child,
      ],
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter({
    required this.animation,
    required this.color1,
    required this.color2,
    required this.strength,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color color1;
  final Color color2;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value * 2 * math.pi;
    final w = size.width;
    final h = size.height;

    void blob(Offset center, double radius, Color color) {
      final rect = Rect.fromCircle(center: center, radius: radius);
      final paint = Paint()
        ..shader = RadialGradient(
          colors: <Color>[color.withValues(alpha: strength), color.withValues(alpha: 0.0)],
        ).createShader(rect);
      canvas.drawCircle(center, radius, paint);
    }

    blob(Offset(w * (0.18 + 0.14 * math.sin(t)), h * (0.12 + 0.07 * math.cos(t))), w * 0.95, color1);
    blob(Offset(w * (0.88 + 0.10 * math.cos(t + 1.0)), h * (0.52 + 0.10 * math.sin(t + 2.0))), w * 0.90, color2);
    blob(
      Offset(w * (0.40 + 0.18 * math.sin(t + 3.0)), h * (0.98 - 0.06 * math.cos(t))),
      w * 0.85,
      Color.lerp(color1, color2, 0.5) ?? color1,
    );
  }

  @override
  bool shouldRepaint(_AuroraPainter oldDelegate) {
    return oldDelegate.color1 != color1 || oldDelegate.color2 != color2 || oldDelegate.strength != strength;
  }
}

/// Shared page transition: a soft fade with a gentle upward drift.
PageRouteBuilder<T> ronovaRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 420),
    reverseTransitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.05), end: Offset.zero).animate(curved),
          child: child,
        ),
      );
    },
  );
}

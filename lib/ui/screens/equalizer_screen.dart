import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/eq_preset.dart';
import '../../core/providers/equalizer_provider.dart';
import '../../core/providers/theme_settings_provider.dart';
import '../../core/theme/ronova_palette.dart';
import '../widgets/glass_sheet.dart';
import '../widgets/info_badge_tooltip.dart';
import '../widgets/ronova_widgets.dart';
import '../widgets/rotary_eq_wheel.dart';

Future<void> showEqualizerScreen(BuildContext context) {
  return Navigator.of(context).push<void>(ronovaRoute<void>((_) => const EqualizerScreen()));
}

/// "20", "125", "1.25k", "16k" - compact band labels.
String eqFrequencyLabel(double hz) {
  if (hz < 1000) return hz.toStringAsFixed(0);
  final k = hz / 1000.0;
  final text = k.toStringAsFixed(2);
  final trimmed = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return '${trimmed}k';
}

String _formatDb(double value) {
  if (value.abs() < 0.05) return '0.0 dB';
  final sign = value > 0 ? '+' : '\u2212';
  return '$sign${value.abs().toStringAsFixed(1)} dB';
}

String _formatPercent(double ratio) => '${(ratio * 100).round()}%';

String _shortName(String name) {
  final cut = name.indexOf(' (');
  return cut > 0 ? name.substring(0, cut) : name;
}

/// 16-band rotary equalizer, 808 sub-bass / stereo width / pre-amp master dials and the
/// 40-preset library with favourites. Everything is live on the C++ engine and persisted.
class EqualizerScreen extends ConsumerStatefulWidget {
  const EqualizerScreen({super.key});

  @override
  ConsumerState<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends ConsumerState<EqualizerScreen> {
  final ScrollController _bankScroll = ScrollController();

  @override
  void dispose() {
    _bankScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = ref.watch(ronovaPaletteProvider);
    final engineAvailable = ref.watch(equalizerProvider.select((s) => s.engineAvailable));
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: RonovaBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: <Widget>[
              const _Header(),
              Expanded(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 28 + bottomInset),
                  children: <Widget>[
                    if (!engineAvailable)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: FrostedCard(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: <Widget>[
                              Icon(Icons.info_outline_rounded, size: 20, color: palette.accentText),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'The audio engine is not available on this device, so changes are saved but not heard yet.',
                                  style: TextStyle(fontSize: 12.5, color: palette.textSecondary),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const _FavoritesBar(),
                    const SizedBox(height: 14),
                    const _PresetHeroCard(),
                    const SizedBox(height: 14),
                    const _CurveCard(),
                    const SizedBox(height: 14),
                    const _MasterDialsCard(),
                    const SizedBox(height: 14),
                    _BankCard(scrollController: _bankScroll),
                    const SizedBox(height: 18),
                    Center(
                      child: Text(
                        'Drag or twist a dial \u00B7 double-tap to reset',
                        style: TextStyle(fontSize: 11.5, color: palette.textMuted),
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
// Header
// ---------------------------------------------------------------------------------------------

class _Header extends ConsumerWidget {
  const _Header();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    final label = ref.watch(equalizerProvider.select((s) => s.activeLabel));
    final modified = ref.watch(equalizerProvider.select((s) => s.modified));
    final controller = ref.read(equalizerProvider.notifier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: <Widget>[
          GlowIconButton(
            icon: Icons.arrow_back_rounded,
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Equalizer', style: RonovaFonts.display(size: 26, color: p.textPrimary)),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: p.textSecondary),
                ),
              ],
            ),
          ),
          GlowIconButton(
            icon: Icons.restart_alt_rounded,
            tooltip: modified ? 'Undo edits' : 'Reset',
            glow: modified,
            onPressed: controller.resetActive,
          ),
          const SizedBox(width: 10),
          GlowIconButton(
            icon: Icons.bookmark_add_rounded,
            tooltip: 'Save to Custom User Slot',
            onPressed: () {
              controller.saveToCustomSlot();
              showRonovaSnack(context, 'Saved to the Custom User Slot');
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Mini Favorites menu
// ---------------------------------------------------------------------------------------------

class _FavoritesBar extends ConsumerWidget {
  const _FavoritesBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    final view = ref.watch(equalizerProvider.select((s) => (s.favoriteIds, s.presets, s.activePresetId)));
    final controller = ref.read(equalizerProvider.notifier);
    final favorites = <EqPreset>[
      for (final preset in view.$2)
        if (view.$1.contains(preset.id)) preset,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(
            children: <Widget>[
              GradientIcon(Icons.star_rounded, gradient: p.accentGradient, size: 16),
              const SizedBox(width: 6),
              Text(
                'FAVORITES',
                style: TextStyle(fontSize: 11, letterSpacing: 1.5, fontWeight: FontWeight.w800, color: p.textMuted),
              ),
              const SizedBox(width: 8),
              Text('${favorites.length}', style: TextStyle(fontSize: 11, color: p.textMuted)),
            ],
          ),
        ),
        if (favorites.isEmpty)
          FrostedCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Text(
              'Tap the star on any preset to pin it here for one-tap switching.',
              style: TextStyle(fontSize: 12.5, color: p.textSecondary),
            ),
          )
        else
          SizedBox(
            height: 46,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              clipBehavior: Clip.none,
              itemCount: favorites.length,
              separatorBuilder: (context, index) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final preset = favorites[index];
                return _FavoritePill(
                  name: _shortName(preset.name),
                  active: preset.id == view.$3,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    controller.selectPreset(preset.id);
                  },
                  onLongPress: () {
                    HapticFeedback.mediumImpact();
                    controller.toggleFavorite(preset.id);
                  },
                );
              },
            ),
          ),
      ],
    );
  }
}

class _FavoritePill extends ConsumerWidget {
  const _FavoritePill({required this.name, required this.active, required this.onTap, required this.onLongPress});

  final String name;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    return PressableScale(
      scale: 0.94,
      onTap: onTap,
      onLongPress: onLongPress,
      child: CustomPaint(
        foregroundPainter: GradientBorderPainter(
          gradient: p.gradient(alpha: active ? 0.0 : 0.55),
          radius: 23,
          width: 1.1,
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(23),
            gradient: active ? p.accentGradient : null,
            color: active ? null : p.surface,
            boxShadow: active ? p.glowShadows(strength: 0.9, blur: 18) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.star_rounded, size: 16, color: active ? p.onAccent : p.accentText),
              const SizedBox(width: 7),
              Text(
                name,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: active ? p.onAccent : p.textPrimary,
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
// Active preset hero card
// ---------------------------------------------------------------------------------------------

class _PresetHeroCard extends ConsumerWidget {
  const _PresetHeroCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    final view = ref.watch(equalizerProvider.select((s) => (s.activePreset, s.modified, s.favoriteIds)));
    final preset = view.$1;
    final modified = view.$2;
    final isFavorite = view.$3.contains(preset.id);
    final meta = EqLibrary.metaFor(preset.id);
    final controller = ref.read(equalizerProvider.notifier);

    return FrostedCard(
      glow: true,
      radius: 26,
      padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'NOW SHAPING',
                      style: TextStyle(fontSize: 11, letterSpacing: 1.6, fontWeight: FontWeight.w800, color: p.textMuted),
                    ),
                    const SizedBox(height: 6),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 260),
                      child: Align(
                        key: ValueKey<String>(preset.id),
                        alignment: Alignment.centerLeft,
                        child: GradientText(
                          preset.name,
                          gradient: p.accentGradient,
                          style: RonovaFonts.display(size: 22, height: 1.15),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      meta.blurb,
                      style: TextStyle(fontSize: 13, height: 1.35, color: p.textSecondary),
                    ),
                  ],
                ),
              ),
              _StarButton(
                active: isFavorite,
                size: 44,
                onTap: () => controller.toggleFavorite(preset.id),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              _Tag(text: meta.category.label, palette: p),
              if (modified) ...<Widget>[
                const SizedBox(width: 8),
                _Tag(text: 'Edited', palette: p, filled: true),
              ],
            ],
          ),
          const SizedBox(height: 14),
          _GradientActionButton(
            icon: Icons.library_music_rounded,
            label: 'Browse all ${EqLibrary.presetCount} presets',
            onTap: () => showPresetDrawer(context),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.palette, this.filled = false});

  final String text;
  final RonovaPalette palette;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: filled ? palette.primary.withValues(alpha: 0.2) : palette.surface,
        border: Border.all(color: filled ? palette.primary.withValues(alpha: 0.6) : palette.border),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: filled ? palette.accentText : palette.textSecondary,
        ),
      ),
    );
  }
}

class _GradientActionButton extends ConsumerWidget {
  const _GradientActionButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    return PressableScale(
      scale: 0.97,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: p.accentGradient,
          boxShadow: p.glowShadows(strength: 0.8, blur: 18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 19, color: p.onAccent),
            const SizedBox(width: 9),
            Text(label, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: p.onAccent)),
          ],
        ),
      ),
    );
  }
}

/// Star toggle with a little spring when it fills in.
class _StarButton extends ConsumerWidget {
  const _StarButton({required this.active, required this.onTap, this.size = 40});

  final bool active;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    return Semantics(
      button: true,
      toggled: active,
      label: active ? 'Remove from favorites' : 'Add to favorites',
      child: PressableScale(
        scale: 0.82,
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 320),
              switchInCurve: Curves.elasticOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) => ScaleTransition(scale: animation, child: child),
              child: active
                  ? GradientIcon(Icons.star_rounded, key: const ValueKey<bool>(true), gradient: p.accentGradient, size: size * 0.7)
                  : Icon(Icons.star_border_rounded, key: const ValueKey<bool>(false), size: size * 0.7, color: p.textMuted),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Live frequency-response curve
// ---------------------------------------------------------------------------------------------

class _CurveCard extends ConsumerWidget {
  const _CurveCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    final preamp = ref.watch(equalizerProvider.select((s) => s.preampDb));

    return FrostedCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              GradientIcon(Icons.show_chart_rounded, gradient: p.accentGradient, size: 20),
              const SizedBox(width: 8),
              Text('Live response', style: RonovaFonts.display(size: 17, color: p.textPrimary)),
              const Spacer(),
              _Tag(text: 'Pre-amp ${_formatDb(preamp)}', palette: p),
            ],
          ),
          const SizedBox(height: 10),
          const SizedBox(height: 168, child: _EqCurveView()),
          const SizedBox(height: 6),
          Text(
            'EQ bands plus pre-amp, computed with the same filter maths as the audio engine.',
            style: TextStyle(fontSize: 11, color: p.textMuted),
          ),
        ],
      ),
    );
  }
}

class _EqCurveView extends ConsumerStatefulWidget {
  const _EqCurveView();

  @override
  ConsumerState<_EqCurveView> createState() => _EqCurveViewState();
}

class _EqCurveViewState extends ConsumerState<_EqCurveView> with SingleTickerProviderStateMixin {
  static const int _points = 112;

  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 170),
  );
  late List<double> _from;
  late List<double> _to;

  List<double> _compute(List<double> gains, double preamp) {
    return EqResponse.curveDb(gainsDb: gains, preampDb: preamp, points: _points);
  }

  List<double> _shown() {
    final t = Curves.easeOutCubic.transform(_morph.value);
    return <double>[
      for (var i = 0; i < _points; i++) _from[i] + (_to[i] - _from[i]) * t,
    ];
  }

  @override
  void initState() {
    super.initState();
    final s = ref.read(equalizerProvider);
    _from = _compute(s.bandGainsDb, s.preampDb);
    _to = _from;
    ref.listenManual<(List<double>, double)>(
      equalizerProvider.select((s) => (s.bandGainsDb, s.preampDb)),
      (previous, next) {
        _from = _shown();
        _to = _compute(next.$1, next.$2);
        _morph.forward(from: 0.0);
      },
    );
  }

  @override
  void dispose() {
    _morph.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(ronovaPaletteProvider);
    final gains = ref.watch(equalizerProvider.select((s) => s.bandGainsDb));
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _CurvePainter(
          repaint: _morph,
          curveOf: _shown,
          bandGains: gains,
          accent1: p.accent1,
          accent2: p.accent2,
          gridColor: p.textMuted.withValues(alpha: 0.22),
          zeroColor: p.textMuted.withValues(alpha: 0.5),
          labelColor: p.textMuted,
        ),
      ),
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter({
    required Listenable repaint,
    required this.curveOf,
    required this.bandGains,
    required this.accent1,
    required this.accent2,
    required this.gridColor,
    required this.zeroColor,
    required this.labelColor,
  }) : super(repaint: repaint);

  static const double _rangeDb = 15.0;

  final List<double> Function() curveOf;
  final List<double> bandGains;
  final Color accent1;
  final Color accent2;
  final Color gridColor;
  final Color zeroColor;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 26.0;
    const right = 6.0;
    const top = 8.0;
    const bottom = 18.0;
    final plot = Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    if (plot.width <= 0 || plot.height <= 0) return;

    double yFor(double db) {
      final clamped = db.clamp(-_rangeDb, _rangeDb).toDouble();
      return plot.center.dy - clamped / _rangeDb * (plot.height / 2);
    }

    double xForHz(double hz) {
      final t = math.log(hz / EqResponse.minHz) / math.log(EqResponse.maxHz / EqResponse.minHz);
      return plot.left + t.clamp(0.0, 1.0).toDouble() * plot.width;
    }

    // ---- Grid -----------------------------------------------------------------------------------
    final gridPaint = Paint()
      ..strokeWidth = 1
      ..color = gridColor;
    for (final db in const <double>[-12, -6, 6, 12]) {
      canvas.drawLine(Offset(plot.left, yFor(db)), Offset(plot.right, yFor(db)), gridPaint);
    }
    canvas.drawLine(
      Offset(plot.left, yFor(0)),
      Offset(plot.right, yFor(0)),
      Paint()
        ..strokeWidth = 1.2
        ..color = zeroColor,
    );
    for (final hz in const <double>[50, 100, 500, 1000, 5000, 10000]) {
      canvas.drawLine(Offset(xForHz(hz), plot.top), Offset(xForHz(hz), plot.bottom), gridPaint);
    }

    void label(String text, Offset anchor, {bool centered = false}) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: TextStyle(fontSize: 9.5, color: labelColor, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx = centered ? anchor.dx - painter.width / 2 : anchor.dx - painter.width;
      painter.paint(canvas, Offset(dx, anchor.dy - painter.height / 2));
      painter.dispose();
    }

    for (final db in const <double>[-12, 0, 12]) {
      label(db == 0 ? '0' : (db > 0 ? '+${db.round()}' : '\u2212${db.abs().round()}'), Offset(left - 5, yFor(db)));
    }
    label('100', Offset(xForHz(100), plot.bottom + 10), centered: true);
    label('1k', Offset(xForHz(1000), plot.bottom + 10), centered: true);
    label('10k', Offset(xForHz(10000), plot.bottom + 10), centered: true);

    // ---- Curve -----------------------------------------------------------------------------------
    final curve = curveOf();
    if (curve.length < 2) return;
    final points = <Offset>[
      for (var i = 0; i < curve.length; i++)
        Offset(plot.left + i / (curve.length - 1) * plot.width, yFor(curve[i])),
    ];

    final line = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length - 1; i++) {
      final mid = Offset((points[i].dx + points[i + 1].dx) / 2, (points[i].dy + points[i + 1].dy) / 2);
      line.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
    }
    line.lineTo(points.last.dx, points.last.dy);

    final fill = Path.from(line)
      ..lineTo(points.last.dx, yFor(0))
      ..lineTo(points.first.dx, yFor(0))
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          colors: <Color>[accent1.withValues(alpha: 0.30), accent2.withValues(alpha: 0.30)],
        ).createShader(plot),
    );

    final shader = LinearGradient(colors: <Color>[accent1, accent2]).createShader(plot);
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeJoin = StrokeJoin.round
        ..shader = shader
        ..color = Colors.white.withValues(alpha: 0.4)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = shader,
    );

    // ---- Band markers (where each of the 16 dials sits on the curve) --------------------------
    for (var band = 0; band < EqPreset.bandCount; band++) {
      final hz = EqPreset.bandFrequenciesHz[band];
      final x = xForHz(hz);
      final t = (x - plot.left) / plot.width;
      final index = (t * (curve.length - 1)).round().clamp(0, curve.length - 1).toInt();
      final center = Offset(x, yFor(curve[index]));
      final touched = band < bandGains.length && bandGains[band].abs() >= 0.05;
      final color = Color.lerp(accent1, accent2, band / (EqPreset.bandCount - 1)) ?? accent1;
      canvas.drawCircle(center, touched ? 3.6 : 2.4, Paint()..color = color.withValues(alpha: touched ? 1.0 : 0.55));
      if (touched) {
        canvas.drawCircle(center, 6.2, Paint()..color = color.withValues(alpha: 0.22));
      }
    }
  }

  @override
  bool shouldRepaint(_CurvePainter old) {
    return old.bandGains != bandGains ||
        old.accent1 != accent1 ||
        old.accent2 != accent2 ||
        old.gridColor != gridColor ||
        old.labelColor != labelColor;
  }
}

// ---------------------------------------------------------------------------------------------
// Master dials: 808 sub-bass, stereo width, pre-amp trim
// ---------------------------------------------------------------------------------------------

class _MasterDialsCard extends ConsumerWidget {
  const _MasterDialsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    final controller = ref.read(equalizerProvider.notifier);

    return FrostedCard(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 12),
            child: Row(
              children: <Widget>[
                GradientIcon(Icons.tune_rounded, gradient: p.accentGradient, size: 20),
                const SizedBox(width: 8),
                Text('Master dials', style: RonovaFonts.display(size: 17, color: p.textPrimary)),
              ],
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Center(
                  child: Consumer(
                    builder: (context, ref, _) {
                      final value = ref.watch(equalizerProvider.select((s) => s.subBass));
                      return RotaryEqWheel(
                        value: value,
                        minValue: 0.0,
                        maxValue: 1.0,
                        defaultValue: 0.0,
                        step: 0.01,
                        size: 92,
                        bipolar: false,
                        readoutInside: true,
                        label: '808 Sub-Bass',
                        info: InfoTopic.subBass808,
                        formatValue: _formatPercent,
                        onChanged: controller.setSubBass,
                      );
                    },
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: Consumer(
                    builder: (context, ref, _) {
                      final value = ref.watch(equalizerProvider.select((s) => s.stereoWidth));
                      return RotaryEqWheel(
                        value: value,
                        minValue: 0.0,
                        maxValue: 2.0,
                        defaultValue: 1.0,
                        step: 0.01,
                        size: 92,
                        bipolar: true,
                        readoutInside: true,
                        label: 'Stereo Width',
                        info: InfoTopic.stereoWidth,
                        formatValue: _formatPercent,
                        onChanged: controller.setStereoWidth,
                      );
                    },
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: Consumer(
                    builder: (context, ref, _) {
                      final value = ref.watch(equalizerProvider.select((s) => s.preampDb));
                      return RotaryEqWheel(
                        value: value,
                        minValue: EqPreset.minPreampDb,
                        maxValue: EqPreset.maxPreampDb,
                        defaultValue: 0.0,
                        step: 0.5,
                        size: 92,
                        bipolar: true,
                        readoutInside: true,
                        label: 'Pre-Amp Trim',
                        info: InfoTopic.preAmp,
                        formatValue: (v) => v.abs() < 0.05 ? '0 dB' : '${v > 0 ? '+' : '\u2212'}${v.abs().toStringAsFixed(1)}',
                        onChanged: controller.setPreampDb,
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// 16-band rotary bank (two rows, scrolls sideways)
// ---------------------------------------------------------------------------------------------

class _BankCard extends ConsumerWidget {
  const _BankCard({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);

    return FrostedCard(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Row(
              children: <Widget>[
                GradientIcon(Icons.equalizer_rounded, gradient: p.accentGradient, size: 20),
                const SizedBox(width: 8),
                Text('16-band bank', style: RonovaFonts.display(size: 17, color: p.textPrimary)),
                const Spacer(),
                Text('swipe the gaps \u2192', style: TextStyle(fontSize: 11, color: p.textMuted)),
              ],
            ),
          ),
          Scrollbar(
            controller: scrollController,
            child: SingleChildScrollView(
              controller: scrollController,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _BankRow(title: 'LOWS & LOW-MIDS \u00B7 20 Hz \u2013 500 Hz', from: 0, to: 8),
                  SizedBox(height: 12),
                  _BankRow(title: 'MIDS & HIGHS \u00B7 800 Hz \u2013 16 kHz', from: 8, to: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BankRow extends ConsumerWidget {
  const _BankRow({required this.title, required this.from, required this.to});

  final String title;
  final int from;
  final int to;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    final controller = ref.read(equalizerProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 6),
          child: Text(
            title,
            style: TextStyle(fontSize: 10.5, letterSpacing: 1.1, fontWeight: FontWeight.w800, color: p.textMuted),
          ),
        ),
        Row(
          children: <Widget>[
            for (var band = from; band < to; band++)
              SizedBox(
                width: 80,
                child: Center(
                  child: Consumer(
                    builder: (context, ref, _) {
                      final gain = ref.watch(equalizerProvider.select((s) => s.bandGainsDb[band]));
                      return RotaryEqWheel(
                        value: gain,
                        minValue: EqPreset.minGainDb,
                        maxValue: EqPreset.maxGainDb,
                        defaultValue: 0.0,
                        step: 0.5,
                        size: 62,
                        label: eqFrequencyLabel(EqPreset.bandFrequenciesHz[band]),
                        formatValue: _formatDb,
                        onChanged: (value) => controller.setBandGain(band, value),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------
// 40-preset drawer
// ---------------------------------------------------------------------------------------------

/// Opens the searchable, scrollable list of all 40 presets with a star toggle on each.
Future<void> showPresetDrawer(BuildContext context) {
  return showGlassSheet(context, builder: (_) => const _PresetDrawer(), heightFactor: 0.88);
}

class _PresetDrawer extends ConsumerStatefulWidget {
  const _PresetDrawer();

  @override
  ConsumerState<_PresetDrawer> createState() => _PresetDrawerState();
}

class _PresetDrawerState extends ConsumerState<_PresetDrawer> {
  final TextEditingController _search = TextEditingController();
  EqCategory? _category;
  bool _favoritesOnly = false;
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(EqPreset preset, Set<String> favorites) {
    if (_favoritesOnly && !favorites.contains(preset.id)) return false;
    final meta = EqLibrary.metaFor(preset.id);
    if (_category != null && meta.category != _category) return false;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return preset.name.toLowerCase().contains(q) ||
        meta.blurb.toLowerCase().contains(q) ||
        meta.category.label.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(ronovaPaletteProvider);
    final view = ref.watch(equalizerProvider.select((s) => (s.presets, s.favoriteIds, s.activePresetId)));
    final controller = ref.read(equalizerProvider.notifier);
    final favorites = view.$2;
    final filtered = <EqPreset>[
      for (final preset in view.$1)
        if (_matches(preset, favorites)) preset,
    ];

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Row(
            children: <Widget>[
              Expanded(child: Text('Presets', style: RonovaFonts.display(size: 24, color: p.textPrimary))),
              Text('${filtered.length} of ${view.$1.length}', style: TextStyle(fontSize: 12.5, color: p.textMuted)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(23),
              border: Border.all(color: p.border),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.search_rounded, size: 20, color: p.textMuted),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _search,
                    onChanged: (value) => setState(() => _query = value),
                    textInputAction: TextInputAction.search,
                    cursorColor: p.primary,
                    style: TextStyle(fontSize: 14.5, color: p.textPrimary),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: 'Search presets, genres, headsets\u2026',
                      hintStyle: TextStyle(fontSize: 14.5, color: p.textMuted),
                    ),
                  ),
                ),
                if (_query.isNotEmpty)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _search.clear();
                      setState(() => _query = '');
                    },
                    child: Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Icon(Icons.close_rounded, size: 19, color: p.textMuted),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: <Widget>[
              _FilterChipPill(
                label: 'All',
                selected: !_favoritesOnly && _category == null,
                onTap: () => setState(() {
                  _favoritesOnly = false;
                  _category = null;
                }),
              ),
              _FilterChipPill(
                label: 'Favorites',
                icon: Icons.star_rounded,
                selected: _favoritesOnly,
                onTap: () => setState(() {
                  _favoritesOnly = !_favoritesOnly;
                  if (_favoritesOnly) _category = null;
                }),
              ),
              for (final category in EqCategory.values)
                _FilterChipPill(
                  label: category.label,
                  selected: !_favoritesOnly && _category == category,
                  onTap: () => setState(() {
                    _favoritesOnly = false;
                    _category = _category == category ? null : category;
                  }),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      _favoritesOnly ? 'No favorites yet. Star a preset to pin it.' : 'No presets match your search.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: p.textMuted),
                    ),
                  ),
                )
              : ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final preset = filtered[index];
                    return _PresetTile(
                      preset: preset,
                      active: preset.id == view.$3,
                      favorite: favorites.contains(preset.id),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        controller.selectPreset(preset.id);
                      },
                      onToggleFavorite: () => controller.toggleFavorite(preset.id),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _FilterChipPill extends ConsumerWidget {
  const _FilterChipPill({required this.label, required this.selected, required this.onTap, this.icon});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: PressableScale(
        scale: 0.94,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(19),
            gradient: selected ? p.accentGradient : null,
            color: selected ? null : p.surface,
            border: selected ? null : Border.all(color: p.border),
            boxShadow: selected ? p.glowShadows(strength: 0.6, blur: 12) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 15, color: selected ? p.onAccent : p.accentText),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: selected ? p.onAccent : p.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresetTile extends ConsumerWidget {
  const _PresetTile({
    required this.preset,
    required this.active,
    required this.favorite,
    required this.onTap,
    required this.onToggleFavorite,
  });

  final EqPreset preset;
  final bool active;
  final bool favorite;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    final meta = EqLibrary.metaFor(preset.id);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: PressableScale(
        scale: 0.985,
        onTap: onTap,
        child: CustomPaint(
          foregroundPainter: GradientBorderPainter(
            gradient: p.gradient(alpha: active ? 0.95 : 0.22),
            radius: 20,
            width: active ? 1.6 : 1.0,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: active ? p.primary.withValues(alpha: 0.13) : p.surface,
              boxShadow: active ? p.glowShadows(strength: 0.5, blur: 16) : null,
            ),
            child: Row(
              children: <Widget>[
                _PresetThumb(preset: preset, accent1: p.accent1, accent2: p.accent2, background: p.surfaceStrong),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              preset.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: p.textPrimary),
                            ),
                          ),
                          if (active) ...<Widget>[
                            const SizedBox(width: 6),
                            Icon(Icons.check_circle_rounded, size: 16, color: p.accentText),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        meta.blurb,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: p.textMuted),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: <Widget>[
                          _Tag(text: meta.category.label, palette: p),
                          if (preset.subBass > 0.04) ...<Widget>[
                            const SizedBox(width: 6),
                            Text(
                              '808 ${_formatPercent(preset.subBass)}',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: p.textSecondary),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                _StarButton(active: favorite, onTap: onToggleFavorite),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Miniature of a preset's EQ curve so presets can be told apart at a glance.
class _PresetThumb extends StatelessWidget {
  const _PresetThumb({required this.preset, required this.accent1, required this.accent2, required this.background});

  final EqPreset preset;
  final Color accent1;
  final Color accent2;
  final Color background;

  static final Map<String, List<double>> _cache = <String, List<double>>{};

  List<double> _curve() {
    final key = '${preset.id}:${Object.hashAll(preset.bandGainsDb)}';
    return _cache.putIfAbsent(
      key,
      () => EqResponse.curveDb(gainsDb: preset.bandGainsDb, preampDb: 0.0, points: 40),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 62,
      height: 40,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: CustomPaint(
        painter: _ThumbPainter(curve: _curve(), accent1: accent1, accent2: accent2),
      ),
    );
  }
}

class _ThumbPainter extends CustomPainter {
  const _ThumbPainter({required this.curve, required this.accent1, required this.accent2});

  final List<double> curve;
  final Color accent1;
  final Color accent2;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(6, 6, size.width - 12, size.height - 12);
    double yFor(double db) => rect.center.dy - db.clamp(-12.0, 12.0).toDouble() / 12.0 * (rect.height / 2);

    canvas.drawLine(
      Offset(rect.left, rect.center.dy),
      Offset(rect.right, rect.center.dy),
      Paint()
        ..strokeWidth = 0.8
        ..color = accent1.withValues(alpha: 0.25),
    );
    final path = Path();
    for (var i = 0; i < curve.length; i++) {
      final point = Offset(rect.left + i / (curve.length - 1) * rect.width, yFor(curve[i]));
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = LinearGradient(colors: <Color>[accent1, accent2]).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_ThumbPainter old) {
    return !identical(old.curve, curve) || old.accent1 != accent1 || old.accent2 != accent2;
  }
}

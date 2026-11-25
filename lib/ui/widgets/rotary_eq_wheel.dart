import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/theme_settings_provider.dart';
import 'info_badge_tooltip.dart';

typedef WheelValueFormatter = String Function(double value);

/// Hardware-inspired tactile rotary knob.
///
/// * Twist the rim for a circular drag, or press the middle and drag up / down.
/// * Double-tap resets to [defaultValue].
/// * A glowing radial arc, tick marks and a knurled body show the position; the readout shows the
///   live value ([formatValue]).
///
/// The knob claims the touch the moment a finger lands on it, so turning a dial never scrolls the
/// page or the horizontal EQ bank underneath it.
class RotaryEqWheel extends ConsumerStatefulWidget {
  const RotaryEqWheel({
    super.key,
    required this.value,
    required this.onChanged,
    required this.minValue,
    required this.maxValue,
    required this.label,
    required this.formatValue,
    this.defaultValue = 0.0,
    this.step = 0.5,
    this.size = 68,
    this.bipolar = true,
    this.readoutInside = false,
    this.info,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final double minValue;
  final double maxValue;
  final String label;
  final WheelValueFormatter formatValue;

  /// Value restored by a double-tap (and the anchor of the arc for [bipolar] wheels).
  final double defaultValue;

  /// Detent size; the wheel only reports multiples of this.
  final double step;
  final double size;

  /// True: the arc grows from [defaultValue] in both directions (EQ gain). False: it grows from
  /// [minValue] (percentages).
  final bool bipolar;

  /// Draws the readout inside the knob centre (for the large master wheels).
  final bool readoutInside;

  /// Adds a `!` badge next to the label.
  final InfoTopic? info;

  @override
  ConsumerState<RotaryEqWheel> createState() => _RotaryEqWheelState();
}

class _RotaryEqWheelState extends ConsumerState<RotaryEqWheel> with SingleTickerProviderStateMixin {
  static const double _sweep = 3 * math.pi / 2;
  static const double _verticalExtent = 190.0;

  late final AnimationController _glide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  double _from = 0.0;
  double _to = 0.0;

  int? _pointer;
  Offset _downPos = Offset.zero;
  Offset _lastPos = Offset.zero;
  Duration _downTime = Duration.zero;
  bool _moved = false;
  bool _circular = true;
  bool _dragging = false;
  double _raw = 0.0;
  int _lastIndex = 0;
  Duration? _lastTapTime;
  Offset _lastTapPos = Offset.zero;

  @override
  void initState() {
    super.initState();
    _from = widget.value;
    _to = widget.value;
  }

  @override
  void didUpdateWidget(RotaryEqWheel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value == widget.value) return;
    if (_dragging) {
      _from = widget.value;
      _to = widget.value;
      _glide.value = 1.0;
    } else {
      // Preset changes glide the knob to its new position.
      _from = _shown;
      _to = widget.value;
      _glide.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _glide.dispose();
    super.dispose();
  }

  double get _shown {
    final t = Curves.easeOutCubic.transform(_glide.value);
    return _from + (_to - _from) * t;
  }

  int _indexFor(double value) => ((value - widget.minValue) / widget.step).round();

  double _valueForIndex(int index) {
    final value = widget.minValue + index * widget.step;
    return value.clamp(widget.minValue, widget.maxValue).toDouble();
  }

  // ---- Pointer handling --------------------------------------------------------------------

  void _down(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _downPos = event.localPosition;
    _lastPos = event.localPosition;
    _downTime = event.timeStamp;
    _moved = false;
    final center = Offset(widget.size / 2, widget.size / 2);
    // Touches near the rim twist the knob; touches near the middle drag it up / down.
    _circular = (event.localPosition - center).distance >= widget.size * 0.25;
    _raw = widget.value;
    _lastIndex = _indexFor(widget.value);
    setState(() => _dragging = true);
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if ((event.localPosition - _downPos).distance > 6) _moved = true;
    final range = widget.maxValue - widget.minValue;
    final center = Offset(widget.size / 2, widget.size / 2);
    final previous = _lastPos - center;
    final current = event.localPosition - center;
    final minRadius = widget.size * 0.12;

    double delta;
    if (_circular && previous.distance > minRadius && current.distance > minRadius) {
      var angle = current.direction - previous.direction;
      if (angle > math.pi) angle -= 2 * math.pi;
      if (angle < -math.pi) angle += 2 * math.pi;
      delta = angle / _sweep * range;
    } else {
      delta = -(event.localPosition.dy - _lastPos.dy) / _verticalExtent * range;
    }
    _lastPos = event.localPosition;

    _raw = (_raw + delta).clamp(widget.minValue, widget.maxValue).toDouble();
    final index = _indexFor(_raw);
    if (index != _lastIndex) {
      _lastIndex = index;
      HapticFeedback.selectionClick();
      widget.onChanged(_valueForIndex(index));
    }
  }

  void _up(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final wasTap = !_moved && (event.timeStamp - _downTime) < const Duration(milliseconds: 300);
    if (wasTap) {
      final last = _lastTapTime;
      if (last != null &&
          (event.timeStamp - last) < const Duration(milliseconds: 320) &&
          (event.localPosition - _lastTapPos).distance < 40) {
        _lastTapTime = null;
        HapticFeedback.mediumImpact();
        widget.onChanged(widget.defaultValue);
      } else {
        _lastTapTime = event.timeStamp;
        _lastTapPos = event.localPosition;
      }
    }
    _pointer = null;
    if (mounted) setState(() => _dragging = false);
  }

  void _cancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    if (mounted) setState(() => _dragging = false);
  }

  void _nudge(int steps) {
    final index = (_indexFor(widget.value) + steps).clamp(0, _indexFor(widget.maxValue)).toInt();
    widget.onChanged(_valueForIndex(index));
  }

  // ---- Build -----------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(ronovaPaletteProvider);
    final readout = widget.formatValue(widget.value);
    final range = widget.maxValue - widget.minValue;
    final zeroT = widget.bipolar ? ((widget.defaultValue - widget.minValue) / range).clamp(0.0, 1.0).toDouble() : 0.0;

    final knob = RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
          () => EagerGestureRecognizer(),
          (EagerGestureRecognizer instance) {},
        ),
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _cancel,
        child: Semantics(
          slider: true,
          label: widget.label,
          value: readout,
          increasedValue: widget.formatValue(_valueForIndex(_indexFor(widget.value) + 1)),
          decreasedValue: widget.formatValue(_valueForIndex(_indexFor(widget.value) - 1)),
          onIncrease: () => _nudge(1),
          onDecrease: () => _nudge(-1),
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _glide,
              builder: (context, _) {
                return CustomPaint(
                  size: Size.square(widget.size),
                  painter: _KnobPainter(
                    value: _shown,
                    min: widget.minValue,
                    max: widget.maxValue,
                    zeroT: zeroT,
                    accent1: p.accent1,
                    accent2: p.accent2,
                    isAbyss: p.isAbyss,
                    trackColor: p.textMuted.withValues(alpha: 0.26),
                    active: _dragging,
                    readout: widget.readoutInside ? readout : null,
                    readoutColor: p.textPrimary,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AnimatedScale(
          scale: _dragging ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          child: SizedBox(width: widget.size, height: widget.size, child: knob),
        ),
        const SizedBox(height: 4),
        if (!widget.readoutInside)
          Text(
            readout,
            maxLines: 1,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              color: p.accentText,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: widget.readoutInside ? 12 : 10.5,
                  fontWeight: widget.readoutInside ? FontWeight.w700 : FontWeight.w600,
                  color: widget.readoutInside ? p.textSecondary : p.textMuted,
                ),
              ),
            ),
            if (widget.info != null) InfoBadge(topic: widget.info!, size: 13),
          ],
        ),
      ],
    );
  }
}

class _KnobPainter extends CustomPainter {
  const _KnobPainter({
    required this.value,
    required this.min,
    required this.max,
    required this.zeroT,
    required this.accent1,
    required this.accent2,
    required this.isAbyss,
    required this.trackColor,
    required this.active,
    required this.readout,
    required this.readoutColor,
  });

  static const double _start = 3 * math.pi / 4;
  static const double _sweep = 3 * math.pi / 2;

  final double value;
  final double min;
  final double max;
  final double zeroT;
  final Color accent1;
  final Color accent2;
  final bool isAbyss;
  final Color trackColor;
  final bool active;
  final String? readout;
  final Color readoutColor;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final t = ((value - min) / (max - min)).clamp(0.0, 1.0).toDouble();
    final angle = _start + _sweep * t;
    final zeroAngle = _start + _sweep * zeroT;
    final pointerColor = Color.lerp(accent1, accent2, t) ?? accent1;

    // ---- Outer arc: track + glowing active segment --------------------------------------------
    final arcStroke = r * 0.13;
    final arcRect = Rect.fromCircle(center: c, radius: r - arcStroke / 2 - 0.5);
    canvas.drawArc(
      arcRect,
      _start,
      _sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = arcStroke
        ..strokeCap = StrokeCap.round
        ..color = trackColor,
    );

    final activeSweep = angle - zeroAngle;
    if (activeSweep.abs() > 0.012) {
      final shader = SweepGradient(
        startAngle: 0.0,
        endAngle: _sweep,
        colors: <Color>[accent1, accent2],
        transform: const GradientRotation(_start),
      ).createShader(arcRect);
      final from = activeSweep >= 0 ? zeroAngle : angle;
      final sweepLength = activeSweep.abs();
      canvas.drawArc(
        arcRect,
        from,
        sweepLength,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = arcStroke * 1.9
          ..strokeCap = StrokeCap.round
          ..shader = shader
          ..color = Colors.white.withValues(alpha: active ? 0.62 : 0.34)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.14),
      );
      canvas.drawArc(
        arcRect,
        from,
        sweepLength,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = arcStroke
          ..strokeCap = StrokeCap.round
          ..shader = shader,
      );
    }

    // ---- Tick marks -----------------------------------------------------------------------------
    const tickCount = 21;
    final tickPaint = Paint()..strokeCap = StrokeCap.round;
    final lo = math.min(zeroAngle, angle);
    final hi = math.max(zeroAngle, angle);
    for (var i = 0; i < tickCount; i++) {
      final tickT = i / (tickCount - 1);
      final tickAngle = _start + _sweep * tickT;
      final major = i % 5 == 0;
      final inActive = activeSweep.abs() > 0.012 && tickAngle >= lo - 0.001 && tickAngle <= hi + 0.001;
      tickPaint
        ..strokeWidth = major ? r * 0.045 : r * 0.03
        ..color = inActive
            ? (Color.lerp(accent1, accent2, tickT) ?? accent1).withValues(alpha: 0.95)
            : trackColor.withValues(alpha: major ? 0.75 : 0.45);
      final inner = r * (major ? 0.74 : 0.77);
      final outer = r * 0.83;
      canvas.drawLine(
        c + Offset.fromDirection(tickAngle, inner),
        c + Offset.fromDirection(tickAngle, outer),
        tickPaint,
      );
    }

    // ---- Knob body ----------------------------------------------------------------------------------
    final bodyR = r * 0.66;
    final bodyRect = Rect.fromCircle(center: c, radius: bodyR);
    canvas.drawCircle(
      c + Offset(0, r * 0.07),
      bodyR,
      Paint()
        ..color = Colors.black.withValues(alpha: isAbyss ? 0.6 : 0.24)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.11),
    );
    canvas.drawCircle(
      c,
      bodyR,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.45),
          radius: 1.15,
          colors: isAbyss
              ? const <Color>[Color(0xFF4C557C), Color(0xFF1C2238), Color(0xFF0F1322)]
              : const <Color>[Colors.white, Color(0xFFE4E9F5), Color(0xFFC2CADF)],
          stops: const <double>[0.0, 0.55, 1.0],
        ).createShader(bodyRect),
    );

    // Knurled grip: it turns with the knob, so rotation is visible even on a plain surface.
    final knurl = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(1.0, r * 0.035)
      ..color = (isAbyss ? Colors.white : const Color(0xFF1A2033)).withValues(alpha: isAbyss ? 0.13 : 0.12);
    const knurlCount = 24;
    for (var i = 0; i < knurlCount; i++) {
      final a = angle + i * 2 * math.pi / knurlCount;
      canvas.drawLine(
        c + Offset.fromDirection(a, bodyR * 0.84),
        c + Offset.fromDirection(a, bodyR * 0.96),
        knurl,
      );
    }

    // Rim light.
    canvas.drawCircle(
      c,
      bodyR - 0.6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Colors.white.withValues(alpha: isAbyss ? 0.48 : 0.95),
            Colors.white.withValues(alpha: 0.02),
          ],
        ).createShader(bodyRect),
    );

    // ---- Pointer + centre cap -------------------------------------------------------------------------
    final capR = readout != null ? bodyR * 0.54 : bodyR * 0.26;
    final pointerFrom = c + Offset.fromDirection(angle, capR + bodyR * 0.10);
    final pointerTo = c + Offset.fromDirection(angle, bodyR * 0.9);
    canvas.drawLine(
      pointerFrom,
      pointerTo,
      Paint()
        ..strokeWidth = r * 0.17
        ..strokeCap = StrokeCap.round
        ..color = pointerColor.withValues(alpha: active ? 0.85 : 0.55)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.08),
    );
    canvas.drawLine(
      pointerFrom,
      pointerTo,
      Paint()
        ..strokeWidth = r * 0.085
        ..strokeCap = StrokeCap.round
        ..color = pointerColor,
    );

    final capRect = Rect.fromCircle(center: c, radius: capR);
    canvas.drawCircle(
      c,
      capR,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.4),
          colors: isAbyss
              ? const <Color>[Color(0xFF2A3150), Color(0xFF0C101E)]
              : const <Color>[Colors.white, Color(0xFFD3D9EA)],
        ).createShader(capRect),
    );
    canvas.drawCircle(
      c,
      capR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = pointerColor.withValues(alpha: 0.55),
    );

    final text = readout;
    if (text != null) {
      var fontSize = r * 0.27;
      TextPainter layout(double size) {
        return TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, color: readoutColor, height: 1.0),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
      }

      var painter = layout(fontSize);
      final maxWidth = capR * 1.86;
      if (painter.width > maxWidth) {
        fontSize *= maxWidth / painter.width;
        painter.dispose();
        painter = layout(fontSize);
      }
      painter.paint(canvas, c - Offset(painter.width / 2, painter.height / 2));
      painter.dispose();
    }
  }

  @override
  bool shouldRepaint(_KnobPainter old) {
    return old.value != value ||
        old.min != min ||
        old.max != max ||
        old.zeroT != zeroT ||
        old.accent1 != accent1 ||
        old.accent2 != accent2 ||
        old.isAbyss != isAbyss ||
        old.trackColor != trackColor ||
        old.active != active ||
        old.readout != readout ||
        old.readoutColor != readoutColor;
  }
}

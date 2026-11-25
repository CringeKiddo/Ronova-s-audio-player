import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Interactive HSV colour wheel (hue around the ring, saturation towards the rim) with a
/// brightness slider underneath. Hue is remembered locally so dragging through white / grey does
/// not make the hue jump back to red.
class HsvColorWheel extends StatefulWidget {
  const HsvColorWheel({
    super.key,
    required this.color,
    required this.onChanged,
    this.size = 208,
  });

  final Color color;
  final ValueChanged<Color> onChanged;
  final double size;

  @override
  State<HsvColorWheel> createState() => _HsvColorWheelState();
}

class _HsvColorWheelState extends State<HsvColorWheel> {
  late HSVColor _hsv;
  late Color _lastEmitted;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.color);
    _lastEmitted = widget.color;
  }

  @override
  void didUpdateWidget(HsvColorWheel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // An outside change (e.g. a preset) replaces the local HSV; our own emissions do not.
    if (widget.color.toARGB32() != _lastEmitted.toARGB32()) {
      _hsv = HSVColor.fromColor(widget.color);
      _lastEmitted = widget.color;
    }
  }

  void _emit() {
    final color = _hsv.toColor();
    _lastEmitted = color;
    widget.onChanged(color);
  }

  void _updateFromPosition(Offset local) {
    final radius = widget.size / 2;
    final dx = local.dx - radius;
    final dy = local.dy - radius;
    final distance = math.sqrt(dx * dx + dy * dy);
    var hue = math.atan2(dy, dx) * 180 / math.pi;
    if (hue < 0) hue += 360;
    final saturation = (distance / radius).clamp(0.0, 1.0).toDouble();
    setState(() {
      _hsv = _hsv.withHue(hue).withSaturation(saturation);
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final fullBrightness = _hsv.withValue(1.0).toColor();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        GestureDetector(
          onPanStart: (details) => _updateFromPosition(details.localPosition),
          onPanUpdate: (details) => _updateFromPosition(details.localPosition),
          onTapDown: (details) {
            HapticFeedback.selectionClick();
            _updateFromPosition(details.localPosition);
          },
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: CustomPaint(painter: HsvWheelPainter(_hsv)),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: widget.size,
          height: 28,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Container(
                height: 12,
                margin: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  gradient: LinearGradient(colors: <Color>[Colors.black, fullBrightness]),
                ),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 12,
                  activeTrackColor: Colors.transparent,
                  inactiveTrackColor: Colors.transparent,
                  thumbColor: Colors.white,
                  overlayColor: Colors.white24,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9, elevation: 3),
                ),
                child: Slider(
                  value: _hsv.value,
                  onChanged: (value) {
                    setState(() => _hsv = _hsv.withValue(value));
                    _emit();
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class HsvWheelPainter extends CustomPainter {
  const HsvWheelPainter(this.hsv);

  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 3;
    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawCircle(
      center,
      radius + 2,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    final hueColors = <Color>[
      for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1.0, h.toDouble() % 360, 1.0, 1.0).toColor(),
    ];
    canvas.drawCircle(center, radius, Paint()..shader = SweepGradient(colors: hueColors).createShader(rect));
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[Colors.white, Colors.white.withValues(alpha: 0.0)],
        ).createShader(rect),
    );
    if (hsv.value < 1.0) {
      canvas.drawCircle(center, radius, Paint()..color = Colors.black.withValues(alpha: 1.0 - hsv.value));
    }
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = Colors.white.withValues(alpha: 0.55),
    );

    final angle = hsv.hue * math.pi / 180;
    final thumb = center + Offset(math.cos(angle), math.sin(angle)) * (hsv.saturation * radius);
    canvas.drawCircle(thumb, 13, Paint()..color = Colors.black.withValues(alpha: 0.35)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawCircle(thumb, 11, Paint()..color = hsv.toColor());
    canvas.drawCircle(
      thumb,
      11,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(HsvWheelPainter oldDelegate) => oldDelegate.hsv != hsv;
}

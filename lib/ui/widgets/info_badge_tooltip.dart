import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/theme_settings_provider.dart';
import 'ronova_widgets.dart';

/// Every control that gets a tiny `!` badge, with its plain-language explanation.
enum InfoTopic {
  shuffle(
    'Shuffle',
    'Plays your queue in a random order instead of top to bottom. Press Previous to step back '
        'through the songs you just heard.',
  ),
  repeat(
    'Repeat',
    'Tap to cycle through three modes: off, repeat the whole queue, or repeat just this one song.',
  ),
  queue(
    'Queue',
    'Your up-next list. Songs you add with "Play next" or "Add to queue" wait here. Tap any song '
        'in the list to jump straight to it.',
  ),
  speed(
    'Speed',
    'Changes the song speed from 0.1x (slower) up to 1.5x (faster) in precise 0.05 steps. With Reverb off, only the tempo '
        'changes and voices keep their normal pitch.',
  ),
  pitchLinkedReverb(
    'Pitch-Linked Reverb',
    'OFF: pitch stays locked at normal while speed changes (a clean time-stretch).\n\n'
        'ON: it behaves like slowing a record, so pitch falls naturally with speed, and a spacious '
        'reverb tail is added. This is the "slowed + reverb" sound.',
  ),
  roomSpace(
    'Room Space',
    'How big the reverb room feels. 0% is normal audio with standard reverb, 100% is a vast, '
        'empty hall. It only applies while Reverb is on.',
  ),
  volumeUpscaler(
    'Volume Upscaler',
    'A clean 32-bit float boost from 0 to +24 dB. A look-ahead brickwall limiter holds every peak '
        'under -0.1 dBFS, so loud songs get louder without clipping or crackle. The meter shows how '
        'much limiting is happening right now.',
  ),
  ronovaMode(
    'Ronova Mode',
    'Scans your headset or DAC, locks the audio stream to its highest native sample rate, then '
        'tunes headphone crossfeed, an 11.5 kHz air lift and sub-bass punch (plus Bluetooth '
        'compensation) to that exact device.',
  ),
  subBass808(
    '808 Sub-Bass Exciter',
    'Synthesizes harmonics of the deepest notes (below 75 Hz) so bass can be felt and heard even '
        'on small drivers and Bluetooth headsets. 0% is off, 100% is maximum punch.',
  ),
  stereoWidth(
    'Stereo Width',
    'Narrows or widens the stereo image. 0% is mono, 100% is the original recording, 200% is '
        'extra wide.',
  ),
  preAmp(
    'Pre-Amp Trim',
    'Raises or lowers the signal before the equalizer, from -12 to +12 dB. If you boost bands a '
        'lot, pull the pre-amp down to keep headroom and avoid distortion.',
  );

  const InfoTopic(this.title, this.body);

  final String title;
  final String body;
}

/// Tiny circular `!` badge. Tapping it opens a soft floating bubble that explains [topic].
class InfoBadge extends ConsumerWidget {
  const InfoBadge({super.key, required this.topic, this.size = 16, this.tint});

  final InfoTopic topic;

  /// Diameter of the visible circle; the tap target is larger.
  final double size;

  /// Overrides the accent colour (the center player box passes its album-art colour).
  final Color? tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    final color = tint ?? p.accentText;
    return Semantics(
      button: true,
      label: 'What is ${topic.title}?',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          final box = context.findRenderObject();
          if (box is! RenderBox || !box.hasSize) return;
          HapticFeedback.selectionClick();
          showInfoBubble(context, topic: topic, anchor: box.localToGlobal(Offset.zero) & box.size, tint: tint);
        },
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.14),
              border: Border.all(color: color.withValues(alpha: 0.85), width: 1.2),
              boxShadow: <BoxShadow>[BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 6)],
            ),
            child: Text(
              '!',
              style: TextStyle(
                fontSize: size * 0.68,
                fontWeight: FontWeight.w800,
                color: color,
                height: 1.0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A label with its `!` badge on the right.
class InfoLabel extends StatelessWidget {
  const InfoLabel({super.key, required this.text, required this.topic, required this.style, this.tint});

  final String text;
  final InfoTopic topic;
  final TextStyle style;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
        InfoBadge(topic: topic, size: 14, tint: tint),
      ],
    );
  }
}

/// Opens the explanation bubble for [topic] next to [anchor].
Future<void> showInfoBubble(
  BuildContext context, {
  required InfoTopic topic,
  required Rect anchor,
  Color? tint,
}) {
  return showRonovaPopover(
    context,
    anchor: anchor,
    width: 292,
    tint: tint,
    builder: (_) => _InfoBubbleContent(topic: topic, tint: tint),
  );
}

class _InfoBubbleContent extends ConsumerWidget {
  const _InfoBubbleContent({required this.topic, this.tint});

  final InfoTopic topic;
  final Color? tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    final color = tint ?? p.accentText;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.16),
                border: Border.all(color: color, width: 1.2),
              ),
              child: Text('!', style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 14, height: 1.0)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                topic.title,
                style: RonovaFonts.display(size: 17, color: p.textPrimary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          topic.body,
          style: TextStyle(fontSize: 13.5, height: 1.42, color: p.textSecondary),
        ),
      ],
    );
  }
}

/// A floating frosted card with a small pointer, springing out of [anchor]. Tapping anywhere else
/// dismisses it. The card opens below the anchor when there is more room there, otherwise above.
Future<void> showRonovaPopover(
  BuildContext context, {
  required Rect anchor,
  required WidgetBuilder builder,
  double width = 300,
  Color? tint,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return _PopoverLayer(anchor: anchor, width: width, tint: tint, animation: animation, builder: builder);
    },
  );
}

class _PopoverLayer extends ConsumerStatefulWidget {
  const _PopoverLayer({
    required this.anchor,
    required this.width,
    required this.animation,
    required this.builder,
    this.tint,
  });

  final Rect anchor;
  final double width;
  final Animation<double> animation;
  final WidgetBuilder builder;
  final Color? tint;

  @override
  ConsumerState<_PopoverLayer> createState() => _PopoverLayerState();
}

class _PopoverLayerState extends ConsumerState<_PopoverLayer> {
  late final CurvedAnimation _scale = CurvedAnimation(
    parent: widget.animation,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInCubic,
  );
  late final CurvedAnimation _fade = CurvedAnimation(
    parent: widget.animation,
    curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
    reverseCurve: Curves.easeIn,
  );

  @override
  void dispose() {
    _scale.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(ronovaPaletteProvider);
    final media = MediaQuery.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        const margin = 14.0;
        const gap = 10.0;
        const radius = 22.0;
        final screenW = constraints.maxWidth;
        final screenH = constraints.maxHeight;
        final w = math.min(widget.width, screenW - margin * 2);
        final left = (widget.anchor.center.dx - w / 2).clamp(margin, math.max(margin, screenW - margin - w)).toDouble();
        final nubX = (widget.anchor.center.dx - left).clamp(26.0, math.max(26.0, w - 26)).toDouble();

        final spaceBelow = screenH - media.padding.bottom - media.viewInsets.bottom - widget.anchor.bottom;
        final spaceAbove = widget.anchor.top - media.padding.top;
        final below = spaceBelow >= spaceAbove;

        final accent = widget.tint ?? p.primary;
        final fill = p.isAbyss
            ? const Color(0xFF171C2E).withValues(alpha: 0.95)
            : Colors.white.withValues(alpha: 0.97);
        final borderGradient = widget.tint != null
            ? LinearGradient(colors: <Color>[widget.tint!.withValues(alpha: 0.9), p.accent2.withValues(alpha: 0.6)])
            : p.gradient(alpha: 0.85);

        final nub = Positioned(
          left: nubX - 7,
          top: below ? -6 : null,
          bottom: below ? null : -6,
          child: Transform.rotate(
            angle: math.pi / 4,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: fill,
                border: Border(
                  top: below ? BorderSide(color: accent.withValues(alpha: 0.85), width: 1.2) : BorderSide.none,
                  left: below ? BorderSide(color: accent.withValues(alpha: 0.85), width: 1.2) : BorderSide.none,
                  bottom: below ? BorderSide.none : BorderSide(color: accent.withValues(alpha: 0.85), width: 1.2),
                  right: below ? BorderSide.none : BorderSide(color: accent.withValues(alpha: 0.85), width: 1.2),
                ),
              ),
            ),
          ),
        );

        final card = Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                boxShadow: <BoxShadow>[
                  BoxShadow(color: Colors.black.withValues(alpha: 0.38), blurRadius: 30, offset: const Offset(0, 12)),
                  BoxShadow(color: accent.withValues(alpha: 0.22), blurRadius: 26),
                ],
              ),
              child: CustomPaint(
                foregroundPainter: GradientBorderPainter(gradient: borderGradient, radius: radius, width: 1.3),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(radius),
                  child: maybeBackdropBlur(
                    sigma: 18,
                    child: Container(
                      color: fill,
                      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                      child: Builder(builder: widget.builder),
                    ),
                  ),
                ),
              ),
            ),
            nub,
          ],
        );

        final animated = FadeTransition(
          opacity: _fade,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.78, end: 1.0).animate(_scale),
            alignment: Alignment((nubX / w) * 2 - 1, below ? -1.0 : 1.0),
            child: card,
          ),
        );

        return Material(
          type: MaterialType.transparency,
          child: Stack(
            children: <Widget>[
              Positioned(
                left: left,
                width: w,
                top: below ? widget.anchor.bottom + gap : null,
                bottom: below ? null : screenH - widget.anchor.top + gap,
                child: animated,
              ),
            ],
          ),
        );
      },
    );
  }
}

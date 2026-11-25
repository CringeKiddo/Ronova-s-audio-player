import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/audio_track.dart';
import '../../core/providers/theme_settings_provider.dart';
import 'ronova_widgets.dart';

/// Everything the element-motif popup can ask the library to do for one track.
enum TrackMenuAction {
  favorite,
  play,
  playNext,
  addToQueue,
  addToPlaylist,
  editTags,
  showInFolders,
  share,
  delete,
}

class _MenuEntry {
  const _MenuEntry(this.action, this.icon, this.label, {this.destructive = false});

  final TrackMenuAction action;
  final IconData icon;
  final String label;
  final bool destructive;
}

const List<_MenuEntry> _entries = <_MenuEntry>[
  _MenuEntry(TrackMenuAction.play, Icons.play_arrow_rounded, 'Play'),
  _MenuEntry(TrackMenuAction.playNext, Icons.skip_next_rounded, 'Play next'),
  _MenuEntry(TrackMenuAction.addToQueue, Icons.queue_music_rounded, 'Add to queue'),
  _MenuEntry(TrackMenuAction.addToPlaylist, Icons.playlist_add_rounded, 'Add to playlist'),
  _MenuEntry(TrackMenuAction.editTags, Icons.edit_note_rounded, 'Edit tags'),
  _MenuEntry(TrackMenuAction.showInFolders, Icons.folder_open_rounded, 'Show in folders'),
  _MenuEntry(TrackMenuAction.share, Icons.ios_share_rounded, 'Send / Share'),
  _MenuEntry(TrackMenuAction.delete, Icons.delete_outline_rounded, 'Delete', destructive: true),
];

// ---------------------------------------------------------------------------------------------
// Trigger button
// ---------------------------------------------------------------------------------------------

/// Sleek four-point celestial star with a triquetra core and a soft outer glow. It replaces the
/// usual three-dots button beside every track and opens the bouncy action popup.
class GenshinMotifButton extends ConsumerWidget {
  const GenshinMotifButton({
    super.key,
    required this.track,
    required this.onAction,
    this.size = 42,
  });

  final AudioTrack track;

  /// Called for every chosen action (including the favorite star toggle).
  final void Function(TrackMenuAction action) onAction;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    return Semantics(
      button: true,
      label: 'Track options for ${track.title}',
      child: PressableScale(
        scale: 0.86,
        onTap: () {
          HapticFeedback.lightImpact();
          final box = context.findRenderObject();
          if (box is! RenderBox || !box.hasSize) return;
          final anchor = box.localToGlobal(Offset.zero) & box.size;
          showGenshinMotifMenu(
            context,
            anchor: anchor,
            track: track,
            onAction: onAction,
          );
        },
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: GenshinMotifPainter(
              gradient: p.accentGradient,
              glowColor1: p.accent1,
              glowColor2: p.accent2,
              favorite: track.isFavorite,
            ),
          ),
        ),
      ),
    );
  }
}

/// Vector element motif: concave four-point star + interlaced triquetra + soft glow.
class GenshinMotifPainter extends CustomPainter {
  const GenshinMotifPainter({
    required this.gradient,
    required this.glowColor1,
    required this.glowColor2,
    this.favorite = false,
  });

  final Gradient gradient;
  final Color glowColor1;
  final Color glowColor2;
  final bool favorite;

  Path _star(Offset c, double r) {
    final k = r * 0.17;
    return Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx + k, c.dy - k, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx + k, c.dy + k, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx - k, c.dy + k, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx - k, c.dy - k, c.dx, c.dy - r)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * 0.36;
    final rect = Rect.fromCircle(center: c, radius: r * 1.2);
    final star = _star(c, r);

    // Soft outer glow in both accent colours.
    canvas.drawPath(
      star,
      Paint()
        ..color = glowColor1.withValues(alpha: 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.save();
    canvas.translate(r * 0.10, 0);
    canvas.drawPath(
      star,
      Paint()
        ..color = glowColor2.withValues(alpha: 0.40)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.restore();

    // Gradient star body.
    canvas.drawPath(star, Paint()..shader = gradient.createShader(rect));

    // Small diagonal sparkles.
    final sparkle = Paint()..shader = gradient.createShader(rect);
    for (final angle in <double>[math.pi / 4, 3 * math.pi / 4, 5 * math.pi / 4, 7 * math.pi / 4]) {
      final p = c + Offset(math.cos(angle), math.sin(angle)) * (r * 0.92);
      canvas.drawCircle(p, r * 0.07, sparkle);
    }

    // Triquetra core: three interlaced rings knocked out of the star.
    final ringRadius = r * 0.30;
    final ringOffset = r * 0.19;
    final knock = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, r * 0.085)
      ..color = const Color(0xCC0A0C12);
    final shine = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.6, r * 0.04)
      ..color = const Color(0xCCFFFFFF);
    for (var i = 0; i < 3; i++) {
      final angle = -math.pi / 2 + i * 2 * math.pi / 3;
      final center = c + Offset(math.cos(angle), math.sin(angle)) * ringOffset;
      canvas.drawCircle(center, ringRadius, knock);
      canvas.drawCircle(center, ringRadius, shine);
    }

    // Favorites get a small gold dot above the star.
    if (favorite) {
      canvas.drawCircle(
        Offset(c.dx + r * 0.95, c.dy - r * 0.95),
        r * 0.14,
        Paint()..color = const Color(0xFFFFD166),
      );
    }
  }

  @override
  bool shouldRepaint(GenshinMotifPainter oldDelegate) {
    return oldDelegate.gradient != gradient ||
        oldDelegate.glowColor1 != glowColor1 ||
        oldDelegate.glowColor2 != glowColor2 ||
        oldDelegate.favorite != favorite;
  }
}

// ---------------------------------------------------------------------------------------------
// Popup
// ---------------------------------------------------------------------------------------------

const double _menuWidth = 256;
const double _headerHeight = 66;
const double _itemHeight = 46;
const double _menuPadding = 8;

double _menuHeightFor(int items) => _headerHeight + items * _itemHeight + _menuPadding * 2 + 2;

/// Opens the floating glass action card next to [anchor], scaling + fading out of the anchor
/// point in 340 ms with an overshooting `Curves.easeOutBack` spring.
Future<void> showGenshinMotifMenu(
  BuildContext context, {
  required Rect anchor,
  required AudioTrack track,
  required void Function(TrackMenuAction action) onAction,
}) {
  final media = MediaQuery.of(context);
  final screen = media.size;
  final safeTop = media.padding.top + 12;
  final safeBottom = media.padding.bottom + 12;
  final height = math.min(_menuHeightFor(_entries.length), screen.height - safeTop - safeBottom);

  final left = (anchor.right - _menuWidth).clamp(12.0, math.max(12.0, screen.width - _menuWidth - 12)).toDouble();
  var top = anchor.bottom + 4;
  if (top + height > screen.height - safeBottom) {
    top = anchor.top - height - 4;
  }
  top = top.clamp(safeTop, math.max(safeTop, screen.height - safeBottom - height)).toDouble();

  final cardCenter = Offset(left + _menuWidth / 2, top + height / 2);
  final anchorCenter = anchor.center;
  final origin = Alignment(
    ((anchorCenter.dx - cardCenter.dx) / (_menuWidth / 2)).clamp(-1.4, 1.4).toDouble(),
    ((anchorCenter.dy - cardCenter.dy) / (height / 2)).clamp(-1.4, 1.4).toDouble(),
  );

  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close menu',
    barrierColor: Colors.black.withValues(alpha: 0.22),
    transitionDuration: const Duration(milliseconds: 340),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return Stack(
        children: <Widget>[
          Positioned(
            left: left,
            top: top,
            width: _menuWidth,
            height: height,
            child: _MenuCard(
              animation: animation,
              track: track,
              onAction: onAction,
            ),
          ),
        ],
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final scale = Tween<double>(begin: 0.55, end: 1.0).animate(
        CurvedAnimation(parent: animation, curve: Curves.easeOutBack, reverseCurve: Curves.easeInCubic),
      );
      final fade = CurvedAnimation(
        parent: animation,
        curve: const Interval(0.0, 0.55, curve: Curves.easeOut),
        reverseCurve: Curves.easeIn,
      );
      return FadeTransition(
        opacity: fade,
        child: ScaleTransition(alignment: origin, scale: scale, child: child),
      );
    },
  );
}

class _MenuCard extends ConsumerStatefulWidget {
  const _MenuCard({
    required this.animation,
    required this.track,
    required this.onAction,
  });

  final Animation<double> animation;
  final AudioTrack track;
  final void Function(TrackMenuAction action) onAction;

  @override
  ConsumerState<_MenuCard> createState() => _MenuCardState();
}

class _MenuCardState extends ConsumerState<_MenuCard> with SingleTickerProviderStateMixin {
  late bool _favorite = widget.track.isFavorite;
  late final AnimationController _starPop =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  late final List<CurvedAnimation> _stagger = <CurvedAnimation>[
    for (var i = 0; i < _entries.length; i++)
      CurvedAnimation(
        parent: widget.animation,
        curve: Interval(
          math.min(0.20 + i * 0.05, 0.70),
          math.min(0.58 + i * 0.05, 1.0),
          curve: Curves.easeOutCubic,
        ),
      ),
  ];

  @override
  void dispose() {
    for (final animation in _stagger) {
      animation.dispose();
    }
    _starPop.dispose();
    super.dispose();
  }

  void _toggleFavorite() {
    HapticFeedback.mediumImpact();
    setState(() => _favorite = !_favorite);
    _starPop.forward(from: 0);
    widget.onAction(TrackMenuAction.favorite);
  }

  void _choose(TrackMenuAction action) {
    HapticFeedback.selectionClick();
    Navigator.of(context).pop();
    widget.onAction(action);
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(ronovaPaletteProvider);
    const danger = Color(0xFFFF5A6E);

    return Material(
      type: MaterialType.transparency,
      child: FrostedCard(
        blur: true,
        strong: true,
        glow: true,
        radius: 26,
        borderAlpha: 0.7,
        child: SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.all(_menuPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                height: _headerHeight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 2, 4),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              widget.track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: RonovaFonts.display(size: 15.5, color: p.textPrimary),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.track.artist.isEmpty ? 'Unknown artist' : widget.track.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5, color: p.textSecondary),
                            ),
                          ],
                        ),
                      ),
                      PressableScale(
                        scale: 0.8,
                        onTap: _toggleFavorite,
                        child: SizedBox(
                          width: 46,
                          height: 46,
                          child: Center(
                            child: AnimatedBuilder(
                              animation: _starPop,
                              builder: (context, child) {
                                final t = Curves.elasticOut.transform(_starPop.value);
                                final scale = _starPop.isAnimating ? 0.6 + 0.4 * t : 1.0;
                                return Transform.scale(scale: scale, child: child);
                              },
                              child: _favorite
                                  ? const Icon(Icons.star_rounded, size: 29, color: Color(0xFFFFD166))
                                  : GradientIcon(Icons.star_outline_rounded, gradient: p.accentGradient, size: 29),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Container(
                height: 1,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(gradient: p.gradient(begin: Alignment.centerLeft, end: Alignment.centerRight, alpha: 0.55)),
              ),
              for (var i = 0; i < _entries.length; i++)
                FadeTransition(
                  opacity: _stagger[i],
                  child: SlideTransition(
                    position: Tween<Offset>(begin: const Offset(0, 0.35), end: Offset.zero).animate(_stagger[i]),
                    child: PressableScale(
                      scale: 0.97,
                      onTap: () => _choose(_entries[i].action),
                      child: SizedBox(
                        height: _itemHeight,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: <Widget>[
                              _entries[i].destructive
                                  ? Icon(_entries[i].icon, size: 22, color: danger)
                                  : GradientIcon(_entries[i].icon, gradient: p.accentGradient, size: 22),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  _entries[i].label,
                                  style: TextStyle(
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w500,
                                    color: _entries[i].destructive ? danger : p.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

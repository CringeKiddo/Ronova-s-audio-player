import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/theme_settings_provider.dart';

/// Opens [builder]'s content inside a frosted-glass bottom sheet (used by the 40-preset drawer and
/// the playback queue). The sheet lifts above the keyboard and never covers the status bar.
Future<void> showGlassSheet(
  BuildContext context, {
  required WidgetBuilder builder,
  double heightFactor = 0.86,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.46),
    elevation: 0,
    builder: (sheetContext) => GlassSheet(
      heightFactor: heightFactor,
      child: builder(sheetContext),
    ),
  );
}

/// Frosted sheet chrome: rounded top corners, backdrop blur, glowing top edge and a grab handle.
class GlassSheet extends ConsumerWidget {
  const GlassSheet({super.key, required this.child, this.heightFactor = 0.86});

  final Widget child;
  final double heightFactor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(ronovaPaletteProvider);
    final media = MediaQuery.of(context);
    final available = media.size.height - media.padding.top - 12 - media.viewInsets.bottom;
    final height = math.min(media.size.height * heightFactor, available);
    final fill = p.isAbyss
        ? const Color(0xFF0E1220).withValues(alpha: 0.93)
        : Colors.white.withValues(alpha: 0.95);

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SizedBox(
        height: height,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 26, sigmaY: 26),
            child: Material(
              type: MaterialType.transparency,
              child: DecoratedBox(
                decoration: BoxDecoration(color: fill),
                child: Column(
                  children: <Widget>[
                    Container(
                      height: 1.6,
                      decoration: BoxDecoration(gradient: p.gradient(begin: Alignment.centerLeft, end: Alignment.centerRight, alpha: 0.9)),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color: p.textMuted.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(child: child),
                    SizedBox(height: media.padding.bottom),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

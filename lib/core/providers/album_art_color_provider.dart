import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:palette_generator/palette_generator.dart';

import '../services/native_platform_service.dart';

/// Dominant + secondary colours pulled from a track's cover art (null when it has no art).
///
/// Used for the mini-player's ambient glow and, in Batch 5, the center player box. When a track
/// has no artwork the UI falls back to the theme accent colours.
final albumArtColorsProvider = FutureProvider.family<List<Color>?, String>((ref, filePath) async {
  if (filePath.isEmpty) return null;
  try {
    final bytes = await NativePlatformService.instance.getAlbumArt(filePath);
    if (bytes == null || bytes.isEmpty) return null;
    final palette = await PaletteGenerator.fromImageProvider(
      ResizeImage(MemoryImage(bytes), width: 72),
      maximumColorCount: 10,
    );
    final first = palette.vibrantColor ?? palette.lightVibrantColor ?? palette.dominantColor;
    if (first == null) return null;
    final second = palette.darkVibrantColor ?? palette.mutedColor ?? palette.dominantColor ?? first;
    return <Color>[first.color, second.color];
  } catch (_) {
    return null;
  }
});

/// Cover-art colours used by the center player box (Batch 5).
///
/// * [vibrant]: the most saturated, eye-catching colour (edge glow, play button, sliders).
/// * [dominant]: the colour covering the most pixels (second glow stop, background tint).
/// * [deep]: a darker, muted colour for the gradient's shadowed corner.
@immutable
class AlbumArtPalette {
  const AlbumArtPalette({required this.vibrant, required this.dominant, required this.deep});

  final Color vibrant;
  final Color dominant;
  final Color deep;
}

/// Extracts an [AlbumArtPalette] with `PaletteGenerator`; null when the track has no artwork,
/// in which case the player box falls back to the active colour-wheel theme colours.
final albumArtPaletteProvider = FutureProvider.family<AlbumArtPalette?, String>((ref, filePath) async {
  if (filePath.isEmpty) return null;
  try {
    final bytes = await NativePlatformService.instance.getAlbumArt(filePath);
    if (bytes == null || bytes.isEmpty) return null;
    final palette = await PaletteGenerator.fromImageProvider(
      ResizeImage(MemoryImage(bytes), width: 96),
      maximumColorCount: 16,
    );
    final vibrant =
        (palette.vibrantColor ?? palette.lightVibrantColor ?? palette.darkVibrantColor ?? palette.dominantColor)?.color;
    final dominant = (palette.dominantColor ?? palette.vibrantColor)?.color;
    if (vibrant == null || dominant == null) return null;
    final deep =
        (palette.darkMutedColor ?? palette.darkVibrantColor ?? palette.mutedColor ?? palette.dominantColor)?.color ??
            dominant;
    return AlbumArtPalette(vibrant: vibrant, dominant: dominant, deep: deep);
  } catch (_) {
    return null;
  }
});

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// True when [path] points at a video file (used to tell video wallpapers from photos).
bool isVideoPath(String? path) {
  if (path == null) return false;
  final lower = path.toLowerCase();
  const extensions = <String>['.mp4', '.m4v', '.mov', '.webm', '.mkv', '.3gp', '.avi'];
  for (final ext in extensions) {
    if (lower.endsWith(ext)) return true;
  }
  return false;
}

/// Muted, looping, edge-to-edge (BoxFit.cover) video wallpaper.
///
/// * Never takes audio focus (`mixWithOthers` + volume 0), so it can't interrupt the music engine.
/// * Pauses while the app is in the background and resumes when it comes back.
/// * Falls back to an empty box if the file can't be decoded.
class VideoBackground extends StatefulWidget {
  const VideoBackground({super.key, required this.path});

  final String path;

  @override
  State<VideoBackground> createState() => _VideoBackgroundState();
}

class _VideoBackgroundState extends State<VideoBackground> with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  @override
  void didUpdateWidget(VideoBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _close();
      _open();
    }
  }

  Future<void> _open() async {
    final controller = VideoPlayerController.file(
      File(widget.path),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _controller = controller;
    _ready = false;
    _failed = false;
    try {
      await controller.initialize();
      if (!mounted || _controller != controller) {
        await controller.dispose();
        return;
      }
      await controller.setLooping(true);
      await controller.setVolume(0);
      await controller.play();
      setState(() => _ready = true);
    } catch (_) {
      if (mounted && _controller == controller) setState(() => _failed = true);
    }
  }

  void _close() {
    final old = _controller;
    _controller = null;
    _ready = false;
    old?.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !_ready) return;
    if (state == AppLifecycleState.resumed) {
      controller.play();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      controller.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_failed || controller == null || !_ready) return const SizedBox.expand();
    final size = controller.value.size;
    if (size.isEmpty) return const SizedBox.expand();
    return RepaintBoundary(
      child: ClipRect(
        child: SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(width: size.width, height: size.height, child: VideoPlayer(controller)),
          ),
        ),
      ),
    );
  }
}

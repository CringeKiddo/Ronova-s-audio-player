import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../ffi/ronova_ffi_bindings.dart' show RonovaHardwareProfile;
import '../models/audio_track.dart';

/// What a native control (notification, lockscreen, overlay, headset button) asked for.
enum NativeControlAction {
  next,
  previous,
  playPause,
  toggleSlow,
  setSpeed,
  toggleReverb,
  toggleRonova,
  setUpscaler,
  overlayClosed,
  notificationDismissed,
  audioRouteChanged,
}

/// Which native surface produced a [NativeControlEvent].
enum NativeControlSource { notification, overlay, mediaButton, noisy, hardware, unknown }

/// One command coming from the Android layer.
///
/// Which fields are set depends on [action]:
/// * [NativeControlAction.playPause]: [play] (desired state)
/// * [NativeControlAction.toggleSlow]: [slowed] (desired state) and [speed] (0.85 or 1.0)
/// * [NativeControlAction.setSpeed]: [speed] (0.10 .. 1.00)
/// * [NativeControlAction.toggleReverb] / [toggleRonova] / [setUpscaler]: [enabled]
/// * [NativeControlAction.audioRouteChanged]: [hardware]
@immutable
class NativeControlEvent {
  const NativeControlEvent({
    required this.action,
    this.source = NativeControlSource.unknown,
    this.play,
    this.enabled,
    this.slowed,
    this.speed,
    this.hardware,
  });

  final NativeControlAction action;
  final NativeControlSource source;
  final bool? play;
  final bool? enabled;
  final bool? slowed;
  final double? speed;
  final HeadsetHardwareInfo? hardware;

  @override
  String toString() =>
      'NativeControlEvent($action from $source, play: $play, enabled: $enabled, slowed: $slowed, speed: $speed)';
}

/// Result of analysing the current output route, used to calibrate Ronova Mode.
@immutable
class HeadsetHardwareInfo {
  const HeadsetHardwareInfo({
    required this.deviceType,
    required this.deviceName,
    required this.transport,
    required this.maxSampleRate,
    required this.sampleRateSource,
    required this.supportedSampleRates,
    required this.channelCount,
    required this.channelCapability,
    required this.androidDeviceType,
    required this.bluetoothPermissionGranted,
  });

  /// Safe fallback when the native layer is unavailable.
  static const HeadsetHardwareInfo speaker = HeadsetHardwareInfo(
    deviceType: 0,
    deviceName: 'Phone speaker',
    transport: 'speaker',
    maxSampleRate: 48000,
    sampleRateSource: 'system',
    supportedSampleRates: <int>[],
    channelCount: 2,
    channelCapability: 'stereo',
    androidDeviceType: 0,
    bluetoothPermissionGranted: false,
  );

  factory HeadsetHardwareInfo.fromMap(Map<Object?, Object?> map) {
    int asInt(Object? v, int fallback) => v is num ? v.toInt() : fallback;
    final rates = map['supportedSampleRates'];
    return HeadsetHardwareInfo(
      deviceType: asInt(map['deviceType'], 0),
      deviceName: (map['deviceName'] as String?) ?? 'Phone speaker',
      transport: (map['transport'] as String?) ?? 'speaker',
      maxSampleRate: asInt(map['maxSampleRate'], 48000),
      sampleRateSource: (map['sampleRateSource'] as String?) ?? 'system',
      supportedSampleRates: <int>[
        if (rates is List)
          for (final r in rates)
            if (r is num) r.toInt(),
      ],
      channelCount: asInt(map['channelCount'], 2),
      channelCapability: (map['channelCapability'] as String?) ?? 'stereo',
      androidDeviceType: asInt(map['androidDeviceType'], 0),
      bluetoothPermissionGranted: map['bluetoothPermissionGranted'] == true,
    );
  }

  /// 0 = phone speaker, 1 = wired headset / USB-C DAC / USB dongle, 2 = Bluetooth.
  final int deviceType;
  final String deviceName;

  /// `speaker`, `wired`, `usb`, `bluetooth`, `ble` or `other`.
  final String transport;
  final int maxSampleRate;

  /// `device` (reported by the hardware), `system` (platform default) or `assumed`.
  final String sampleRateSource;
  final List<int> supportedSampleRates;
  final int channelCount;

  /// `mono`, `stereo` or `multichannel`.
  final String channelCapability;
  final int androidDeviceType;
  final bool bluetoothPermissionGranted;

  bool get isSpeaker => deviceType == 0;
  bool get isWired => deviceType == 1;
  bool get isBluetooth => deviceType == 2;

  /// Profile to hand to `RonovaFfiBindings.setHardwareProfile` before engaging Ronova Mode.
  RonovaHardwareProfile get ronovaProfile {
    if (isBluetooth) return RonovaHardwareProfile.bluetooth;
    if (isWired) {
      return transport == 'usb' ? RonovaHardwareProfile.usbDac : RonovaHardwareProfile.wiredHeadphones;
    }
    return RonovaHardwareProfile.speaker;
  }

  @override
  String toString() => 'HeadsetHardwareInfo($deviceName, $transport, max $maxSampleRate Hz, $channelCount ch)';
}

/// Outcome of [NativePlatformService.startFloatingOverlay].
@immutable
class OverlayStartResult {
  const OverlayStartResult({required this.started, required this.needsPermission});

  final bool started;

  /// True when Android's "Display over other apps" permission still has to be granted.
  final bool needsPermission;
}

/// Typed singleton around the `com.ronova.audio/native` MethodChannel.
///
/// Usage: subscribe to [events] first, then call [initialize] once (events that arrived before
/// the first listener are buffered and delivered on subscription).
class NativePlatformService {
  NativePlatformService._();

  static final NativePlatformService instance = NativePlatformService._();

  static const MethodChannel _channel = MethodChannel('com.ronova.audio/native');
  static const int _maxArtCacheEntries = 80;
  static const int _maxBacklog = 16;

  late final StreamController<NativeControlEvent> _controller =
      StreamController<NativeControlEvent>.broadcast(onListen: _flushBacklog);
  final List<NativeControlEvent> _backlog = <NativeControlEvent>[];
  final LinkedHashMap<String, Uint8List?> _artCache = LinkedHashMap<String, Uint8List?>();
  final Map<String, Future<Uint8List?>> _artInFlight = <String, Future<Uint8List?>>{};
  bool _initialised = false;

  /// Commands from the notification, lockscreen, headset buttons and gaming overlay.
  Stream<NativeControlEvent> get events => _controller.stream;

  /// Native services only exist on Android.
  bool get isSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> initialize() async {
    if (_initialised || !isSupported) return;
    _initialised = true;
    _channel.setMethodCallHandler(_handleNativeCall);
    // Tells Kotlin that Dart is listening, which flushes any queued button presses.
    await _invoke<bool>('nativeReady');
  }

  // ---- Library -------------------------------------------------------------------------------

  /// One batched MediaStore sweep. Throws [PlatformException] (`PERMISSION_DENIED`) if the audio
  /// permission has not been granted yet.
  Future<List<AudioTrack>> scanAllTracks() async {
    if (!isSupported) return const <AudioTrack>[];
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>('scanAllTracks');
    if (raw == null) return const <AudioTrack>[];
    return <AudioTrack>[
      for (final map in raw) AudioTrack.fromJson(Map<String, Object?>.from(map)),
    ];
  }

  /// Lazily loads cover art (embedded picture, or cover.jpg / folder.jpg next to the file).
  /// Results and misses are cached; concurrent requests for the same file share one call.
  Future<Uint8List?> getAlbumArt(String filePath) {
    if (!isSupported || filePath.isEmpty) return Future<Uint8List?>.value(null);
    if (_artCache.containsKey(filePath)) {
      final cached = _artCache.remove(filePath);
      _artCache[filePath] = cached;  // refresh LRU position
      return Future<Uint8List?>.value(cached);
    }
    return _artInFlight.putIfAbsent(filePath, () async {
      try {
        final bytes = await _invoke<Uint8List>('getAlbumArt', <String, Object?>{'path': filePath});
        _artCache[filePath] = bytes;
        while (_artCache.length > _maxArtCacheEntries) {
          _artCache.remove(_artCache.keys.first);
        }
        return bytes;
      } finally {
        unawaited(_artInFlight.remove(filePath));
      }
    });
  }

  /// Opens Android's share sheet for one library track (audio/* via its MediaStore URI).
  Future<bool> shareTrack({required int mediaStoreId, required String title}) async {
    final ok = await _invoke<bool>('shareTrack', <String, Object?>{
      'mediaStoreId': mediaStoreId,
      'title': title,
    });
    return ok ?? false;
  }

  // ---- Hardware --------------------------------------------------------------------------------

  Future<HeadsetHardwareInfo> analyzeHeadsetHardware() async {
    final map = await _invoke<Map<Object?, Object?>>('analyzeHeadsetHardware');
    return map == null ? HeadsetHardwareInfo.speaker : HeadsetHardwareInfo.fromMap(map);
  }

  /// Emits [NativeControlAction.audioRouteChanged] whenever headphones / DACs / Bluetooth connect or disconnect.
  Future<void> startHeadsetMonitoring() => _invoke<bool>('startHeadsetMonitoring');

  Future<void> stopHeadsetMonitoring() => _invoke<bool>('stopHeadsetMonitoring');

  // ---- Notification ----------------------------------------------------------------------------

  /// Updates the lockscreen / notification-shade player. The notification becomes un-swipeable
  /// while [isPlaying] is true. Pass [artBytes] only when the track changes and set [keepArt] on
  /// later updates so the artwork is not re-sent.
  Future<void> updateNotificationState({
    required String title,
    required String artist,
    required bool isPlaying,
    required bool isSlowed,
    Uint8List? artBytes,
    bool keepArt = false,
  }) {
    return _invoke<bool>('updateNotificationState', <String, Object?>{
      'title': title,
      'artist': artist,
      'isPlaying': isPlaying,
      'isSlowed': isSlowed,
      'artBytes': keepArt ? null : artBytes,
      'keepArt': keepArt,
    });
  }

  Future<void> stopNotification() => _invoke<bool>('stopNotification');

  // ---- Gaming overlay ----------------------------------------------------------------------------

  Future<bool> canDrawOverlays() async => (await _invoke<bool>('canDrawOverlays')) ?? false;

  /// Opens Android's "Display over other apps" screen for this app.
  Future<bool> openOverlaySettings() async => (await _invoke<bool>('openOverlaySettings')) ?? false;

  Future<bool> isOverlayRunning() async => (await _invoke<bool>('isOverlayRunning')) ?? false;

  Future<OverlayStartResult> startFloatingOverlay({
    bool doubleTap = true,
    double scale = 1.0,
    double opacity = 0.9,
  }) async {
    final map = await _invoke<Map<Object?, Object?>>('startFloatingOverlay', <String, Object?>{
      'doubleTap': doubleTap,
      'scale': scale,
      'opacity': opacity,
    });
    return OverlayStartResult(
      started: map?['started'] == true,
      needsPermission: map?['needsPermission'] == true,
    );
  }

  Future<void> stopFloatingOverlay() => _invoke<bool>('stopFloatingOverlay');

  /// Pushes the player state shown in the overlay's mini card. Only non-null fields are changed.
  Future<void> updateOverlayState({
    String? title,
    bool? isPlaying,
    double? speed,
    bool? reverbEnabled,
    bool? upscalerEnabled,
    bool? ronovaEnabled,
    bool? doubleTap,
    double? scale,
    double? opacity,
  }) {
    return _invoke<bool>('updateOverlayState', <String, Object?>{
      if (title != null) 'title': title,
      if (isPlaying != null) 'isPlaying': isPlaying,
      if (speed != null) 'speed': speed,
      if (reverbEnabled != null) 'reverbEnabled': reverbEnabled,
      if (upscalerEnabled != null) 'upscalerEnabled': upscalerEnabled,
      if (ronovaEnabled != null) 'ronovaEnabled': ronovaEnabled,
      if (doubleTap != null) 'doubleTap': doubleTap,
      if (scale != null) 'scale': scale,
      if (opacity != null) 'opacity': opacity,
    });
  }

  // ---- Internals ---------------------------------------------------------------------------------

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    }
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    final raw = call.arguments;
    final args = raw is Map ? Map<String, Object?>.from(raw) : const <String, Object?>{};
    final source = _parseSource(args['source']);
    double? asDouble(Object? v) => v is num ? v.toDouble() : null;

    NativeControlEvent? event;
    switch (call.method) {
      case 'onNext':
        event = NativeControlEvent(action: NativeControlAction.next, source: source);
      case 'onPrev':
        event = NativeControlEvent(action: NativeControlAction.previous, source: source);
      case 'onPlayPause':
        event = NativeControlEvent(
          action: NativeControlAction.playPause,
          source: source,
          play: args['play'] as bool?,
        );
      case 'onToggleSlow':
        event = NativeControlEvent(
          action: NativeControlAction.toggleSlow,
          source: source,
          slowed: args['slowed'] as bool?,
          speed: asDouble(args['speed']),
        );
      case 'onSetSpeed':
        event = NativeControlEvent(
          action: NativeControlAction.setSpeed,
          source: source,
          speed: asDouble(args['speed']),
        );
      case 'onToggleReverb':
        event = NativeControlEvent(
          action: NativeControlAction.toggleReverb,
          source: source,
          enabled: args['enabled'] as bool?,
        );
      case 'onToggleRonova':
        event = NativeControlEvent(
          action: NativeControlAction.toggleRonova,
          source: source,
          enabled: args['enabled'] as bool?,
        );
      case 'onSetUpscaler':
        event = NativeControlEvent(
          action: NativeControlAction.setUpscaler,
          source: source,
          enabled: args['enabled'] as bool?,
        );
      case 'onOverlayClosed':
        event = NativeControlEvent(action: NativeControlAction.overlayClosed, source: source);
      case 'onNotificationDismissed':
        event = NativeControlEvent(action: NativeControlAction.notificationDismissed, source: source);
      case 'onAudioRouteChanged':
        final hardware = args['hardware'];
        event = NativeControlEvent(
          action: NativeControlAction.audioRouteChanged,
          source: source,
          hardware: hardware is Map ? HeadsetHardwareInfo.fromMap(hardware) : null,
        );
      default:
        return null;
    }
    _dispatch(event);
    return null;
  }

  NativeControlSource _parseSource(Object? value) {
    switch (value) {
      case 'notification':
        return NativeControlSource.notification;
      case 'overlay':
        return NativeControlSource.overlay;
      case 'mediaButton':
        return NativeControlSource.mediaButton;
      case 'noisy':
        return NativeControlSource.noisy;
      case 'hardware':
        return NativeControlSource.hardware;
      default:
        return NativeControlSource.unknown;
    }
  }

  void _dispatch(NativeControlEvent event) {
    if (_controller.hasListener) {
      _controller.add(event);
    } else {
      _backlog.add(event);
      if (_backlog.length > _maxBacklog) _backlog.removeAt(0);
    }
  }

  void _flushBacklog() {
    if (_backlog.isEmpty) return;
    final pending = List<NativeControlEvent>.of(_backlog);
    _backlog.clear();
    scheduleMicrotask(() {
      for (final event in pending) {
        _controller.add(event);
      }
    });
  }
}

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// ---- Native / Dart signature pairs (must match native/include/ronova_dsp_bridge.h) ----

typedef _NativeVoidFn = Void Function();
typedef _DartVoidFn = void Function();

typedef _NativeInitFn = Int32 Function(Int32 sampleRateHz, Int32 framesPerBurst);
typedef _DartInitFn = int Function(int sampleRateHz, int framesPerBurst);

typedef _NativeLoadFileFn = Int32 Function(Pointer<Utf8> path);
typedef _DartLoadFileFn = int Function(Pointer<Utf8> path);

typedef _NativeSeekFn = Void Function(Int64 positionMs);
typedef _DartSeekFn = void Function(int positionMs);

typedef _NativeI64Fn = Int64 Function();
typedef _DartI64Fn = int Function();

typedef _NativeI32Fn = Int32 Function();
typedef _DartI32Fn = int Function();

typedef _NativeSetFloatFn = Void Function(Float value);
typedef _DartSetFloatFn = void Function(double value);

typedef _NativeSetI32Fn = Void Function(Int32 value);
typedef _DartSetI32Fn = void Function(int value);

typedef _NativeGetFloatFn = Float Function();
typedef _DartGetFloatFn = double Function();

typedef _NativeSetEqBandFn = Void Function(Int32 band, Float freqHz, Float gainDb, Float q);
typedef _DartSetEqBandFn = void Function(int band, double freqHz, double gainDb, double q);

typedef _NativeSetEqBandTypeFn = Void Function(Int32 band, Int32 type);
typedef _DartSetEqBandTypeFn = void Function(int band, int type);

typedef _NativeI32FromI32Fn = Int32 Function(Int32 value);
typedef _DartI32FromI32Fn = int Function(int value);

typedef _NativeStringFn = Pointer<Utf8> Function();
typedef _DartStringFn = Pointer<Utf8> Function();

/// EQ band filter topology (matches RONOVA_FILTER_* in the C header).
enum RonovaFilterType {
  peaking(0),
  lowShelf(1),
  highShelf(2),
  highPass(3),
  lowPass(4);

  const RonovaFilterType(this.id);
  final int id;
}

/// Output-device profile used by Ronova hardware calibration.
enum RonovaHardwareProfile {
  auto(0),
  speaker(1),
  wiredHeadphones(2),
  bluetooth(3),
  usbDac(4);

  const RonovaHardwareProfile(this.id);
  final int id;
}

/// Typed Dart wrapper around `libronova_dsp.so`.
class RonovaFfiBindings {
  RonovaFfiBindings._(DynamicLibrary lib)
      : _getVersion = lib.lookupFunction<_NativeStringFn, _DartStringFn>('ronova_get_version'),
        _getDiagnostics = lib.lookupFunction<_NativeStringFn, _DartStringFn>('ronova_get_diagnostics'),
        _engineInit = lib.lookupFunction<_NativeInitFn, _DartInitFn>('ronova_engine_init'),
        _engineShutdown = lib.lookupFunction<_NativeVoidFn, _DartVoidFn>('ronova_engine_shutdown'),
        _loadFile = lib.lookupFunction<_NativeLoadFileFn, _DartLoadFileFn>('ronova_load_file'),
        _play = lib.lookupFunction<_NativeVoidFn, _DartVoidFn>('ronova_play'),
        _pause = lib.lookupFunction<_NativeVoidFn, _DartVoidFn>('ronova_pause'),
        _seekMs = lib.lookupFunction<_NativeSeekFn, _DartSeekFn>('ronova_seek_ms'),
        _getPositionMs = lib.lookupFunction<_NativeI64Fn, _DartI64Fn>('ronova_get_position_ms'),
        _getDurationMs = lib.lookupFunction<_NativeI64Fn, _DartI64Fn>('ronova_get_duration_ms'),
        _isPlaying = lib.lookupFunction<_NativeI32Fn, _DartI32Fn>('ronova_is_playing'),
        _setSpeed = lib.lookupFunction<_NativeSetFloatFn, _DartSetFloatFn>('ronova_set_speed'),
        _setReverbEnabled = lib.lookupFunction<_NativeSetI32Fn, _DartSetI32Fn>('ronova_set_reverb_enabled'),
        _setRoomSpace = lib.lookupFunction<_NativeSetFloatFn, _DartSetFloatFn>('ronova_set_room_space'),
        _setMasterVolume = lib.lookupFunction<_NativeSetFloatFn, _DartSetFloatFn>('ronova_set_master_volume'),
        _setVolumeUpscalerGain =
            lib.lookupFunction<_NativeSetFloatFn, _DartSetFloatFn>('ronova_set_volume_upscaler_gain'),
        _getPeakReductionDb =
            lib.lookupFunction<_NativeGetFloatFn, _DartGetFloatFn>('ronova_get_peak_reduction_db'),
        _setPreampDb = lib.lookupFunction<_NativeSetFloatFn, _DartSetFloatFn>('ronova_set_preamp_db'),
        _setEqBand = lib.lookupFunction<_NativeSetEqBandFn, _DartSetEqBandFn>('ronova_set_eq_band'),
        _setEqBandType =
            lib.lookupFunction<_NativeSetEqBandTypeFn, _DartSetEqBandTypeFn>('ronova_set_eq_band_type'),
        _setSubBassBoost = lib.lookupFunction<_NativeSetFloatFn, _DartSetFloatFn>('ronova_set_sub_bass_boost'),
        _setStereoWidth = lib.lookupFunction<_NativeSetFloatFn, _DartSetFloatFn>('ronova_set_stereo_width'),
        _setMonoMode = lib.lookupFunction<_NativeSetI32Fn, _DartSetI32Fn>('ronova_set_mono_mode'),
        _engageRonovaMode =
            lib.lookupFunction<_NativeI32FromI32Fn, _DartI32FromI32Fn>('ronova_engage_ronova_mode'),
        _setHardwareProfile =
            lib.lookupFunction<_NativeSetI32Fn, _DartSetI32Fn>('ronova_set_hardware_profile');

  static const String libraryName = 'libronova_dsp.so';
  static const int eqBandCount = 16;
  static const int statusOk = 0;

  /// Message of the most recent [tryLoad] failure, if any.
  static String? lastLoadError;

  /// Loads the native library; returns null (and sets [lastLoadError]) on failure.
  static RonovaFfiBindings? tryLoad() {
    try {
      final bindings = RonovaFfiBindings._(DynamicLibrary.open(libraryName));
      lastLoadError = null;
      return bindings;
    } catch (error) {
      lastLoadError = '$error';
      return null;
    }
  }

  final _DartStringFn _getVersion;
  final _DartStringFn _getDiagnostics;
  final _DartInitFn _engineInit;
  final _DartVoidFn _engineShutdown;
  final _DartLoadFileFn _loadFile;
  final _DartVoidFn _play;
  final _DartVoidFn _pause;
  final _DartSeekFn _seekMs;
  final _DartI64Fn _getPositionMs;
  final _DartI64Fn _getDurationMs;
  final _DartI32Fn _isPlaying;
  final _DartSetFloatFn _setSpeed;
  final _DartSetI32Fn _setReverbEnabled;
  final _DartSetFloatFn _setRoomSpace;
  final _DartSetFloatFn _setMasterVolume;
  final _DartSetFloatFn _setVolumeUpscalerGain;
  final _DartGetFloatFn _getPeakReductionDb;
  final _DartSetFloatFn _setPreampDb;
  final _DartSetEqBandFn _setEqBand;
  final _DartSetEqBandTypeFn _setEqBandType;
  final _DartSetFloatFn _setSubBassBoost;
  final _DartSetFloatFn _setStereoWidth;
  final _DartSetI32Fn _setMonoMode;
  final _DartI32FromI32Fn _engageRonovaMode;
  final _DartSetI32Fn _setHardwareProfile;

  // ---- Diagnostics ----

  String get nativeVersion => _getVersion().toDartString();
  String get nativeDiagnostics => _getDiagnostics().toDartString();

  // ---- Lifecycle ----

  /// Returns true when the engine initialised (or was already initialised).
  bool engineInit({int sampleRateHz = 48000, int framesPerBurst = 192}) {
    return _engineInit(sampleRateHz, framesPerBurst) == statusOk;
  }

  void engineShutdown() => _engineShutdown();

  // ---- Playback & seeking ----

  /// Returns true when the file exists and was accepted by the engine.
  bool loadFile(String path) {
    final nativePath = path.toNativeUtf8();
    try {
      return _loadFile(nativePath) == statusOk;
    } finally {
      malloc.free(nativePath);
    }
  }

  void play() => _play();
  void pause() => _pause();
  void seekMs(int positionMs) => _seekMs(positionMs);
  int get positionMs => _getPositionMs();
  int get durationMs => _getDurationMs();
  bool get isPlaying => _isPlaying() == 1;

  // ---- Speed & pitch-linked reverb ----

  void setSpeed(double speedRatio) => _setSpeed(speedRatio);
  void setReverbEnabled(bool enabled) => _setReverbEnabled(enabled ? 1 : 0);
  void setRoomSpace(double roomSpace) => _setRoomSpace(roomSpace);

  // ---- Volume upscaler / brickwall limiter ----

  void setMasterVolume(double linearGain) => _setMasterVolume(linearGain);
  void setVolumeUpscalerGain(double gainDb) => _setVolumeUpscalerGain(gainDb);
  double get peakReductionDb => _getPeakReductionDb();

  // ---- EQ / sub-bass / stereo ----

  /// Pre-amp trim in front of the EQ, -12 .. +12 dB (clamped natively).
  void setPreampDb(double gainDb) => _setPreampDb(gainDb);

  void setEqBand(int band, {required double freqHz, required double gainDb, double q = 1.41}) {
    _setEqBand(band, freqHz, gainDb, q);
  }

  void setEqBandType(int band, RonovaFilterType type) => _setEqBandType(band, type.id);

  void setSubBassBoost(double amount) => _setSubBassBoost(amount);
  void setStereoWidth(double width) => _setStereoWidth(width);
  void setMonoMode(bool enabled) => _setMonoMode(enabled ? 1 : 0);

  // ---- Ronova hardware calibration ----

  bool engageRonovaMode(bool enabled) => _engageRonovaMode(enabled ? 1 : 0) == statusOk;
  void setHardwareProfile(RonovaHardwareProfile profile) => _setHardwareProfile(profile.id);
}

/// Spec-facing name for the typed C++ DSP bridge (Batch 4 providers refer to it by this name).
typedef RonovaDspBridge = RonovaFfiBindings;

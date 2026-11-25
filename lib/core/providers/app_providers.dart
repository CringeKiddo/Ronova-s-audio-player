import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/local_track_database.dart';
import '../ffi/ronova_ffi_bindings.dart';
import '../storage/preferences_store.dart';

/// Snapshot of what happened during cold-start bootstrap.
class BootReport {
  const BootReport({
    required this.ffiLinked,
    required this.engineInitOk,
    required this.sqliteReady,
    required this.prefsReady,
    this.ffiError,
    this.nativeVersion = '',
    this.nativeDiagnostics = '',
    this.sqliteError,
    this.sqliteOpenMs = 0,
    this.trackCount = 0,
    this.prefsError,
    this.bootCount = 0,
    this.bootMs = 0,
  });

  static const BootReport empty = BootReport(
    ffiLinked: false,
    engineInitOk: false,
    sqliteReady: false,
    prefsReady: false,
  );

  final bool ffiLinked;
  final bool engineInitOk;
  final bool sqliteReady;
  final bool prefsReady;
  final String? ffiError;
  final String nativeVersion;
  final String nativeDiagnostics;
  final String? sqliteError;
  final double sqliteOpenMs;
  final int trackCount;
  final String? prefsError;
  final int bootCount;
  final int bootMs;

  bool get allOk => ffiLinked && engineInitOk && sqliteReady && prefsReady;
}

/// Overridden in `main()` with the real bootstrap result.
final bootReportProvider = Provider<BootReport>((ref) => BootReport.empty);

/// Null when the database failed to open.
final trackDatabaseProvider = Provider<LocalTrackDatabase?>((ref) => null);

/// Null when `libronova_dsp.so` failed to load.
final ffiBindingsProvider = Provider<RonovaFfiBindings?>((ref) => null);

/// Null when SharedPreferences failed to open.
final preferencesStoreProvider = Provider<PreferencesStore?>((ref) => null);

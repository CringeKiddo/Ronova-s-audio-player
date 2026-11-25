import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import 'core/database/local_track_database.dart';
import 'core/ffi/ronova_ffi_bindings.dart';
import 'core/models/theme_config.dart';
import 'core/providers/app_providers.dart';
import 'core/providers/audio_library_provider.dart';
import 'core/providers/equalizer_provider.dart';
import 'core/providers/theme_settings_provider.dart';
import 'core/storage/preferences_store.dart';
import 'ui/screens/library_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final bootWatch = Stopwatch()..start();

  // Edge-to-edge: the frosted UI draws under the system bars.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    ),
  );

  // 1) Preferences (themes, favorites, playback settings): needed first so frame one is themed.
  PreferencesStore? prefs;
  String? prefsError;
  var bootCount = 0;
  try {
    prefs = await PreferencesStore.open();
    bootCount = await prefs.incrementBootCount();
  } catch (error) {
    prefs = null;
    prefsError = '$error';
  }

  // 2) SQLite instant-cache.
  LocalTrackDatabase? database;
  String? sqliteError;
  var trackCount = 0;
  var sqliteOpenMs = 0.0;
  try {
    database = await LocalTrackDatabase.open();
    sqliteOpenMs = database.openElapsedMicros / 1000.0;
    trackCount = await database.count();
  } catch (error) {
    database = null;
    sqliteError = '$error';
  }

  // 3) Native 32-bit float DSP library over FFI.
  final ffi = RonovaFfiBindings.tryLoad();
  final ffiError = RonovaFfiBindings.lastLoadError;
  var engineInitOk = false;
  var nativeVersion = '';
  var nativeDiagnostics = '';
  if (ffi != null) {
    try {
      engineInitOk = ffi.engineInit(sampleRateHz: 48000, framesPerBurst: 192);
      nativeVersion = ffi.nativeVersion;
      nativeDiagnostics = ffi.nativeDiagnostics;
    } catch (error) {
      nativeDiagnostics = 'engine init failed: $error';
    }
  }

  bootWatch.stop();

  final container = ProviderContainer(
    overrides: <Override>[
      preferencesStoreProvider.overrideWithValue(prefs),
      ffiBindingsProvider.overrideWithValue(ffi),
      trackDatabaseProvider.overrideWithValue(database),
      bootReportProvider.overrideWithValue(
        BootReport(
          ffiLinked: ffi != null,
          engineInitOk: engineInitOk,
          sqliteReady: database != null,
          prefsReady: prefs != null,
          ffiError: ffiError,
          nativeVersion: nativeVersion,
          nativeDiagnostics: nativeDiagnostics,
          sqliteError: sqliteError,
          sqliteOpenMs: sqliteOpenMs,
          trackCount: trackCount,
          prefsError: prefsError,
          bootCount: bootCount,
          bootMs: bootWatch.elapsedMilliseconds,
        ),
      ),
    ],
  );

  // Equalizer: creating the controller restores the saved preset, favourites and every dial
  // (16 bands, 808 sub-bass, stereo width, pre-amp) and pushes them to the native engine.
  container.read(equalizerProvider);

  // Stale-while-revalidate: show cached songs on the first frame, then re-scan in the background.
  final library = container.read(audioLibraryProvider.notifier);
  await library.initialize();

  runApp(UncontrolledProviderScope(container: container, child: const RonovaApp()));

  unawaited(library.refreshFromDevice());
}

class RonovaApp extends ConsumerWidget {
  const RonovaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(themeSettingsProvider);
    final palette = ref.watch(ronovaPaletteProvider);

    final base = ThemeData(
      useMaterial3: true,
      brightness: palette.brightness,
      scaffoldBackgroundColor: palette.bg,
      colorScheme: ColorScheme.fromSeed(
        seedColor: palette.primary,
        brightness: palette.brightness,
        surface: palette.bg,
      ),
    );
    TextTheme textTheme = base.textTheme;
    try {
      textTheme = GoogleFonts.interTextTheme(base.textTheme);
    } catch (_) {
      textTheme = base.textTheme;
    }
    textTheme = textTheme.apply(bodyColor: palette.textPrimary, displayColor: palette.textPrimary);

    final overlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      statusBarIconBrightness: config.mode == AppThemeMode.abyss ? Brightness.light : Brightness.dark,
      systemNavigationBarIconBrightness: config.mode == AppThemeMode.abyss ? Brightness.light : Brightness.dark,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: MaterialApp(
        title: 'Ronova Audio',
        debugShowCheckedModeBanner: false,
        theme: base.copyWith(textTheme: textTheme),
        themeAnimationDuration: const Duration(milliseconds: 420),
        themeAnimationCurve: Curves.easeOutCubic,
        home: const LibraryScreen(),
      ),
    );
  }
}

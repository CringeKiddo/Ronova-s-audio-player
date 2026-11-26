package com.ronova.audio.bridge

import android.content.ClipData
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.MediaStore
import android.provider.Settings
import com.ronova.audio.hardware.HeadsetHardwareAnalyzer
import com.ronova.audio.scanner.FastMediaStoreScanner
import com.ronova.audio.services.RonovaFloatingOverlayService
import com.ronova.audio.services.RonovaMediaPlaybackService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Routes every `com.ronova.audio/native` MethodChannel call from Flutter to the Kotlin layer.
 * Calls in the other direction (notification / overlay / hardware events) go through
 * [RonovaEventBus].
 */
object NativeChannelRouter {

    const val CHANNEL_NAME = "com.ronova.audio/native"

    private lateinit var appContext: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val scanner by lazy { FastMediaStoreScanner(appContext) }
    private val analyzer by lazy { HeadsetHardwareAnalyzer(appContext) }

    @Synchronized
    fun attach(engine: FlutterEngine, context: Context) {
        appContext = context.applicationContext
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler { call, result -> onMethodCall(call, result) }
        RonovaEventBus.attach(channel)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "nativeReady" -> {
                RonovaEventBus.markDartReady()
                result.success(true)
            }

            // ---- Library ------------------------------------------------------------------------
            "scanAllTracks" -> scope.launch {
                try {
                    val tracks = scanner.scanAllTracks()
                    val maps = withContext(Dispatchers.Default) { tracks.map { it.toMap() } }
                    result.success(maps)
                } catch (e: SecurityException) {
                    result.error("PERMISSION_DENIED", "Audio library permission not granted", e.message)
                } catch (e: Exception) {
                    result.error("SCAN_FAILED", e.message ?: "MediaStore scan failed", null)
                }
            }

            "getAlbumArt" -> {
                val path = call.argument<String>("path") ?: ""
                scope.launch {
                    val bytes = withContext(Dispatchers.IO) { scanner.extractAlbumArtBytes(path) }
                    result.success(bytes)
                }
            }

            "shareTrack" -> {
                val mediaStoreId = (call.argument<Number>("mediaStoreId") ?: -1).toLong()
                val title = call.argument<String>("title") ?: ""
                if (mediaStoreId < 0) {
                    result.success(false)
                } else {
                    try {
                        val uri = ContentUris.withAppendedId(
                            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                            mediaStoreId,
                        )
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "audio/*"
                            putExtra(Intent.EXTRA_STREAM, uri)
                            putExtra(Intent.EXTRA_SUBJECT, title)
                            clipData = ClipData.newRawUri(title, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        val chooser = Intent.createChooser(send, "Share track")
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        appContext.startActivity(chooser)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
            }

            // ---- Hardware -------------------------------------------------------------------------
            "analyzeHeadsetHardware" -> scope.launch {
                try {
                    result.success(analyzer.analyze().toMap())
                } catch (e: Exception) {
                    result.error("ANALYZE_FAILED", e.message ?: "Hardware analysis failed", null)
                }
            }

            "startHeadsetMonitoring" -> {
                analyzer.startMonitoring { info ->
                    RonovaEventBus.emit(
                        "onAudioRouteChanged",
                        mapOf("source" to "hardware", "hardware" to info.toMap()),
                    )
                }
                result.success(true)
            }

            "stopHeadsetMonitoring" -> {
                analyzer.stopMonitoring()
                result.success(true)
            }

            // ---- Notification ---------------------------------------------------------------------
            "updateNotificationState" -> {
                val snapshot = RonovaMediaPlaybackService.PlaybackSnapshot(
                    title = call.argument<String>("title") ?: "",
                    artist = call.argument<String>("artist") ?: "",
                    isPlaying = call.argument<Boolean>("isPlaying") ?: false,
                    isSlowed = call.argument<Boolean>("isSlowed") ?: false,
                    positionMs = (call.argument<Number>("positionMs") ?: 0).toLong(),
                    durationMs = (call.argument<Number>("durationMs") ?: 0).toLong(),
                    speed = (call.argument<Number>("speed") ?: 1.0).toFloat(),
                    artBytes = call.argument<ByteArray>("artBytes"),
                    keepArt = call.argument<Boolean>("keepArt") ?: false,
                )
                RonovaMediaPlaybackService.updateState(appContext, snapshot)
                result.success(true)
            }

            "stopNotification" -> {
                RonovaMediaPlaybackService.stop(appContext)
                result.success(true)
            }

            // ---- Gaming overlay -------------------------------------------------------------------
            "canDrawOverlays" -> result.success(Settings.canDrawOverlays(appContext))

            "openOverlaySettings" -> {
                // Try the per-app page first, then the generic list, then App info (where the
                // "Allow restricted settings" menu lives on sideloaded installs).
                val pkg = Uri.parse("package:${appContext.packageName}")
                val attempts = listOf(
                    Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, pkg),
                    Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION),
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkg),
                )
                var opened = false
                for (intent in attempts) {
                    try {
                        appContext.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        opened = true
                        break
                    } catch (_: Exception) {
                        // Next fallback.
                    }
                }
                result.success(opened)
            }

            "openAppDetails" -> {
                try {
                    appContext.startActivity(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:${appContext.packageName}"),
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }

            "startFloatingOverlay" -> {
                val granted = Settings.canDrawOverlays(appContext)
                var started = false
                if (granted) {
                    started = RonovaFloatingOverlayService.start(
                        appContext,
                        doubleTap = call.argument<Boolean>("doubleTap") ?: true,
                        scale = (call.argument<Number>("scale") ?: 1.0).toFloat(),
                        opacity = (call.argument<Number>("opacity") ?: 0.9).toFloat(),
                    )
                }
                result.success(mapOf("started" to started, "needsPermission" to !granted))
            }

            "stopFloatingOverlay" -> {
                RonovaFloatingOverlayService.stop(appContext)
                result.success(true)
            }

            "isOverlayRunning" -> result.success(RonovaFloatingOverlayService.isRunning)

            "updateOverlayState" -> {
                val previous = RonovaFloatingOverlayService.currentState()
                RonovaFloatingOverlayService.updateState(
                    RonovaFloatingOverlayService.OverlayState(
                        title = call.argument<String>("title") ?: previous.title,
                        isPlaying = call.argument<Boolean>("isPlaying") ?: previous.isPlaying,
                        speed = call.argument<Number>("speed")?.toFloat() ?: previous.speed,
                        reverbEnabled = call.argument<Boolean>("reverbEnabled") ?: previous.reverbEnabled,
                        upscalerEnabled = call.argument<Boolean>("upscalerEnabled") ?: previous.upscalerEnabled,
                        ronovaEnabled = call.argument<Boolean>("ronovaEnabled") ?: previous.ronovaEnabled,
                    ),
                )
                val scale = call.argument<Number>("scale")?.toFloat()
                val opacity = call.argument<Number>("opacity")?.toFloat()
                val doubleTap = call.argument<Boolean>("doubleTap")
                if (scale != null || opacity != null || doubleTap != null) {
                    RonovaFloatingOverlayService.updateConfig(doubleTap, scale, opacity)
                }
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }
}

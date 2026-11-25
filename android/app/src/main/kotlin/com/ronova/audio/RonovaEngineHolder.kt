package com.ronova.audio

import android.content.Context
import com.ronova.audio.bridge.NativeChannelRouter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * Owns the one long-lived FlutterEngine. Because it is cached (not tied to the Activity), the Dart
 * isolate - and with it the C++ audio engine controller, the notification buttons and the gaming
 * overlay - keeps working after the user swipes the app out of the recents list.
 */
object RonovaEngineHolder {

    const val ENGINE_ID = "ronova_main_engine"

    @Synchronized
    fun ensure(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let { return it }

        val appContext = context.applicationContext
        val engine = FlutterEngine(appContext)
        // A cached engine is not auto-registered by FlutterActivity, so register plugins here.
        GeneratedPluginRegistrant.registerWith(engine)
        NativeChannelRouter.attach(engine, appContext)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        cache.put(ENGINE_ID, engine)
        return engine
    }
}

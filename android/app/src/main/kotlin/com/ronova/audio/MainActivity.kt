package com.ronova.audio

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

/**
 * Hosts the Flutter UI on top of the cached engine from [RonovaEngineHolder]. The
 * `com.ronova.audio/native` MethodChannel (scan, album art, hardware analysis, notification and
 * overlay control) is wired up by `NativeChannelRouter` when that engine is created, so it is
 * available even while no Activity exists.
 */
class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        RonovaEngineHolder.ensure(applicationContext)  // must exist before the delegate looks it up
        super.onCreate(savedInstanceState)
    }

    override fun getCachedEngineId(): String? = RonovaEngineHolder.ENGINE_ID

    // Keep the engine (and the audio control isolate) alive when the Activity goes away.
    override fun shouldDestroyEngineWithHost(): Boolean = false
}

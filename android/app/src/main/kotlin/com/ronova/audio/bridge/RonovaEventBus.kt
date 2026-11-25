package com.ronova.audio.bridge

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * Process-wide pipe from the Android services (notification, media session, overlay, audio
 * route monitor) to Dart. Events are held until Dart has called `nativeReady`, so a button press
 * that arrives while the Dart isolate is still starting is delivered instead of dropped.
 *
 * Everything runs on the main thread, which is where MethodChannel requires it.
 */
object RonovaEventBus {

    private const val MAX_BACKLOG = 24

    private class PendingEvent(val method: String, val args: Map<String, Any?>?)

    private val mainHandler = Handler(Looper.getMainLooper())
    private val backlog = ArrayDeque<PendingEvent>()
    private var channel: MethodChannel? = null
    private var dartReady = false

    fun attach(target: MethodChannel) = runOnMain {
        channel = target
        dartReady = false
    }

    fun markDartReady() = runOnMain {
        dartReady = true
        flush()
    }

    /** Sends [method] to Dart (`onNext`, `onPrev`, `onPlayPause`, `onToggleSlow`, ...). */
    fun emit(method: String, args: Map<String, Any?>? = null) = runOnMain {
        val target = channel
        if (target != null && dartReady) {
            target.invokeMethod(method, args)
        } else {
            backlog.addLast(PendingEvent(method, args))
            while (backlog.size > MAX_BACKLOG) backlog.removeFirst()
        }
    }

    private fun flush() {
        val target = channel ?: return
        while (backlog.isNotEmpty()) {
            val event = backlog.removeFirst()
            target.invokeMethod(event.method, event.args)
        }
    }

    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else mainHandler.post(block)
    }
}

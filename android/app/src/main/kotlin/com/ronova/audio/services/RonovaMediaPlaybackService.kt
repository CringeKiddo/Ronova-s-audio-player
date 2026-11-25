package com.ronova.audio.services

import android.annotation.SuppressLint
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.media.app.NotificationCompat.MediaStyle
import com.ronova.audio.R
import com.ronova.audio.bridge.RonovaEventBus

/**
 * Foreground media-playback service: MediaSession + MediaStyle notification.
 *
 * While audio is playing the notification is ongoing and carries FLAG_NO_CLEAR, so it cannot be
 * swiped away. Compact (collapsed) layout shows exactly three buttons: Slow-down toggle,
 * Previous, Next. Play/Pause sits between them in the expanded layout. Every press is forwarded to
 * Flutter through [RonovaEventBus] (which drives the C++ engine), and Flutter reports the real
 * state back through [updateState].
 */
class RonovaMediaPlaybackService : Service() {

    data class PlaybackSnapshot(
        val title: String,
        val artist: String,
        val isPlaying: Boolean,
        val isSlowed: Boolean,
        val artBytes: ByteArray? = null,
        /** When true, [artBytes] is ignored and the current artwork is kept. */
        val keepArt: Boolean = false,
    )

    companion object {
        const val ACTION_TOGGLE_SLOW = "com.ronova.audio.action.TOGGLE_SLOW"
        const val ACTION_PREV = "com.ronova.audio.action.PREV"
        const val ACTION_NEXT = "com.ronova.audio.action.NEXT"
        const val ACTION_PLAY_PAUSE = "com.ronova.audio.action.PLAY_PAUSE"
        const val ACTION_DISMISSED = "com.ronova.audio.action.DISMISSED"
        const val ACTION_REFRESH = "com.ronova.audio.action.REFRESH"

        /** Speed used by the notification's slow-down toggle (slowed + reverb). */
        const val SLOW_SPEED = 0.85f

        private const val CHANNEL_ID = "ronova_playback"
        private const val NOTIFICATION_ID = 4101
        private const val MAX_ART_PX = 512

        @Volatile
        private var instance: RonovaMediaPlaybackService? = null

        @Volatile
        private var lastSnapshot = PlaybackSnapshot("", "", isPlaying = false, isSlowed = false)

        /** Applies [snapshot]; starts the foreground service on demand when audio is playing. */
        fun updateState(context: Context, snapshot: PlaybackSnapshot) {
            lastSnapshot = if (snapshot.keepArt) {
                snapshot.copy(artBytes = lastSnapshot.artBytes, keepArt = false)
            } else {
                snapshot
            }
            val running = instance
            if (running != null) {
                running.mainHandler.post { running.applySnapshot(snapshot, forceForeground = false) }
            } else if (snapshot.isPlaying) {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, RonovaMediaPlaybackService::class.java).setAction(ACTION_REFRESH),
                )
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RonovaMediaPlaybackService::class.java))
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var session: MediaSessionCompat
    private lateinit var notificationManager: NotificationManagerCompat

    private var snapshot = PlaybackSnapshot("", "", isPlaying = false, isSlowed = false)
    private var artBitmap: Bitmap? = null
    private var isForeground = false

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY && snapshot.isPlaying) {
                emitPlayPause(play = false, source = "noisy")
            }
        }
    }

    private val sessionCallback = object : MediaSessionCompat.Callback() {
        override fun onPlay() = emitPlayPause(play = true, source = "mediaButton")
        override fun onPause() = emitPlayPause(play = false, source = "mediaButton")
        override fun onStop() = emitPlayPause(play = false, source = "mediaButton")
        override fun onSkipToNext() = RonovaEventBus.emit("onNext", mapOf("source" to "mediaButton"))
        override fun onSkipToPrevious() = RonovaEventBus.emit("onPrev", mapOf("source" to "mediaButton"))
        override fun onCustomAction(action: String?, extras: Bundle?) {
            if (action == ACTION_TOGGLE_SLOW) handleToggleSlow("mediaButton")
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        notificationManager = NotificationManagerCompat.from(this)
        createChannel()
        session = MediaSessionCompat(this, "RonovaAudio").apply {
            setCallback(sessionCallback)
            isActive = true
        }
        ContextCompat.registerReceiver(
            this,
            noisyReceiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        snapshot = lastSnapshot
        decodeArt(snapshot.artBytes)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PREV -> RonovaEventBus.emit("onPrev", mapOf("source" to "notification"))
            ACTION_NEXT -> RonovaEventBus.emit("onNext", mapOf("source" to "notification"))
            ACTION_PLAY_PAUSE -> emitPlayPause(play = !snapshot.isPlaying, source = "notification")
            ACTION_TOGGLE_SLOW -> handleToggleSlow("notification")
            ACTION_DISMISSED -> {
                RonovaEventBus.emit("onNotificationDismissed", mapOf("source" to "notification"))
                stopSelf()
            }
            else -> {
                // ACTION_REFRESH / restart: startForegroundService() requires startForeground() promptly.
                applySnapshot(lastSnapshot, forceForeground = true)
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        mainHandler.removeCallbacksAndMessages(null)
        try {
            unregisterReceiver(noisyReceiver)
        } catch (_: IllegalArgumentException) {
            // Already unregistered.
        }
        session.isActive = false
        session.release()
        if (isForeground) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            isForeground = false
        }
        notificationManager.cancel(NOTIFICATION_ID)
        instance = null
        super.onDestroy()
    }

    // ---- State -------------------------------------------------------------------------------

    private fun applySnapshot(newSnapshot: PlaybackSnapshot, forceForeground: Boolean) {
        if (newSnapshot.keepArt) {
            snapshot = newSnapshot.copy(artBytes = snapshot.artBytes, keepArt = false)
        } else {
            snapshot = newSnapshot
            decodeArt(newSnapshot.artBytes)
        }
        lastSnapshot = snapshot
        updateSession()

        val notification = buildNotification(snapshot)
        if (snapshot.isPlaying || forceForeground) {
            if (!isForeground) {
                startForegroundCompat(notification)
            } else {
                postNotification(notification)
            }
        }
        if (!snapshot.isPlaying && isForeground) {
            // Paused: let the notification be dismissed again, keep it visible.
            stopForeground(STOP_FOREGROUND_DETACH)
            isForeground = false
            postNotification(notification)
        } else if (!snapshot.isPlaying && !forceForeground) {
            postNotification(notification)
        }
    }

    private fun handleToggleSlow(source: String) {
        val slowed = !snapshot.isSlowed
        // Optimistic: flip the button immediately; Flutter confirms through updateState().
        applySnapshot(snapshot.copy(isSlowed = slowed, keepArt = true), forceForeground = false)
        RonovaEventBus.emit(
            "onToggleSlow",
            mapOf(
                "source" to source,
                "slowed" to slowed,
                "speed" to if (slowed) SLOW_SPEED.toDouble() else 1.0,
            ),
        )
    }

    private fun emitPlayPause(play: Boolean, source: String) {
        RonovaEventBus.emit("onPlayPause", mapOf("source" to source, "play" to play))
    }

    // ---- MediaSession --------------------------------------------------------------------------

    private fun updateSession() {
        val metadata = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, snapshot.title.ifBlank { "Ronova Audio" })
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, snapshot.artist)
            .apply { artBitmap?.let { putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, it) } }
            .build()
        session.setMetadata(metadata)

        val actions = PlaybackStateCompat.ACTION_PLAY or
            PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_PLAY_PAUSE or
            PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
            PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
            PlaybackStateCompat.ACTION_STOP
        val state = PlaybackStateCompat.Builder()
            .setActions(actions)
            .setState(
                if (snapshot.isPlaying) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED,
                PlaybackStateCompat.PLAYBACK_POSITION_UNKNOWN,
                if (snapshot.isPlaying) (if (snapshot.isSlowed) SLOW_SPEED else 1.0f) else 0.0f,
            )
            // Android 13+ builds its media controls from the playback state, so expose the slow toggle there too.
            .addCustomAction(
                ACTION_TOGGLE_SLOW,
                if (snapshot.isSlowed) "Normal 1.0x" else "Slow 0.85x",
                if (snapshot.isSlowed) R.drawable.ic_notif_slow_on else R.drawable.ic_notif_slow,
            )
            .build()
        session.setPlaybackState(state)
    }

    // ---- Notification --------------------------------------------------------------------------

    private fun createChannel() {
        val channel = NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW)
            .setName("Playback")
            .setDescription("Ronova Audio playback controls")
            .setShowBadge(false)
            .setVibrationEnabled(false)
            .setLightsEnabled(false)
            .build()
        notificationManager.createNotificationChannel(channel)
    }

    private fun buildNotification(s: PlaybackSnapshot): Notification {
        val slowAction = NotificationCompat.Action.Builder(
            if (s.isSlowed) R.drawable.ic_notif_slow_on else R.drawable.ic_notif_slow,
            if (s.isSlowed) "Normal 1.0x" else "Slow 0.85x",
            servicePendingIntent(ACTION_TOGGLE_SLOW, 1),
        ).build()
        val prevAction = NotificationCompat.Action.Builder(
            R.drawable.ic_notif_prev, "Previous", servicePendingIntent(ACTION_PREV, 2),
        ).build()
        val playPauseAction = NotificationCompat.Action.Builder(
            if (s.isPlaying) R.drawable.ic_notif_pause else R.drawable.ic_notif_play,
            if (s.isPlaying) "Pause" else "Play",
            servicePendingIntent(ACTION_PLAY_PAUSE, 3),
        ).build()
        val nextAction = NotificationCompat.Action.Builder(
            R.drawable.ic_notif_next, "Next", servicePendingIntent(ACTION_NEXT, 4),
        ).build()

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_ronova)
            .setContentTitle(s.title.ifBlank { "Ronova Audio" })
            .setContentText(s.artist)
            .setSubText(if (s.isSlowed) "Slowed + Reverb · 0.85x" else null)
            .setLargeIcon(artBitmap)
            .setContentIntent(openAppPendingIntent())
            .setDeleteIntent(servicePendingIntent(ACTION_DISMISSED, 5))
            .setOngoing(s.isPlaying)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(slowAction)       // 0  compact
            .addAction(prevAction)       // 1  compact
            .addAction(playPauseAction)  // 2  expanded only
            .addAction(nextAction)       // 3  compact
            .setStyle(
                MediaStyle()
                    .setMediaSession(session.sessionToken)
                    .setShowActionsInCompactView(0, 1, 3),
            )

        val notification = builder.build()
        if (s.isPlaying) {
            // Un-swipeable while audio is playing.
            notification.flags = notification.flags or Notification.FLAG_NO_CLEAR or Notification.FLAG_ONGOING_EVENT
        }
        return notification
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        isForeground = true
    }

    @SuppressLint("MissingPermission")
    private fun postNotification(notification: Notification) {
        // On Android 13+ this is a silent no-op until the user grants POST_NOTIFICATIONS; the
        // foreground service itself keeps running either way.
        try {
            notificationManager.notify(NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
            // Notification permission denied.
        }
    }

    private fun servicePendingIntent(action: String, requestCode: Int): PendingIntent =
        PendingIntent.getService(
            this,
            requestCode,
            Intent(this, RonovaMediaPlaybackService::class.java).setAction(action),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    private fun openAppPendingIntent(): PendingIntent? {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            this, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    // ---- Artwork -------------------------------------------------------------------------------

    private fun decodeArt(bytes: ByteArray?) {
        artBitmap = null
        if (bytes == null || bytes.isEmpty()) return
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_ART_PX) sample *= 2
        artBitmap = BitmapFactory.decodeByteArray(
            bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample },
        )
    }
}

package com.ronova.audio.services

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.util.DisplayMetrics
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.view.animation.OvershootInterpolator
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.ronova.audio.R
import com.ronova.audio.bridge.RonovaEventBus
import com.ronova.audio.overlay.RonovaBubbleView
import java.util.Locale
import kotlin.math.hypot
import kotlin.math.roundToInt

private val COLOR_RED = 0xFFE53935.toInt()
private val COLOR_CARD = 0xF2141821.toInt()
private val COLOR_CARD_STROKE = 0x66E53935
private val COLOR_PILL_OFF_STROKE = 0x66FFFFFF
private val COLOR_PILL_OFF_TEXT = 0xCCFFFFFF.toInt()
private val COLOR_SUBTLE = 0x22FFFFFF

/**
 * Draggable red "R" music-note bubble that floats over games (WindowManager overlay) and expands
 * into a compact control card. Only the bubble / card windows themselves capture touches; touches
 * anywhere else go straight through to the game underneath.
 */
class RonovaFloatingOverlayService : Service() {

    data class OverlayState(
        val title: String = "",
        val isPlaying: Boolean = false,
        val speed: Float = 1.0f,
        val reverbEnabled: Boolean = false,
        val upscalerEnabled: Boolean = false,
        val ronovaEnabled: Boolean = false,
    )

    data class OverlayConfig(
        val doubleTapToOpen: Boolean = true,
        val scale: Float = 1.0f,
        val opacity: Float = 0.9f,
    )

    companion object {
        const val ACTION_START = "com.ronova.audio.overlay.START"
        const val ACTION_STOP = "com.ronova.audio.overlay.STOP"
        const val DOUBLE_TAP_WINDOW_MS = 280L

        private const val CHANNEL_ID = "ronova_overlay"
        private const val NOTIFICATION_ID = 4102
        private const val PREFS = "ronova_overlay"
        private const val KEY_X = "bubble_x"
        private const val KEY_Y = "bubble_y"
        private const val BASE_BUBBLE_DP = 58
        private const val EDGE_MARGIN_DP = 6
        private const val MIN_SPEED = 0.10f
        private const val MAX_SPEED = 1.50f
        private const val SPEED_STEPS = 140  // 0.10x .. 1.50x in 0.01 steps
        private const val SPEED_EMIT_INTERVAL_MS = 80L

        @Volatile
        private var instance: RonovaFloatingOverlayService? = null

        @Volatile
        private var lastState = OverlayState()

        @Volatile
        private var lastConfig = OverlayConfig()

        val isRunning: Boolean
            get() = instance != null

        fun currentState(): OverlayState = lastState

        /** Starts (or re-configures) the overlay. Returns false when "draw over other apps" is not granted. */
        fun start(context: Context, doubleTap: Boolean, scale: Float, opacity: Float): Boolean {
            if (!Settings.canDrawOverlays(context)) return false
            lastConfig = OverlayConfig(doubleTap, scale.coerceIn(0.5f, 2.0f), opacity.coerceIn(0.2f, 1.0f))
            ContextCompat.startForegroundService(
                context,
                Intent(context, RonovaFloatingOverlayService::class.java).setAction(ACTION_START),
            )
            return true
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RonovaFloatingOverlayService::class.java))
        }

        fun updateState(state: OverlayState) {
            lastState = state
            val running = instance ?: return
            running.mainHandler.post { running.applyState(state) }
        }

        fun updateConfig(doubleTap: Boolean?, scale: Float?, opacity: Float?) {
            val current = lastConfig
            lastConfig = OverlayConfig(
                doubleTapToOpen = doubleTap ?: current.doubleTapToOpen,
                scale = (scale ?: current.scale).coerceIn(0.5f, 2.0f),
                opacity = (opacity ?: current.opacity).coerceIn(0.2f, 1.0f),
            )
            val running = instance ?: return
            running.mainHandler.post { running.applyConfig() }
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var windowManager: WindowManager
    private lateinit var prefs: SharedPreferences

    private var config = OverlayConfig()
    private var state = OverlayState()

    private var bubble: RonovaBubbleView? = null
    private var bubbleParams: WindowManager.LayoutParams? = null
    private var bubbleAttached = false

    private var card: MiniCard? = null
    private var cardParams: WindowManager.LayoutParams? = null

    private var snapAnimator: ValueAnimator? = null
    private var lastTapUptime = 0L

    private val touchSlop by lazy { ViewConfiguration.get(this).scaledTouchSlop }

    // ---- Service lifecycle ---------------------------------------------------------------------

    override fun onCreate() {
        super.onCreate()
        instance = this
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // "Hide" button in the notification.
            RonovaEventBus.emit("onOverlayClosed", mapOf("source" to "notification"))
            stopSelf()
            return START_NOT_STICKY
        }

        startForegroundCompat()
        if (!Settings.canDrawOverlays(this)) {
            stopSelf()
            return START_NOT_STICKY
        }

        config = lastConfig
        state = lastState
        ensureBubble()
        applyConfig()
        applyState(state)
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        mainHandler.post {
            bubbleParams?.let { clampToScreen(it) }
            val view = bubble
            val params = bubbleParams
            if (view != null && params != null && bubbleAttached) safeUpdate(view, params)
            card?.let { collapseToBubble() }  // simplest correct behaviour across rotations
        }
    }

    override fun onDestroy() {
        snapAnimator?.cancel()
        mainHandler.removeCallbacksAndMessages(null)
        removeCardWindow()
        detachBubble()
        bubble = null
        instance = null
        super.onDestroy()
    }

    // ---- Foreground notification ---------------------------------------------------------------

    private fun createChannel() {
        val channel = NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_MIN)
            .setName("Floating overlay")
            .setDescription("Shown while the Ronova floating control is active")
            .setShowBadge(false)
            .build()
        NotificationManagerCompat.from(this).createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val hide = PendingIntent.getService(
            this,
            1,
            Intent(this, RonovaFloatingOverlayService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_ronova)
            .setContentTitle("Ronova floating control")
            .setContentText("Drag the red R anywhere. Tap to open the mini player.")
            .setContentIntent(open)
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .addAction(R.drawable.ic_overlay_close, "Hide", hide)
            .build()
    }

    private fun startForegroundCompat() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    // ---- State / config ------------------------------------------------------------------------

    private fun applyState(newState: OverlayState) {
        state = newState
        bubble?.setPlaying(newState.isPlaying)
        card?.bind(newState)
    }

    private fun applyConfig() {
        config = lastConfig
        val view = bubble
        val params = bubbleParams
        if (view != null && params != null) {
            val size = bubbleSizePx()
            params.width = size
            params.height = size
            view.alpha = config.opacity
            clampToScreen(params)
            if (bubbleAttached) safeUpdate(view, params)
        }
        card?.root?.alpha = config.opacity.coerceAtLeast(0.75f)
    }

    // ---- Bubble window -------------------------------------------------------------------------

    private fun ensureBubble() {
        if (bubble == null) {
            val size = bubbleSizePx()
            val (screenW, screenH) = screenSize()
            val view = RonovaBubbleView(this).apply {
                alpha = config.opacity
                setPlaying(state.isPlaying)
                setOnTouchListener(BubbleTouchListener())
                contentDescription = "Ronova floating control"
            }
            val params = overlayParams(size, size).apply {
                x = prefs.getInt(KEY_X, screenW - size - dp(EDGE_MARGIN_DP))
                y = prefs.getInt(KEY_Y, (screenH * 0.30f).toInt())
            }
            clampToScreen(params)
            bubble = view
            bubbleParams = params
        }
        if (card == null && !bubbleAttached) attachBubble()
    }

    private fun attachBubble() {
        val view = bubble ?: return
        val params = bubbleParams ?: return
        try {
            windowManager.addView(view, params)
            bubbleAttached = true
        } catch (_: Exception) {
            // Overlay permission revoked or window token problem: nothing to show.
            stopSelf()
        }
    }

    private fun detachBubble() {
        val view = bubble ?: return
        if (!bubbleAttached) return
        try {
            windowManager.removeViewImmediate(view)
        } catch (_: IllegalArgumentException) {
            // Already removed.
        }
        bubbleAttached = false
    }

    private fun overlayParams(width: Int, height: Int): WindowManager.LayoutParams =
        WindowManager.LayoutParams(
            width,
            height,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.TOP or Gravity.START }

    private fun bubbleSizePx(): Int = (dp(BASE_BUBBLE_DP) * config.scale).roundToInt()

    private fun clampToScreen(params: WindowManager.LayoutParams) {
        val (screenW, screenH) = screenSize()
        params.x = params.x.coerceIn(0, (screenW - params.width).coerceAtLeast(0))
        params.y = params.y.coerceIn(0, (screenH - params.height).coerceAtLeast(0))
    }

    private fun savePosition() {
        val params = bubbleParams ?: return
        prefs.edit().putInt(KEY_X, params.x).putInt(KEY_Y, params.y).apply()
    }

    private fun snapToEdge() {
        val view = bubble ?: return
        val params = bubbleParams ?: return
        val (screenW, _) = screenSize()
        val size = params.width
        val margin = dp(EDGE_MARGIN_DP)
        val target = if (params.x + size / 2 < screenW / 2) margin else screenW - size - margin
        snapAnimator?.cancel()
        snapAnimator = ValueAnimator.ofInt(params.x, target).apply {
            duration = 300L
            interpolator = OvershootInterpolator(0.9f)
            addUpdateListener {
                params.x = (it.animatedValue as Int).coerceIn(0, (screenW - size).coerceAtLeast(0))
                safeUpdate(view, params)
            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    savePosition()
                }
            })
            start()
        }
    }

    private fun onBubbleTapped(uptime: Long) {
        if (!config.doubleTapToOpen) {
            expandCard()
            return
        }
        // Double-tap mode: a single brush during gameplay must never open the menu.
        if (uptime - lastTapUptime <= DOUBLE_TAP_WINDOW_MS) {
            lastTapUptime = 0L
            expandCard()
        } else {
            lastTapUptime = uptime
        }
    }

    private inner class BubbleTouchListener : View.OnTouchListener {
        private var downRawX = 0f
        private var downRawY = 0f
        private var startX = 0
        private var startY = 0
        private var moved = false
        private var downTime = 0L

        @SuppressLint("ClickableViewAccessibility")
        override fun onTouch(v: View, event: MotionEvent): Boolean {
            val params = bubbleParams ?: return false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    snapAnimator?.cancel()
                    downRawX = event.rawX
                    downRawY = event.rawY
                    startX = params.x
                    startY = params.y
                    moved = false
                    downTime = event.eventTime
                    bubble?.setPressedState(true)
                }

                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downRawX
                    val dy = event.rawY - downRawY
                    if (!moved && hypot(dx, dy) > touchSlop) moved = true
                    if (moved) {
                        params.x = startX + dx.roundToInt()
                        params.y = startY + dy.roundToInt()
                        clampToScreen(params)
                        safeUpdate(v, params)
                    }
                }

                MotionEvent.ACTION_UP -> {
                    bubble?.setPressedState(false)
                    if (moved) {
                        snapToEdge()
                    } else if (event.eventTime - downTime < 400L) {
                        onBubbleTapped(event.eventTime)
                    }
                }

                MotionEvent.ACTION_CANCEL -> {
                    bubble?.setPressedState(false)
                    if (moved) snapToEdge()
                }
            }
            return true
        }
    }

    // ---- Mini control card ---------------------------------------------------------------------

    private fun expandCard() {
        if (card != null) return
        val anchor = bubbleParams ?: return
        val (screenW, screenH) = screenSize()

        val miniCard = MiniCard()
        val width = minOf(dp(320), screenW - dp(24))
        miniCard.root.measure(
            View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
        )
        val height = miniCard.root.measuredHeight

        val params = overlayParams(width, WindowManager.LayoutParams.WRAP_CONTENT).apply {
            x = (anchor.x + anchor.width / 2 - width / 2).coerceIn(0, (screenW - width).coerceAtLeast(0))
            y = anchor.y.coerceIn(0, (screenH - height).coerceAtLeast(0))
        }
        try {
            detachBubble()
            windowManager.addView(miniCard.root, params)
        } catch (_: Exception) {
            attachBubble()
            return
        }
        card = miniCard
        cardParams = params
        miniCard.root.alpha = config.opacity.coerceAtLeast(0.75f)
        miniCard.bind(state)
    }

    private fun removeCardWindow() {
        val current = card ?: return
        try {
            windowManager.removeViewImmediate(current.root)
        } catch (_: IllegalArgumentException) {
            // Already removed.
        }
        card = null
        cardParams = null
    }

    /** Close (X): the card collapses back into the red R note. */
    private fun collapseToBubble() {
        removeCardWindow()
        bubbleParams?.let { clampToScreen(it) }
        attachBubble()
        bubble?.setPlaying(state.isPlaying)
    }

    private fun emit(method: String, vararg extras: Pair<String, Any?>) {
        RonovaEventBus.emit(method, mapOf("source" to "overlay") + extras.toMap())
    }

    private fun commitState(newState: OverlayState) {
        state = newState
        lastState = newState
        bubble?.setPlaying(newState.isPlaying)
        card?.bind(newState)
    }

    private inner class MiniCard {
        private val ctx: Context = this@RonovaFloatingOverlayService

        val root = LinearLayout(ctx)
        private val header = LinearLayout(ctx)
        private val titleView = TextView(ctx)
        private val closeButton = iconButton(R.drawable.ic_overlay_close, 34, COLOR_SUBTLE)
        private val prevButton = iconButton(R.drawable.ic_notif_prev, 44, COLOR_SUBTLE)
        private val playButton = iconButton(R.drawable.ic_notif_play, 54, COLOR_RED)
        private val nextButton = iconButton(R.drawable.ic_notif_next, 44, COLOR_SUBTLE)
        private val speedLabel = TextView(ctx)
        private val speedBar = SeekBar(ctx)
        private val reverbPill = pill("Reverb")
        private val boostPill = pill("Boost")
        private val ronovaPill = pill("Ronova")

        private var seeking = false
        private var lastSpeedEmit = 0L

        init {
            root.orientation = LinearLayout.VERTICAL
            root.setPadding(dp(14), dp(10), dp(14), dp(14))
            root.background = GradientDrawable().apply {
                setColor(COLOR_CARD)
                cornerRadius = dp(22).toFloat()
                setStroke(dp(1), COLOR_CARD_STROKE)
            }

            // Header: track title (drag handle) + close.
            header.orientation = LinearLayout.HORIZONTAL
            header.gravity = Gravity.CENTER_VERTICAL
            titleView.apply {
                setTextColor(Color.WHITE)
                textSize = 15f
                typeface = Typeface.DEFAULT_BOLD
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
                text = "Ronova Audio"
            }
            header.addView(titleView, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            header.addView(closeButton)
            header.setOnTouchListener(CardDragListener())
            closeButton.contentDescription = "Close"
            closeButton.setOnClickListener { collapseToBubble() }
            root.addView(header, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(40)))

            // Transport row.
            val transport = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
            }
            prevButton.contentDescription = "Previous"
            playButton.contentDescription = "Play or pause"
            nextButton.contentDescription = "Next"
            transport.addView(prevButton)
            transport.addView(playButton, spacedParams(dp(54), dp(54), dp(18)))
            transport.addView(nextButton)
            root.addView(transport, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(60)))

            prevButton.setOnClickListener { emit("onPrev") }
            nextButton.setOnClickListener { emit("onNext") }
            playButton.setOnClickListener {
                val play = !state.isPlaying
                commitState(state.copy(isPlaying = play))
                emit("onPlayPause", "play" to play)
            }

            // Speed row.
            speedLabel.apply {
                setTextColor(Color.WHITE)
                textSize = 13f
                text = speedText(state.speed)
            }
            val speedHeader = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            }
            speedHeader.addView(
                TextView(ctx).apply {
                    setTextColor(COLOR_PILL_OFF_TEXT)
                    textSize = 13f
                    text = "Speed"
                },
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
            )
            speedHeader.addView(speedLabel)
            root.addView(
                speedHeader,
                LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                    .apply { topMargin = dp(6) },
            )

            speedBar.max = SPEED_STEPS
            speedBar.progressTintList = ColorStateList.valueOf(COLOR_RED)
            speedBar.thumbTintList = ColorStateList.valueOf(COLOR_RED)
            speedBar.progressBackgroundTintList = ColorStateList.valueOf(COLOR_SUBTLE)
            speedBar.progress = speedToProgress(state.speed)
            speedBar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                    if (!fromUser) return
                    val speed = progressToSpeed(progress)
                    speedLabel.text = speedText(speed)
                    val now = System.currentTimeMillis()
                    if (now - lastSpeedEmit >= SPEED_EMIT_INTERVAL_MS) {
                        lastSpeedEmit = now
                        commitState(state.copy(speed = speed))
                        emit("onSetSpeed", "speed" to speed.toDouble())
                    }
                }

                override fun onStartTrackingTouch(seekBar: SeekBar?) {
                    seeking = true
                }

                override fun onStopTrackingTouch(seekBar: SeekBar?) {
                    seeking = false
                    val speed = progressToSpeed(speedBar.progress)
                    commitState(state.copy(speed = speed))
                    emit("onSetSpeed", "speed" to speed.toDouble())
                }
            })
            root.addView(
                speedBar,
                LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(32)),
            )

            // Toggle row: Reverb / Volume upscaler boost / Ronova mode.
            val toggles = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
            }
            toggles.addView(reverbPill, pillParams(true))
            toggles.addView(boostPill, pillParams(true))
            toggles.addView(ronovaPill, pillParams(false))
            root.addView(
                toggles,
                LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(36)).apply { topMargin = dp(8) },
            )

            reverbPill.setOnClickListener {
                val enabled = !state.reverbEnabled
                commitState(state.copy(reverbEnabled = enabled))
                emit("onToggleReverb", "enabled" to enabled)
            }
            boostPill.setOnClickListener {
                val enabled = !state.upscalerEnabled
                commitState(state.copy(upscalerEnabled = enabled))
                emit("onSetUpscaler", "enabled" to enabled)
            }
            ronovaPill.setOnClickListener {
                val enabled = !state.ronovaEnabled
                commitState(state.copy(ronovaEnabled = enabled))
                emit("onToggleRonova", "enabled" to enabled)
            }
        }

        fun bind(s: OverlayState) {
            titleView.text = s.title.ifBlank { "Ronova Audio" }
            playButton.setImageResource(if (s.isPlaying) R.drawable.ic_notif_pause else R.drawable.ic_notif_play)
            if (!seeking) {
                speedBar.progress = speedToProgress(s.speed)
                speedLabel.text = speedText(s.speed)
            }
            styleToggle(reverbPill, s.reverbEnabled)
            styleToggle(boostPill, s.upscalerEnabled)
            styleToggle(ronovaPill, s.ronovaEnabled)
        }

        init {
            bind(state)
        }

        private fun spacedParams(width: Int, height: Int, margin: Int) =
            LinearLayout.LayoutParams(width, height).apply {
                marginStart = margin
                marginEnd = margin
            }

        private fun pillParams(withEndMargin: Boolean) =
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f).apply {
                if (withEndMargin) marginEnd = dp(8)
            }
    }

    /** Lets the user drag the card by its title row. */
    private inner class CardDragListener : View.OnTouchListener {
        private var downRawX = 0f
        private var downRawY = 0f
        private var startX = 0
        private var startY = 0

        @SuppressLint("ClickableViewAccessibility")
        override fun onTouch(v: View, event: MotionEvent): Boolean {
            val params = cardParams ?: return false
            val view = card?.root ?: return false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = event.rawX
                    downRawY = event.rawY
                    startX = params.x
                    startY = params.y
                }

                MotionEvent.ACTION_MOVE -> {
                    val (screenW, screenH) = screenSize()
                    val cardHeight = view.height.coerceAtLeast(1)
                    params.x = (startX + (event.rawX - downRawX).roundToInt())
                        .coerceIn(0, (screenW - params.width).coerceAtLeast(0))
                    params.y = (startY + (event.rawY - downRawY).roundToInt())
                        .coerceIn(0, (screenH - cardHeight).coerceAtLeast(0))
                    safeUpdate(view, params)
                }
            }
            return true
        }
    }

    // ---- View helpers --------------------------------------------------------------------------

    private fun iconButton(iconRes: Int, sizeDp: Int, circleColor: Int): ImageButton =
        ImageButton(this).apply {
            setImageResource(iconRes)
            setColorFilter(Color.WHITE)
            scaleType = android.widget.ImageView.ScaleType.CENTER_INSIDE
            val padding = dp(sizeDp / 4)
            setPadding(padding, padding, padding, padding)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(circleColor)
            }
            layoutParams = LinearLayout.LayoutParams(dp(sizeDp), dp(sizeDp))
        }

    private fun pill(label: String): TextView =
        TextView(this).apply {
            text = label
            textSize = 13f
            gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD
            isClickable = true
        }

    private fun styleToggle(view: TextView, on: Boolean) {
        view.background = GradientDrawable().apply {
            cornerRadius = dp(18).toFloat()
            if (on) {
                setColor(COLOR_RED)
            } else {
                setColor(Color.TRANSPARENT)
                setStroke(dp(1), COLOR_PILL_OFF_STROKE)
            }
        }
        view.setTextColor(if (on) Color.WHITE else COLOR_PILL_OFF_TEXT)
    }

    private fun speedText(speed: Float): String = String.format(Locale.US, "%.2fx", speed)

    private fun progressToSpeed(progress: Int): Float =
        (((MIN_SPEED * 100f).roundToInt() + progress) / 100f).coerceIn(MIN_SPEED, MAX_SPEED)

    private fun speedToProgress(speed: Float): Int =
        ((speed.coerceIn(MIN_SPEED, MAX_SPEED) * 100f).roundToInt() - (MIN_SPEED * 100f).roundToInt())
            .coerceIn(0, SPEED_STEPS)

    private fun safeUpdate(view: View, params: WindowManager.LayoutParams) {
        try {
            windowManager.updateViewLayout(view, params)
        } catch (_: IllegalArgumentException) {
            // View is not attached (yet / anymore).
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

    @Suppress("DEPRECATION")
    private fun screenSize(): Pair<Int, Int> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = windowManager.currentWindowMetrics.bounds
            Pair(bounds.width(), bounds.height())
        } else {
            val metrics = DisplayMetrics()
            windowManager.defaultDisplay.getRealMetrics(metrics)
            Pair(metrics.widthPixels, metrics.heightPixels)
        }

}

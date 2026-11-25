package com.ronova.audio.overlay

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.view.View
import android.view.animation.LinearInterpolator

/**
 * The floating badge: a dark glowing disc with a red "R" whose stem and note-head form a musical
 * eighth note (the bowl of the R doubles as the flag). Everything is drawn with Canvas paths, so it
 * is crisp at any scale. Opacity is controlled by the host through [View.setAlpha].
 */
class RonovaBubbleView(context: Context) : View(context) {

    private val density = resources.displayMetrics.density

    private val discPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = RED
    }
    private val glyphFill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = RED_BRIGHT
    }
    private val glyphStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = RED_BRIGHT
        strokeWidth = 9f
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    private val bowl = Path().apply {
        moveTo(44.5f, 20f)
        lineTo(57f, 20f)
        cubicTo(81f, 20f, 81f, 49f, 57f, 49f)
        lineTo(44.5f, 49f)
    }
    private val leg = Path().apply {
        moveTo(58f, 49f)
        lineTo(76f, 77f)
    }
    private val stem = RectF(40f, 14f, 49f, 76f)
    private val head = RectF(17f, 68f, 45f, 87f)

    private var playing = false
    private var pressedScale = 1f
    private var glowPhase = 0f
    private var pulse: ValueAnimator? = null

    init {
        // Software layer so the glow (setShadowLayer) renders identically on every API level.
        setLayerType(LAYER_TYPE_SOFTWARE, null)
    }

    fun setPlaying(isPlaying: Boolean) {
        if (playing == isPlaying) return
        playing = isPlaying
        updatePulse()
        invalidate()
    }

    fun setPressedState(isPressed: Boolean) {
        pressedScale = if (isPressed) 0.93f else 1f
        invalidate()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        val radius = w * DISC_RADIUS_FRACTION
        discPaint.shader = RadialGradient(
            w / 2f, h / 2f, radius,
            intArrayOf(0xFF2B1218.toInt(), 0xFF0C0E13.toInt()),
            floatArrayOf(0f, 1f),
            Shader.TileMode.CLAMP,
        )
        ringPaint.strokeWidth = maxOf(1.5f * density, w * 0.03f)
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        updatePulse()
    }

    override fun onDetachedFromWindow() {
        pulse?.cancel()
        pulse = null
        super.onDetachedFromWindow()
    }

    private fun updatePulse() {
        if (playing && isAttachedToWindow) {
            if (pulse == null) {
                pulse = ValueAnimator.ofFloat(0f, 1f).apply {
                    duration = 1500
                    repeatMode = ValueAnimator.REVERSE
                    repeatCount = ValueAnimator.INFINITE
                    interpolator = LinearInterpolator()
                    addUpdateListener {
                        glowPhase = it.animatedValue as Float
                        invalidate()
                    }
                    start()
                }
            }
        } else {
            pulse?.cancel()
            pulse = null
            glowPhase = 0f
        }
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val cx = w / 2f
        val cy = height / 2f
        val radius = w * DISC_RADIUS_FRACTION

        canvas.save()
        canvas.scale(pressedScale, pressedScale, cx, cy)

        // Glow: brighter and breathing while audio is playing.
        val glowRadius = w * (if (playing) 0.07f + 0.04f * glowPhase else 0.05f)
        ringPaint.setShadowLayer(glowRadius, 0f, 0f, GLOW)
        canvas.drawCircle(cx, cy, radius, discPaint)
        canvas.drawCircle(cx, cy, radius, ringPaint)

        // "R" eighth-note glyph, drawn in a 100 x 100 design space and centred in the disc.
        val box = radius * 1.32f
        canvas.save()
        canvas.translate(cx - box / 2f, cy - box / 2f)
        canvas.scale(box / 100f, box / 100f)
        canvas.drawRoundRect(stem, 4f, 4f, glyphFill)
        canvas.drawPath(bowl, glyphStroke)
        canvas.drawPath(leg, glyphStroke)
        canvas.save()
        canvas.rotate(-22f, 31f, 77.5f)
        canvas.drawOval(head, glyphFill)
        canvas.restore()
        canvas.restore()

        canvas.restore()
    }

    private companion object {
        const val DISC_RADIUS_FRACTION = 0.40f
        val RED = 0xFFE53935.toInt()
        val RED_BRIGHT = 0xFFFF4D4D.toInt()
        val GLOW = 0xCCFF3030.toInt()
    }
}

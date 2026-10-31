package au.interstellr.glassbridge

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.view.View
import au.interstellr.glassbridge.core.ManeuverShapes

/**
 * The turn arrow on the nav card, 170x170 px, drawn with Canvas paths from
 * [ManeuverShapes] (one distinct shape per `maneuver` value).
 */
class ManeuverView(context: Context) : View(context) {
    private var maneuver = "straight"
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.FILL
    }
    private val path = Path()

    fun setManeuver(m: String) {
        if (m != maneuver) {
            maneuver = m
            invalidate()
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(resolveSize(SIZE_PX, widthMeasureSpec), resolveSize(SIZE_PX, heightMeasureSpec))
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val s = Math.min(width, height).toFloat()
        if (s <= 0f) return
        val ox = (width - s) / 2f
        val oy = (height - s) / 2f
        val shape = ManeuverShapes.of(maneuver)
        stroke.strokeWidth = ManeuverShapes.STROKE * s

        for (l in shape.lines) {
            if (l.size < 4) continue
            path.reset()
            path.moveTo(ox + l[0] * s, oy + l[1] * s)
            var i = 2
            while (i + 1 < l.size) {
                path.lineTo(ox + l[i] * s, oy + l[i + 1] * s)
                i += 2
            }
            canvas.drawPath(path, stroke)
        }
        for (h in shape.heads) {
            val t = ManeuverShapes.headTriangle(h)
            path.reset()
            path.moveTo(ox + t[0][0] * s, oy + t[0][1] * s)
            path.lineTo(ox + t[1][0] * s, oy + t[1][1] * s)
            path.lineTo(ox + t[2][0] * s, oy + t[2][1] * s)
            path.close()
            canvas.drawPath(path, fill)
        }
        for (r in shape.rings) canvas.drawCircle(ox + r[0] * s, oy + r[1] * s, r[2] * s, stroke)
        for (d in shape.dots) canvas.drawCircle(ox + d[0] * s, oy + d[1] * s, d[2] * s, fill)
    }

    companion object {
        const val SIZE_PX = 170
    }
}

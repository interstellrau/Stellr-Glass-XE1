package au.interstellr.glassbridge.core

/**
 * The turn arrow for each `maneuver` value, as geometry in a unit box (0..1, y down).
 * ManeuverView scales it to 170x170 px and draws it with Canvas paths: [lines] as round-capped
 * strokes, [heads] as filled triangles, [rings] as stroked circles and [dots] as filled ones.
 * One distinct shape per maneuver (see the unit test).
 *
 * Left turns mirror right turns. The U-turn swings to the right, as it does in left-hand
 * traffic (Australia, where StellrGlass is used).
 */
class ManeuverShape(
    /** Polylines: x0, y0, x1, y1, ... */
    val lines: List<FloatArray>,
    /** Arrowheads: baseX, baseY, angle in degrees (0 = right, 90 = down). */
    val heads: List<FloatArray>,
    /** Stroked circles: x, y, radius. */
    val rings: List<FloatArray>,
    /** Filled circles: x, y, radius. */
    val dots: List<FloatArray>
) {
    /** Exact text form, for comparing shapes. */
    fun signature(): String {
        val sb = StringBuilder()
        fun part(name: String, list: List<FloatArray>) {
            sb.append(name).append('[')
            for (a in list) sb.append(a.joinToString(",")).append(';')
            sb.append(']')
        }
        part("L", lines)
        part("H", heads)
        part("R", rings)
        part("D", dots)
        return sb.toString()
    }

    /** Every x and y of every element (arrowhead tips included), for bounds checks. */
    fun allPoints(): List<FloatArray> {
        val out = ArrayList<FloatArray>()
        for (l in lines) {
            var i = 0
            while (i + 1 < l.size) {
                out.add(floatArrayOf(l[i], l[i + 1]))
                i += 2
            }
        }
        for (h in heads) for (p in ManeuverShapes.headTriangle(h)) out.add(p)
        for (r in rings) {
            out.add(floatArrayOf(r[0] - r[2], r[1] - r[2]))
            out.add(floatArrayOf(r[0] + r[2], r[1] + r[2]))
        }
        for (d in dots) {
            out.add(floatArrayOf(d[0] - d[2], d[1] - d[2]))
            out.add(floatArrayOf(d[0] + d[2], d[1] + d[2]))
        }
        return out
    }
}

object ManeuverShapes {
    /** Stroke width, as a fraction of the view size. */
    const val STROKE = 0.085f

    /** Arrowhead length and half width, as fractions of the view size. */
    const val HEAD_LENGTH = 0.24f
    const val HEAD_HALF_WIDTH = 0.16f

    private val cache = HashMap<String, ManeuverShape>()

    /** The shape for [maneuver]; unknown values draw as "straight" (as NavState does). */
    @JvmStatic
    fun of(maneuver: String?): ManeuverShape {
        val m = NavState.maneuverOf(maneuver)
        synchronized(cache) {
            return cache[m] ?: build(m).also { cache[m] = it }
        }
    }

    /** Tip, left corner and right corner of an arrowhead (baseX, baseY, angleDeg). */
    @JvmStatic
    fun headTriangle(head: FloatArray): List<FloatArray> {
        val a = Math.toRadians(head[2].toDouble())
        val ux = Math.cos(a).toFloat()
        val uy = Math.sin(a).toFloat()
        val bx = head[0]
        val by = head[1]
        val tip = floatArrayOf(bx + ux * HEAD_LENGTH, by + uy * HEAD_LENGTH)
        // Perpendicular (-uy, ux).
        val left = floatArrayOf(bx - uy * HEAD_HALF_WIDTH, by + ux * HEAD_HALF_WIDTH)
        val right = floatArrayOf(bx + uy * HEAD_HALF_WIDTH, by - ux * HEAD_HALF_WIDTH)
        return listOf(tip, left, right)
    }

    private fun build(m: String): ManeuverShape = when (m) {
        "depart" -> ManeuverShape(
            lines = listOf(floatArrayOf(0.5f, 0.71f, 0.5f, 0.40f)),
            heads = listOf(floatArrayOf(0.5f, 0.40f, -90f)),
            rings = listOf(floatArrayOf(0.5f, 0.80f, 0.075f)),
            dots = emptyList()
        )
        "straight" -> ManeuverShape(
            lines = listOf(floatArrayOf(0.5f, 0.88f, 0.5f, 0.36f)),
            heads = listOf(floatArrayOf(0.5f, 0.36f, -90f)),
            rings = emptyList(),
            dots = emptyList()
        )
        "right" -> turnRight
        "slight_right" -> slightRight
        "sharp_right" -> sharpRight
        "left" -> mirror(turnRight)
        "slight_left" -> mirror(slightRight)
        "sharp_left" -> mirror(sharpRight)
        "uturn" -> uturn()
        "arrive" -> ManeuverShape(
            lines = listOf(floatArrayOf(0.5f, 0.64f, 0.5f, 0.90f)),
            heads = emptyList(),
            rings = listOf(floatArrayOf(0.5f, 0.40f, 0.22f)),
            dots = listOf(floatArrayOf(0.5f, 0.40f, 0.09f))
        )
        else -> build("straight")
    }

    private val turnRight = ManeuverShape(
        lines = listOf(floatArrayOf(0.36f, 0.88f, 0.36f, 0.50f, 0.64f, 0.50f)),
        heads = listOf(floatArrayOf(0.64f, 0.50f, 0f)),
        rings = emptyList(),
        dots = emptyList()
    )

    private val slightRight = ManeuverShape(
        lines = listOf(floatArrayOf(0.42f, 0.88f, 0.42f, 0.58f, 0.62f, 0.38f)),
        heads = listOf(floatArrayOf(0.62f, 0.38f, -45f)),
        rings = emptyList(),
        dots = emptyList()
    )

    private val sharpRight = ManeuverShape(
        lines = listOf(floatArrayOf(0.38f, 0.88f, 0.38f, 0.30f, 0.58f, 0.50f)),
        heads = listOf(floatArrayOf(0.58f, 0.50f, 45f)),
        rings = emptyList(),
        dots = emptyList()
    )

    /** Up the left side, over the top to the right, then down (left-hand traffic U-turn). */
    private fun uturn(): ManeuverShape {
        val pts = ArrayList<Float>()
        pts.add(0.34f); pts.add(0.88f)
        val cx = 0.5f
        val cy = 0.42f
        val r = 0.16f
        val steps = 12
        for (i in 0..steps) {
            val a = Math.PI + Math.PI * i / steps // 180 to 360 degrees: over the top (y down)
            pts.add(round3(cx + r * Math.cos(a).toFloat()))
            pts.add(round3(cy + r * Math.sin(a).toFloat()))
        }
        pts.add(0.66f); pts.add(0.52f)
        return ManeuverShape(
            lines = listOf(pts.toFloatArray()),
            heads = listOf(floatArrayOf(0.66f, 0.52f, 90f)),
            rings = emptyList(),
            dots = emptyList()
        )
    }

    private fun mirror(s: ManeuverShape): ManeuverShape = ManeuverShape(
        lines = s.lines.map { l -> FloatArray(l.size) { i -> if (i % 2 == 0) round3(1f - l[i]) else l[i] } },
        heads = s.heads.map { h -> floatArrayOf(round3(1f - h[0]), h[1], normalizeAngle(180f - h[2])) },
        rings = s.rings.map { r -> floatArrayOf(round3(1f - r[0]), r[1], r[2]) },
        dots = s.dots.map { d -> floatArrayOf(round3(1f - d[0]), d[1], d[2]) }
    )

    private fun normalizeAngle(a: Float): Float {
        var x = a
        while (x > 180f) x -= 360f
        while (x <= -180f) x += 360f
        return x
    }

    private fun round3(v: Float): Float = Math.round(v * 1000f) / 1000f
}

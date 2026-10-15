package ai.desertant.shapes

import ai.desertant.core.FfiReader
import ai.desertant.core.FfiWriter
import ai.desertant.core.LoadedModel

/** The catalog id, which is how the shared native layer is asked for Shapes. */
private const val MODEL_ID = "shapes"
private const val MODEL_NAME = "Shapes"

/** How Shapes snaps a recognized shape's rotation. */
enum class Rotation {
    /** The default. Shapes rounds rotations to 15° steps and snaps lines and edges within 5° of an axis onto it. */
    SNAPPED,
    /** Shapes removes rotation: boxes and ellipses align with the axes, and stars have a tip straight up. */
    UPRIGHT,
    /** Shapes keeps the shape as drawn and skips the snapping to circles, squares, and regular polygons. */
    FREE,
}

/** Options controlling recognition. */
data class Options(
    /** How Shapes snaps rotation. */
    val rotation: Rotation = Rotation.SNAPPED,
    /**
     * The kinds Shapes recognizes, all of them by default. For a stroke of any
     * other kind, [Shapes.recognize] returns `null`. For example, leave out
     * [Shape.Kind.SCRIBBLE] if your app has no erase gesture.
     */
    val kinds: Set<Shape.Kind> = Shape.Kind.entries.toSet(),
    /**
     * The lowest classifier confidence Shapes accepts, on top of each kind's calibrated threshold.
     * `0.0` (the default) applies only the model's own gates.
     */
    val minimumConfidence: Double = 0.0,
)

/** Thrown when the model cannot be created, loaded, or run. */
class ShapesException(message: String) : Exception(message)

/**
 * Turns a hand-drawn stroke into a clean [Shape] on the device: a connector,
 * an arrow, a rectangle, an ellipse, a polygon, a star, a heart, a cloud, or a
 * scribble, which your app can use as an erase gesture. For any other stroke,
 * such as handwriting, [recognize] returns `null`, so you can keep that stroke
 * as ink.
 *
 * Create one `Shapes` and reuse it. The model loads on the first [recognize],
 * or ahead of time with [download].
 *
 * ```kotlin
 * val shapes = Shapes(context)                 // download on demand, cached
 * when (val shape = shapes.recognize(strokePoints, Options(rotation = Rotation.UPRIGHT))) {
 *     is Shape.Scribble -> eraseUnder(shape.hull)
 *     null -> keepInk()
 *     else -> draw(shape.outline)
 * }
 * shapes.close()
 * ```
 *
 * @param directory the model's home. Files already there are adopted (so an app
 *   that ships the model just points at the folder it unpacked it into),
 *   otherwise the model is downloaded into it. Omit to use the app cache.
 */
class Shapes(
    context: android.content.Context,
    directory: String? = null,
) : AutoCloseable {
    private val model = LoadedModel(MODEL_ID, MODEL_NAME, context, directory, ::ShapesException, ShapesNative)

    companion object

    /** Whether the model is available for this recognizer with no network. */
    fun isDownloaded(): Boolean = model.isDownloaded()

    /**
     * Download the model ahead of time so the first [recognize] is instant. A
     * no-op once available (see [isDownloaded]). Suspends on a background
     * dispatcher.
     */
    suspend fun download() = model.download()

    /**
     * Recognizes a stroke given as ordered [points] in canvas coordinates.
     * Returns the clean [Shape], or `null` for a stroke that isn't a shape or
     * isn't one of [Options.kinds]. The first call loads the model.
     */
    suspend fun recognize(points: List<Point>, options: Options = Options()): Shape? {
        // Fewer than two points cannot be a stroke, so it is answered here rather
        // than by waking the model.
        if (points.size < 2) return null
        // Input payload: an int point count, then an x and a y per point. Options
        // payload: f64 minimum confidence, int rotation, int kinds mask. Result
        // payload: a 0/1 present flag, the kind, its fields, then the outline.
        // All three must match Sources/Shapes/Binding.swift.
        val input = FfiWriter().int(points.size)
        for (p in points) input.double(p.x).double(p.y)
        var mask = 0
        for (k in options.kinds) mask = mask or (1 shl WIRE_KINDS.indexOf(k))
        val opts = FfiWriter()
            .double(options.minimumConfidence)
            .int(options.rotation.ordinal)
            .int(mask)
            .done()
        return model.run(input.done(), opts, failureMessage = "recognition failed", decode = ::decodeShape)
    }

    /** Release the native model. The recognizer is unusable afterwards; calling
     *  this again is a no-op. */
    @Synchronized override fun close() = model.close()
}

/** Kinds by wire number (Sources/Shapes/Binding.swift `wireKinds`); 0 is "no shape". */
private val WIRE_KINDS: List<Shape.Kind?> = listOf(
    null,
    Shape.Kind.LINE, Shape.Kind.RECTANGLE, Shape.Kind.TRIANGLE, Shape.Kind.ELLIPSE, Shape.Kind.STAR,
    Shape.Kind.CURVE, Shape.Kind.ARROW, Shape.Kind.DIAMOND, Shape.Kind.PENTAGON, Shape.Kind.HEXAGON,
    Shape.Kind.HEART, Shape.Kind.CLOUD, Shape.Kind.SCRIBBLE,
)

/** Decode the result payload Sources/Shapes/Binding.swift writes. */
private fun decodeShape(r: FfiReader): Shape? {
    if (r.int() == 0) return null
    // A kind this SDK doesn't know comes from a core newer than the AAR. The
    // decoder returns no shape instead of reading a payload it can't parse.
    val kind = WIRE_KINDS.getOrNull(r.int()) ?: return null
    return when (kind) {
        Shape.Kind.LINE -> { val a = r.point(); val b = r.point(); Shape.Line(a, b, r.points()) }
        Shape.Kind.CURVE -> {
            val a = r.point(); val c1 = r.point(); val c2 = r.point(); val b = r.point()
            Shape.Curve(a, c1, c2, b, r.points())
        }
        Shape.Kind.ARROW -> {
            val a = r.point(); val c1 = r.point(); val c2 = r.point(); val b = r.point()
            val start = r.int() == 1; val end = r.int() == 1
            Shape.Arrow(a, c1, c2, b, start, end, r.points())
        }
        Shape.Kind.RECTANGLE -> { val c = r.points(); Shape.Rectangle(c, r.points()) }
        Shape.Kind.ELLIPSE -> {
            val c = r.point(); val a = r.double(); val b = r.double(); val rot = r.double()
            Shape.Ellipse(c, a, b, rot, r.points())
        }
        Shape.Kind.TRIANGLE -> { val v = r.points(); Shape.Triangle(v, r.points()) }
        Shape.Kind.DIAMOND -> { val v = r.points(); Shape.Diamond(v, r.points()) }
        Shape.Kind.PENTAGON -> { val v = r.points(); Shape.Pentagon(v, r.points()) }
        Shape.Kind.HEXAGON -> { val v = r.points(); Shape.Hexagon(v, r.points()) }
        Shape.Kind.STAR -> {
            val c = r.point(); val o = r.double(); val i = r.double(); val rot = r.double(); val n = r.int()
            Shape.Star(c, o, i, rot, n, r.points())
        }
        Shape.Kind.HEART -> { val c = r.point(); val w = r.double(); val h = r.double(); Shape.Heart(c, w, h, r.points()) }
        Shape.Kind.CLOUD -> { r.points(); Shape.Cloud(r.points()) }
        Shape.Kind.SCRIBBLE -> { val h = r.points(); Shape.Scribble(h, r.points()) }
    }
}

private fun FfiReader.point(): Point = Point(double(), double())

private fun FfiReader.points(): List<Point> = List(int()) { point() }

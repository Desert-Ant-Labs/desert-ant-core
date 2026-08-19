package ai.desertant.shapes

import ai.desertant.core.FfiReader
import ai.desertant.core.FfiWriter
import ai.desertant.core.LoadedModel

/** The catalog id, which is how the shared native layer is asked for Shapes. */
private const val MODEL_ID = "shapes"
private const val MODEL_NAME = "Shapes"

/** Options controlling recognition. */
data class Options(
    /**
     * Minimum classifier confidence, on top of each class's calibrated gate.
     * `0.0` (the default) applies only the model's own gates.
     */
    val minimumConfidence: Double = 0.0,
)

/** Thrown when the model cannot be created, loaded, or run. */
class ShapesException(message: String) : Exception(message)

/**
 * On-device single-stroke shape recognition. Mirrors the iOS/Swift SDK: create
 * one `Shapes` and reuse it; the model loads lazily on the first [recognize]
 * (or eagerly via [download]).
 *
 * ```kotlin
 * val shapes = Shapes(context)                 // download on demand, cached
 * val shape = shapes.recognize(strokePoints)   // Shape? (null if rejected)
 * when (shape) {
 *     is Shape.Rectangle -> shape.corners
 *     is Shape.Ellipse -> shape.center
 *     else -> {}
 * }
 * shapes.close()
 * ```
 *
 * Creating, downloading, running, and releasing the model are the shared
 * `ai.desertant:core` shell ([LoadedModel]); what lives here is Shapes' API and
 * its payload schemas.
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
     * Recognize a stroke given as ordered [points] (canvas coordinates). Returns
     * the snapped [Shape], or `null` when the stroke is rejected or degenerate.
     * Loads the model lazily on first call.
     */
    suspend fun recognize(points: List<Point>, options: Options = Options()): Shape? {
        // Fewer than two points cannot be a stroke, so it is answered here rather
        // than by waking the model.
        if (points.size < 2) return null
        // Input payload: an int point count, then an x and a y per point. Options
        // payload: the f64 minimum confidence. Result payload: a 0/1 present
        // flag, then the shape's kind and that kind's fields. All three must
        // match Sources/Shapes/Binding.swift.
        val input = FfiWriter().int(points.size)
        for (p in points) input.double(p.x).double(p.y)
        val opts = FfiWriter().double(options.minimumConfidence).done()
        return model.run(input.done(), opts, failureMessage = "recognition failed", decode = ::decodeShape)
    }

    /** Release the native model. The recognizer is unusable afterwards; calling
     *  this again is a no-op. */
    @Synchronized override fun close() = model.close()
}

/** Decode the result payload Sources/Shapes/Binding.swift writes. */
private fun decodeShape(r: FfiReader): Shape? {
    if (r.int() == 0) return null
    return when (r.int()) {
        1 -> Shape.Line(r.point(), r.point())
        2 -> Shape.Rectangle(r.points())
        3 -> Shape.Triangle(r.points())
        4 -> Shape.Ellipse(r.point(), r.double(), r.double(), r.double())
        5 -> Shape.Star(r.point(), r.double(), r.double(), r.double(), r.int())
        // A kind this SDK does not know is a core newer than the AAR. Report it
        // as "no shape" rather than half-decoding a payload we cannot read.
        else -> null
    }
}

private fun FfiReader.point(): Point = Point(double(), double())

private fun FfiReader.points(): List<Point> = List(int()) { point() }

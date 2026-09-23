package ai.desertant.moderator

import ai.desertant.core.FfiReader
import ai.desertant.core.FfiWriter
import ai.desertant.core.LoadedModel
import android.graphics.Bitmap

/** The catalog id, which is how the shared native layer is asked for Moderator. */
private const val MODEL_ID = "moderator"
private const val MODEL_NAME = "Moderator"

/** How many crops each image is scored on; the image score is the max over crops. */
enum class Quality(internal val nativeValue: Int) {
    /** One center square crop. Cheapest; the right choice for video frames. */
    FAST(0),
    /** Four multiscale tiles: the letterboxed image plus three center zoom-ins. */
    BALANCED(1),
    /** The four tiles and their mirror images, the evaluated setting. Default. */
    ACCURATE(2),
}

/** Which region heads count toward the single NSFW score. */
enum class Policy(internal val nativeValue: Int) {
    /** Any nudity or sexual content, including a bare chest. Default. */
    STANDARD(0),
    /** A bare chest alone does not flag; everything else still does. */
    ALLOW_TOPLESS(1),
}

/** Options for one [Moderator.analyze] call. */
data class Options(
    /** Score at or above which [Moderation.isNSFW] is `true`. */
    val threshold: Double = 0.5,
    val policy: Policy = Policy.STANDARD,
    val quality: Quality = Quality.ACCURATE,
)

/** Per-region confidences in `0..1`, each the max over the scored crops. */
data class Regions(
    val nipples: Double,
    val genitals: Double,
    val buttocks: Double,
    val nude: Double,
    val sexAct: Double,
)

/** The result of analyzing one image. */
data class Moderation(
    /** The NSFW score in `0..1` under the requested policy. */
    val score: Double,
    /** Whether [score] meets the threshold. */
    val isNSFW: Boolean,
    /** Per-region detail, for custom policies and UI. */
    val regions: Regions,
)

/** Thrown when the model cannot be created, loaded, or run. */
class ModeratorException(message: String) : Exception(message)

/**
 * On-device NSFW image detection. Mirrors the Swift SDK: create one `Moderator`
 * and reuse it; the model loads lazily on the first [analyze] (or eagerly via
 * [download]).
 *
 * ```kotlin
 * Moderator(context).use { moderator ->
 *     val result = moderator.analyze(bitmap)
 *     if (result.isNSFW) blur()
 * }
 * ```
 *
 * @param directory the model's home. Files already there are adopted, otherwise
 *   the model is downloaded into it. Omit to use the app cache.
 */
class Moderator(
    context: android.content.Context,
    directory: String? = null,
) : AutoCloseable {
    private val model = LoadedModel(MODEL_ID, MODEL_NAME, context, directory, ::ModeratorException, ModeratorNative)

    /** Whether the model is available with no network. */
    fun isDownloaded(): Boolean = model.isDownloaded()

    /** Download the model ahead of time so the first [analyze] is instant. */
    suspend fun download() = model.download()

    /** Score a [Bitmap] (any config; hardware bitmaps are copied to software first). */
    suspend fun analyze(bitmap: Bitmap, options: Options = Options()): Moderation {
        val source = if (bitmap.config == Bitmap.Config.ARGB_8888) bitmap
            else bitmap.copy(Bitmap.Config.ARGB_8888, false)
                ?: throw ModeratorException("the bitmap could not be read")
        val width = source.width
        val height = source.height
        val argb = IntArray(width * height)
        source.getPixels(argb, 0, width, 0, 0, width, height)
        if (source !== bitmap) source.recycle()
        val rgb = ByteArray(argb.size * 3)
        for (i in argb.indices) {
            val c = argb[i]
            rgb[i * 3] = (c shr 16).toByte()
            rgb[i * 3 + 1] = (c shr 8).toByte()
            rgb[i * 3 + 2] = c.toByte()
        }
        return analyze(rgb, width, height, options)
    }

    /**
     * Score raw pixels: `width * height` RGB or RGBA bytes, row-major from the
     * top-left. Alpha is ignored.
     */
    suspend fun analyze(pixels: ByteArray, width: Int, height: Int, options: Options = Options()): Moderation {
        val channels = if (width > 0 && height > 0) pixels.size / (width * height) else 0
        require((channels == 3 || channels == 4) && pixels.size == width * height * channels) {
            "pixels must hold ${width}x$height RGB or RGBA bytes, got ${pixels.size}"
        }
        // Payloads must match Sources/Moderator/Binding.swift.
        val input = FfiWriter().int(width).int(height).int(channels).blob(pixels).done()
        val opts = FfiWriter().double(options.threshold).int(options.policy.nativeValue)
            .int(options.quality.nativeValue).done()
        return model.run(input, opts, failureMessage = "analysis failed", decode = ::decodeModeration)
    }

    /** Release the native model. Calling this again is a no-op. */
    @Synchronized override fun close() = model.close()
}

private fun decodeModeration(r: FfiReader): Moderation {
    val score = r.double()
    val isNSFW = r.int() == 1
    return Moderation(score, isNSFW, Regions(r.double(), r.double(), r.double(), r.double(), r.double()))
}

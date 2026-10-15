package ai.desertant.eye

import ai.desertant.core.FfiReader
import ai.desertant.core.FfiWriter
import ai.desertant.core.LoadedModel
import android.graphics.Bitmap
import org.json.JSONObject

/** The catalog id, which is how the shared native layer is asked for Eye. */
private const val MODEL_ID = "eye"
private const val MODEL_NAME = "Eye"

/** What an analysis computes: each part is one or more model runs. */
enum class Part(internal val bit: Int) {
    /** What the photo is and how good: the 384x384 centre crop (types, scenes, reject reasons, sensitive, scores, embedding). */
    PHOTO(1),
    /** Where things are, from the whole frame: people and pet boxes, crops. Pet boxes are gated by the photo's scenes, so this runs the photo part too. */
    LAYOUT(2),
    /** Faces: detection on the whole frame, then one run per face. */
    FACES(4),
    /** Sharpness. */
    SHARPNESS(8),
}

/** Options for one [Eye.analyze] call. */
data class Options(
    /** What to compute. Default: everything. */
    val parts: Set<Part> = Part.entries.toSet(),
    /** At most this many faces are analyzed, the most confident first. */
    val maxFaces: Int = 20,
)

/** An axis-aligned rectangle in `0..1` of the image's size, origin top left. */
data class Box(val x0: Double, val y0: Double, val x1: Double, val y1: Double) {
    val width: Double get() = x1 - x0
    val height: Double get() = y1 - y0
}

/** A point in `0..1` of the image's size, origin top left. */
data class Point(val x: Double, val y: Double)

/** A map over the image, row-major from the top left. */
class Grid(val width: Int, val height: Int, val values: FloatArray) {
    /** The value at column [x], row [y]. */
    operator fun get(x: Int, y: Int): Float = values[y * width + x]
}

/** The photo function's raw outputs, from the centre crop. */
data class Photo(
    /** 512 dimensions, unit length: a dot product is a cosine similarity. */
    val embedding: FloatArray,
    /** `photo`, `selfie`, `screenshot`, `receipt`, ...: probabilities that sum to 1. */
    val type: Map<String, Double>,
    /** `forgettable`, `accidental`, `technical_flaw`, ... (`keeper` the opposite), each `0..1`. */
    val reject: Map<String, Double>,
    /** `nsfw_explicit`, `blood_injury`, `weapon`, ..., each `0..1`. */
    val sensitive: Map<String, Double>,
    /** 565 Open Images classes (`Person`, `Dog`, `Beach`, ...), each `0..1`. */
    val scenes: Map<String, Double>,
    /** How far the photo is turned clockwise from upright (0, 90, 180, 270 degrees): probabilities that sum to 1. */
    val rotation: Map<Int, Double>,
    /** How good the photo is as a photograph, `0..1`. */
    val aesthetic: Double,
    /** Ratings from 1 (poor) to 5 (excellent): `composition`, `lighting`, `color`, ... */
    val aestheticAttributes: Map<String, Double>,
    /** Whether people keep a photo like this, `0..1`. */
    val keeper: Double,
    /** Whether it would make a good cover or thumbnail, `0..1`. */
    val cover: Double,
    /** `none`, `defocus`, `motion`: probabilities that sum to 1. */
    val blur: Map<String, Double>,
    /** Deliberate background blur; higher is more. A score, not a probability. */
    val bokeh: Double,
    /** For a pet photo: `quality`, `face_visible`, `facing_camera`, `eyes_open`, `sharp`, `cut_off`, `occluded`. */
    val pet: Map<String, Double>,
    /** `airborne`, `peak`, `action`, `dramatic`, each `0..1`. */
    val peak: Map<String, Double>,
)

/** One detected object: `person`, `cat` or `dog`. */
data class Detection(val label: String, val confidence: Double, val box: Box)

/** A crop candidate and how good a crop it is (higher is better). */
data class Crop(val box: Box, val score: Double)

/** The spatial function's raw outputs, from the whole frame. */
data class Layout(
    /** Where people look when they see the photo: 64x64, sums to 1. */
    val attention: Grid,
    val people: List<Detection>,
    /** Cats and dogs. */
    val pets: List<Detection>,
    /** How the main person is framed: `extreme_close_up`, `close_up`, `medium`, `wide`. */
    val shot: Map<String, Double>,
    /** Every crop candidate with its score, in the model's order. */
    val crops: List<Crop>,
)

/** Head pose in degrees. */
data class Pose(val yaw: Double, val pitch: Double, val roll: Double)

/** Everything the model read from one face: [Face] has its tags; this has the raw outputs behind them. */
data class FaceDetails(
    val box: Box,
    val confidence: Double,
    /** Left to right in the image: left eye, right eye, nose tip, left and right mouth corners. */
    val landmarks: List<Point>,
    val isFace: Double,
    /** A real face rather than a statue, painting or screen. */
    val isReal: Double,
    val eyesOpen: Double,
    /** How closed each eye is: `left`, `right`. */
    val blink: Map<String, Double>,
    val smile: Double,
    /** `closed`, `talking`, `laughing`, `other_open`. */
    val mouth: Map<String, Double>,
    /** `neutral`, `happy`, `surprised`, `awkward_or_grimace`, `sad_or_angry`. */
    val expression: Map<String, Double>,
    /** Looking into the camera. */
    val looking: Double,
    /** `sunglasses`, `face_mask`, `hand_or_object_covering`, `cut_off_by_frame`. */
    val occlusion: Map<String, Double>,
    /** The face is in focus. */
    val sharp: Double,
    /** `good`, `dark`, `overexposed`, `harsh_shadows`. */
    val lighting: Map<String, Double>,
    /** A shot of this face worth keeping. */
    val keepsake: Double,
    val pose: Pose,
    val quality: Double,
)

/** How sharp the photo is. */
data class Sharpness(
    /** The probability that a person calls the photo sharp. */
    val score: Double,
    /** Blur over the image, higher is blurrier. */
    val blurMap: Grid,
)

/** The model's raw outputs behind an [Analysis]; a part not asked for is `null`. Not stored. */
data class Details(
    val photo: Photo?,
    val layout: Layout?,
    /** In the order of [Analysis.faces]. */
    val faces: List<FaceDetails>?,
    val sharpness: Sharpness?,
)

/** Thrown when the model cannot be created, loaded, or run. */
class EyeException(message: String) : Exception(message)

/**
 * On-device photo understanding. Mirrors the Swift SDK: create one `Eye` and
 * reuse it; the model loads lazily on the first [analyze] (or eagerly via
 * [download]).
 *
 * ```kotlin
 * Eye(context).use { eye ->
 *     val photo = eye.analyze(bitmap)
 *     if (photo.has(Tags.DOG) && !photo.has(Tags.BLURRY)) keep(photo)
 * }
 * ```
 *
 * @param directory the model's home. Files already there are adopted, otherwise
 *   the model is downloaded into it. Omit to use the app cache.
 */
class Eye(
    context: android.content.Context,
    directory: String? = null,
) : AutoCloseable {
    private val model = LoadedModel(MODEL_ID, MODEL_NAME, context, directory, ::EyeException, EyeNative)

    /** Whether the model is available with no network. */
    fun isDownloaded(): Boolean = model.isDownloaded()

    /** Download the model ahead of time so the first [analyze] is instant. */
    suspend fun download() = model.download()

    /** Analyze a [Bitmap], upright (any config; hardware bitmaps are copied to software first). */
    suspend fun analyze(bitmap: Bitmap, options: Options = Options()): Analysis {
        val source = if (bitmap.config == Bitmap.Config.ARGB_8888) bitmap
            else bitmap.copy(Bitmap.Config.ARGB_8888, false)
                ?: throw EyeException("the bitmap could not be read")
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
     * Analyze raw pixels: `width * height` RGB or RGBA bytes, row-major from the
     * top-left, upright. Alpha is ignored.
     */
    suspend fun analyze(pixels: ByteArray, width: Int, height: Int, options: Options = Options()): Analysis {
        val channels = if (width > 0 && height > 0) pixels.size / (width * height) else 0
        require((channels == 3 || channels == 4) && pixels.size == width * height * channels) {
            "pixels must hold ${width}x$height RGB or RGBA bytes, got ${pixels.size}"
        }
        require(options.maxFaces >= 0) { "maxFaces must not be negative" }
        // Payloads must match Sources/Eye/Binding.swift.
        val input = FfiWriter().int(width).int(height).int(channels).blob(pixels).done()
        val opts = FfiWriter().int(options.parts.fold(0) { bits, p -> bits or p.bit }).int(options.maxFaces).done()
        return model.run(input, opts, failureMessage = "analysis failed", decode = ::decodeAnalysis)
    }

    /** Release the native model. Calling this again is a no-op. */
    @Synchronized override fun close() = model.close()

    companion object {
        /**
         * Groups of near-duplicates, as indices into [analyses], each at least two photos, best first. With [dates]
         * (capture times in seconds, any epoch), only photos taken within the model's window of each other count.
         */
        @JvmStatic @JvmOverloads
        fun duplicates(analyses: List<Analysis>, dates: List<Double?>? = null): List<List<Int>> = Collections.duplicates(analyses, dates)

        /** The index of the photo to keep from a set: no closed eyes, then the best faces, then keeper. */
        @JvmStatic fun best(analyses: List<Analysis>): Int? = Collections.best(analyses)

        /** Photos ranked by similarity to [photo], most similar first: (index into [analyses], cosine similarity). */
        @JvmStatic @JvmOverloads
        fun similar(photo: Analysis, analyses: List<Analysis>, limit: Int = 20): List<Pair<Int, Double>> =
            Collections.similar(photo, analyses, limit)
    }
}

private fun FfiReader.dist(): Map<String, Double> {
    val out = LinkedHashMap<String, Double>()
    repeat(int()) { out[string()] = double() }
    return out
}

private fun FfiReader.box() = Box(double(), double(), double(), double())

private fun FfiReader.grid(): Grid {
    val width = int()
    val height = int()
    return Grid(width, height, floats())
}

private fun FfiReader.detections(): List<Detection> = List(int()) { Detection(string(), double(), box()) }

private fun decodeAnalysis(r: FfiReader): Analysis {
    val json = JSONObject(r.string())
    return Analysis.fromJson(json, decodeDetails(r))
}

private fun decodeDetails(r: FfiReader): Details {
    val photo = if (r.int() == 1) {
        val embedding = r.floats()
        val type = r.dist(); val reject = r.dist(); val sensitive = r.dist(); val scenes = r.dist()
        val rotation = r.dist().mapKeys { it.key.toInt() }
        val aesthetic = r.double(); val attributes = r.dist()
        val keeper = r.double(); val cover = r.double()
        val blur = r.dist(); val bokeh = r.double()
        Photo(embedding, type, reject, sensitive, scenes, rotation, aesthetic, attributes, keeper, cover, blur, bokeh,
            r.dist(), r.dist())
    } else null
    val layout = if (r.int() == 1) {
        val attention = r.grid(); val people = r.detections(); val pets = r.detections(); val shot = r.dist()
        val flat = r.floats()
        val crops = List(flat.size / 5) { i ->
            Crop(Box(flat[i * 5].toDouble(), flat[i * 5 + 1].toDouble(), flat[i * 5 + 2].toDouble(), flat[i * 5 + 3].toDouble()),
                flat[i * 5 + 4].toDouble())
        }
        Layout(attention, people, pets, shot, crops)
    } else null
    val faces = if (r.int() == 1) List(r.int()) {
        val box = r.box(); val confidence = r.double()
        val landmarks = List(r.int()) { Point(r.double(), r.double()) }
        val isFace = r.double(); val isReal = r.double(); val eyesOpen = r.double()
        val blink = r.dist(); val smile = r.double(); val mouth = r.dist(); val expression = r.dist()
        val looking = r.double(); val occlusion = r.dist(); val sharp = r.double(); val lighting = r.dist()
        val keepsake = r.double()
        val pose = Pose(r.double(), r.double(), r.double())
        FaceDetails(box, confidence, landmarks, isFace, isReal, eyesOpen, blink, smile, mouth, expression, looking, occlusion,
            sharp, lighting, keepsake, pose, r.double())
    } else null
    val sharpness = if (r.int() == 1) Sharpness(r.double(), r.grid()) else null
    return Details(photo, layout, faces, sharpness)
}

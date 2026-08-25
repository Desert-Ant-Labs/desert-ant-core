package ai.desertant.ear

import ai.desertant.core.FfiWriter
import ai.desertant.core.LoadedModel

/** The catalog id, which is how the shared native layer is asked for Ear. */
private const val MODEL_ID = "ear"
private const val MODEL_NAME = "Ear"

/** The rate the model works at. Audio at any other rate is resampled. */
const val SAMPLE_RATE: Double = 16_000.0

/** A candidate language and how likely the model thinks it is. */
data class LanguageCandidate(
    /** ISO 639-1 where one exists, otherwise 639-3. */
    val language: String,
    /** `0..1`, averaged over the windows that were listened to. */
    val probability: Double,
)

/** What the model heard. */
data class Detection(
    /** Candidates, most likely first. */
    val candidates: List<LanguageCandidate>,
    /** How many windows of audio the answer is averaged over. */
    val windows: Int,
    /**
     * Whether this answer is worth routing work on.
     *
     * False when the top two candidates are too close to separate, and false
     * for the Nordic languages, which the model confuses with each other
     * confidently rather than uncertainly - so their probability does not
     * reveal the problem and a margin test cannot catch it. Branch on this
     * rather than on [confidence].
     *
     * Decided natively rather than recomputed here: the rule behind it is
     * measured, and three SDKs reimplementing it is three chances to differ.
     */
    val isReliable: Boolean,
) {
    /** The detected language, or null if there was nothing to listen to. */
    val language: String? get() = candidates.firstOrNull()?.language

    /** The detected language's probability, `0..1`. */
    val confidence: Double get() = candidates.firstOrNull()?.probability ?: 0.0
}

/** How much audio to listen to. */
data class Options(
    /**
     * How many thirty-second windows to sample. Windows are chosen by how
     * speech-like they are rather than by position, so a jingle or a long
     * silence does not decide the answer; shorter recordings use fewer.
     */
    val windows: Int = 3,
)

class EarException(message: String) : Exception(message)

/**
 * On-device spoken language identification: name the language of a recording
 * before you transcribe it. Mirrors the iOS/Swift SDK: create one `Ear` and
 * reuse it; the model loads lazily on the first [identify] (or eagerly via
 * [download]).
 *
 * ```kotlin
 * val ear = Ear(context)                       // downloads on first use
 * val d = ear.identify(samples, 16_000.0)
 * if (d.isReliable) route(d.language)
 * ear.close()
 * ```
 *
 * Creating, downloading, running, and releasing the model are the shared
 * `ai.desertant:core` shell ([LoadedModel]); what lives here is Ear's API and
 * its payload schemas.
 *
 * @param directory the model's home. Files already there are adopted (so an app
 *   that ships the model just points at the folder it unpacked it into),
 *   otherwise the model is downloaded into it. Omit to use the app cache.
 */
class Ear(
    context: android.content.Context,
    directory: String? = null,
) : AutoCloseable {
    private val model = LoadedModel(MODEL_ID, MODEL_NAME, context, directory, ::EarException, EarNative)

    companion object

    /** Whether the model is available for this identifier with no network. */
    fun isDownloaded(): Boolean = model.isDownloaded()

    /**
     * Download the model ahead of time so the first [identify] is instant. A
     * no-op once available (see [isDownloaded]). Suspends on a background
     * dispatcher.
     */
    suspend fun download() = model.download()

    /**
     * Name the language of mono [samples] at [sampleRate]. Loads the model
     * lazily on first call. Audio at any rate is accepted; 16 kHz avoids the
     * conversion.
     */
    suspend fun identify(
        samples: FloatArray,
        sampleRate: Double = SAMPLE_RATE,
        options: Options = Options(),
    ): Detection {
        require(samples.isNotEmpty()) { "no samples" }
        require(sampleRate > 0) { "sampleRate must be positive" }

        // Input payload: f32Array samples, then f64 sampleRate.
        val input = FfiWriter().floats(samples).double(sampleRate).done()
        // Options payload: f64 windows.
        val opts = FfiWriter().double(options.windows.toDouble()).done()

        return model.run(input, opts, failureMessage = "language identification failed") { r ->
            val count = r.int()
            val candidates = ArrayList<LanguageCandidate>(count)
            repeat(count) { candidates.add(LanguageCandidate(r.string(), r.double())) }
            val windows = r.double().toInt()
            val reliable = r.double() == 1.0
            Detection(candidates, windows, reliable)
        }
    }

    /** Release the model. The identifier is unusable afterwards. */
    override fun close() = model.close()
}

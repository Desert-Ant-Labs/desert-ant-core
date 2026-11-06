package ai.desertant.uhm

import ai.desertant.core.FfiWriter
import ai.desertant.core.LoadedModel

/** The catalog id, which is how the shared native layer is asked for Uhm. */
private const val MODEL_ID = "uhm"
private const val MODEL_NAME = "Uhm"

/** The rate the model works at. Audio at any other rate is resampled. */
const val SAMPLE_RATE: Double = 16_000.0

/** The confidence threshold presets, the same numbers as the Swift and JS SDKs. */
enum class Bias(val threshold: Double) {
    /** For automatic cuts. */
    PRECISION(0.75),
    /** The default. */
    BALANCED(0.65),
    /** When someone reviews each filler before the cut. */
    RECALL(0.50),
}

/** A filler span, in seconds from the start of the audio. */
data class Filler(
    val start: Double,
    val end: Double,
    /** Model confidence for the span, `0..1`. */
    val confidence: Double,
    /** Always null on Android: the type labeler runs only on Apple platforms. */
    val type: String?,
)

/** A transcript word, in seconds from the start of the audio. */
data class Word(val start: Double, val end: Double, val text: String)

data class Options(
    val bias: Bias = Bias.BALANCED,
    /** Overrides [bias] when set. */
    val minConfidence: Double? = null,
    /** Drop spans shorter than this, in seconds. Null keeps the SDK default of 0.12. */
    val minDurationSec: Double? = null,
    /** Minimum share of a word a filler must overlap before the word is adjusted. */
    val minOverlapFraction: Double = 0.5,
    /** When a word contains a filler, keep both halves instead of the longer one. */
    val splitContainedWords: Boolean = false,
)

data class UhmResult(
    /** Detected fillers, in time order. */
    val fillers: List<Filler>,
    /** Decoded audio length, in seconds. */
    val audioDuration: Double,
    /** The words you passed, adjusted so a cut at a filler keeps every real word. Null when no words were passed. */
    val words: List<Word>?,
)

/** Thrown when the model cannot be created, loaded, or run. */
class UhmException(message: String) : Exception(message)

/**
 * On-device filler-word detection. Create one `Uhm` and reuse it; the model
 * loads on the first [detect], or earlier through [download].
 *
 * ```kotlin
 * val uhm = Uhm(context)                       // downloads on first use
 * val result = uhm.detect(samples, 16_000.0)
 * result.fillers.forEach { println("${it.start} ${it.end} ${it.confidence}") }
 * uhm.close()
 * ```
 *
 * @param directory the model's home. Files already there are used, otherwise
 *   the model is downloaded into it. Omit to use the app cache.
 */
class Uhm(
    context: android.content.Context,
    directory: String? = null,
) : AutoCloseable {
    private val model = LoadedModel(MODEL_ID, MODEL_NAME, context, directory, ::UhmException, UhmNative)

    companion object

    /** Whether the model is available with no network. */
    fun isDownloaded(): Boolean = model.isDownloaded()

    /** Download the model ahead of time so the first [detect] is instant. */
    suspend fun download() = model.download()

    /**
     * Find filler spans in mono [samples] at [sampleRate]. Pass [words] from
     * your transcript to get them back in [UhmResult.words], adjusted to the fillers.
     */
    suspend fun detect(
        samples: FloatArray,
        sampleRate: Double = SAMPLE_RATE,
        options: Options = Options(),
        words: List<Word>? = null,
    ): UhmResult {
        require(samples.isNotEmpty()) { "no samples" }
        require(sampleRate > 0) { "sampleRate must be positive" }

        // Payload layouts must match Sources/Uhm/Binding.swift.
        val input = FfiWriter().floats(samples).double(sampleRate)
        if (words != null) {
            input.int(words.size)
            for (w in words) input.double(w.start).double(w.end).string(w.text)
        }
        val opts = FfiWriter()
            .double(options.minConfidence ?: options.bias.threshold)
            .double(options.minDurationSec ?: Double.NaN)
            .int(0)
            .double(options.minOverlapFraction)
            .int(if (options.splitContainedWords) 1 else 0)
            .done()

        return model.run(input.done(), opts, failureMessage = "filler detection failed") { r ->
            val audioDuration = r.double()
            val fillers = List(r.int()) {
                val start = r.double()
                val end = r.double()
                val confidence = r.double()
                Filler(start, end, confidence, r.string().ifEmpty { null })
            }
            val reconciled = if (words != null) {
                List(r.int()) {
                    val start = r.double()
                    val end = r.double()
                    Word(start, end, r.string())
                }
            } else null
            UhmResult(fillers, audioDuration, reconciled)
        }
    }

    /** Release the model. The detector is unusable afterwards; calling this again is a no-op. */
    @Synchronized override fun close() = model.close()
}

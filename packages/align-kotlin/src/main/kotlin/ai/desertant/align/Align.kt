package ai.desertant.align

import ai.desertant.core.FfiWriter
import ai.desertant.core.LoadedModel

/** The catalog id, which is how the shared native layer is asked for Align. */
private const val MODEL_ID = "align"
private const val MODEL_NAME = "Align"

/** The rate the model works at. Audio at any other rate is resampled. */
const val SAMPLE_RATE: Double = 16_000.0

/** The time range a word may carry, in seconds: the same bounds as Swift's `Align.validate`. */
private const val MIN_SECONDS = -1.0
private const val MAX_SECONDS = 10_000_000.0

/** The largest resampled buffer the core accepts, about 37 hours at 16 kHz: Swift's `Align.maxResampledCount`. */
private const val MAX_RESAMPLED_COUNT = Int.MAX_VALUE.toDouble()

/** A transcript word, in seconds from the start of the audio. */
data class Word(
    val text: String,
    val start: Double,
    val end: Double,
    /** True when [Align.refine] corrected this word's times. False means they are the times you passed. */
    val refined: Boolean = false,
)

/** Thrown when the model cannot be created, loaded, or run. */
class AlignException(message: String) : Exception(message)

/**
 * On-device word-timestamp refinement. Create one `Align` and reuse it; the model
 * loads on the first [refine], or earlier through [download].
 *
 * ```kotlin
 * val align = Align(context)                   // downloads on first use
 * val refined = align.refine(samples, 16_000.0, words, language = "en")
 * refined.forEach { println("${it.text} ${it.start} ${it.end}") }
 * align.close()
 * ```
 *
 * @param directory the model's home. Files already there are used, otherwise
 *   the model is downloaded into it. Omit to use the app cache.
 */
class Align(
    context: android.content.Context,
    directory: String? = null,
) : AutoCloseable {
    private val model = LoadedModel(MODEL_ID, MODEL_NAME, context, directory, ::AlignException, AlignNative)

    companion object {
        /** The nine language codes the model was trained on. */
        val languages: List<String> = listOf("de", "en", "es", "fr", "it", "ja", "ko", "pt", "zh")

        /** True when [refine] will correct times for this language. False means the words come back unchanged. */
        fun isSupported(language: String): Boolean = language.take(2).lowercase() in languages
    }

    /** Whether the model is available with no network. */
    fun isDownloaded(): Boolean = model.isDownloaded()

    /** Download the model ahead of time so the first [refine] is instant. */
    suspend fun download() = model.download()

    /**
     * Correct the start and end of each of [words] against mono [samples] at [sampleRate].
     * [language] is a BCP-47 or bare ISO code, for example "en" or "pt-BR".
     *
     * The words come back in the same order. A word in a language the model does not
     * know, or more than about 1.2 s past the end of the audio, keeps its times.
     */
    suspend fun refine(
        samples: FloatArray,
        sampleRate: Double = SAMPLE_RATE,
        words: List<Word>,
        language: String,
    ): List<Word> {
        require(samples.isNotEmpty()) { "no samples" }
        require(sampleRate.isFinite() && sampleRate > 0) { "sampleRate is $sampleRate, expected a finite positive rate" }
        require(sampleRate == SAMPLE_RATE || samples.size * SAMPLE_RATE / sampleRate <= MAX_RESAMPLED_COUNT) {
            "${samples.size} samples at $sampleRate Hz is too long to resample"
        }
        words.forEachIndexed { i, word ->
            for ((name, t) in listOf("start" to word.start, "end" to word.end)) {
                require(t.isFinite() && t >= MIN_SECONDS && t <= MAX_SECONDS) {
                    "word $i $name is $t, expected a time from $MIN_SECONDS to $MAX_SECONDS seconds"
                }
            }
        }

        // Payload layouts must match Sources/Align/Binding.swift.
        val input = FfiWriter().floats(samples).double(sampleRate).int(words.size)
        for (w in words) input.string(w.text).double(w.start).double(w.end)
        val opts = FfiWriter().string(language).done()

        return model.run(input.done(), opts, failureMessage = "timestamp refinement failed") { r ->
            val count = r.int()
            if (count != words.size) throw AlignException("core returned $count words for ${words.size}")
            words.map { word ->
                val start = r.double()
                val end = r.double()
                word.copy(start = start, end = end, refined = r.int() == 1)
            }
        }
    }

    /** Release the model. The refiner is unusable afterwards; calling this again is a no-op. */
    @Synchronized override fun close() = model.close()
}

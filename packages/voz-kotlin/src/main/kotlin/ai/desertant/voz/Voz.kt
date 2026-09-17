package ai.desertant.voz

import ai.desertant.core.FfiWriter
import ai.desertant.core.LoadedModel

/** The catalog id, which is how the shared native layer is asked for Voz. */
private const val MODEL_ID = "voz"
private const val MODEL_NAME = "Voz"

/** The rate the model works at. Audio at any other rate is resampled. */
const val SAMPLE_RATE: Double = 16_000.0

/** A word and when it sounds, in seconds from the beginning of the audio. */
data class Word(
    val text: String,
    /** When the word starts. Resolution is 80 ms. */
    val start: Double,
    /** When the word stops sounding. Never before [start]. */
    val end: Double,
)

/** What the model heard. */
data class Transcription(
    /** The full transcript. */
    val text: String,
    /** Every word with the time it starts and ends. */
    val words: List<Word>,
    /** Length of the audio transcribed, in seconds. */
    val duration: Double,
)

class VozException(message: String) : Exception(message)

/**
 * On-device speech recognition: a transcript with word-level timestamps.
 * Mirrors the iOS/Swift SDK: create one `Voz` and reuse it; the model loads
 * lazily on the first [transcribe] (or eagerly via [download]).
 *
 * ```kotlin
 * val voz = Voz(context)                       // downloads on first use
 * val t = voz.transcribe(samples, 16_000.0)
 * println(t.text)
 * voz.close()
 * ```
 *
 * The model does not detect which language it is hearing, and audio in a
 * language it was not trained on produces confident nonsense rather than an
 * error; a caller routing mixed input should name the language first (see
 * `ai.desertant:ear`).
 *
 * Creating, downloading, running, and releasing the model are the shared
 * `ai.desertant:core` shell ([LoadedModel]); what lives here is Voz's API and
 * its payload schemas.
 *
 * @param directory the model's home. Files already there are adopted (so an app
 *   that ships the model just points at the folder it unpacked it into),
 *   otherwise the model is downloaded into it. Omit to use the app cache.
 */
class Voz(
    context: android.content.Context,
    directory: String? = null,
) : AutoCloseable {
    private val model = LoadedModel(MODEL_ID, MODEL_NAME, context, directory, ::VozException, VozNative)

    companion object

    /** Whether the model is available for this recogniser with no network. */
    fun isDownloaded(): Boolean = model.isDownloaded()

    /**
     * Download the model ahead of time so the first [transcribe] is instant. A
     * no-op once available (see [isDownloaded]). Suspends on a background
     * dispatcher.
     */
    suspend fun download() = model.download()

    /**
     * Transcribe mono [samples] at [sampleRate]. Loads the model lazily on
     * first call. Audio at any rate is accepted; 16 kHz avoids the conversion.
     *
     * Long audio is fine: the recogniser windows, decodes and splices
     * natively, so the transcript comes back whole with monotonic word times.
     */
    suspend fun transcribe(
        samples: FloatArray,
        sampleRate: Double = SAMPLE_RATE,
    ): Transcription {
        require(samples.isNotEmpty()) { "no samples" }
        require(sampleRate > 0) { "sampleRate must be positive" }

        // Input payload: f32Array samples, then f64 sampleRate.
        val input = FfiWriter().floats(samples).double(sampleRate).done()

        // Result payload: string text, u32 count, count x (string, f64 start,
        // f64 end), then f64 duration. Appended, never reordered.
        return model.run(input, options = null, failureMessage = "transcription failed") { r ->
            val text = r.string()
            val count = r.int()
            val words = ArrayList<Word>(count)
            repeat(count) { words.add(Word(r.string(), r.double(), r.double())) }
            Transcription(text, words, r.double())
        }
    }

    /** Release the model. The recogniser is unusable afterwards. */
    override fun close() = model.close()
}

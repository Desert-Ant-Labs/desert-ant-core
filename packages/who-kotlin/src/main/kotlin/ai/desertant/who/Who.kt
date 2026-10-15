package ai.desertant.who

import ai.desertant.core.FfiWriter
import ai.desertant.core.LoadedModel

/** The catalog id, which is how the shared native layer is asked for Who. */
private const val MODEL_ID = "who"
private const val MODEL_NAME = "Who"

/** The rate the model works at. Audio at any other rate is resampled. */
const val SAMPLE_RATE: Double = 16_000.0

/** One stretch of one speaker's speech, in seconds from the beginning of the audio. */
data class Turn(
    /** The speaker, numbered from 0 in order of first appearance. */
    val speaker: Int,
    /** When the turn starts. Resolution is 10 ms. */
    val start: Double,
    /** When the turn ends. Never before [start]. */
    val end: Double,
) {
    val duration: Double get() = end - start
}

/** Who spoke when. */
data class Diarization(
    /** Every turn, by start time. Turns of different speakers may overlap. */
    val turns: List<Turn>,
    /** How many speakers were found; the turns use 0 until this minus one. */
    val speakerCount: Int,
    /** Length of the audio diarized, in seconds. */
    val duration: Double,
) {
    /** The turns of one speaker. */
    fun turns(of: Int): List<Turn> = turns.filter { it.speaker == of }

    /**
     * The speakers whose speech adds up to at least [share] of the recording. A laugh, an audience
     * or a jingle can get a number of its own; a share of a few percent leaves the real voices.
     * A share of 0 keeps everyone.
     */
    fun speakers(minimumShare: Double): List<Int> {
        val total = DoubleArray(speakerCount)
        for (turn in turns) total[turn.speaker] += turn.duration
        return (0 until speakerCount).filter { total[it] >= minimumShare * duration }
    }

    /**
     * The same result without the speakers under [minimumShare] of the recording: their turns are
     * gone and the rest are numbered by first appearance again.
     */
    fun keepingSpeakers(minimumShare: Double): Diarization {
        val kept = speakers(minimumShare).toSet()
        if (kept.size == speakerCount) return this
        val remaining = turns.filter { it.speaker in kept }
        val renumbered = HashMap<Int, Int>()
        for (turn in remaining) renumbered.getOrPut(turn.speaker) { renumbered.size }
        return Diarization(
            remaining.map { Turn(renumbered.getValue(it.speaker), it.start, it.end) },
            renumbered.size,
            duration,
        )
    }
}

class WhoException(message: String) : Exception(message)

/**
 * On-device speaker labeling: who spoke when, as turns with timestamps, in one
 * pass over the audio. Mirrors the Swift SDK: create one `Who` and reuse it; the
 * model loads lazily on the first [diarize] (or eagerly via [download]).
 *
 * ```kotlin
 * val who = Who(context)                       // downloads on first use
 * val result = who.diarize(samples, 16_000.0)
 * result.speakerCount                          // 3
 * for (turn in result.turns) println("${turn.speaker} ${turn.start} ${turn.end}")
 * who.close()
 * ```
 *
 * Who follows up to four speakers in any five-minute stretch; a longer recording is
 * read in pieces whose speakers are matched by voice, so it can hold more.
 *
 * Creating, downloading, running, and releasing the model are the shared
 * `ai.desertant:core` shell ([LoadedModel]); what lives here is Who's API and
 * its payload schemas.
 *
 * @param directory the model's home. Files already there are adopted (so an app
 *   that ships the model just points at the folder it unpacked it into),
 *   otherwise the model is downloaded into it. Omit to use the app cache.
 */
class Who(
    context: android.content.Context,
    directory: String? = null,
) : AutoCloseable {
    private val model = LoadedModel(MODEL_ID, MODEL_NAME, context, directory, ::WhoException, WhoNative)

    companion object

    /** Whether the model is available for this diarizer with no network. */
    fun isDownloaded(): Boolean = model.isDownloaded()

    /**
     * Download the model ahead of time so the first [diarize] is instant. A
     * no-op once available (see [isDownloaded]). Suspends on a background
     * dispatcher.
     */
    suspend fun download() = model.download()

    /**
     * Label the speakers of mono [samples] at [sampleRate]. Loads the model lazily
     * on first call. Audio at any rate is accepted; 16 kHz avoids the conversion.
     *
     * Long audio is fine: the model reads the recording in five-minute pieces and
     * matches the speakers across them natively, so the turns come back whole.
     */
    suspend fun diarize(
        samples: FloatArray,
        sampleRate: Double = SAMPLE_RATE,
    ): Diarization {
        require(samples.isNotEmpty()) { "no samples" }
        require(sampleRate > 0) { "sampleRate must be positive" }

        // Input payload: f32Array samples, then f64 sampleRate.
        val input = FfiWriter().floats(samples).double(sampleRate).done()

        // Result payload: u32 speakerCount, u32 count, count x (u32 speaker, f64 start,
        // f64 end), then f64 duration. Appended, never reordered.
        return model.run(input, options = null, failureMessage = "diarization failed") { r ->
            val speakerCount = r.int()
            val count = r.int()
            val turns = ArrayList<Turn>(count)
            repeat(count) { turns.add(Turn(r.int(), r.double(), r.double())) }
            Diarization(turns, speakerCount, r.double())
        }
    }

    /** Release the model. The diarizer is unusable afterwards. */
    override fun close() = model.close()
}

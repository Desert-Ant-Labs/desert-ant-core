package ai.desertant.clear

import ai.desertant.core.FfiWriter
import ai.desertant.core.LoadedModel

/** The catalog id, which is how the shared native layer is asked for Clear. */
private const val MODEL_ID = "clear"
private const val MODEL_NAME = "Clear"

/** Standard delivery loudness targets, in integrated LUFS. */
enum class LoudnessPreset(val integratedLufs: Double) {
    APPLE_PODCASTS(-19.0),
    SPOTIFY(-14.0),
    YOUTUBE(-14.0),
    BROADCAST(-23.0),
}

/** Post-DSP mastering: where the enhanced audio should land, loudness-wise. */
data class Mastering(
    /** Integrated loudness target in LUFS. */
    val integratedLufs: Double = LoudnessPreset.APPLE_PODCASTS.integratedLufs,
    /** True-peak ceiling in dBTP. -1.5 leaves headroom for lossy codecs. */
    val truePeakDbtp: Double = -1.5,
    /** Upper bound on the loudness gain in dB, so a very quiet input lands
     *  under target rather than lifting the model's noise floor with it. */
    val maxLoudnessGainDb: Double = 9.0,
    /** Set false to return the unmastered model output. */
    val enabled: Boolean = true,
) {
    companion object {
        fun of(preset: LoudnessPreset): Mastering = Mastering(integratedLufs = preset.integratedLufs)

        /** Skip mastering: the output level tracks the input. */
        val BYPASS: Mastering = Mastering(enabled = false)
    }
}

/** Options controlling enhancement and mastering. */
data class Options(
    /** Enhancement blend in `0.0..1.0`. 1.0 is the full model output. */
    val strength: Double = 1.0,
    val mastering: Mastering = Mastering(),
)

/** The enhanced audio, and what mastering measured on the way out. */
data class Result(
    /** Enhanced audio: 48 kHz mono, whatever the input rate was. */
    val samples: FloatArray,
    /** Always 48000.0. */
    val sampleRate: Double,
    /** Length of the output in seconds. */
    val durationSec: Double,
    /** Wall-clock time the enhance took. */
    val processingSec: Double,
    /** Integrated loudness of the *input*, or null when mastering was bypassed. */
    val measuredLufs: Double?,
    /**
     * True peak of the delivered audio in dBFS (4x oversampled), or null when
     * mastering was bypassed. Measured after limiting, so it is what to assert
     * a delivery spec against.
     */
    val measuredTruePeakDbfs: Double?,
) {
    /** Above 1.0 is faster than real time. */
    val realtimeFactor: Double get() = if (processingSec > 0) durationSec / processingSec else 0.0

    // FloatArray needs identity-free equals/hashCode to behave as a data class.
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is Result) return false
        return samples.contentEquals(other.samples) &&
            sampleRate == other.sampleRate &&
            durationSec == other.durationSec &&
            processingSec == other.processingSec &&
            measuredLufs == other.measuredLufs &&
            measuredTruePeakDbfs == other.measuredTruePeakDbfs
    }

    override fun hashCode(): Int {
        var result = samples.contentHashCode()
        result = 31 * result + sampleRate.hashCode()
        result = 31 * result + durationSec.hashCode()
        result = 31 * result + processingSec.hashCode()
        result = 31 * result + (measuredLufs?.hashCode() ?: 0)
        result = 31 * result + (measuredTruePeakDbfs?.hashCode() ?: 0)
        return result
    }
}

/** Thrown when the model cannot be created, loaded, or run. */
class ClearException(message: String) : Exception(message)

/**
 * On-device speech enhancement: denoise, dereverb, and loudness-normalize.
 * Mirrors the iOS/Swift SDK: create one `Clear` and reuse it; the model loads
 * lazily on the first [enhance] (or eagerly via [download]).
 *
 * ```kotlin
 * val clear = Clear(context)                   // downloads on first use
 * val r = clear.enhance(samples, 48_000.0)
 * r.samples                                    // 48 kHz mono
 * clear.close()
 * ```
 *
 * Creating, downloading, running, and releasing the model are the shared
 * `ai.desertant:core` shell ([LoadedModel]); what lives here is Clear's API and
 * its payload schemas.
 *
 * @param directory the model's home. Files already there are adopted (so an app
 *   that ships the model just points at the folder it unpacked it into),
 *   otherwise the model is downloaded into it. Omit to use the app cache.
 */
class Clear(
    context: android.content.Context,
    directory: String? = null,
) : AutoCloseable {
    private val model = LoadedModel(MODEL_ID, MODEL_NAME, context, directory, ::ClearException, ClearNative)

    companion object

    /** Whether the model is available for this enhancer with no network. */
    fun isDownloaded(): Boolean = model.isDownloaded()

    /**
     * Download the model ahead of time so the first [enhance] is instant. A
     * no-op once available (see [isDownloaded]). Suspends on a background
     * dispatcher.
     */
    suspend fun download() = model.download()

    /**
     * Enhance mono [samples] at [sampleRate], returning 48 kHz mono whatever
     * the input rate. Loads the model lazily on first call.
     */
    suspend fun enhance(
        samples: FloatArray,
        sampleRate: Double = 48_000.0,
        options: Options = Options(),
    ): Result {
        // Input payload: the samples, then the sample rate. Options payload:
        // f64 strength, then the mastering chain as f64 integratedLUFS (NaN
        // bypasses), f64 truePeakDBTP, f64 maxLoudnessGainDB. Result payload:
        // the samples, then f64 sampleRate/durationSec/processingSec, and the
        // two measurements (NaN when bypassed). All three must match
        // Sources/Clear/Binding.swift.
        val input = FfiWriter().floats(samples).double(sampleRate).done()
        val m = options.mastering
        val payload = FfiWriter()
            .double(options.strength)
            .double(if (m.enabled) m.integratedLufs else Double.NaN)
            .double(m.truePeakDbtp)
            .double(m.maxLoudnessGainDb)
            .done()
        return model.run(input, payload, failureMessage = "enhance failed") { r ->
            val out = r.floats()
            val rate = r.double()
            val duration = r.double()
            val processing = r.double()
            val lufs = r.double()
            // Appended after the first release: a core built before it leaves
            // nothing to read, and the field reads as absent.
            val truePeak = if (r.hasRemaining()) r.double() else Double.NaN
            Result(
                samples = out,
                sampleRate = rate,
                durationSec = duration,
                processingSec = processing,
                measuredLufs = lufs.takeUnless { it.isNaN() },
                measuredTruePeakDbfs = truePeak.takeUnless { it.isNaN() },
            )
        }
    }

    /** Release the native model. The enhancer is unusable afterwards; calling
     *  this again is a no-op. */
    @Synchronized override fun close() = model.close()
}

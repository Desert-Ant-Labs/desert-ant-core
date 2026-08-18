package ai.desertant.tongue

import ai.desertant.tongue.usage.UsageTurnstile

/**
 * On-device language identification for short text, across 84 languages.
 *
 * ```kotlin
 * val tongue = Tongue.bundled()
 * tongue.detect("kann ich das haben").language   // "de"
 * ```
 *
 * A direct Kotlin port rather than a JNI binding over the Swift core. That is a
 * deliberate departure from emo and toxic: their pipelines are a tokenizer plus a
 * transformer plus an inference session, so writing them once in Swift and
 * bridging is clearly right. This pipeline is arithmetic — an int8 gather, a sum,
 * one 59x32 matmul and a masked softmax — so bridging would cost ~51 MB of static
 * Swift runtime per ABI to serve 2 MB of weights (see ANDROID.md). Pure Kotlin
 * needs no native library, no JNI and no cross-compile, and works unchanged on
 * the JVM and on Android.
 *
 * The safety normally bought by having one implementation is bought here instead
 * by the shared vectors: the normalizer, hasher and router are a frozen
 * specification, and `GoldenVectorTest` replays the same vector files the Swift
 * and JavaScript ports do, byte for byte.
 */
public class Tongue internal constructor(
    private val metadata: Metadata,
    private val weights: Weights,
    private val usage: UsageTurnstile? = null,
) {
    public companion object {
        /**
         * Load the model bundled in this artifact's resources.
         *
         * On Android, pass the `Context` overload instead: without one there is
         * nowhere durable to keep the usage device id, so every process looks like
         * a new device. See docs/USAGE.md.
         */
        @JvmStatic
        public fun bundled(): Tongue = bundled(null)

        /**
         * Load the bundled model, giving usage tracking somewhere to persist.
         *
         * `context` is an `android.content.Context`, typed as `Any` so this stays
         * a plain jar that also runs on a bare JVM — it is never compiled against
         * the Android SDK. Anything else is ignored.
         */
        @JvmStatic
        public fun bundled(context: Any?): Tongue {
            val loader = Tongue::class.java.classLoader
            val metadataJson = loader.getResourceAsStream("tongue_meta.json")?.use {
                it.readBytes().toString(Charsets.UTF_8)
            } ?: throw TongueException("tongue_meta.json is missing from the artifact resources")
            val weightBytes = loader.getResourceAsStream("tongue_int8.bin")?.use { it.readBytes() }
                ?: throw TongueException("tongue_int8.bin is missing from the artifact resources")
            return of(metadataJson, weightBytes, context)
        }

        /** Load from raw bytes, for an on-demand download or a custom build. */
        @JvmStatic
        @JvmOverloads
        public fun of(metadataJson: String, weightBytes: ByteArray, context: Any? = null): Tongue {
            val metadata = Metadata.parse(metadataJson)
            return Tongue(metadata, Weights(weightBytes, metadata), UsageTurnstile.create(context))
        }
    }

    /** Identify the language of a short string. */
    @JvmOverloads
    public fun detect(text: String, topK: Int = 3): Detection {
        usage?.record()
        val normalized = Normalizer.normalize(text)
        val route = Router.route(normalized)

        if (normalized.isEmpty()) {
            return Detection(normalized, emptyList(), Reliability.EMPTY, route)
        }
        // A script only one language uses needs no model, and no guessing is
        // involved, so it is always reported confident.
        if (route.verdict == Verdict.DECISIVE) {
            val language = route.candidates.firstOrNull()
            if (language != null) {
                return Detection(
                    normalized, listOf(Prediction(language, 1.0)), Reliability.CONFIDENT, route
                )
            }
        }

        val allowed = if (route.verdict == Verdict.NARROWING) {
            metadata.labels.filter { it in route.candidates }
        } else {
            metadata.latinLabels
        }
        if (allowed.isEmpty()) {
            return Detection(normalized, emptyList(), Reliability.EMPTY, route)
        }

        val ranked = weights.rank(normalized, allowed.toSet(), topK)
        return Detection(normalized, ranked, reliabilityOf(normalized, ranked), route)
    }

    /**
     * Keyed off evidence — input length and how far the top candidate leads the
     * runner-up — not raw softmax confidence, which is badly overconfident on very
     * short text. `"hi i am"` reads as Welsh to any character model at high
     * probability; the margin and the length are what reveal it as a guess.
     */
    private fun reliabilityOf(text: String, ranked: List<Prediction>): Reliability {
        val characters = text.codePointCount(0, text.length)
        val margin = when {
            ranked.size > 1 -> ranked[0].probability - ranked[1].probability
            ranked.isNotEmpty() -> ranked[0].probability
            else -> 0.0
        }
        return when {
            characters >= 18 && margin >= 0.30 -> Reliability.CONFIDENT
            characters >= 12 && margin >= 0.20 -> Reliability.LIKELY
            else -> Reliability.TENTATIVE
        }
    }
}

/** How much to trust an answer. */
public enum class Reliability { CONFIDENT, LIKELY, TENTATIVE, EMPTY }

/** Which stage answered. */
public enum class Verdict { DECISIVE, NARROWING, AMBIGUOUS }

public data class Prediction(
    /** ISO 639-1 or 639-3 code. */
    val language: String,
    val probability: Double,
)

public data class Route(
    val verdict: Verdict,
    val candidates: List<String>,
    val script: String?,
)

public data class Detection(
    val normalized: String,
    val candidates: List<Prediction>,
    val reliability: Reliability,
    val route: Route,
) {
    public val language: String? get() = candidates.firstOrNull()?.language

    /**
     * True when the top two candidates are too close to separate. Present both
     * rather than crowning one: `"la casa"` is equally Italian and Spanish, and
     * saying so is more useful than picking.
     */
    public val isTooCloseToCall: Boolean
        get() = candidates.size > 1 &&
            candidates[0].probability - candidates[1].probability < 0.12
}

public class TongueException(message: String) : RuntimeException(message)

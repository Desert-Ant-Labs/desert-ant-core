package ai.desertant.tongue

/**
 * On-device language identification for short text, across 84 languages.
 *
 * ```kotlin
 * val tongue = Tongue.bundled(context)   // null on a bare JVM
 * tongue.detect("kann ich das haben").language   // "de"
 * ```
 *
 * A direct Kotlin port rather than a JNI binding over the Swift core, unlike the
 * other models: this pipeline is arithmetic (an int8 gather, a sum, one 59x32
 * matmul and a masked softmax), so bridging would cost ~51 MB of static Swift
 * runtime per ABI to serve 2 MB of weights. Pure Kotlin needs no native library,
 * no JNI and no cross-compile, and works unchanged on the JVM and on Android.
 *
 * The safety normally bought by having one implementation is bought here instead
 * by the shared vectors: the normalizer, hasher and router are a frozen
 * specification, and `GoldenVectorTest` replays the same vector files the Swift
 * and JavaScript ports do, byte for byte.
 */
public class Tongue internal constructor(
    private val metadata: Metadata,
    private val weights: Weights,
) {
    public companion object {
        private const val NO_CONTEXT = "Pass the Context on Android, or null on a bare JVM."

        /** Load the model bundled in this artifact's resources. */
        @Deprecated(NO_CONTEXT)
        @JvmStatic
        public fun bundled(): Tongue = bundled(null)

        /**
         * Load the model bundled in this artifact's resources.
         *
         * `context` is an `android.content.Context`, typed as `Any` so this stays
         * a plain jar that also runs on a bare JVM. Tongue doesn't read it in this
         * release.
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

        /**
         * [of] without a `Context`, deprecated for the reason [bundled] is. An
         * explicit overload rather than the old `@JvmOverloads` one, so the Java
         * signature stays and only the no-context call warns.
         */
        @Deprecated(NO_CONTEXT)
        @JvmStatic
        public fun of(metadataJson: String, weightBytes: ByteArray): Tongue = of(metadataJson, weightBytes, null)

        /**
         * Load from raw bytes, for an on-demand download or a custom build.
         * `context` is as in `bundled(context)`. Its default is kept only so Kotlin code
         * compiled against the earlier release still links; a two-argument call
         * now resolves to the deprecated overload above.
         */
        @JvmStatic
        public fun of(metadataJson: String, weightBytes: ByteArray, context: Any? = null): Tongue {
            val metadata = Metadata.parse(metadataJson)
            return Tongue(metadata, Weights(weightBytes, metadata))
        }
    }

    @Deprecated("Has no effect: Tongue sends no requests. Returns true.")
    public fun flushTelemetry(): Boolean = true

    /** Identify the language of a short string. */
    @JvmOverloads
    public fun detect(text: String, topK: Int = 3): Detection {
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

        // Rank the runner-up even when one candidate was asked for: the margin
        // between the top two is what reliability and the tie flag are made of.
        val ranked = weights.rank(normalized, allowed.toSet(), if (topK == 1) 2 else topK)
        return Detection(
            normalized,
            if (topK == 1) ranked.take(1) else ranked,
            reliabilityOf(normalized, ranked),
            route,
            isTooCloseToCall = tooCloseToCall(ranked),
        )
    }

    /**
     * Keyed off evidence (input length and how far the top candidate leads the
     * runner-up), not raw softmax confidence, which is badly overconfident on very
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
    /**
     * True when the top two ranked candidates are too close to separate. Present
     * both rather than crowning one: `"la casa"` is equally Italian and Spanish,
     * and saying so is more useful than picking. Detection ranks the runner-up
     * whatever `topK` is, so this holds even when one candidate was returned;
     * ask for two to show them.
     */
    val isTooCloseToCall: Boolean = tooCloseToCall(candidates),
) {
    public val language: String? get() = candidates.firstOrNull()?.language
}

internal fun tooCloseToCall(ranked: List<Prediction>): Boolean =
    ranked.size > 1 && ranked[0].probability - ranked[1].probability < 0.12

public class TongueException(message: String) : RuntimeException(message)

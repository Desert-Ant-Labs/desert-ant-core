package ai.desertant.gist

import ai.desertant.core.FfiWriter
import ai.desertant.core.LoadedModel

/** The catalog id, which is how the shared native layer is asked for Gist. */
private const val MODEL_ID = "gist"
private const val MODEL_NAME = "Gist"

/** A single predicted topic and its probability, from [Gist.classify]. */
data class Topic(
    /** The taxonomy slug, e.g. `"technology"`. */
    val slug: String,
    /** The human-readable name, e.g. `"Technology & Software"`. */
    val name: String,
    /** The model's probability, from `0.0` to `1.0`. */
    val score: Double,
)

/** Thrown when the model cannot be created, loaded, or run. */
class GistException(message: String) : Exception(message)

/**
 * On-device, multi-label content topic tagging. Mirrors the iOS/Swift SDK: create
 * one `Gist` and reuse it; the model loads lazily on the first [classify] or
 * [scores] (or eagerly via [download]).
 *
 * ```kotlin
 * val gist = Gist(context)                        // download on demand, cached
 * val topics = gist.classify("How to start a podcast with just your iPhone")
 * // [Topic("technology", "Technology & Software", 0.93), ...]
 * gist.close()
 * ```
 *
 * Creating, downloading, running, and releasing the model are the shared
 * `ai.desertant:core` shell ([LoadedModel]); what lives here is Gist's API and
 * its payload schemas.
 *
 * The English-only model build is currently selectable from the Swift SDK only.
 *
 * @param directory the model's home. Files already there are adopted (so an app
 *   that ships the model just points at the folder it unpacked it into),
 *   otherwise the model is downloaded into it. Omit to use the app cache.
 */
class Gist(
    context: android.content.Context,
    directory: String? = null,
) : AutoCloseable {
    private val model = LoadedModel(MODEL_ID, MODEL_NAME, context, directory, ::GistException, GistNative)

    companion object

    /** Whether the model is available for this tagger with no network. */
    fun isDownloaded(): Boolean = model.isDownloaded()

    /**
     * Download the model ahead of time so the first [classify] is instant. A
     * no-op once available (see [isDownloaded]). Suspends on a background
     * dispatcher.
     */
    suspend fun download() = model.download()

    /**
     * The full 36-topic probability distribution for [text] (slug to
     * probability). Feed these to [channelTopics] to roll a channel up. Empty or
     * blank input returns an empty map.
     */
    suspend fun scores(text: String): Map<String, Double> {
        if (text.isBlank()) return emptyMap()
        return tagged(text).scores
    }

    /**
     * The ranked topics for [text] above the model's tuned threshold, most likely
     * first. The top topic is always returned even when nothing clears the
     * threshold; [topK] caps the list and [threshold] overrides the model's own.
     * Empty or blank input returns an empty list.
     */
    suspend fun classify(text: String, topK: Int = 3, threshold: Double? = null): List<Topic> {
        if (text.isBlank()) return emptyList()
        val tagged = tagged(text)
        val cutoff = threshold ?: tagged.threshold
        // Ranked by score, ties broken by slug - the same order Swift produces.
        return tagged.scores.entries
            .sortedWith(compareByDescending<Map.Entry<String, Double>> { it.value }.thenBy { it.key })
            .take(topK)
            .filterIndexed { i, e -> e.value >= cutoff || i == 0 }
            .map { Topic(it.key, tagged.names[it.key] ?: it.key, it.value) }
    }

    /** One run, decoded. Both public calls need the same payload. */
    private suspend fun tagged(text: String): Tagged {
        // Input payload: the text. Options payload: empty. Result payload: an f64
        // tuned threshold, a count, then per topic a slug, a display name, and an
        // f64 probability - the whole taxonomy, ordered by slug. All three must
        // match Sources/Gist/Binding.swift.
        val input = FfiWriter().string(text).done()
        return model.run(input, failureMessage = "topic tagging failed") { r ->
            val threshold = r.double()
            val count = r.int()
            val scores = LinkedHashMap<String, Double>(count)
            val names = LinkedHashMap<String, String>(count)
            repeat(count) {
                val slug = r.string()
                names[slug] = r.string()
                scores[slug] = r.double()
            }
            Tagged(threshold, scores, names)
        }
    }

    private data class Tagged(
        val threshold: Double,
        val scores: Map<String, Double>,
        val names: Map<String, String>,
    )

    /** Release the native model. The tagger is unusable afterwards; calling this
     *  again is a no-op. */
    @Synchronized override fun close() = model.close()
}

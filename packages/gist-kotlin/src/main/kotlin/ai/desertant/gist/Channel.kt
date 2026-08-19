package ai.desertant.gist

import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max

/** One post's topic scores (slug to probability), from [Gist.scores]. */
data class PostTopics(
    val topics: Map<String, Double>,
    /** Epoch-milliseconds timestamp; enables recency weighting when both
     *  [RollupOptions.halfLifeDays] and [RollupOptions.nowMillis] are set. */
    val timestampMillis: Double? = null,
)

/** A channel-level topic in the ranked roll-up. */
data class ChannelTopic(
    val slug: String,
    /** Share of the channel's total topical weight, `0.0` to `1.0`. */
    val share: Double,
    /** Posts that meaningfully touch this topic. */
    val postCount: Int,
)

/** Options for [channelTopics]. Defaults match the Swift and JS SDKs. */
data class RollupOptions(
    val topN: Int = 5,
    val floor: Double = 0.05,
    val minPosts: Int = 3,
    /** Recency half-life. `0.0` (the default) disables decay. */
    val halfLifeDays: Double = 0.0,
    val touch: Double = 0.15,
    /** The clock decay is measured against. Defaults to `0.0`, which leaves
     *  decay off until you supply one. */
    val nowMillis: Double = 0.0,
)

/**
 * Aggregate a channel's per-post topic scores into a ranked list of channel-level
 * topics. Pure and deterministic — no model. Probability-weighted with optional
 * recency decay; a share floor and a minimum post count keep one-off posts from
 * characterizing a channel.
 *
 * Mirrors `channelTopics` in Sources/Gist/Channel.swift and the JS package, field
 * for field and default for default, so the same posts roll up identically on
 * every SDK.
 */
fun channelTopics(posts: List<PostTopics>, options: RollupOptions = RollupOptions()): List<ChannelTopic> {
    if (posts.size < options.minPosts) return emptyList()
    val decay = if (options.halfLifeDays > 0) ln(2.0) / (options.halfLifeDays * 86_400_000) else 0.0

    val weight = HashMap<String, Double>()
    val count = HashMap<String, Int>()
    for (post in posts) {
        var w = 1.0
        val t = post.timestampMillis
        if (decay > 0 && t != null) w = exp(-decay * max(0.0, options.nowMillis - t))
        for ((slug, prob) in post.topics) {
            if (prob <= 0) continue
            weight[slug] = (weight[slug] ?: 0.0) + prob * w
            if (prob >= options.touch) count[slug] = (count[slug] ?: 0) + 1
        }
    }

    val total = weight.values.sum()
    if (total <= 0) return emptyList()

    return weight.entries
        .map { ChannelTopic(it.key, it.value / total, count[it.key] ?: 0) }
        .filter { it.share >= options.floor }
        .sortedWith(compareByDescending<ChannelTopic> { it.share }.thenBy { it.slug })
        .take(options.topN)
}

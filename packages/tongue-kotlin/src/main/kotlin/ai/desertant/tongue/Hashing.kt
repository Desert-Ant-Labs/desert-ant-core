package ai.desertant.tongue

/**
 * FNV-1a character n-gram featurizer, ported from src/tongue_training/hashing.py.
 *
 * Hashing instead of a learned vocabulary is why this SDK ships no tokenizer:
 * given the same normalized string, every platform produces the same bucket
 * indices by construction, with no BPE merge-order drift to reconcile.
 *
 * Iterated over **Unicode code points** — not UTF-8 bytes and not UTF-16 `char`s.
 * Iterating `char` would split astral characters into surrogate pairs and hash
 * something the reference never sees.
 */
public object Hashing {
    public const val OFFSET_BASIS: Int = -0x7EE3623B     // 0x811C9DC5 as a signed Int
    public const val PRIME: Int = 0x01000193
    public val NGRAM_ORDERS: List<Int> = listOf(1, 2, 3, 4, 5)

    private const val BOUNDARY_START = '^'
    private const val BOUNDARY_END = '$'

    /** FNV-1a 32-bit over Unicode code points, returned as an unsigned Long. */
    public fun fnv1a(text: String): Long {
        var hash = OFFSET_BASIS
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            hash = (hash xor codePoint) * PRIME
            index += Character.charCount(codePoint)
        }
        return hash.toLong() and 0xFFFFFFFFL
    }

    /** FNV-1a over a code-point slice, avoiding a substring per n-gram. */
    private fun fnv1a(codePoints: IntArray, from: Int, until: Int): Long {
        var hash = OFFSET_BASIS
        for (index in from until until) hash = (hash xor codePoints[index]) * PRIME
        return hash.toLong() and 0xFFFFFFFFL
    }

    /**
     * Bucket counts for a normalized string: the bag the model consumes.
     *
     * Each whitespace token is wrapped in `^`/`$` so word-initial and word-final
     * sequences stay distinguishable from word-internal ones. That distinction
     * carries much of the signal — Portuguese `ão$`, Italian `^gli`.
     */
    @JvmOverloads
    public fun buckets(
        text: String,
        numBuckets: Int,
        orders: List<Int> = NGRAM_ORDERS,
    ): Map<Int, Int> {
        if (text.isEmpty()) return emptyMap()
        val counts = HashMap<Int, Int>()
        for (token in text.split(" ")) {
            if (token.isEmpty()) continue
            val marked = buildMarked(token)
            for (order in orders) {
                if (order > marked.size) continue
                for (start in 0..(marked.size - order)) {
                    val bucket = (fnv1a(marked, start, start + order) % numBuckets).toInt()
                    counts[bucket] = (counts[bucket] ?: 0) + 1
                }
            }
        }
        return counts
    }

    private fun buildMarked(token: String): IntArray {
        val inner = token.codePoints().toArray()
        val marked = IntArray(inner.size + 2)
        marked[0] = BOUNDARY_START.code
        inner.copyInto(marked, 1)
        marked[marked.size - 1] = BOUNDARY_END.code
        return marked
    }
}

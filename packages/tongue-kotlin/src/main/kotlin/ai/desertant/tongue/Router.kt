package ai.desertant.tongue

/**
 * The script router: a zero-parameter layer that answers before the model runs.
 * Ported from src/tongue_training/script.py; the script_vectors.json copied into
 * src/test/resources holds
 * this file to those semantics.
 */
internal object Router {
    fun scriptFor(codePoint: Int): String? {
        val ranges = ScriptTables.ranges
        var low = 0
        var high = ranges.size - 1
        var found = -1
        while (low <= high) {                       // last range whose start <= codePoint
            val mid = (low + high) / 2
            if (ranges[mid].start <= codePoint) { found = mid; low = mid + 1 } else high = mid - 1
        }
        if (found < 0 || codePoint > ranges[found].end) return null
        return ranges[found].script
    }

    fun histogram(text: String): Map<String, Int> {
        val counts = HashMap<String, Int>()
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            scriptFor(codePoint)?.let { counts[it] = (counts[it] ?: 0) + 1 }
            index += Character.charCount(codePoint)
        }
        return counts
    }

    /**
     * Best-supported script that clears the presence rule.
     *
     * Presence beats dominance for non-Latin scripts: Latin brand names embed in
     * Greek or Thai text constantly, while the reverse essentially never happens.
     * So a script only some languages use decides the route even when Latin
     * characters outnumber it — provided the evidence is substantial: at least half
     * the scripted characters, or at least two carrying a quarter of them.
     *
     * Ties break on the lexicographically greatest script name, matching Python's
     * `max((count, name))`. Iteration order would diverge on mixed-script input —
     * that exact mismatch cost the JavaScript port 2 of 119 golden vectors.
     */
    fun presence(histogram: Map<String, Int>, among: Set<String>): String? {
        val scripted = histogram.values.sum()
        if (scripted == 0) return null
        var best: String? = null
        var bestCount = 0
        for ((script, count) in histogram) {
            if (script !in among) continue
            val current = best
            if (count > bestCount || (count == bestCount && current != null && script > current)) {
                best = script
                bestCount = count
            }
        }
        val winner = best ?: return null
        val share = bestCount.toDouble() / scripted
        return if (share >= 0.5 || (bestCount >= 2 && share >= 0.25)) winner else null
    }

    fun dominantScript(text: String): String? {
        val histogram = histogram(text)
        if (histogram.isEmpty()) return null
        // Same tie-break as presence: highest count, then greatest name.
        return histogram.entries
            .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenByDescending { it.key })
            .first().key
    }

    /**
     * Route already-normalized text to a verdict and candidate set.
     *
     * Japanese is special-cased ahead of everything: Japanese mixes Han with kana,
     * so any kana settles it even when Han characters outnumber them. Without this,
     * kanji-heavy Japanese misroutes to Chinese.
     */
    fun route(text: String): Route {
        val histogram = histogram(text)
        if (histogram.isEmpty()) return Route(Verdict.AMBIGUOUS, emptyList(), null)

        if ((histogram["Hiragana"] ?: 0) > 0 || (histogram["Katakana"] ?: 0) > 0) {
            return Route(Verdict.DECISIVE, listOf("ja"), ScriptTables.JAPANESE)
        }
        presence(histogram, ScriptTables.decisive.keys)?.let { script ->
            ScriptTables.decisive[script]?.let { language ->
                return Route(Verdict.DECISIVE, listOf(language), script)
            }
        }
        presence(histogram, ScriptTables.narrowing.keys)?.let { script ->
            ScriptTables.narrowing[script]?.let { languages ->
                return Route(Verdict.NARROWING, languages, script)
            }
        }
        return Route(Verdict.AMBIGUOUS, emptyList(), dominantScript(text))
    }
}

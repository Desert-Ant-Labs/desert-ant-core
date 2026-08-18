package ai.desertant.tongue

import java.text.Normalizer as JavaNormalizer

/**
 * The pinned input normalizer, ported from src/tongue_training/normalize.py.
 *
 * That module is a frozen specification, not an implementation detail: this file
 * must reproduce its output exactly, or the model sees different features here
 * than it was trained on. The contract is docs/normalizer.md plus
 * src/test/resources/normalize_vectors.json, copied from the reference repo's
 * golden/ and replayed by GoldenVectorTest.
 *
 * Porting hazards this file is deliberate about:
 *
 *  - **NFC, not NFKC.** Canonical composition only. NFKC also folds compatibility
 *    characters (U+FB01 to "fi", U+00BD to "1/2"), changing the character
 *    sequence and therefore every n-gram derived from it.
 *  - **Code-point truncation.** Python slices by code point, so the 512 cap counts
 *    code points, not UTF-16 `char`s. A string of astral characters would
 *    otherwise truncate at half the length.
 *  - **Invariant lowercase.** `lowercase()` with no locale is Unicode-default;
 *    `lowercase(Locale.getDefault())` would diverge under a Turkish locale.
 *  - **Category filter.** The pinned [DiscardTable] matches Python's
 *    `unicodedata.category` for the five classes dropped here.
 */
public object Normalizer {
    public const val MAX_CHARACTERS: Int = 512

    // Order is part of the contract; see [normalize].
    //
    // Every class is spelled out. `\w`, `\d`, `\s` and `\S` are engine-defined and
    // the three engines behind this spec disagree. java.util.regex is the worst
    // offender: without UNICODE_CHARACTER_CLASS they are ASCII-only, so this port
    // used to leave Cyrillic hashtags and Devanagari digits in place and answered
    // `ky` where Swift and JavaScript answered `en`. Python's definitions are the
    // spec, so they are written out and the same three strings appear in all three
    // ports.
    //
    //   \w  ->  [\p{L}\p{N}_]   verified equal to Python's `\w` over all 0x110000
    //   \d  ->  \p{Nd}          verified equal to Python's `\d` (650 scalars)
    //   \s  ->  the 29 scalars below, which is exactly Python's `\s`
    internal const val WHITESPACE_CLASS: String =
        "\\u0009-\\u000D\\u001C-\\u0020\\u0085\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000"
    private const val NON_WHITESPACE = "[^$WHITESPACE_CLASS]"

    private val URL = Regex("""(?:https?://|www\.)$NON_WHITESPACE+""", RegexOption.IGNORE_CASE)
    private val EMAIL = Regex("""$NON_WHITESPACE+@$NON_WHITESPACE+\.$NON_WHITESPACE+""")
    private val MENTION = Regex("""[@#][\p{L}\p{N}_]+""")
    private val DIGITS = Regex("""\p{Nd}+""")
    private val WHITESPACE = Regex("[$WHITESPACE_CLASS]+")

    /**
     * Emoji, symbol modifiers and invisible formatting characters: no language
     * signal, but they do perturb the n-gram bag.
     *
     * From [DiscardTable] rather than `Character.getType`, because that answers
     * from the host JDK's Unicode version and the model was trained on 13.0.0.
     * The same jar used to give different answers on JDK 17 and JDK 26 — and on
     * Android, on two phones with different platform ICU.
     */
    private fun isDiscarded(codePoint: Int): Boolean {
        val ranges = DiscardTable.ranges
        var low = 0
        var high = ranges.size - 1
        while (low <= high) {
            val mid = (low + high) / 2
            val (start, end) = ranges[mid]
            when {
                codePoint < start -> high = mid - 1
                codePoint > end -> low = mid + 1
                else -> return true
            }
        }
        return false
    }

    /**
     * Apply the frozen normalization pipeline.
     *
     * 1. Unicode NFC
     * 2. remove URLs, then emails, then @mentions and #hashtags
     * 3. remove digit runs
     * 4. remove symbol and format characters
     * 5. invariant lowercase
     * 6. collapse whitespace runs to one space and trim the ends
     * 7. truncate to [MAX_CHARACTERS] code points
     */
    public fun normalize(text: String): String {
        var result = JavaNormalizer.normalize(text, JavaNormalizer.Form.NFC)
        result = URL.replace(result, " ")
        result = EMAIL.replace(result, " ")
        result = MENTION.replace(result, " ")
        result = DIGITS.replace(result, " ")
        result = dropDiscardedCategories(result)
        result = result.lowercase()
        result = WHITESPACE.replace(result, " ").trim()
        return truncateToCodePoints(result, MAX_CHARACTERS)
    }

    private fun dropDiscardedCategories(text: String): String {
        val out = StringBuilder(text.length)
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            if (!isDiscarded(codePoint)) out.appendCodePoint(codePoint)
            index += Character.charCount(codePoint)
        }
        return out.toString()
    }

    /** Truncate by code point, matching Python's string slice. */
    private fun truncateToCodePoints(text: String, limit: Int): String {
        if (text.codePointCount(0, text.length) <= limit) return text
        return text.substring(0, text.offsetByCodePoints(0, limit))
    }

    /** Whitespace tokens of already-normalized text. */
    public fun tokens(text: String): List<String> =
        if (text.isEmpty()) emptyList() else text.split(" ")
}

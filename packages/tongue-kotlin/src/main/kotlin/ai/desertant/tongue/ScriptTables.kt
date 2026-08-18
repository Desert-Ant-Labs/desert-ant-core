package ai.desertant.tongue

// UAX#24 script routing, GENERATED from the Python reference by
// scripts/gen_kotlin_tables.py. Do not hand-edit: regenerate instead, so the
// three ports and the reference cannot drift.

internal data class Range(val start: Int, val end: Int, val script: String)

internal object ScriptTables {
    // Sorted, non-overlapping; looked up by binary search.
    val ranges: List<Range> = listOf(
        Range(0x0041, 0x005A, "Latin"),
        Range(0x0061, 0x007A, "Latin"),
        Range(0x00C0, 0x024F, "Latin"),
        Range(0x0370, 0x03FF, "Greek"),
        Range(0x0400, 0x052F, "Cyrillic"),
        Range(0x0530, 0x058F, "Armenian"),
        Range(0x0590, 0x05FF, "Hebrew"),
        Range(0x0600, 0x06FF, "Arabic"),
        Range(0x0700, 0x074F, "Syriac"),
        Range(0x0750, 0x077F, "Arabic"),
        Range(0x0780, 0x07BF, "Thaana"),
        Range(0x08A0, 0x08FF, "Arabic"),
        Range(0x0900, 0x097F, "Devanagari"),
        Range(0x0980, 0x09FF, "Bengali"),
        Range(0x0A00, 0x0A7F, "Gurmukhi"),
        Range(0x0A80, 0x0AFF, "Gujarati"),
        Range(0x0B00, 0x0B7F, "Oriya"),
        Range(0x0B80, 0x0BFF, "Tamil"),
        Range(0x0C00, 0x0C7F, "Telugu"),
        Range(0x0C80, 0x0CFF, "Kannada"),
        Range(0x0D00, 0x0D7F, "Malayalam"),
        Range(0x0D80, 0x0DFF, "Sinhala"),
        Range(0x0E00, 0x0E7F, "Thai"),
        Range(0x0E80, 0x0EFF, "Lao"),
        Range(0x0F00, 0x0FFF, "Tibetan"),
        Range(0x1000, 0x109F, "Myanmar"),
        Range(0x10A0, 0x10FF, "Georgian"),
        Range(0x1100, 0x11FF, "Hangul"),
        Range(0x1200, 0x137F, "Ethiopic"),
        Range(0x13A0, 0x13FF, "Cherokee"),
        Range(0x1780, 0x17FF, "Khmer"),
        Range(0x1800, 0x18AF, "Mongolian"),
        Range(0x1F00, 0x1FFF, "Greek"),
        Range(0x2D00, 0x2D2F, "Georgian"),
        Range(0x2DE0, 0x2DFF, "Cyrillic"),
        Range(0x3040, 0x309F, "Hiragana"),
        Range(0x30A0, 0x30FF, "Katakana"),
        Range(0x3130, 0x318F, "Hangul"),
        Range(0x31F0, 0x31FF, "Katakana"),
        Range(0x3400, 0x4DBF, "Han"),
        Range(0x4E00, 0x9FFF, "Han"),
        Range(0xA640, 0xA69F, "Cyrillic"),
        Range(0xAB70, 0xABBF, "Cherokee"),
        Range(0xAC00, 0xD7AF, "Hangul"),
        Range(0xF900, 0xFAFF, "Han"),
        Range(0xFB50, 0xFDFF, "Arabic"),
        Range(0xFE70, 0xFEFF, "Arabic"),
    )

    // Scripts only one language uses: presence settles the answer outright.
    val decisive: Map<String, String> = mapOf(
        "Armenian" to "hy",
        "Cherokee" to "chr",
        "Ethiopic" to "am",
        "Georgian" to "ka",
        "Greek" to "el",
        "Gujarati" to "gu",
        "Gurmukhi" to "pa",
        "Han" to "zh",
        "Hangul" to "ko",
        "Hebrew" to "he",
        "Hiragana" to "ja",
        "Kannada" to "kn",
        "Katakana" to "ja",
        "Khmer" to "km",
        "Lao" to "lo",
        "Malayalam" to "ml",
        "Mongolian" to "mn",
        "Myanmar" to "my",
        "Oriya" to "or",
        "Sinhala" to "si",
        "Syriac" to "syr",
        "Tamil" to "ta",
        "Telugu" to "te",
        "Thaana" to "dv",
        "Thai" to "th",
        "Tibetan" to "bo",
    )

    // Scripts several languages share: presence narrows the candidate set.
    val narrowing: Map<String, List<String>> = mapOf(
        "Arabic" to listOf("ar", "fa", "ur", "ug"),
        "Bengali" to listOf("bn", "as"),
        "Cyrillic" to listOf("ru", "uk", "bg", "sr", "mk", "be", "kk", "ky"),
        "Devanagari" to listOf("hi", "mr", "ne"),
    )

    /// Reported by the router for the kana special case; owns no range.
    const val JAPANESE = "Japanese"
}

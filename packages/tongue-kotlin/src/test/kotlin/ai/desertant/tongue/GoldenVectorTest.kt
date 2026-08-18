package ai.desertant.tongue

// The golden vectors are the cross-platform contract. The Python reference and
// the Swift, Kotlin and JavaScript ports all replay the same files; if any drifts,
// the model sees different features on that platform and the implementations
// disagree silently. This exists so drift fails loudly instead.
//
// A plain main() rather than a JUnit suite: this artifact deliberately has no
// dependencies, and adding a test framework to run three loops is not worth the
// transitive weight. `mise run test-kotlin` executes it.

private var failures = 0

private fun check(condition: Boolean, message: () -> String) {
    if (!condition) { failures++; println("  FAIL ${message()}") }
}

/** Minimal reader for the flat vector documents, matching Metadata.parse's approach. */
private object Vectors {
    fun read(name: String): String =
        Vectors::class.java.classLoader.getResourceAsStream(name)?.use {
            it.readBytes().toString(Charsets.UTF_8)
        } ?: error("$name missing from test resources")

    /** Objects inside the top-level array named [key]. */
    fun objects(json: String, key: String): List<String> {
        val start = json.indexOf("\"$key\"")
        if (start < 0) return emptyList()
        val open = json.indexOf('[', start)
        var depth = 0
        var index = open
        val out = mutableListOf<String>()
        var objectStart = -1
        while (index < json.length) {
            when (json[index]) {
                '[' -> depth++
                ']' -> { depth--; if (depth == 0) return out }
                '{' -> if (objectStart < 0) objectStart = index
                '}' -> if (objectStart >= 0) { out.add(json.substring(objectStart, index + 1)); objectStart = -1 }
            }
            index++
        }
        return out
    }

    fun string(obj: String, key: String): String? =
        Regex("\"$key\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"").find(obj)?.groupValues?.get(1)?.let(::unescape)

    fun number(obj: String, key: String): Long? =
        Regex("\"$key\"\\s*:\\s*(-?\\d+)").find(obj)?.groupValues?.get(1)?.toLongOrNull()

    fun doubles(obj: String, key: String): List<Double> =
        Regex("\"$key\"\\s*:\\s*\\[([^\\]]*)\\]").find(obj)?.groupValues?.get(1)
            ?.split(",")?.mapNotNull { it.trim().toDoubleOrNull() } ?: emptyList()

    fun strings(obj: String, key: String): List<String>? =
        Regex("\"$key\"\\s*:\\s*\\[(.*?)]", RegexOption.DOT_MATCHES_ALL).find(obj)?.groupValues?.get(1)
            ?.let { body -> Regex("\"(.*?)\"").findAll(body).map { it.groupValues[1] }.toList() }

    fun hasNullOrMissing(obj: String, key: String): Boolean =
        string(obj, key) == null

    private fun unescape(raw: String): String {
        val out = StringBuilder(raw.length)
        var index = 0
        while (index < raw.length) {
            val char = raw[index]
            if (char != '\\') { out.append(char); index++; continue }
            when (val escape = raw[index + 1]) {
                'u' -> { out.append(raw.substring(index + 2, index + 6).toInt(16).toChar()); index += 6 }
                'n' -> { out.append('\n'); index += 2 }
                't' -> { out.append('\t'); index += 2 }
                'r' -> { out.append('\r'); index += 2 }
                else -> { out.append(escape); index += 2 }
            }
        }
        return out.toString()
    }
}

private fun testNormalizer() {
    val json = Vectors.read("normalize_vectors.json")
    val cases = Vectors.objects(json, "cases")
    check(cases.isNotEmpty()) { "no normalizer cases loaded" }
    for (case in cases) {
        val input = Vectors.string(case, "input") ?: ""
        val expected = Vectors.string(case, "output") ?: ""
        val actual = Normalizer.normalize(input)
        check(actual == expected) { "normalize(${input.quoted()}) = ${actual.quoted()}, expected ${expected.quoted()}" }
    }
    // The cap counts code points, matching Python's slice.
    val long = "é".repeat(Normalizer.MAX_CHARACTERS + 50)
    val truncated = Normalizer.normalize(long)
    check(truncated.codePointCount(0, truncated.length) == Normalizer.MAX_CHARACTERS) {
        "code-point truncation: got ${truncated.codePointCount(0, truncated.length)}"
    }
    println("normalizer: ${cases.size} cases")
}

private fun testHasher() {
    val json = Vectors.read("hashing_vectors.json")
    check(Hashing.OFFSET_BASIS.toLong() and 0xFFFFFFFFL == (Vectors.number(json, "offset_basis") ?: 0)) {
        "offset basis differs from the reference"
    }
    check(Hashing.PRIME.toLong() == (Vectors.number(json, "prime") ?: 0)) { "prime differs" }

    var hashes = 0
    for (case in Vectors.objects(json, "fnv1a")) {
        val input = Vectors.string(case, "input") ?: ""
        val expected = Vectors.number(case, "hash") ?: 0
        val actual = Hashing.fnv1a(input)
        check(actual == expected) { "fnv1a(${input.quoted()}) = $actual, expected $expected" }
        hashes++
    }

    // Whole-bag equality: catches boundary marking, order coverage and the modulo,
    // which per-string hashes alone would not.
    val buckets = (Vectors.number(json, "num_buckets") ?: 262_144L).toInt()
    var bags = 0
    for (case in Vectors.objects(json, "bags")) {
        val normalized = Vectors.string(case, "normalized") ?: continue
        val expected = Regex("\"(\\d+)\"\\s*:\\s*(\\d+)")
            .findAll(case.substringAfter("\"bag\""))
            .associate { it.groupValues[1].toInt() to it.groupValues[2].toInt() }
        val actual = Hashing.buckets(normalized, buckets)
        check(actual == expected) {
            "bag for ${normalized.quoted()} differs (${actual.size} vs ${expected.size} buckets)"
        }
        bags++
    }
    println("hasher: $hashes hashes, $bags whole bags")
}

private fun testRouter() {
    val cases = Vectors.objects(Vectors.read("script_vectors.json"), "cases")
    check(cases.isNotEmpty()) { "no router cases loaded" }
    for (case in cases) {
        val input = Vectors.string(case, "input") ?: ""
        val normalized = Normalizer.normalize(input)
        Vectors.string(case, "normalized")?.let { expected ->
            check(normalized == expected) { "normalization before routing ${input.quoted()}" }
        }
        val route = Router.route(normalized)
        check(route.verdict.name.lowercase() == Vectors.string(case, "verdict")) {
            "verdict for ${input.quoted()}: ${route.verdict.name.lowercase()} vs ${Vectors.string(case, "verdict")}"
        }
        check(route.candidates == (Vectors.strings(case, "candidates") ?: emptyList<String>())) {
            "candidates for ${input.quoted()}: ${route.candidates}"
        }
        val expectedScript = Vectors.string(case, "script")
        check(route.script == expectedScript) {
            "script for ${input.quoted()}: ${route.script} vs $expectedScript"
        }
    }
    println("router: ${cases.size} cases")
}

private fun testDetection() {
    val tongue = Tongue.bundled()
    val expectations = listOf(
        "je voudrais un café au lait" to "fr",
        "kann ich das haben" to "de",
        "muchas gracias por la ayuda" to "es",
        "привет как твои дела" to "ru",
        "안녕하세요 만나서 반갑습니다" to "ko",
        "こんにちは、お元気ですか" to "ja",
        "مرحبا كيف حالك اليوم" to "ar",
        "ᏣᎳᎩ ᎦᏬᏂᎯᏍᏗ" to "chr",
        "the garage sale is on saturday morning" to "en",
    )
    for ((text, expected) in expectations) {
        val actual = tongue.detect(text).language
        check(actual == expected) { "detect(${text.quoted()}) = $actual, expected $expected" }
    }
    // Equally Italian and Spanish; presenting one would be a lie.
    val tie = tongue.detect("la casa")
    check(tie.isTooCloseToCall) { "'la casa' should be too close to call" }
    // Reads as Welsh to any character model. The point is that it says so.
    check(tongue.detect("hi i am").reliability == Reliability.TENTATIVE) {
        "'hi i am' should be tentative"
    }
    check(tongue.detect("   ").reliability == Reliability.EMPTY) { "blank input should be empty" }
    println("detection: ${expectations.size} languages + abstention behaviour")
    testDetectionVectors(tongue)
}

/**
 * Replays detection_vectors.json — the head's output, which nothing asserted
 * before. Every other stage had vectors, so three ports could disagree on
 * `language` for hashtag input while all three suites stayed green.
 *
 * Generated by scripts/gen_detection_vectors.py, a fourth implementation of the
 * documented arithmetic reading the shipped weights, so agreement here is between
 * four independent implementations rather than three ports and a file one of them
 * wrote. Probabilities carry a tolerance because exp() differs in the last bits
 * between libms; the discrete fields are exact.
 */
private fun testDetectionVectors(tongue: Tongue) {
    val json = Vectors.read("detection_vectors.json")
    val tolerance = (Vectors.string(json, "tolerance") ?: "0.000001").toDouble()
    val cases = Vectors.objects(json, "cases")
    check(cases.isNotEmpty()) { "no detection cases loaded" }

    for (case in cases) {
        val input = Vectors.string(case, "input") ?: error("case without input")
        val detection = tongue.detect(input)
        check(detection.normalized == Vectors.string(case, "normalized")) {
            "detect(${input.quoted()}).normalized = ${detection.normalized.quoted()}"
        }
        check(detection.language == Vectors.string(case, "language")) {
            "detect(${input.quoted()}) = ${detection.language}, expected ${Vectors.string(case, "language")}"
        }
        check(detection.reliability.name.lowercase() == Vectors.string(case, "reliability")) {
            "detect(${input.quoted()}).reliability = ${detection.reliability}"
        }
        check(detection.isTooCloseToCall == (case.contains("\"isTooCloseToCall\": true"))) {
            "detect(${input.quoted()}).isTooCloseToCall = ${detection.isTooCloseToCall}"
        }
        val languages = Vectors.strings(case, "candidateLanguages") ?: emptyList()
        val probabilities = Vectors.doubles(case, "candidateProbabilities")
        check(detection.candidates.size == languages.size) {
            "detect(${input.quoted()}) returned ${detection.candidates.size} candidates, expected ${languages.size}"
        }
        languages.forEachIndexed { index, language ->
            val candidate = detection.candidates[index]
            check(candidate.language == language) {
                "detect(${input.quoted()}) candidate $index = ${candidate.language}, expected $language"
            }
            val delta = kotlin.math.abs(candidate.probability - probabilities[index])
            check(delta <= tolerance) {
                "detect(${input.quoted()}) probability $index off by $delta (tolerance $tolerance)"
            }
        }
    }
    println("detection vectors: ${cases.size} cases")
}

private fun String.quoted() = "\"" + replace("\n", "\\n") + "\""

fun main() {
    println("tongue-kotlin golden vectors")
    testNormalizer()
    testHasher()
    testRouter()
    testDetection()
    if (failures > 0) {
        println("\n$failures FAILURES")
        kotlin.system.exitProcess(1)
    }
    println("\nall checks passed")
}

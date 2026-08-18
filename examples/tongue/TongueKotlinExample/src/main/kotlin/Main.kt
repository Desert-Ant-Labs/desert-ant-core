import ai.desertant.tongue.Tongue

// Identify the language of each argument, or of a built-in spread of scripts.
//
//   ./gradlew run
//   ./gradlew run --args="kann ich das haben 안녕하세요"

private val SAMPLES = listOf(
    "je voudrais un café au lait",
    "kann ich das haben",
    "quanto costa il biglietto",
    "привет как твои дела",
    "안녕하세요 만나서 반갑습니다",
    "こんにちは、お元気ですか",
    "مرحبا كيف حالك اليوم",
    "la casa",          // equally Italian and Spanish
    "hi i am",          // too short to be sure
    "Samsung Galaxy",   // a brand, not a language
)

fun main(args: Array<String>) {
    val tongue = Tongue.bundled()
    for (text in if (args.isNotEmpty()) args.toList() else SAMPLES) {
        val detection = tongue.detect(text)
        val headline = if (detection.isTooCloseToCall && detection.candidates.size > 1) {
            // Too close to separate: name both rather than crowning one.
            "${detection.candidates[0].language} or ${detection.candidates[1].language}"
        } else {
            detection.language ?: "unknown"
        }
        val ranked = detection.candidates.take(3)
            .joinToString("  ") { "${it.language} ${"%.2f".format(it.probability)}" }
        println(text)
        println("  -> $headline   [${detection.reliability.name.lowercase()}, via ${detection.route.verdict.name.lowercase()}]")
        println("     $ranked")
        println()
    }
}

import Tongue

// Identify the language of each argument, or of a built-in spread of scripts.
//
//   swift run TongueCLIExample
//   swift run TongueCLIExample "kann ich das haben" "안녕하세요"

let samples = [
    "je voudrais un café au lait",
    "kann ich das haben",
    "quanto costa il biglietto",
    "привет как твои дела",
    "안녕하세요 만나서 반갑습니다",
    "こんにちは、お元気ですか",
    "مرحبا كيف حالك اليوم",
    "la casa",                                  // equally Italian and Spanish
    "hi i am",                                  // too short to be sure
    "Samsung Galaxy",                           // a brand, not a language
]

let inputs = CommandLine.arguments.count > 1 ? Array(CommandLine.arguments.dropFirst()) : samples
let tongue = try Tongue()

for text in inputs {
    let detection = tongue.detect(text)
    let headline: String
    if detection.isTooCloseToCall, detection.candidates.count > 1 {
        // Too close to separate: name both rather than crowning one.
        headline = "\(detection.candidates[0].language) or \(detection.candidates[1].language)"
    } else {
        headline = detection.language ?? "unknown"
    }
    let ranked = detection.candidates
        .prefix(3)
        .map { "\($0.language) \(String(format: "%.2f", $0.probability))" }
        .joined(separator: "  ")
    print("\(text.padding(toLength: min(34, max(34, text.count)), withPad: " ", startingAt: 0))")
    print("  -> \(headline)   [\(detection.reliability.rawValue), via \(detection.route.verdict.rawValue)]")
    print("     \(ranked)\n")
}

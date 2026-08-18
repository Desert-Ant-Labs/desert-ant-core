import Foundation

// The script router: a zero-parameter layer that answers before the model runs.
// Ported from src/tongue_training/script.py; semantics are load-bearing and the
// the script_vectors.json copied into Tests/TongueTests/Resources hold this file
// to them (generated in the reference repo's golden/).

public enum Verdict: String, Sendable {
    /// One language uses this script; no model needed.
    case decisive
    /// Several languages share it; the head decodes among them.
    case narrowing
    /// No script carries enough evidence.
    case ambiguous
}

public struct Route: Sendable, Equatable {
    public let verdict: Verdict
    public let candidates: [String]
    public let script: Script?
}

public enum Router {
    static func script(for scalar: Unicode.Scalar) -> Script? {
        let value = scalar.value
        var low = 0, high = ScriptTables.ranges.count - 1, found: Int? = nil
        while low <= high {                       // last range whose start <= value
            let mid = (low + high) / 2
            if ScriptTables.ranges[mid].0 <= value { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        guard let index = found, value <= ScriptTables.ranges[index].1 else { return nil }
        return ScriptTables.ranges[index].2
    }

    static func histogram(_ text: String) -> [Script: Int] {
        var counts: [Script: Int] = [:]
        for scalar in text.unicodeScalars {
            if let script = script(for: scalar) { counts[script, default: 0] += 1 }
        }
        return counts
    }

    /// Best-supported script that clears the presence rule.
    ///
    /// Presence beats dominance for non-Latin scripts: Latin brand names embed in
    /// Greek or Thai text constantly, while the reverse essentially never happens.
    /// So a script only some languages use decides the route even when Latin
    /// characters outnumber it — provided the evidence is substantial: at least
    /// half the scripted characters, or at least two carrying a quarter of them.
    /// The floor keeps an English sentence quoting one Greek letter routed Latin.
    ///
    /// Ties break on the lexicographically greatest script name, matching
    /// Python's `max((count, name))`. Insertion order would diverge on
    /// mixed-script input — this exact mismatch cost the JS port 2 of 119 golden
    /// vectors before it was found.
    static func presence(_ histogram: [Script: Int], among names: Set<Script>) -> Script? {
        let scripted = histogram.values.reduce(0, +)
        guard scripted > 0 else { return nil }
        var best: Script? = nil
        var bestCount = 0
        for (script, count) in histogram where names.contains(script) {
            if count > bestCount || (count == bestCount && best.map { script.rawValue > $0.rawValue } == true) {
                best = script; bestCount = count
            }
        }
        guard let winner = best else { return nil }
        let share = Double(bestCount) / Double(scripted)
        guard share >= 0.5 || (bestCount >= 2 && share >= 0.25) else { return nil }
        return winner
    }

    static func dominantScript(_ text: String) -> Script? {
        let histogram = histogram(text)
        guard !histogram.isEmpty else { return nil }
        // Same tie-break as `presence`: highest count, then greatest name.
        return histogram.max {
            $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue < $1.key.rawValue)
        }?.key
    }

    /// Route already-normalized text to a verdict and candidate set.
    ///
    /// Japanese is special-cased ahead of everything: Japanese mixes Han with
    /// kana, so any kana settles it even when Han characters outnumber them.
    /// Without this, kanji-heavy Japanese misroutes to Chinese.
    public static func route(_ text: String) -> Route {
        let histogram = histogram(text)
        guard !histogram.isEmpty else {
            return Route(verdict: .ambiguous, candidates: [], script: nil)
        }
        if (histogram[.hiragana] ?? 0) > 0 || (histogram[.katakana] ?? 0) > 0 {
            return Route(verdict: .decisive, candidates: ["ja"], script: .japanese)
        }
        if let script = presence(histogram, among: Set(ScriptTables.decisive.keys)),
           let language = ScriptTables.decisive[script] {
            return Route(verdict: .decisive, candidates: [language], script: script)
        }
        if let script = presence(histogram, among: Set(ScriptTables.narrowing.keys)),
           let languages = ScriptTables.narrowing[script] {
            return Route(verdict: .narrowing, candidates: languages, script: script)
        }
        return Route(verdict: .ambiguous, candidates: [], script: dominantScript(text))
    }
}

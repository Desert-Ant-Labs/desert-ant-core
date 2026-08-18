
/// How much to trust an answer.
///
/// Keyed off evidence — input length and how far the top candidate leads the
/// runner-up — not raw softmax confidence, which is badly overconfident on very
/// short text. `"hi i am"` reads as Welsh to any character model at high
/// probability; the margin and length are what reveal that it is a guess.
public enum Reliability: String, Sendable {
    case confident, likely, tentative, empty
}

public struct Prediction: Sendable, Equatable {
    /// ISO 639-1 or 639-3 code.
    public let language: String
    public let probability: Double
}

public struct Detection: Sendable {
    public let normalized: String
    public let candidates: [Prediction]
    public let reliability: Reliability
    /// Which stage answered: the script router, or the head.
    public let route: Route

    public var language: String? { candidates.first?.language }

    /// True when the top two candidates are too close to separate. Callers
    /// should present both rather than crowning one — `"la casa"` is equally
    /// Italian and Spanish, and saying so is more useful than picking.
    public var isTooCloseToCall: Bool {
        guard candidates.count > 1 else { return false }
        return candidates[0].probability - candidates[1].probability < 0.12
    }
}

/// On-device language identification for short text.
///
/// ```swift
/// let tongue = try Tongue()
/// tongue.detect("kann ich das haben")?.language   // "de"
/// ```
public struct Tongue: Sendable {
    private let weights: Weights
    private let metadata: Metadata
    /// One turnstile per instance, shared by copies of this value. See
    /// UsageTracking.swift and docs/USAGE.md.
    private let usage: UsageTurnstile?

    /// Load from raw bytes. The core initializer: no file system, no Foundation,
    /// so the pipeline cross-compiles as pure Swift. `Tongue()` and
    /// `Tongue(directory:)` in TongueLoading.swift are conveniences over this.
    public init(metadataJSON: String, weightBytes: [UInt8]) throws {
        self.metadata = try Metadata(json: metadataJSON)
        self.weights = try Weights(bytes: weightBytes, metadata: metadata)
        self.usage = makeTurnstile()
    }

    /// Identify the language of a short string.
    public func detect(_ text: String, topK: Int = 3) -> Detection {
        if let usage {
            // Fire-and-forget: the turnstile must never sit between a keystroke
            // and its answer.
            Task { await usage.record() }
        }
        let normalized = Normalizer.normalize(text)
        let route = Router.route(normalized)

        guard !normalized.isEmpty else {
            return Detection(normalized: normalized, candidates: [],
                             reliability: .empty, route: route)
        }
        // A script that only one language uses needs no model, and there is no
        // guessing involved, so it is always reported confident.
        if route.verdict == .decisive, let language = route.candidates.first {
            return Detection(normalized: normalized,
                             candidates: [Prediction(language: language, probability: 1)],
                             reliability: .confident, route: route)
        }

        let allowed = route.verdict == .narrowing
            ? metadata.labels.filter { route.candidates.contains($0) }
            : metadata.latinLabels
        guard !allowed.isEmpty else {
            return Detection(normalized: normalized, candidates: [],
                             reliability: .empty, route: route)
        }

        let ranked = weights.rank(normalized, restrictedTo: Set(allowed), topK: topK)
        return Detection(normalized: normalized, candidates: ranked,
                         reliability: reliability(normalized, ranked), route: route)
    }

    private func reliability(_ text: String, _ ranked: [Prediction]) -> Reliability {
        let characters = text.unicodeScalars.count
        let margin = ranked.count > 1
            ? ranked[0].probability - ranked[1].probability
            : (ranked.first?.probability ?? 0)
        if characters >= 18 && margin >= 0.30 { return .confident }
        if characters >= 12 && margin >= 0.20 { return .likely }
        return .tentative
    }
}

public enum TongueError: Error, CustomStringConvertible {
    case bundledModelMissing
    case malformedMetadata(String)
    case weightsSizeMismatch(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .bundledModelMissing:
            return "the bundled model resources are missing from the package bundle"
        case .malformedMetadata(let field):
            return "tongue_meta.json is missing or malformed: \(field)"
        case .weightsSizeMismatch(let expected, let actual):
            return "weights file is \(actual) bytes, expected \(expected) for this metadata"
        }
    }
}


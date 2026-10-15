import DesertAnt

/// One stretch of one speaker's speech.
public struct Turn: Sendable, Equatable {
    /// Seconds from the start of the recording.
    public let start: Double
    public let end: Double
    /// `0, 1, 2, ...` in order of first appearance.
    public let speaker: Int

    public var duration: Double { end - start }

    public init(start: Double, end: Double, speaker: Int) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// Who spoke when.
public struct Diarization: Sendable, Equatable {
    /// Every turn, by start time. Turns of different speakers may overlap.
    public let turns: [Turn]
    public let speakerCount: Int
    /// The recording's length in seconds.
    public let duration: Double

    public func turns(of speaker: Int) -> [Turn] { turns.filter { $0.speaker == speaker } }

    /// A result from turns numbered as given, for a host that stored one and reads it back.
    public init(turns: [Turn], duration: Double) {
        self.turns = turns.sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
        speakerCount = (turns.map(\.speaker).max() ?? -1) + 1
        self.duration = duration
    }

    /// The speakers whose speech adds up to at least `share` of the recording, in their numbering here.
    /// A share of 0 keeps everyone.
    public func speakers(withMinimumShare share: Double) -> [Int] {
        var total: [Int: Double] = [:]
        for turn in turns { total[turn.speaker, default: 0] += turn.duration }
        return (0..<speakerCount).filter { (total[$0] ?? 0) >= share * duration }
    }

    /// The same result without the speakers under `share` of the recording: their turns are gone and the
    /// rest are numbered by first appearance again.
    public func keepingSpeakers(minimumShare share: Double) -> Diarization {
        let kept = Set(speakers(withMinimumShare: share))
        guard kept.count < speakerCount else { return self }
        return Diarization(turns: turns.filter { kept.contains($0.speaker) }.map { LabelledTurn(start: $0.start, end: $0.end, label: $0.speaker) }, duration: duration)
    }

    init(stretches: [Decision.Stretch], clock: FrameClock, duration: Double) {
        let turns = stretches.map { stretch -> LabelledTurn in
            let (start, end) = clock.bounds(stretch)
            return LabelledTurn(start: start, end: end, label: stretch.query)
        }
        self.init(turns: turns, duration: duration)
    }

    /// Speakers are numbered by when each is first heard, so the labels mean the same from one run to the next.
    init(turns labelled: [LabelledTurn], duration: Double) {
        let ordered = labelled.sorted { ($0.start, $0.label) < ($1.start, $1.label) }
        var label: [Int: Int] = [:]
        var turns: [Turn] = []
        for turn in ordered {
            if label[turn.label] == nil { label[turn.label] = label.count }
            turns.append(Turn(start: turn.start, end: turn.end, speaker: label[turn.label]!))
        }
        self.turns = turns
        speakerCount = label.count
        self.duration = duration
    }
}

/// Errors thrown while loading or running the model.
public enum WhoError: MessageError, Sendable {
    case modelNotFound
    case invalidModel(String)
    case invalidAudio(String)
    case predictionFailed(String)

    public var message: String {
        switch self {
        case .modelNotFound: "A Who model resource was not found."
        case .invalidModel(let detail): "Invalid Who model: \(detail)."
        case .invalidAudio(let detail): "Invalid audio: \(detail)."
        case .predictionFailed(let detail): "On-device speaker labeling failed: \(detail)."
        }
    }
}

/// On-device speaker diarization: who spoke when, in one pass, on the Neural
/// Engine. Built for conversations of up to four speakers; a recording with
/// more is labelled with its four most present voices. Any length: up to five
/// minutes in one pass, longer recordings in five-minute pieces, the speakers
/// joined across them by voice.
///
/// ```swift
/// let who = Who()
/// let result = try await who.diarize(contentsOf: url)
/// result.speakerCount            // 3
/// result.turns.first?.speaker    // 0
/// ```
///
/// Create one and reuse it. Construction starts no download; the model loads on
/// the first ``diarize(samples:sampleRate:)`` or ``download(progress:)``.
/// `directory` is where the model lives: used offline if it already holds the
/// model, else downloaded into it. With no `directory` a managed cache is used.
public final class Who: @unchecked Sendable {
    private let model: LoadedModel<Model>
    /// Which published precision this instance runs.
    public let variant: ModelVariant

    public convenience init(directory: String? = nil, variant: ModelVariant = .default,
                            computeUnits: ComputeUnits = .cpuAndNeuralEngine) {
        self.init(directory: directory, cacheRoot: nil, variant: variant, computeUnits: computeUnits)
    }

    /// Binding entry point that also supplies the platform base cache root. The
    /// graphs run whole on the Neural Engine, hence the `computeUnits` default.
    public init(directory: String?, cacheRoot: String?, variant: ModelVariant = .default,
                computeUnits: ComputeUnits = .cpuAndNeuralEngine) {
        self.variant = variant
        model = LoadedModel(variant.distribution, directory: directory, cacheRoot: cacheRoot) {
            try await Model(assets: .who(files: $0, variant: variant, computeUnits: computeUnits))
        }
    }

    /// Creates a diarizer from explicitly provided assets, for hosts that resolved the files themselves.
    @_spi(WhoBindings)
    public init(assets: ModelAssets, variant: ModelVariant = .default) throws {
        self.variant = variant
        let built = try Model(assets: assets)
        model = LoadedModel { built }
    }

    /// Whether this diarizer's model is present.
    public func isDownloaded() -> Bool { model.isDownloaded() }

    /// Whether the default variant's model is on disk for a given location, before one is built.
    public static func isDownloaded(directory: String? = nil, cacheRoot: String? = nil) -> Bool {
        WhoModel.isAvailable(directory: directory, cacheRoot: cacheRoot)
    }

    /// Fetch and prepare the model without diarizing anything.
    public func download(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        try await model.download(progress: progress)
    }

    /// Who spoke when, from mono samples at `sampleRate`; audio at another rate is resampled.
    public func diarize(samples: [Float], sampleRate: Double) async throws -> Diarization {
        guard !samples.isEmpty else { throw WhoError.invalidAudio("no samples") }
        return try await model.value().diarize(samples: samples, sampleRate: sampleRate)
    }

    /// The rate the model expects, so a file can decode straight to it.
    func modelSampleRate() async throws -> Double {
        Double(try await model.value().sampleRate)
    }

    /// The built pipeline, for the tests that read its logits.
    func loadedModel() async throws -> Model { try await model.value() }
}

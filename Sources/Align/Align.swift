import DesertAnt

/// Errors thrown for input `refine` cannot use.
public enum AlignError: MessageError, Sendable {
    case invalidInput(String)

    public var message: String {
        switch self {
        case .invalidInput(let detail): "Invalid Align input: \(detail)."
        }
    }
}

/// Word-timestamp refinement for any transcript: audio and proposed times in, corrected times out.
public final class Align: Sendable {
    let model: LoadedModel<Runtime>

    struct Runtime: Sendable {
        let assets: ModelAssets
        let frontend: Frontend
        let coarse: StageModel
        let fine: StageModel

        init(assets: ModelAssets) {
            self.assets = assets
            self.frontend = Frontend(cfg: assets.config, melFilters: assets.melFilters)
            let name = AlignModel.outputName(for: .current)
            self.coarse = StageModel(session: assets.coarse, width: assets.config.coarse_frames, outputName: name)
            self.fine = StageModel(session: assets.fine, width: assets.config.fine_frames, outputName: name)
        }
    }

    /// Creates a refiner. Construction does no work and starts no download; the
    /// model loads on the first ``refine(_:audio:sampleRate:languageCode:)`` or
    /// ``download(progress:)``, off your calling thread.
    ///
    /// `directory` is where the model lives. If it already contains the model
    /// (you pre-downloaded or shipped it there) it is used offline; otherwise the
    /// model is downloaded into it and reused offline afterward. With no
    /// `directory` (the default), a managed cache location is used.
    public convenience init(directory: String? = nil, computeUnits: ComputeUnits = .cpuAndNeuralEngine) {
        self.init(directory: directory, cacheRoot: nil, computeUnits: computeUnits)
    }

    /// Binding entry point that also supplies the platform base cache root under
    /// which the managed layout lives.
    @_spi(AlignBindings)
    public init(directory: String?, cacheRoot: String?, computeUnits: ComputeUnits = .cpuAndNeuralEngine) {
        model = LoadedModel(AlignModel.self, directory: directory, cacheRoot: cacheRoot) { files in
            Runtime(assets: try await .align(files: files, computeUnits: computeUnits, revision: AlignModel.revision))
        }
    }

    /// Creates a refiner from explicitly provided assets (the bindings and
    /// custom-deployment paths).
    @_spi(AlignBindings)
    public init(assets: ModelAssets) {
        model = LoadedModel { Runtime(assets: assets) }
    }

    /// Whether the model is usable with no network: cached, or already present
    /// in `directory`.
    public func isDownloaded() -> Bool { model.isDownloaded() }

    /// Download and load the model ahead of time, so the first refinement is
    /// instant. Reports download progress `0...1`.
    public func download(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        try await model.download(progress: progress)
    }

    /// False means `refine` is a passthrough for this language.
    public func isSupported(languageCode: String) async throws -> Bool {
        try await model.value().assets.config.languages[Self.key(languageCode)] != nil
    }

    static func key(_ languageCode: String) -> String { String(languageCode.prefix(2)).lowercased() }

    /// A word keeps its input times when its correction hits the search edge, would end before it
    /// starts, lies past the end of the audio, or, when streaming, has no forward context
    /// buffered yet.
    ///
    /// Wherever a word ends at or before the next one starts in `words`, it still does in the
    /// result, and every refined word has `start < end`. Two refined words that would overlap meet
    /// at the midpoint of their estimates; a refined word that would overlap an unrefined neighbor
    /// stops at that neighbor's input time; a refined word left empty keeps its input times.
    /// Words that already overlap in `words` are left in that relation.
    ///
    /// Every `start` and `end` must be finite and within `-1...10_000_000` seconds, `sampleRate`
    /// must be finite and positive, and `samples` must not be empty; anything else throws
    /// ``AlignError/invalidInput(_:)``, even for an unsupported language. A word whose `start`
    /// is after its `end` is accepted.
    public func refine(_ words: [WordTiming], audio samples: [Float], sampleRate: Double = 16000,
                       languageCode: String) async throws -> [WordTiming] {
        try Self.validate(words, sampleRate: sampleRate)
        guard !samples.isEmpty else { throw AlignError.invalidInput("the audio is empty") }
        guard !words.isEmpty else { return words }
        let rt = try await model.value()
        guard let langId = rt.assets.config.languages[Self.key(languageCode)].map(Int32.init) else {
            return words
        }
        let audio = try Self.resampled(samples, from: sampleRate, to: rt.assets.config.sample_rate)
        let (logmel, nFrames) = rt.frontend.logMel(audio)
        return try await Self.runCascade(rt, words, logmel: logmel, nFrames: nFrames, langId: langId,
                                         sampleOffset: 0, streaming: false)
    }

    /// The latest time a word may carry, in seconds (about 115 days). Times become frame indices
    /// as `Int`, so an unbounded time traps the process instead of failing the call.
    static let maxSeconds = 10_000_000.0
    /// How far before zero a time may be. A small negative (offset arithmetic upstream) still
    /// refines against the reflect-padded edge, so it is not rejected.
    static let negativeTolerance = 1.0

    static func validate(_ words: [WordTiming], sampleRate: Double) throws {
        try validate(sampleRate: sampleRate)
        try validate(words)
    }

    static func validate(sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AlignError.invalidInput("sampleRate is \(sampleRate), expected a finite positive rate")
        }
    }

    static func validate(_ words: [WordTiming]) throws {
        for (i, w) in words.enumerated() {
            for (name, t) in [("start", w.start), ("end", w.end)]
            where !(t.isFinite && t >= -negativeTolerance && t <= maxSeconds) {
                throw AlignError.invalidInput(
                    "word \(i) \(name) is \(t), expected a time from \(-negativeTolerance) to \(maxSeconds) seconds")
            }
        }
    }

    /// The largest resampled buffer accepted, about 37 hours at 16 kHz. A tiny `sampleRate`
    /// would otherwise ask the resampler for an unrepresentable length.
    static let maxResampledCount = Double(Int32.max)

    static func resampled(_ samples: [Float], from sampleRate: Double, to rate: Int) throws -> [Float] {
        try validate(sampleRate: sampleRate)
        if sampleRate == Double(rate) { return samples }
        guard Double(samples.count) * Double(rate) / sampleRate <= maxResampledCount else {
            throw AlignError.invalidInput("\(samples.count) samples at \(sampleRate) Hz is too long to resample")
        }
        return Resampler.toRate(samples, from: sampleRate, to: Double(rate))
    }

    struct Boundary { let frame: Int; let bytes: [Int32]; let kind: Int32 }

    static func runCascade(_ rt: Runtime, _ words: [WordTiming], logmel: [Float], nFrames: Int,
                           langId: Int32, sampleOffset: Int, streaming: Bool) async throws -> [WordTiming] {
        guard !words.isEmpty else { return words }
        // Cropping indexes the log-mel, so it needs at least one frame. Streaming with
        // nothing buffered yet is the documented "no context" fallback, not an error.
        guard nFrames > 0 else {
            if streaming { return words }
            throw AlignError.invalidInput("the audio is empty")
        }
        let cfg = rt.assets.config
        let hop = cfg.hop_seconds
        let coarseCenter = cfg.coarse_frames / 2, fineCenter = cfg.fine_frames / 2
        let baseFrame = sampleOffset / cfg.hop_length

        var bounds: [Boundary] = []
        bounds.reserveCapacity(words.count * 2)
        for (i, w) in words.enumerated() {
            let prev = i > 0 ? words[i - 1].text : "", next = i + 1 < words.count ? words[i + 1].text : ""
            bounds.append(Boundary(frame: rt.frontend.timeToFrame(w.start) - baseFrame,
                                   bytes: Lexical.bytes(preceding: prev, following: w.text), kind: 0))
            bounds.append(Boundary(frame: rt.frontend.timeToFrame(w.end) - baseFrame,
                                   bytes: Lexical.bytes(preceding: w.text, following: next), kind: 1))
        }

        let coarsePred = try await batched(rt, bounds, width: cfg.coarse_frames, logmel: logmel, nFrames: nFrames,
                                           langId: langId, centers: bounds.map { $0.frame }, model: rt.coarse)
        var fineCenters = [Int](repeating: 0, count: bounds.count)
        for i in 0..<bounds.count {
            // Non-finite audio (NaN, or values whose power overflows) makes the position NaN,
            // and Int(NaN) traps. Such a boundary is marked not ok below.
            let position = coarsePred[i].position.isFinite ? coarsePred[i].position : Double(coarseCenter)
            fineCenters[i] = bounds[i].frame + Int((position - Double(coarseCenter)).rounded())
        }
        let finePred = try await batched(rt, bounds, width: cfg.fine_frames, logmel: logmel, nFrames: nFrames,
                                         langId: langId, centers: fineCenters, model: rt.fine)

        // The calibration policy was fit only on the validation split; it reduces held-out MAE
        // and large regressions.
        var corr = [Double](repeating: 0, count: bounds.count), ok = [Bool](repeating: true, count: bounds.count)
        for i in 0..<bounds.count {
            let cOff = coarsePred[i].position - Double(coarseCenter), fOff = finePred[i].position - Double(fineCenter)
            let features = calibrationFeatures(coarse: coarsePred[i], fine: finePred[i], coarseCorrection: cOff * hop,
                                               fineCorrection: fOff * hop, languageId: Int(langId), kind: Int(bounds[i].kind))
            corr[i] = rt.assets.calibrator.correction(features: features)
            // Offline reflect-pads true edges, but streaming cannot refine a boundary whose
            // forward context is not buffered yet.
            let futureMissing = streaming && bounds[i].frame + coarseCenter >= nFrames
            let pastMissing = streaming && bounds[i].frame < 0
            // Offline, a boundary more than a coarse half-window past the last frame searches only
            // mirrored audio, which yields a confident but meaningless correction.
            let beyondAudio = !streaming && bounds[i].frame - (coarseCenter - 2) > nFrames - 1
            if !cOff.isFinite || !fOff.isFinite || abs(cOff) >= Double(coarseCenter - 2)
                || futureMissing || pastMissing || beyondAudio {
                ok[i] = false
            }
        }

        var out = words
        for i in 0..<words.count {
            let newStart = words[i].start + corr[2 * i], newEnd = words[i].end + corr[2 * i + 1]
            if ok[2 * i], ok[2 * i + 1], newStart < newEnd {
                out[i] = WordTiming(text: words[i].text, start: newStart, end: newEnd, refined: true)
            }
        }
        return resolvingOverlaps(out, input: words)
    }

    /// Keeps words the input had in order from overlapping, exactly as the Python reference does.
    static func resolvingOverlaps(_ output: [WordTiming], input: [WordTiming]) -> [WordTiming] {
        var refined = output.map(\.refined)
        while true {
            var times = input.indices.map { refined[$0] ? output[$0] : input[$0] }
            for i in times.indices.dropLast()
            where input[i].end <= input[i + 1].start && times[i].end > times[i + 1].start {
                switch (refined[i], refined[i + 1]) {
                case (true, true):
                    let meet = (times[i].end + times[i + 1].start) / 2
                    times[i].end = meet
                    times[i + 1].start = meet
                case (true, false): times[i].end = times[i + 1].start
                default: times[i + 1].start = times[i].end
                }
            }
            let collapsed = times.indices.filter { refined[$0] && times[$0].start >= times[$0].end }
            if collapsed.isEmpty { return times }
            for i in collapsed { refined[i] = false }
        }
    }

    static func calibrationFeatures(
        coarse: StagePrediction,
        fine: StagePrediction,
        coarseCorrection: Double,
        fineCorrection: Double,
        languageId: Int,
        kind: Int
    ) -> [Float] {
        let total = coarseCorrection + fineCorrection
        var features: [Float] = [
            Float(coarseCorrection), Float(coarse.entropy), Float(coarse.normalizedDeviation),
            Float(coarse.maxProbability), Float(coarse.probabilityMargin), Float(coarse.edgeProbability),
            Float(fineCorrection), Float(fine.entropy), Float(fine.normalizedDeviation),
            Float(fine.maxProbability), Float(fine.probabilityMargin), Float(fine.edgeProbability),
            Float(total), Float(abs(coarseCorrection)), Float(abs(fineCorrection)), Float(abs(total)),
            Float(coarseCorrection * fineCorrection),
        ]
        for language in 0..<9 { features.append(language == languageId ? 1 : 0) }
        features.append(Float(kind))
        return features
    }

    private static func batched(_ rt: Runtime, _ bounds: [Boundary], width: Int, logmel: [Float], nFrames: Int,
                                langId: Int32, centers: [Int], model: StageModel) async throws -> [StagePrediction] {
        var result: [StagePrediction] = []
        result.reserveCapacity(bounds.count)
        var i = 0
        while i < bounds.count {
            let j = min(i + StageModel.batch, bounds.count)
            let slice = Array(i..<j)
            let mel = slice.map { rt.frontend.crop(logmel, nFrames: nFrames, centerFrame: centers[$0], width: width) }
            result.append(contentsOf: try await model.predictions(mel: mel, bytes: slice.map { bounds[$0].bytes },
                                                                  langs: slice.map { _ in langId },
                                                                  kinds: slice.map { bounds[$0].kind }))
            i = j
        }
        return result
    }

    /// Testing hook for portable calibrator parity.
    func _debugCalibratedCorrection(_ features: [Float]) async throws -> Double {
        try await model.value().assets.calibrator.correction(features: features)
    }
}

@available(*, deprecated, renamed: "Align")
public typealias SpeechTimestampRefiner = Align

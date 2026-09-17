import DesertAnt

/// Word-timestamp refinement for any transcript: audio and proposed times in, corrected times out.
public final class Align: Sendable {
    // Resolving the files, loading once, sharing that load, and reporting
    // availability are the same for every model, so they live in the core's
    // `LoadedModel`; Align adds only how a resolved directory becomes its model.
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
    public convenience init(directory: String? = nil, computeUnits: ComputeUnits = .all) {
        self.init(directory: directory, cacheRoot: nil, computeUnits: computeUnits)
    }

    /// Binding entry point that also supplies the platform base cache root under
    /// which the managed layout lives.
    @_spi(AlignBindings)
    public init(directory: String?, cacheRoot: String?, computeUnits: ComputeUnits = .all) {
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

    /// A word keeps its input times when a correction is structurally invalid or hits the search edge.
    public func refine(_ words: [WordTiming], audio samples: [Float], sampleRate: Double = 16000,
                       languageCode: String) async throws -> [WordTiming] {
        guard !words.isEmpty else { return words }
        let rt = try await model.value()
        guard let langId = rt.assets.config.languages[Self.key(languageCode)].map(Int32.init) else {
            return words
        }
        let cfg = rt.assets.config
        let audio = sampleRate == Double(cfg.sample_rate) ? samples
            : Resampler.toRate(samples, from: sampleRate, to: Double(cfg.sample_rate))
        let (logmel, nFrames) = rt.frontend.logMel(audio)
        return try await Self.runCascade(rt, words, logmel: logmel, nFrames: nFrames, langId: langId,
                                         sampleOffset: 0, streaming: false)
    }

    struct Boundary { let word: Int; let isEnd: Bool; let time: Double; let frame: Int
                      let bytes: [Int32]; let kind: Int32 }

    static func runCascade(_ rt: Runtime, _ words: [WordTiming], logmel: [Float], nFrames: Int,
                           langId: Int32, sampleOffset: Int, streaming: Bool) async throws -> [WordTiming] {
        guard !words.isEmpty else { return words }
        let cfg = rt.assets.config
        let hop = cfg.hop_seconds
        let coarseCenter = cfg.coarse_frames / 2, fineCenter = cfg.fine_frames / 2
        let baseFrame = sampleOffset / cfg.hop_length

        var bounds: [Boundary] = []
        bounds.reserveCapacity(words.count * 2)
        for (i, w) in words.enumerated() {
            let prev = i > 0 ? words[i - 1].text : "", next = i + 1 < words.count ? words[i + 1].text : ""
            bounds.append(Boundary(word: i, isEnd: false, time: w.start,
                                   frame: rt.frontend.timeToFrame(w.start) - baseFrame,
                                   bytes: Lexical.bytes(preceding: prev, following: w.text), kind: 0))
            bounds.append(Boundary(word: i, isEnd: true, time: w.end,
                                   frame: rt.frontend.timeToFrame(w.end) - baseFrame,
                                   bytes: Lexical.bytes(preceding: w.text, following: next), kind: 1))
        }

        let coarsePred = try await batched(rt, bounds, width: cfg.coarse_frames, logmel: logmel, nFrames: nFrames,
                                           langId: langId, centers: bounds.map { $0.frame }, model: rt.coarse)
        var fineCenters = [Int](repeating: 0, count: bounds.count)
        for i in 0..<bounds.count {
            fineCenters[i] = bounds[i].frame + Int((coarsePred[i].position - Double(coarseCenter)).rounded())
        }
        let finePred = try await batched(rt, bounds, width: cfg.fine_frames, logmel: logmel, nFrames: nFrames,
                                         langId: langId, centers: fineCenters, model: rt.fine)

        // Calibrate each correction from both output distributions. This policy was fit only
        // on the validation split and reduces held-out MAE and large regressions.
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
            if !coarsePred[i].isValid || !finePred[i].isValid || abs(cOff) >= Double(coarseCenter - 2)
                || futureMissing || pastMissing {
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
        return out
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
        let uniformDeviation = ((Double(width * width) - 1) / 12).squareRoot() / Double(width)
        let fallback = StagePrediction(isValid: false, position: Double(width / 2), entropy: 1,
                                       normalizedDeviation: uniformDeviation, maxProbability: 1 / Double(width),
                                       probabilityMargin: 0, edgeProbability: 10 / Double(width))
        var result = [StagePrediction](repeating: fallback, count: bounds.count)
        var i = 0
        while i < bounds.count {
            let j = min(i + StageModel.batch, bounds.count)
            let slice = Array(i..<j)
            let mel = slice.map { rt.frontend.crop(logmel, nFrames: nFrames, centerFrame: centers[$0], width: width) }
            let predictions = try await model.predictions(mel: mel, bytes: slice.map { bounds[$0].bytes },
                                                          langs: slice.map { _ in langId },
                                                          kinds: slice.map { bounds[$0].kind })
            for (k, idx) in slice.enumerated() { result[idx] = predictions[k] }
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

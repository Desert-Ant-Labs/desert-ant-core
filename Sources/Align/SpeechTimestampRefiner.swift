import DesertAnt
import Foundation

/// Errors raised while locating the compiled models and preprocessing sidecars.
public enum AlignResourceError: Error, Sendable, Equatable {
    case missingResource(String)
}

private struct RefinerResources {
    let config: URL
    let melFilters: URL
    let coarseModel: URL
    let fineModel: URL
    let calibrator: URL

    init(directory: URL) throws {
        func require(_ relativePath: String) throws -> URL {
            let url = directory.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AlignResourceError.missingResource(relativePath)
            }
            return url
        }
        config = try require("refiner_config.json")
        melFilters = try require("mel_filters.bin")
        coarseModel = try require(AlignModel.coarse)
        fineModel = try require(AlignModel.fine)
        calibrator = try require("calibrator.bin")
    }
}

/// Corrects Apple SpeechAnalyzer word timestamps. Attach it to the standard Speech pipeline:
///
///     let refiner = try SpeechTimestampRefiner(locale: locale)
///
///     try await analyzer.start(inputSequence: inputs.recordingAudio(for: refiner))
///
///     for try await result in transcriber.results.refiningTimestamps(with: refiner) {
///         // result.text has corrected word-level audioTimeRange attributes
///     }
///
/// Runs on the Neural Engine (fixed batch-16), and keeps Apple's original timestamp when
/// a correction is structurally invalid, lacks streaming context, or hits the search edge.
public final class SpeechTimestampRefiner: @unchecked Sendable {
    private let cfg: RefinerConfig
    private let frontend: Frontend
    private let coarse: StageModel
    private let fine: StageModel
    private let calibrator: CorrectionCalibrator
    private let languageId: Int32?

    // streaming ring buffer (absolute sample timeline)
    private var buffer: [Float] = []
    private var completeAudio: [Float]?
    private var baseSample: Int = 0
    private let maxBufferedSeconds: Double
    private let lock = NSLock()

    /// True if this locale/language is covered by the model. When false, `refine` is a no-op
    /// passthrough (returns the input unchanged).
    public var isSupported: Bool { languageId != nil }

    /// Create a refiner, resolving the model on demand: adopt files already in
    /// `directory` (or the managed cache when nil), else download them there
    /// first. Subsequent creations are offline.
    public convenience init(
        locale: Locale,
        directory: String? = nil,
        maxBufferedSeconds: Double = 30,
        progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws {
        let files = try await AlignModel.resolve(directory: directory, progress: progress)
        try self.init(
            locale: locale,
            resourceDirectory: URL(fileURLWithPath: files.rootPath, isDirectory: true),
            maxBufferedSeconds: maxBufferedSeconds
        )
    }

    /// Create a refiner from a directory containing the compiled models and sidecars.
    public convenience init(
        locale: Locale,
        resourceDirectory: URL,
        maxBufferedSeconds: Double = 30
    ) throws {
        try self.init(
            languageCode: locale.language.languageCode?.identifier ?? "",
            resources: RefinerResources(directory: resourceDirectory),
            maxBufferedSeconds: maxBufferedSeconds
        )
    }

    /// Language-code convenience used by tests.
    convenience init(
        languageCode: String,
        resourceDirectory: URL,
        maxBufferedSeconds: Double = 30
    ) throws {
        try self.init(
            languageCode: languageCode,
            resources: RefinerResources(directory: resourceDirectory),
            maxBufferedSeconds: maxBufferedSeconds
        )
    }

    private init(
        languageCode: String,
        resources: RefinerResources,
        maxBufferedSeconds: Double
    ) throws {
        let cfgData = try Data(contentsOf: resources.config)
        self.cfg = try JSONDecoder().decode(RefinerConfig.self, from: cfgData)
        let melData = try Data(contentsOf: resources.melFilters)
        let mel = melData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        self.frontend = Frontend(cfg: cfg, melFilters: mel)
        self.coarse = try StageModel(url: resources.coarseModel, width: cfg.coarse_frames)
        self.fine = try StageModel(url: resources.fineModel, width: cfg.fine_frames)
        self.calibrator = try CorrectionCalibrator(url: resources.calibrator)
        self.languageId = cfg.languages[String(languageCode.prefix(2)).lowercased()].map(Int32.init)
        self.maxBufferedSeconds = maxBufferedSeconds
    }

    // MARK: offline

    /// Correct `words` using the provided audio. `samples` must be mono; resampled to 16 kHz.
    func refine(_ words: [WordTiming], audio samples: [Float], sampleRate: Double = 16000) -> [WordTiming] {
        guard let langId = languageId, !words.isEmpty else { return words }
        let audio = sampleRate == Double(cfg.sample_rate) ? samples
            : Resampler.toRate(samples, from: sampleRate, to: Double(cfg.sample_rate))
        let (logmel, nFrames) = frontend.logMel(audio)
        return runCascade(words, logmel: logmel, nFrames: nFrames, langId: langId, sampleOffset: 0, streaming: false)
    }

    // MARK: streaming

    /// Feed audio as it arrives (same audio you give SpeechAnalyzer).
    func appendAudio(_ samples: [Float], sampleRate: Double = 16000) {
        let audio = sampleRate == Double(cfg.sample_rate) ? samples
            : Resampler.toRate(samples, from: sampleRate, to: Double(cfg.sample_rate))
        lock.lock(); defer { lock.unlock() }
        completeAudio = nil
        buffer.append(contentsOf: audio)
        let cap = Int(maxBufferedSeconds * Double(cfg.sample_rate))
        if buffer.count > cap {
            let drop = buffer.count - cap
            buffer.removeFirst(drop)
            baseSample += drop
        }
    }

    /// Correct finalized `words` using buffered audio. Boundaries whose +/-1.2 s context is not
    /// yet buffered fall back to Apple's original timestamp.
    func refine(_ words: [WordTiming]) -> [WordTiming] {
        guard let langId = languageId, !words.isEmpty else { return words }
        lock.lock()
        let fullAudio = completeAudio
        let audio = fullAudio ?? buffer
        let base = fullAudio == nil ? baseSample : 0
        lock.unlock()
        let (logmel, nFrames) = frontend.logMel(audio)
        return runCascade(
            words,
            logmel: logmel,
            nFrames: nFrames,
            langId: langId,
            sampleOffset: base,
            streaming: fullAudio == nil
        )
    }

    func useCompleteAudio(_ samples: [Float], sampleRate: Double) {
        let audio = sampleRate == Double(cfg.sample_rate) ? samples
            : Resampler.toRate(samples, from: sampleRate, to: Double(cfg.sample_rate))
        lock.lock()
        completeAudio = audio
        buffer.removeAll(keepingCapacity: false)
        baseSample = 0
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        completeAudio = nil
        baseSample = 0
        lock.unlock()
    }

    /// Testing hooks for frontend and portable calibrator parity.
    func _debugLogMel(_ samples: [Float]) -> (data: [Float], nFrames: Int) { frontend.logMel(samples) }
    func _debugCalibratedCorrection(_ features: [Float]) -> Double {
        calibrator.correction(features: features)
    }

    // MARK: cascade

    private struct Boundary { let word: Int; let isEnd: Bool; let time: Double; let frame: Int
                              let bytes: [Int32]; let kind: Int32 }

    private func runCascade(_ words: [WordTiming], logmel: [Float], nFrames: Int,
                            langId: Int32, sampleOffset: Int, streaming: Bool) -> [WordTiming] {
        let hop = cfg.hop_seconds
        let coarseCenter = cfg.coarse_frames / 2, fineCenter = cfg.fine_frames / 2
        let baseFrame = sampleOffset / cfg.hop_length

        // build 2 boundaries per word
        var bounds: [Boundary] = []
        bounds.reserveCapacity(words.count * 2)
        for (i, w) in words.enumerated() {
            let prev = i > 0 ? words[i - 1].text : ""
            let next = i + 1 < words.count ? words[i + 1].text : ""
            let sf = frontend.timeToFrame(w.start) - baseFrame
            let ef = frontend.timeToFrame(w.end) - baseFrame
            bounds.append(Boundary(word: i, isEnd: false, time: w.start, frame: sf,
                                   bytes: Lexical.bytes(preceding: prev, following: w.text), kind: 0))
            bounds.append(Boundary(word: i, isEnd: true, time: w.end, frame: ef,
                                   bytes: Lexical.bytes(preceding: w.text, following: next), kind: 1))
        }

        // stage 1: coarse
        let coarsePred = batched(bounds, width: cfg.coarse_frames, logmel: logmel, nFrames: nFrames,
                                 langId: langId, centers: bounds.map { $0.frame }, model: coarse)
        // stage 2: fine, recentered on coarse
        var fineCenters = [Int](repeating: 0, count: bounds.count)
        for i in 0..<bounds.count {
            fineCenters[i] = bounds[i].frame
                + Int((coarsePred[i].position - Double(coarseCenter)).rounded())
        }
        let finePred = batched(bounds, width: cfg.fine_frames, logmel: logmel, nFrames: nFrames,
                               langId: langId, centers: fineCenters, model: fine)

        // Calibrate each correction from both output distributions. This policy was fit only
        // on the validation split and reduces held-out MAE and large regressions.
        var corr = [Double](repeating: 0, count: bounds.count)
        var ok = [Bool](repeating: true, count: bounds.count)
        for i in 0..<bounds.count {
            let cOff = coarsePred[i].position - Double(coarseCenter)
            let fOff = finePred[i].position - Double(fineCenter)
            let features = calibrationFeatures(
                coarse: coarsePred[i],
                fine: finePred[i],
                coarseCorrection: cOff * hop,
                fineCorrection: fOff * hop,
                languageId: Int(langId),
                kind: Int(bounds[i].kind)
            )
            corr[i] = calibrator.correction(features: features)
            // Reject coarse predictions at the search edge; offline reflect-pads true
            // edges, but streaming can't refine a boundary whose forward context isn't buffered yet.
            let futureMissing = streaming && bounds[i].frame + coarseCenter >= nFrames
            let pastMissing = streaming && bounds[i].frame < 0
            if !coarsePred[i].isValid || !finePred[i].isValid
                || abs(cOff) >= Double(coarseCenter - 2) || futureMissing || pastMissing {
                ok[i] = false
            }
        }

        // apply with fallback (keep Apple's range if invalid)
        var out = words
        for i in 0..<words.count {
            let cs = corr[2 * i], ce = corr[2 * i + 1]
            let newStart = words[i].start + cs, newEnd = words[i].end + ce
            if ok[2 * i], ok[2 * i + 1], newStart < newEnd {
                out[i] = WordTiming(text: words[i].text, start: newStart, end: newEnd, refined: true)
            }
        }
        return out
    }

    private func calibrationFeatures(
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

    private func batched(_ bounds: [Boundary], width: Int, logmel: [Float], nFrames: Int,
                         langId: Int32, centers: [Int], model: StageModel) -> [StagePrediction] {
        let uniformDeviation = sqrt((Double(width * width) - 1) / 12) / Double(width)
        let fallback = StagePrediction(
            isValid: false, position: Double(width / 2), entropy: 1, normalizedDeviation: uniformDeviation,
            maxProbability: 1 / Double(width), probabilityMargin: 0,
            edgeProbability: 10 / Double(width)
        )
        var result = [StagePrediction](repeating: fallback, count: bounds.count)
        var i = 0
        while i < bounds.count {
            let j = min(i + 16, bounds.count)
            let slice = Array(i..<j)
            let mel = slice.map { frontend.crop(logmel, nFrames: nFrames, centerFrame: centers[$0], width: width) }
            let bytes = slice.map { bounds[$0].bytes }
            let langs = slice.map { _ in langId }
            let kinds = slice.map { bounds[$0].kind }
            if let predictions = try? model.predictions(mel: mel, bytes: bytes, langs: langs, kinds: kinds) {
                for (k, idx) in slice.enumerated() { result[idx] = predictions[k] }
            }
            i = j
        }
        return result
    }
}

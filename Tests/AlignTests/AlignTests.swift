import FFIBuffer
import ModelStore
import Foundation
import Testing
@_spi(AlignBindings) @testable import Align
@testable import AudioDSP
import TestSupport

struct Golden: Codable {
    struct W: Codable { let text: String; let start: Double; let end: Double }
    let sample_rate: Int; let n_samples: Int; let language: String
    let words: [W]; let logmel_b64: String; let n_frames: Int; var corrections: [Double]
}

func loadGolden() throws -> Golden {
    let url = Bundle.module.url(forResource: "golden", withExtension: "json")!
    return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
}

func synthAudio(_ n: Int, _ sr: Int) -> [Float] {
    var out = [Float](repeating: 0, count: n)
    let twoPi = 2.0 * Double.pi
    for i in 0..<n {
        let t = Double(i) / Double(sr)
        let a: Double = 0.3 * sin(twoPi * 200 * t)
        let b: Double = 0.2 * sin(twoPi * 350 * t)
        let c: Double = 0.1 * sin(twoPi * 61 * t) * sin(twoPi * 3 * t)
        out[i] = Float(a + b + c)
    }
    return out
}

#if !os(WASI)
/// The downloaded model's directory (fetched once per process, then offline).
func modelDirectory() async throws -> URL {
    let files = try await ModelFixture.files(AlignModel.self)
    return URL(fileURLWithPath: files.rootPath, isDirectory: true)
}

/// The frontend alone, from the model's config and mel filterbank; no inference runtime.
func makeFrontend() async throws -> Frontend {
    let directory = try await modelDirectory()
    let cfgData = try Data(contentsOf: directory.appendingPathComponent("refiner_config.json"))
    let cfg = try JSONDecoder().decode(RefinerConfig.self, from: cfgData)
    let melData = try Data(contentsOf: directory.appendingPathComponent("mel_filters.bin"))
    let mel = melData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    return Frontend(cfg: cfg, melFilters: mel)
}

@Suite(.serialized, .modelBacked) struct FrontendTests {
    @Test func frontendParity() async throws {
        let g = try loadGolden()
        let frontend = try await makeFrontend()
        let audio = synthAudio(g.n_samples, g.sample_rate)
        let (lm, nF) = frontend.logMel(audio)
        #expect(nF == g.n_frames)
        let ref = Data(base64Encoded: g.logmel_b64)!.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(lm.count == ref.count)
        var mse = 0.0, peak = 0.0, maxAbs = 0.0
        for k in 0..<lm.count {
            let d = Double(lm[k] - ref[k])
            mse += d * d
            peak = max(peak, abs(Double(ref[k])))
            maxAbs = max(maxAbs, abs(d))
        }
        mse /= Double(lm.count)
        let psnr = 10 * log10(peak * peak / max(mse, 1e-12))
        print("frontend PSNR \(psnr) dB, RMSE \(sqrt(mse)), max abs diff \(maxAbs)")
        #expect(psnr > 60.0, "log-mel frontend diverges from Python reference")
    }

    // The FFT path is what runs without Accelerate; exercise it on every host.
    @Test func frontendFFTPathMatchesMatmulPath() async throws {
        let g = try loadGolden()
        let frontend = try await makeFrontend()
        #expect(frontend.stft.hasFFT)
        let ref = Data(base64Encoded: g.logmel_b64)!.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var state: UInt64 = 42
        let noise = (0..<(16000 * 4)).map { _ -> Float in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(state >> 11) / 0x1p53) - 0.5
        }
        let signals: [(String, [Float])] = [("golden", synthAudio(g.n_samples, g.sample_rate)), ("noise", noise)]
        for (name, audio) in signals {
            let fft = frontend.logMel(spectrogram: frontend.stft.forwardFFT(audio))
            let matmul = frontend.logMel(spectrogram: frontend.stft.forwardMatmul(audio))
            #expect(fft.nFrames == matmul.nFrames)
            var maxAbs: Float = 0
            for k in 0..<fft.data.count { maxAbs = max(maxAbs, abs(fft.data[k] - matmul.data[k])) }
            print("frontend \(name): fft vs matmul max abs diff \(maxAbs)")
            // Unit-variance log-mel; the gap is the matmul bases' own float32 error.
            #expect(maxAbs < 1e-3, "\(name): FFT and matmul log-mel diverge")
            guard name == "golden" else { continue }
            var mse = 0.0, peak = 0.0
            for k in 0..<ref.count {
                let d = Double(fft.data[k] - ref[k])
                mse += d * d
                peak = max(peak, abs(Double(ref[k])))
            }
            let psnr = 10 * log10(peak * peak / max(mse / Double(ref.count), 1e-12))
            print("frontend FFT path PSNR \(psnr) dB vs Python reference")
            #expect(psnr > 60.0)
        }
    }
}

// Validation runs before the model loads, so none of these need the weights.
@Suite struct InputValidationTests {
    func refiner() -> Align {
        Align(directory: NSTemporaryDirectory() + "align-unloaded-\(UUID().uuidString)")
    }

    // Word times become Int frame indices, so a time Int cannot hold used to trap the host process.
    @Test(arguments: [Double.nan, .infinity, -.infinity, 1e17, 1e308, -1e20])
    func untrappableStartThrows(_ start: Double) async throws {
        let words = [WordTiming(text: "one", start: start, end: 0.5)]
        await #expect(throws: AlignError.self) {
            try await refiner().refine(words, audio: synthAudio(16000, 16000), languageCode: "en")
        }
    }

    // Rejected by policy, not because it traps: times in [-9.2e16, -1) and (1e7, 9.2e16] used to
    // return a meaningless result and are now refused.
    @Test(arguments: [-5.0, 1e8])
    func outOfRangeStartThrows(_ start: Double) async throws {
        let words = [WordTiming(text: "one", start: start, end: 0.5)]
        await #expect(throws: AlignError.self) {
            try await refiner().refine(words, audio: synthAudio(16000, 16000), languageCode: "en")
        }
    }

    @Test(arguments: [Double.nan, .infinity, 1e17, -1e20])
    func invalidEndThrows(_ end: Double) async throws {
        let words = [WordTiming(text: "one", start: 0.2, end: 0.5), WordTiming(text: "two", start: 0.6, end: end)]
        await #expect(throws: AlignError.self) {
            try await refiner().refine(words, audio: synthAudio(16000, 16000), languageCode: "en")
        }
    }

    // Rejected even where refine would otherwise be a passthrough, so the rule does not depend on
    // language. An unsupported language used to return these inputs unchanged.
    @Test func invalidInputThrowsForUnsupportedLanguage() async throws {
        let good = [WordTiming(text: "one", start: 0.2, end: 0.5)]
        await #expect(throws: AlignError.self) {
            try await refiner().refine([WordTiming(text: "one", start: .nan, end: 0.5)],
                                       audio: synthAudio(16000, 16000), languageCode: "xx")
        }
        await #expect(throws: AlignError.self) {
            try await refiner().refine(good, audio: synthAudio(16000, 16000), sampleRate: .nan, languageCode: "xx")
        }
        await #expect(throws: AlignError.self) {
            try await refiner().refine(good, audio: [], languageCode: "xx")
        }
    }

    // The path the Node binding takes: the thrown error must come back as nil, which the host
    // reports as a failed call, rather than trapping.
    @Test(arguments: [Double.nan, 1e17, -1e20])
    func bindingRunReturnsNilForInvalidTime(_ start: Double) async throws {
        var input = FFIWriter()
        input.f32Array(synthAudio(16000, 16000))
        input.f64(16000)
        input.u32(1)
        input.string("one"); input.f64(start); input.f64(0.5)
        var options = FFIWriter()
        options.string("en")
        let out = await refiner().run(input: FFIReader(input.bytes), options: FFIReader(options.bytes))
        #expect(out == nil)
    }

    #if canImport(Speech)
    @Test(arguments: [Double.nan, -1])
    func invalidBufferLengthThrows(_ seconds: Double) async throws {
        let streaming = StreamingRefiner(align: refiner(), languageCode: "en", maxBufferedSeconds: seconds)
        await #expect(throws: AlignError.self) { try await streaming.appendAudio(synthAudio(1600, 16000)) }
    }
    #endif

    @Test(arguments: [Double.nan, .infinity, 0, -16000])
    func invalidSampleRateThrows(_ rate: Double) async throws {
        #expect(throws: AlignError.self) { try Align.resampled(synthAudio(16000, 16000), from: rate, to: 16000) }
    }

    @Test func tinySampleRateThrows() {
        #expect(throws: AlignError.self) { try Align.resampled(synthAudio(16000, 16000), from: 1e-300, to: 16000) }
    }

    @Test func boundaryTimesAreAccepted() throws {
        try Align.validate([
            WordTiming(text: "a", start: -0.5, end: 0),
            WordTiming(text: "b", start: 100, end: Align.maxSeconds),
            WordTiming(text: "c", start: 3, end: 2),
        ])
    }

    @Test func errorNamesTheWord() {
        do {
            try Align.validate([WordTiming(text: "a", start: 0, end: 1), WordTiming(text: "b", start: 1, end: .nan)])
            Issue.record("expected a throw")
        } catch {
            #expect("\(error.localizedDescription)".contains("word 1 end is nan"))
        }
    }
}

#if canImport(Speech)
import CoreMedia
import Speech
#endif

@Suite(.serialized, .modelBacked) struct AlignTests {
    struct CalibrationGolden: Codable {
        let features: [[Float]]
        var corrections: [Double]
    }

    /// How far the cascade may drift from the recorded corrections, per backend, in ms.
    ///
    /// Parity fixtures are recorded and compared on the CPU. The ANE and CPU paths disagree,
    /// and where the model is unsure that becomes tens of milliseconds, so one number cannot
    /// cover two runtimes. A backend with no row prints its drift and asserts nothing.
    ///
    /// litert: 10.4 ms measured 2026-09-17 on linux-arm64 (Docker, swift:6.3.3-jammy). The
    /// Linux and Windows CI lanes read this row.
    static let parityToleranceMs: [String: Double] = ["coreml-cpu": 25.0, "litert": 15.0]

    /// Which row applies here: the runtime that opens the stages, plus the compute units this
    /// suite pins, which only Core ML has.
    static var parityBackend: String {
        let runtime = ModelRuntime.inferred(fromPath: AlignModel.coarseArtifact(for: .current))
            ?? .platformDefault
        return runtime == .coreML ? "coreml-cpu" : runtime.rawValue
    }

    func makeRefiner() async throws -> Align {
        let files = try await ModelFixture.files(AlignModel.self)
        return Align(assets: try await .align(files: files, computeUnits: .cpuOnly, revision: nil))
    }

    // A user pre-populating a directory with the declared files can load from it.
    @Test func explicitResourceLoading() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("align-explicit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ModelFixture.populate(AlignModel.self, into: directory)

        let refiner = Align(directory: directory.path)
        #expect(refiner.isDownloaded())
        #expect(try await refiner.isSupported(languageCode: "en"))
    }

    /// Rewrites both golden fixtures from the weights this SDK resolves.
    ///
    /// The parity tests compare to 1e-6, so the fixtures have to come from this runtime
    /// rather than a reimplementation, and they go stale whenever the pinned weights
    /// revision changes.
    ///
    ///     ALIGN_REGENERATE_GOLDENS=1 swift test --filter regenerateGoldens
    ///
    /// Then re-run the suite: the parity tests must pass against what this wrote.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ALIGN_REGENERATE_GOLDENS"] == "1",
                   "set ALIGN_REGENERATE_GOLDENS=1 to rewrite the fixtures"))
    func regenerateGoldens() async throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Resources")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var golden = try loadGolden()
        let refiner = try await makeRefiner()
        let audio = synthAudio(golden.n_samples, golden.sample_rate)
        let words = golden.words.map { WordTiming(text: $0.text, start: $0.start, end: $0.end) }
        // The cascade fixture is not English: it carries its own language, and refining it
        // through the wrong embedding row silently produces a different model.
        let fixed = try await refiner.refine(words, audio: audio, sampleRate: Double(golden.sample_rate),
                                             languageCode: golden.language)
        var corrections: [Double] = []
        var drift = 0.0
        for i in words.indices {
            corrections.append(fixed[i].start - words[i].start)
            corrections.append(fixed[i].end - words[i].end)
            drift = max(drift, abs(corrections[2 * i] - golden.corrections[2 * i]) * 1000)
            drift = max(drift, abs(corrections[2 * i + 1] - golden.corrections[2 * i + 1]) * 1000)
        }
        golden.corrections = corrections
        try encoder.encode(golden).write(to: resources.appendingPathComponent("golden.json"))

        let calURL = resources.appendingPathComponent("calibration_golden.json")
        var cal = try JSONDecoder().decode(CalibrationGolden.self, from: Data(contentsOf: calURL))
        var calibrated: [Double] = []
        for features in cal.features { calibrated.append(try await refiner._debugCalibratedCorrection(features)) }
        cal.corrections = calibrated
        try encoder.encode(cal).write(to: calURL)

        print("regenerated goldens: \(corrections.count) cascade, \(cal.corrections.count) calibration")
        print("max correction drift from the previous fixture \(drift) ms")
    }

    @Test func calibrationParity() async throws {
        let url = Bundle.module.url(forResource: "calibration_golden", withExtension: "json")!
        let golden = try JSONDecoder().decode(CalibrationGolden.self, from: Data(contentsOf: url))
        let refiner = try await makeRefiner()
        #expect(golden.features.count == golden.corrections.count)
        for i in golden.features.indices {
            let actual = try await refiner._debugCalibratedCorrection(golden.features[i])
            #expect(abs(actual - golden.corrections[i]) <= 0.000_001)
        }
    }

    // The corrections fixture is recorded from this runtime; the test pins determinism per backend.
    // Reference parity against gold is measured on device before a release, not here.
    @Test func endToEndParity() async throws {
        let g = try loadGolden()
        let refiner = try await makeRefiner()
        let audio = synthAudio(g.n_samples, g.sample_rate)
        let words = g.words.map { WordTiming(text: $0.text, start: $0.start, end: $0.end) }
        let fixed = try await refiner.refine(words, audio: audio, sampleRate: Double(g.sample_rate),
                                             languageCode: g.language)
        #expect(fixed.count == words.count)
        var maxDiff = 0.0
        var checkedBoundaries = 0
        for i in 0..<words.count {
            let cs = (fixed[i].start - words[i].start) * 1000
            let ce = (fixed[i].end - words[i].end) * 1000
            print("word \(i) start swift \(cs) golden \(g.corrections[2*i]*1000) | end swift \(ce) golden \(g.corrections[2*i+1]*1000) refined \(fixed[i].refined)")
            // The synthetic audio can produce a start after the corrected end. That is expected
            // to trigger structural fallback, so only compare corrections the runtime applied.
            guard fixed[i].refined else { continue }
            checkedBoundaries += 2
            maxDiff = max(maxDiff, abs(cs - g.corrections[2 * i] * 1000))
            maxDiff = max(maxDiff, abs(ce - g.corrections[2 * i + 1] * 1000))
        }
        print("end-to-end max correction diff \(maxDiff) ms on \(Self.parityBackend)")
        #expect(checkedBoundaries > 0)
        guard let tolerance = Self.parityToleranceMs[Self.parityBackend] else { return }
        #expect(maxDiff < tolerance, "the cascade drifted from its recorded corrections")
    }

    // The whole cascade fed by the FFT frontend path against the matmul path, on this host's runtime.
    @Test func endToEndFFTFrontendMatchesMatmulFrontend() async throws {
        let g = try loadGolden()
        let refiner = try await makeRefiner()
        let rt = try await refiner.model.value()
        let langId = try #require(rt.assets.config.languages[g.language].map(Int32.init))
        var speech = synthAudio(16000 * 20, 16000)
        for i in speech.indices where (i / 8000) % 3 == 2 { speech[i] *= 0.02 }
        let spaced = (0..<24).map { i in
            WordTiming(text: ["one", "two", "three", "four"][i % 4], start: 0.4 + Double(i) * 0.8, end: 0.75 + Double(i) * 0.8)
        }
        let cases: [([Float], [WordTiming])] = [
            (synthAudio(g.n_samples, g.sample_rate), g.words.map { WordTiming(text: $0.text, start: $0.start, end: $0.end) }),
            (speech, spaced),
        ]
        var diffs: [Double] = []
        for (audio, words) in cases {
            let a = rt.frontend.logMel(spectrogram: rt.frontend.stft.forwardFFT(audio))
            let b = rt.frontend.logMel(spectrogram: rt.frontend.stft.forwardMatmul(audio))
            let viaFFT = try await Align.runCascade(rt, words, logmel: a.data, nFrames: a.nFrames, langId: langId,
                                                    sampleOffset: 0, streaming: false)
            let viaMatmul = try await Align.runCascade(rt, words, logmel: b.data, nFrames: b.nFrames, langId: langId,
                                                       sampleOffset: 0, streaming: false)
            for i in words.indices {
                #expect(viaFFT[i].refined == viaMatmul[i].refined)
                diffs.append(abs(viaFFT[i].start - viaMatmul[i].start) * 1000)
                diffs.append(abs(viaFFT[i].end - viaMatmul[i].end) * 1000)
            }
        }
        let maxDiff = diffs.max() ?? 0, meanDiff = diffs.reduce(0, +) / Double(diffs.count)
        print("end-to-end FFT vs matmul frontend: max \(maxDiff) ms, mean \(meanDiff) ms over \(diffs.count) boundaries")
        // Where the model is unsure, float32 rounding alone can move a boundary by one 10 ms frame.
        #expect(maxDiff < 15)
        #expect(meanDiff < 2)
    }

    #if canImport(Speech)
    @available(iOS 26, macOS 26, tvOS 26, visionOS 26, *)
    @Test func attributedTimestampApplicationMatchesWordOutput() async throws {
        let g = try loadGolden()
        let refiner = try await makeRefiner()
        let audio = synthAudio(g.n_samples, g.sample_rate)
        let inputWords = g.words.map { WordTiming(text: $0.text, start: $0.start, end: $0.end) }
        let expected = try await refiner.refine(inputWords, audio: audio, sampleRate: Double(g.sample_rate),
                                                languageCode: g.language)

        var text = AttributedString(g.words.map(\.text).joined(separator: " "))
        for word in g.words {
            let range = text.range(of: word.text)!
            text[range].audioTimeRange = CMTimeRange(
                start: CMTime(seconds: word.start, preferredTimescale: 1_000_000),
                duration: CMTime(seconds: word.end - word.start, preferredTimescale: 1_000_000)
            )
        }
        let correctedText = try await refiner.refine(text, audio: audio, sampleRate: Double(g.sample_rate),
                                                     languageCode: g.language)
        let actual = refiner.words(from: correctedText)
        #expect(actual.count == expected.count)
        for i in expected.indices {
            #expect(actual[i].text == expected[i].text)
            #expect(abs(actual[i].start - expected[i].start) <= 0.000_003)
            #expect(abs(actual[i].end - expected[i].end) <= 0.000_003)
        }
    }
    #endif

    @Test func unsupportedLocalePassthrough() async throws {
        let refiner = try await makeRefiner()
        #expect(try await refiner.isSupported(languageCode: "xx") == false)
        let words = [WordTiming(text: "a", start: 0.1, end: 0.2)]
        let out = try await refiner.refine(words, audio: synthAudio(16000, 16000), languageCode: "xx")
        #expect(out == words)
    }

    @Test func emptyAudioThrowsInsteadOfTrapping() async throws {
        let refiner = try await makeRefiner()
        let words = [WordTiming(text: "one", start: 0.30, end: 0.55)]
        await #expect(throws: AlignError.self) {
            try await refiner.refine(words, audio: [], languageCode: "en")
        }
        // A rate so high the resampler returns nothing is the same empty audio.
        await #expect(throws: AlignError.self) {
            try await refiner.refine(words, audio: synthAudio(16000, 16000), sampleRate: 1e300, languageCode: "en")
        }
    }

    @Test func nonFiniteAudioKeepsInputTimes() async throws {
        let refiner = try await makeRefiner()
        let words = [WordTiming(text: "one", start: 0.30, end: 0.55), WordTiming(text: "two", start: 0.6, end: 0.9)]
        let audio = [Float](repeating: .nan, count: 16000)
        let out = try await refiner.refine(words, audio: audio, languageCode: "en")
        #expect(out == words)
    }

    // More than a coarse half-window past the last frame there is only mirrored audio to search.
    @Test func wordsPastTheAudioKeepTheirTimes() async throws {
        let refiner = try await makeRefiner()
        let words = [WordTiming(text: "late", start: 100, end: 101)]
        let out = try await refiner.refine(words, audio: synthAudio(48000, 16000), languageCode: "en")
        #expect(out == words)
    }

    #if canImport(Speech)
    // Nothing buffered is the "no context yet" fallback, which must not crop an empty log-mel.
    @Test func streamingWithNothingBufferedKeepsTheWords() async throws {
        let streaming = StreamingRefiner(align: try await makeRefiner(), languageCode: "en")
        let words = [WordTiming(text: "one", start: 0.3, end: 0.55)]
        #expect(try await streaming.refine(words) == words)
    }

    // Infinity means unbounded; Int() of it would trap.
    @Test func infiniteBufferDoesNotTrap() async throws {
        let streaming = StreamingRefiner(align: try await makeRefiner(), languageCode: "en",
                                         maxBufferedSeconds: .infinity)
        try await streaming.appendAudio(synthAudio(16000, 16000))
        try await streaming.appendAudio(synthAudio(16000, 16000))
        let out = try await streaming.refine([WordTiming(text: "one", start: 0.3, end: 0.55)])
        #expect(out.count == 1)
    }
    #endif

    // The deprecated name still resolves for the asset init, with a warning.
    @Test func deprecatedNameStillResolves() async throws {
        let files = try await ModelFixture.files(AlignModel.self)
        let refiner = SpeechTimestampRefiner(
            assets: try await .align(files: files, computeUnits: .cpuOnly, revision: nil))
        let words = [WordTiming(text: "one", start: 0.30, end: 0.55)]
        let fixed = try await refiner.refine(words, audio: synthAudio(16000, 16000), languageCode: "en")
        #expect(fixed.count == words.count)
    }
}
#endif

// The refiner only exists where Core ML does; elsewhere this suite is empty.
#if canImport(CoreML) && canImport(Accelerate)
import Foundation
import Testing
#if canImport(Speech)
import CoreMedia
import Speech
#endif
@testable import Align
import TestSupport

struct AlignTests {
    struct Golden: Decodable {
        struct W: Decodable { let text: String; let start: Double; let end: Double }
        let sample_rate: Int; let n_samples: Int; let language: String
        let words: [W]; let logmel_b64: String; let n_frames: Int; let corrections: [Double]
    }

    struct CalibrationGolden: Decodable {
        let features: [[Float]]
        let corrections: [Double]
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

    /// The downloaded model's directory (fetched once per process, then offline).
    func modelDirectory() async throws -> URL {
        let files = try await ModelFixture.files(AlignModel.self)
        return URL(fileURLWithPath: files.rootPath, isDirectory: true)
    }

    func makeRefiner(languageCode: String) async throws -> SpeechTimestampRefiner {
        try SpeechTimestampRefiner(
            languageCode: languageCode,
            resourceDirectory: try await modelDirectory()
        )
    }

    // A user pre-populating a directory with the declared files can load from it.
    @Test func explicitResourceLoading() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("align-explicit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ModelFixture.populate(AlignModel.self, into: directory)

        let fromDirectory = try SpeechTimestampRefiner(
            languageCode: "en",
            resourceDirectory: directory
        )
        #expect(fromDirectory.isSupported)
    }

    // Frontend log-mel must match the Python reference (PSNR high).
    @Test func frontendParity() async throws {
        let g = try loadGolden()
        let refiner = try await makeRefiner(languageCode: g.language)
        let audio = synthAudio(g.n_samples, g.sample_rate)
        let (lm, nF) = refiner._debugLogMel(audio)
        #expect(nF == g.n_frames)
        let ref = Data(base64Encoded: g.logmel_b64)!.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(lm.count == ref.count)
        var mse = 0.0, peak = 0.0
        for k in 0..<lm.count { let d = Double(lm[k] - ref[k]); mse += d * d; peak = max(peak, abs(Double(ref[k]))) }
        mse /= Double(lm.count)
        let psnr = 10 * log10(peak * peak / max(mse, 1e-12))
        print("frontend PSNR \(psnr) dB, RMSE \(sqrt(mse))")
        #expect(psnr > 30.0, "log-mel frontend diverges from Python reference")
    }

    @Test func calibrationParity() async throws {
        let url = Bundle.module.url(forResource: "calibration_golden", withExtension: "json")!
        let golden = try JSONDecoder().decode(CalibrationGolden.self, from: Data(contentsOf: url))
        let refiner = try await makeRefiner(languageCode: "en")
        #expect(golden.features.count == golden.corrections.count)
        for i in golden.features.indices {
            let actual = refiner._debugCalibratedCorrection(golden.features[i])
            #expect(abs(actual - golden.corrections[i]) <= 0.000_001)
        }
    }

    // Full cascade (Core ML) corrections match the PyTorch reference within FP16 tolerance.
    @Test func endToEndParity() async throws {
        let g = try loadGolden()
        let refiner = try await makeRefiner(languageCode: g.language)
        let audio = synthAudio(g.n_samples, g.sample_rate)
        let words = g.words.map { WordTiming(text: $0.text, start: $0.start, end: $0.end) }
        let fixed = refiner.refine(words, audio: audio, sampleRate: Double(g.sample_rate))
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
        print("end-to-end max correction diff \(maxDiff) ms")
        #expect(checkedBoundaries > 0)
        #expect(maxDiff < 25.0, "Core ML cascade diverges from PyTorch reference")
    }

    #if canImport(Speech)
    @available(iOS 26, macOS 26, tvOS 26, visionOS 26, *)
    @Test func attributedTimestampApplicationMatchesWordOutput() async throws {
        let g = try loadGolden()
        let refiner = try await makeRefiner(languageCode: g.language)
        let audio = synthAudio(g.n_samples, g.sample_rate)
        let inputWords = g.words.map { WordTiming(text: $0.text, start: $0.start, end: $0.end) }
        let expected = refiner.refine(inputWords, audio: audio, sampleRate: Double(g.sample_rate))

        var text = AttributedString(g.words.map(\.text).joined(separator: " "))
        for word in g.words {
            let range = text.range(of: word.text)!
            text[range].audioTimeRange = CMTimeRange(
                start: CMTime(seconds: word.start, preferredTimescale: 1_000_000),
                duration: CMTime(seconds: word.end - word.start, preferredTimescale: 1_000_000)
            )
        }
        let correctedText = refiner.refine(text, audio: audio, sampleRate: Double(g.sample_rate))
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
        let refiner = try await makeRefiner(languageCode: "xx")  // not a trained language
        #expect(!refiner.isSupported)
        let words = [WordTiming(text: "a", start: 0.1, end: 0.2)]
        #expect(refiner.refine(words, audio: synthAudio(16000, 16000)) == words)
    }
}
#endif

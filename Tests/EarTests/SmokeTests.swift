import DesertAnt
import Foundation
import Testing
import TestSupport

@testable import Ear

/// Resolve the model the way a caller does, run it, and check the answer has a
/// shape. On every platform, in CI, with no local fixtures.
///
/// This is deliberately not an accuracy test - the audio is synthetic and the
/// language it returns means nothing. It exercises the seam that accuracy tests
/// never reach: downloading the pinned revision, finding the files the catalog
/// names, binding the tensors each runtime names differently, and getting a
/// distribution back. File names and tensor names (LiteRT's
/// `serving_default_args_0`/`output_0` against Core ML's `mel`/`logits`) only
/// meet the code here.
//
// `.serialized` and the shared fixture, which is the house pattern: swift-testing
// runs a suite in parallel by default, and several instances resolving the same
// model at once collide moving the same partial file into place. `.modelBacked`
// decides where these run.
#if !os(WASI)
@Suite(.serialized, .modelBacked)
struct SmokeTests {
    /// One resolution, shared by every test here and with every other model's
    /// suite in the process.
    private func ear() async throws -> Ear {
        let files = try await ModelFixture.files(EarModel.self)
        return Ear(directory: files.rootPath)
    }

    /// Speech-shaped noise: syllables at 4 Hz. Enough for the model to produce a
    /// distribution, and not enough for that distribution to mean anything.
    static func audio(seconds: Int = 40) -> [Float] {
        var samples = [Float](repeating: 0, count: 16000 * seconds)
        var generator = SystemRandomNumberGenerator()
        for n in samples.indices {
            let t = Double(n) / 16000.0
            let syllable = 0.5 + 0.5 * sin(2.0 * Double.pi * 4.0 * t)
            let noise = Float.random(in: -1...1, using: &generator)
            samples[n] = Float(syllable) * 0.3 * noise
        }
        return samples
    }

    #if os(Linux)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EAR_CAPTURE_ANDROID_PARITY"] != "1",
                   "capturing a new Android reference"))
    #else
    @Test
    #endif
    func resolvesTheModelAndRunsIt() async throws {
        let ear = try await ear()
        #if os(Linux)
        let golden = try ParityReference.load()
        let samples = Self.parityAudio(sampleCount: golden.sampleCount, sampleRate: golden.sampleRate)
        let sampleRate = golden.sampleRate
        #else
        let samples = Self.audio()
        let sampleRate = 16_000
        #endif
        let began = Date()
        let detection = try await ear.identify(samples: samples, sampleRate: Double(sampleRate))
        let seconds = Date().timeIntervalSince(began)

        #if os(Linux)
        #expect(golden.revision == EarModel.revision)
        #expect(golden.backend == "litert")
        #expect(detection.windows == golden.windows)
        #expect(detection.isReliable == golden.isReliable)
        try #require(!golden.candidates.isEmpty)
        let prefix = detection.candidates.prefix(golden.candidates.count)
        #expect(prefix.map(\.language) == golden.candidates.map(\.language))
        for (actual, expected) in zip(prefix, golden.candidates) {
            #expect(abs(actual.probability - expected.probability) < 0.01, "\(expected.language)")
        }
        #endif

        let language = try #require(detection.language)
        #expect(!language.isEmpty)
        #expect(detection.confidence > 0 && detection.confidence <= 1)
        #expect(detection.windows >= 1)
        // Candidates must be a ranked distribution, not an arbitrary order:
        // the top one is what every caller reads.
        let probabilities = detection.candidates.map(\.probability)
        #expect(probabilities == probabilities.sorted(by: >))
        #expect(detection.confidence == probabilities.first)
        print("  resolved and ran in \(Int(seconds * 1000)) ms -> \(language)")
    }

    @Test func namesTheLanguagesItCanReport() async throws {
        let languages = try await ear().supportedLanguages()
        #expect(languages.count > 90)
        #expect(languages.contains("en") && languages.contains("pt"))
        #expect(Set(languages).count == languages.count, "duplicate codes")
        // Aliases are applied on the way out, or callers see the model's own
        // code for Norwegian rather than the one they asked about.
        #expect(!languages.contains("nb"))
    }

    @Test func rateConversionStillProducesAVerdict() async throws {
        // Callers hand us whatever their file decoded to. The resampler runs
        // before the frontend, so a rate mismatch must not break the pipeline.
        // The verdict on synthetic noise means nothing, so there is nothing to
        // compare against the 16 kHz run (resolvesTheModelAndRunsIt covers that
        // path); what this buys is the resampler seam producing a distribution.
        // One inference, not two: each is minutes on the Windows CPU runner.
        let resampled = try await ear().identify(samples: Self.audio(), sampleRate: 44100)
        #expect(resampled.language != nil)
        #expect(resampled.windows >= 1)
    }

    @Test func rejectsEmptyAudio() async throws {
        let directory = try await ModelFixture.files(EarModel.self).rootPath
        await #expect(throws: EarError.self) {
            _ = try await Ear(directory: directory).identify(samples: [], sampleRate: 16000)
        }
    }

    @Test func reportsWhetherItIsCached() async throws {
        // After a successful run the model must report itself present, or the
        // catalog's file names disagree with the published repo and every
        // launch re-downloads.
        _ = try await ModelFixture.files(EarModel.self)
        #expect(Ear.isDownloaded())
    }

    #if os(Linux)
    private struct ParityReference: Decodable {
        struct Candidate: Decodable {
            let language: String
            let probability: Double
        }

        let revision, backend: String
        let sampleRate, sampleCount, windows: Int
        let isReliable: Bool
        let candidates: [Candidate]

        static func load() throws -> Self {
            let url = try #require(Bundle.module.url(forResource: "ear-parity", withExtension: "json"))
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        }
    }

    private static func parityAudio(sampleCount: Int, sampleRate: Int) -> [Float] {
        var seed: UInt64 = 12_345
        return (0..<sampleCount).map { index -> Float in
            seed = (seed * 1_103_515_245 + 12_345) & 0x7fff_ffff
            let noise = (Float(seed) / Float(0x7fff_ffff) - 0.5) * 2
            let syllable = 0.5 + 0.5 * sin(2 * Double.pi * 4 * Double(index) / Double(sampleRate))
            return Float(syllable * 0.3 * Double(noise))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EAR_CAPTURE_ANDROID_PARITY"] == "1"))
    func captureAndroidParityReference() async throws {
        let sampleRate = 16_000
        let sampleCount = 40 * sampleRate
        let samples = Self.parityAudio(sampleCount: sampleCount, sampleRate: sampleRate)
        let detection = try await ear().identify(samples: samples, sampleRate: Double(sampleRate))
        #expect(detection.candidates.count >= 3)
        let reference: [String: Any] = [
            "note": "Swift LiteRT output on Linux. To recapture, run EAR_CAPTURE_ANDROID_PARITY=1 mise run test:swift ear and use the printed JSON.",
            "revision": EarModel.revision,
            "backend": "litert",
            "sampleRate": sampleRate,
            "sampleCount": sampleCount,
            "windows": detection.windows,
            "isReliable": detection.isReliable,
            "candidates": detection.candidates.prefix(3).map {
                ["language": $0.language, "probability": $0.probability] as [String: Any]
            },
        ]
        let json = try JSONSerialization.data(withJSONObject: reference, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
    #endif
}
#endif

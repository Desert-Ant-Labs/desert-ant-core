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
/// distribution back.
///
/// That seam is where every bug in this SDK has been. The catalog asked for
/// `detector.mlmodelc` after the artifact was renamed to `ear.mlmodelc`; the
/// LiteRT graph declared `serving_default_args_0` where the code passed `mel`;
/// its output is `output_0` where Core ML's is `logits`. All three were found by
/// reading files by hand. None of them would have survived this test.
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

    @Test func resolvesTheModelAndRunsIt() async throws {
        let ear = try await ear()
        let began = Date()
        let detection = try await ear.identify(samples: Self.audio(), sampleRate: 16000)
        let seconds = Date().timeIntervalSince(began)

        // A language, not a specific one.
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
}
#endif

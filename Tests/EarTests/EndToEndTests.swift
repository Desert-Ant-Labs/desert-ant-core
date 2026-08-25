import DesertAnt
import Foundation
import TestSupport
import Testing

@testable import Ear

/// The whole path: a file on disk to a language, through the shipped artifact.
///
/// Everything else in this suite tests a piece. The frontend is checked against
/// golden vectors, the artifacts against their own headers, the decision rules
/// against constructed inputs. None of that exercises loading the model,
/// binding its tensors, or running a real recording through it, and two tensor
/// names were wrong in exactly that gap - caught by reading the files, not by a
/// test.
///
/// Skipped when the model and audio are absent, because both are downloads
/// rather than fixtures. Point `EAR_MODEL_DIR` and `EAR_AUDIO_DIR` at them:
///
///     EAR_MODEL_DIR=~/work/ear/model EAR_AUDIO_DIR=~/work/e2e swift test
// Reads model files and audio from disk, which wasm has no backing for
// in this harness. The pieces it composes are covered on every platform.
#if !os(WASI)
@Suite(.serialized, .modelBacked,
       .enabled(if: !EarFixtures.recordings.isEmpty,
                "no labelled audio: set EAR_AUDIO_DIR to <language>__<name>.wav files"))
struct EndToEndTests {
    @Test func identifiesRealRecordings() async throws {
        // Staged directory if there is one, otherwise the same cached download
        // the smoke suite uses, so this runs on every platform that has audio.
        let directory: String
        if let staged = EarFixtures.modelDirectory {
            directory = staged
        } else {
            directory = try await ModelFixture.files(EarModel.self).rootPath
        }
        let ear = Ear(directory: directory)

        var correct = 0, reliable = 0, reliableAndRight = 0
        var elapsed = 0.0
        for (expected, path) in EarFixtures.recordings {
            let began = Date()
            let detection = try await ear.identify(path: path)
            elapsed += Date().timeIntervalSince(began)

            let got = detection.language ?? "-"
            if got == expected { correct += 1 }
            if detection.isReliable {
                reliable += 1
                if got == expected { reliableAndRight += 1 }
            }
            let verdict = detection.isReliable ? "reliable" : "unsure"
            print("  \(expected) -> \(got)  "
                  + String(format: "%.2f", detection.confidence)
                  + "  \(verdict)  \(detection.windows) windows")
        }
        let total = EarFixtures.recordings.count
        print("  exact \(correct)/\(total), reliable \(reliable)/\(total), "
              + "of those right \(reliableAndRight)/\(max(reliable, 1))")
        print(String(format: "  %.0f ms per file", elapsed / Double(total) * 1000))

        // The point of this test is that the path runs at all and is not
        // systematically wrong. The accuracy bound is deliberately loose: the
        // sweeps that pinned the policy are in ear-training, and duplicating
        // their thresholds here would only make this fail for the wrong reasons.
        #expect(correct >= total * 3 / 4)
        #expect(reliableAndRight == reliable, "a confident answer was wrong")
    }

    @Test func aMissingFileIsAnErrorNotACrash() async throws {
        // Staged directory if there is one, otherwise the same cached download
        // the smoke suite uses, so this runs on every platform that has audio.
        let directory: String
        if let staged = EarFixtures.modelDirectory {
            directory = staged
        } else {
            directory = try await ModelFixture.files(EarModel.self).rootPath
        }
        let ear = Ear(directory: directory)
        await #expect(throws: (any Error).self) {
            _ = try await ear.identify(path: "/nonexistent/audio.wav")
        }
    }

    @Test func reportsWhatItCanName() async throws {
        let directory: String
        if let staged = EarFixtures.modelDirectory {
            directory = staged
        } else {
            directory = try await ModelFixture.files(EarModel.self).rootPath
        }
        let languages = try await Ear(directory: directory).supportedLanguages()
        #expect(languages.count > 90)
        #expect(languages.contains("en") && languages.contains("pt"))
        // The alias has to be applied on the way out, or callers see the
        // model's code for Norwegian rather than the one they asked about.
        #expect(!languages.contains("nb"))
    }
}
#endif

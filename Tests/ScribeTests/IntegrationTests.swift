#if canImport(CoreML)
import Foundation
import Testing

@testable import Scribe

// End-to-end coverage against a real model directory. The weights are a ~490 MB
// download, so this is opt-in: point SCRIBE_MODEL_DIR at a laid-out model and
// SCRIBE_AUDIO at a file to transcribe.
//
//   SCRIBE_MODEL_DIR=... SCRIBE_AUDIO=... swift test --filter ScribeIntegration

private struct Fixture {
    let model: URL
    let audio: URL

    init?() {
        let env = ProcessInfo.processInfo.environment
        guard let model = env["SCRIBE_MODEL_DIR"], let audio = env["SCRIBE_AUDIO"] else {
            return nil
        }
        self.model = URL(fileURLWithPath: model)
        self.audio = URL(fileURLWithPath: audio)
    }
}

@Suite(.enabled(if: Fixture() != nil, "set SCRIBE_MODEL_DIR and SCRIBE_AUDIO"))
struct ScribeIntegration {

    @Test func transcribesWithWordsAndMonotonicProgress() async throws {
        let fixture = try #require(Fixture())
        let scribe = try Scribe(modelDirectory: fixture.model)

        // The callback is not isolated to this task, so collect through a lock
        // rather than assuming ordering.
        let ticks = Ticks()
        let result = try await scribe.transcribe(fixture.audio) { ticks.record($0.fractionCompleted) }

        print(String(format: "  scribe: %.1f s audio in %.2f s -> RTFx %.1f, %d words",
                     result.duration, result.processingTime, result.realtimeFactor,
                     result.words.count))
        // SCRIBE_DUMP writes the transcript out so it can be scored against a
        // reference or another system.
        if let path = ProcessInfo.processInfo.environment["SCRIBE_DUMP"] {
            try result.text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #expect(!result.text.isEmpty)
        #expect(!result.words.isEmpty)
        #expect(result.duration > 0)
        // The whole point of the port: comfortably faster than real time.
        #expect(result.realtimeFactor > 10)

        let values = ticks.values
        #expect(!values.isEmpty, "progress should be reported")
        #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(zip(values, values.dropFirst()).allSatisfy(<=), "progress must not go backwards")
        #expect(values.last == 1, "progress must finish at 1")

        // Word times are ordered and inside the audio.
        let starts = result.words.map(\.start)
        #expect(zip(starts, starts.dropFirst()).allSatisfy(<=))
        #expect(starts.allSatisfy { $0 >= 0 && $0 <= result.duration + 1 })
        // Every word appears in the transcript.
        for word in result.words.prefix(20) {
            #expect(result.text.contains(word.text.trimmingCharacters(in: .punctuationCharacters))
                    || word.text.isEmpty)
        }
    }

    @Test func rejectsEmptyAudio() async throws {
        let fixture = try #require(Fixture())
        let scribe = try Scribe(modelDirectory: fixture.model)
        await #expect(throws: ScribeError.self) {
            try await scribe.transcribe(samples: [])
        }
    }
}

/// Small lock so the progress callback can be collected from any isolation.
private final class Ticks: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func record(_ v: Double) { lock.lock(); storage.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}
#endif

import DesertAnt
import Foundation
import Testing

@testable import Who

/// Build the model from the artifact on disk, run it on synthetic audio, and check the answer's shape.
/// `.serialized`: the graphs run on one Neural Engine.
@Suite(.serialized, .enabled(if: WhoFixtures.hasSchema2, "no pieced model: set WHO_MODEL_DIR"))
struct SmokeTests {
    /// Speech-shaped noise: syllables at 4 Hz under two alternating spectral tilts.
    static func audio(seconds: Int = 100) -> [Float] {
        var samples = [Float](repeating: 0, count: 16000 * seconds)
        var generator = SystemRandomNumberGenerator()
        for n in samples.indices {
            let t = Double(n) / 16000.0
            let syllable = 0.5 + 0.5 * sin(2.0 * Double.pi * 4.0 * t)
            let tilt = (Int(t) / 5) % 2 == 0 ? 1.0 : 0.3
            samples[n] = Float(syllable * tilt * Double.random(in: -0.3...0.3, using: &generator))
        }
        return samples
    }

    @Test func runsEndToEndOnSyntheticAudio() async throws {
        let who = try WhoFixtures.who()
        let result = try await who.diarize(samples: Self.audio(), sampleRate: 16000)
        #expect(abs(result.duration - 100) < 1e-6)
        #expect(result.speakerCount >= 0 && result.speakerCount <= 64)
        #expect(result.turns.count == result.turns.filter { $0.end > $0.start && $0.start >= 0 && $0.end <= 100.1 }.count)
        #expect(result.turns.map(\.start) == result.turns.map(\.start).sorted())
        #expect(Set(result.turns.map(\.speaker)).count == result.speakerCount)
    }

    @Test func resamplesAudioAtAnotherRate() async throws {
        let who = try WhoFixtures.who()
        let result = try await who.diarize(samples: Self.audio(seconds: 40), sampleRate: 48000)
        #expect(abs(result.duration - 40.0 / 3.0) < 0.01)                                 // 40 s at 48 kHz is 13.3 s at 16 kHz
    }

    @Test func refusesEmptyAudio() async throws {
        let who = try WhoFixtures.who()
        await #expect(throws: WhoError.self) { try await who.diarize(samples: [], sampleRate: 16000) }
    }

    @Test func aRecordingLongerThanTheWindowComesBackWhole() async throws {
        let who = try WhoFixtures.who()
        let model = try await who.loadedModel()
        let seconds = Int(model.maximumSeconds) * 2 + 40
        let result = try await who.diarize(samples: Self.audio(seconds: seconds), sampleRate: 16000)
        #expect(abs(result.duration - Double(seconds)) < 1e-6)
        #expect(result.turns.allSatisfy { $0.end > $0.start && $0.start >= 0 && $0.end <= Double(seconds) + 0.1 })
        #expect(Set(result.turns.map(\.speaker)).count == result.speakerCount)
    }
}

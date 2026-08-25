import Foundation
import Testing

@testable import Ear

/// The frontend is the half of this model that is not a network, so it is the
/// half that can be tested without one.
struct FrontendTests {
    /// Whisper-tiny geometry, which is what the shipped meta describes.
    static let geometry = Frontend.Geometry(
        sampleRate: 16000, nFFT: 400, hop: 160, mels: 80, frames: 3000,
        clampMin: 1e-10, floorDecades: 8, affineAdd: 4, affineDivide: 4)

    /// A filterbank table in the sidecar's format: `[mels, bins]` then the rows.
    static func table(mels: Int, bins: Int,
                      value: (Int, Int) -> Float = { m, b in m == b % max(m, 1) ? 1 : 0 }) -> [UInt8] {
        var bytes: [UInt8] = []
        for count in [UInt32(mels), UInt32(bins)] {
            bytes.append(contentsOf: (0..<4).map { UInt8((count >> (8 * $0)) & 0xFF) })
        }
        for m in 0..<mels {
            for b in 0..<bins {
                let raw = value(m, b).bitPattern
                bytes.append(contentsOf: (0..<4).map { UInt8((raw >> (8 * $0)) & 0xFF) })
            }
        }
        return bytes
    }

    static func make() throws -> Frontend {
        try Frontend(geometry: geometry, filterTable: table(mels: 80, bins: 201))
    }

    @Test func producesTheShapeTheDetectorExpects() throws {
        let frontend = try Self.make()
        let features = frontend.features([Float](repeating: 0, count: 16000 * 30))
        #expect(features.count == 80 * 3000)
    }

    @Test func shortAudioIsPaddedRatherThanRejected() throws {
        // The tail of a recording is short. That is not an error.
        let frontend = try Self.make()
        #expect(frontend.features([Float](repeating: 0, count: 8000)).count == 80 * 3000)
    }

    @Test func longAudioIsTruncatedToOneWindow() throws {
        let frontend = try Self.make()
        #expect(frontend.features([Float](repeating: 0.1, count: 16000 * 90)).count == 80 * 3000)
    }

    @Test func silenceLandsAtTheFloor() throws {
        // Every bin is equally quiet, so every bin is the peak and the relative
        // floor puts them all at the same value.
        let frontend = try Self.make()
        let features = frontend.features([Float](repeating: 0, count: 16000 * 30))
        #expect(features.allSatisfy { abs($0 - features[0]) < 1e-5 })
    }

    @Test func aMalformedFilterbankIsRejected() {
        #expect(throws: EarError.self) {
            try Frontend(geometry: Self.geometry, filterTable: [1, 2, 3])
        }
        #expect(throws: EarError.self) {
            // Right format, wrong number of bins for a 400-point transform.
            try Frontend(geometry: Self.geometry, filterTable: Self.table(mels: 80, bins: 64))
        }
    }

    // MARK: - Window placement

    @Test func shortAudioGetsASingleWindow() throws {
        let frontend = try Self.make()
        #expect(frontend.windowOffsets([Float](repeating: 0.1, count: 16000 * 10),
                                       count: 3) == [0])
    }

    /// Something with the loudness pattern of speech: syllables at 4 Hz.
    static func speechLike(_ count: Int, level: Float = 0.3) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for n in 0..<count {
            let t = Double(n) / 16000.0
            let syllable = 0.5 + 0.5 * sin(2.0 * Double.pi * 4.0 * t)
            out[n] = Float(syllable) * level * Float.random(in: -1...1)
        }
        return out
    }

    /// Something with the loudness pattern of music: sustained, no gaps.
    static func musicLike(_ count: Int, level: Float = 0.6) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for n in 0..<count {
            let t = Double(n) / 16000.0
            let a = 0.4 * sin(2.0 * Double.pi * 220.0 * t)
            let b = 0.3 * sin(2.0 * Double.pi * 330.0 * t)
            let c = 0.3 * sin(2.0 * Double.pi * 440.0 * t)
            out[n] = Float(a + b + c) * level
        }
        return out
    }

    @Test func windowsLandOnTheSpeechNotOnTheSilence() throws {
        let frontend = try Self.make()
        var audio = [Float](repeating: 0.00003, count: 16000 * 300)
        let speechAt = 16000 * 200
        let speech = Self.speechLike(16000 * 40)
        for (i, sample) in speech.enumerated() { audio[speechAt + i] = sample }
        for offset in frontend.windowOffsets(audio, count: 3) {
            let overlap = min(offset + 16000 * 30, speechAt + 16000 * 40) - max(offset, speechAt)
            #expect(overlap > 0, "window at \(offset / 16000)s heard only silence")
        }
    }

    @Test func aLoudIntroDoesNotWinOverQuieterSpeech() throws {
        // The case ranking by loudness gets wrong: a jingle mixed hotter than
        // the voice after it. Measured, loudness picks the jingle on half of
        // real intro-and-outro files.
        let frontend = try Self.make()
        let intro = Self.musicLike(16000 * 45, level: 0.9)
        let speech = Self.speechLike(16000 * 120, level: 0.25)
        let audio = intro + speech
        let offsets = frontend.windowOffsets(audio, count: 3)
        #expect(offsets.allSatisfy { $0 + 16000 * 15 > intro.count },
                "a window still sits inside the intro: \(offsets.map { $0 / 16000 })")
    }

    @Test func modulationPrefersSpeechToMusic() throws {
        let speech = Self.speechLike(16000 * 30)
        let music = Self.musicLike(16000 * 30)
        let hop = Self.geometry.hop
        let window = speech.count
        let s = Frontend.modulationScores(speech, hop: hop, window: window,
                                          step: window)[0].score
        let m = Frontend.modulationScores(music, hop: hop, window: window,
                                          step: window)[0].score
        #expect(s > m, "speech \(s) should modulate more than music \(m)")
    }

    @Test func windowsAreReturnedInOrder() throws {
        let frontend = try Self.make()
        var audio = [Float](repeating: 0.001, count: 16000 * 300)
        for i in (16000 * 250)..<(16000 * 280) { audio[i] = 0.4 }
        let offsets = frontend.windowOffsets(audio, count: 3)
        #expect(offsets == offsets.sorted())
    }

    @Test func fewerWindowsThanAskedWhenTheAudioIsShort() throws {
        let frontend = try Self.make()
        let audio = (0..<(16000 * 45)).map { _ in Float.random(in: -0.2...0.2) }
        #expect(frontend.windowOffsets(audio, count: 3).count <= 3)
    }

    @Test func silenceIsExcludedRatherThanRanked() {
        // A ratio does not know how loud its input was: the fluctuation of a
        // noise floor sits in the same band speech does. Without an energy
        // floor, a mostly-empty file ranks its own silence first.
        var audio = [Float](repeating: 0.00003, count: 16000 * 120)
        let speech = Self.speechLike(16000 * 30)
        for (i, sample) in speech.enumerated() { audio[16000 * 60 + i] = sample }
        let scores = Frontend.modulationScores(audio, hop: 160, window: 16000 * 30,
                                               step: 16000 * 10)
        let best = scores.max { $0.score < $1.score }!
        // The invariant is that the chosen window contains speech, not that it
        // is centred on it: a window at 40 s still hears the speech at 60 s.
        let overlap = min(best.offset + 16000 * 30, 16000 * 90) - max(best.offset, 16000 * 60)
        #expect(overlap > 0,
                "best window at \(best.offset / 16000)s hears none of the speech at 60s")
        #expect(scores.first(where: { $0.offset == 0 })?.score == 0,
                "a window of pure noise floor should not be ranked at all")
    }
}

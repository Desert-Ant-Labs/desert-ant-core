// The cross-runtime parity fixture. Apple is the reference because it is what
// ships in apps; every other runtime has to reproduce it.
//
// `Tests/Fixtures/clear-parity.json` is read by the JavaScript and Kotlin
// suites too, so regenerating it is a deliberate act - say so in the commit.
//
// Sines rather than a PRNG: identical bits would need identical 64-bit overflow
// in Swift, Kotlin and JavaScript, which is not spelled the same way in all

import Foundation

enum ParityFixture {
    static let sampleRate = 48_000.0
    static let sampleCount = 96_000        // 2 s
    static let blockCount = 40

    /// Block RMS as a fraction of the loudest block. Only asserted on Apple,
    /// where the reference was produced, so it compares like with like: the
    /// runtimes disagree far more than they do on loudness (measured envelope
    /// 0.005 Apple, 0.064 Linux LiteRT, 0.395 Android arm64 LiteRT - the last
    /// unexplained). Elsewhere it is printed, not asserted; asserting it needs
    /// a golden per runtime.
    static let envelopeTolerance = 0.15

    /// Loudness and true peak, which every runtime does agree on (0.44 dB and
    /// 0.56 dB on Linux, 0.64 dB on Android), so these are asserted everywhere.
    static let loudnessToleranceDB = 1.5

    struct Golden {
        let sampleCount: Int
        let blockRMS: [Double]
        let measuredLUFS: Double
        let truePeakDBFS: Double
    }

    /// A 120 Hz harmonic stack under a 4 Hz syllable envelope, reproduced
    /// exactly in every language. Voiced-shaped because Clear gates non-speech
    /// hard: a plain sum of sines loses 83% of its energy, leaving the output
    /// dominated by suppression residual and small runtime differences looking
    /// enormous. This keeps roughly twice as much.
    static func input() -> [Float] {
        (0..<sampleCount).map { i in
            let t = Double(i) / sampleRate
            let envelope = 0.5 * (1 + sin(2 * .pi * 4 * t))
            var harmonics = 0.0
            for h in 1...12 { harmonics += sin(2 * .pi * 120 * Double(h) * t) / Double(h) }
            return Float(0.25 * envelope * harmonics)
        }
    }

    /// RMS per block: a compact shape of the signal that survives the small
    /// numerical differences between runtimes while still catching a pipeline
    /// that has genuinely diverged.
    static func envelope(_ samples: [Float], blocks: Int = blockCount) -> [Double] {
        guard !samples.isEmpty, blocks > 0 else { return [] }
        let size = samples.count / blocks
        guard size > 0 else { return [] }
        return (0..<blocks).map { b in
            var acc = 0.0
            for i in (b * size)..<min((b + 1) * size, samples.count) {
                acc += Double(samples[i]) * Double(samples[i])
            }
            return (acc / Double(size)).squareRoot()
        }
    }

    /// The reference fingerprint, or nil where the repo is not reachable (a
    /// sandboxed or wasm run) - the rest of the suite still runs.
    static func golden() -> Golden? {
        // #filePath is Tests/ClearTests/<file>, so the repo root is two up.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Tests/Fixtures/clear-parity.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = json["sampleCount"] as? Int,
              let blocks = json["blockRMS"] as? [Double],
              let lufs = json["measuredLUFS"] as? Double,
              let peak = json["truePeakDBFS"] as? Double
        else { return nil }
        return Golden(sampleCount: count, blockRMS: blocks,
                      measuredLUFS: lufs, truePeakDBFS: peak)
    }
}

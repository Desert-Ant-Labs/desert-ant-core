import DesertAnt
import Foundation

@testable import Who

/// The local model directory the gated suites run against, one subdirectory per precision:
///
///     WHO_MODEL_DIR=~/work/who/model swift test --filter WhoTests
enum WhoFixtures {
    static var modelDirectory: String? {
        let path = ProcessInfo.processInfo.environment["WHO_MODEL_DIR"] ?? NSHomeDirectory() + "/work/who/model"
        let expanded = NSString(string: path).expandingTildeInPath
        let artifact = WhoModel.artifact(for: .current)
        return FileManager.default.fileExists(atPath: expanded + "/" + artifact) ? expanded : nil
    }

    static func sidecar(_ name: String, variant: ModelVariant = .default) -> Data? {
        guard let directory = modelDirectory else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: directory + "/\(variant.directory(for: .current))/" + name))
    }

    /// `WHO_FIXTURES_DIR`: the speech golden and its WAV, which live outside the repo.
    static var speechFixtures: String? {
        guard let path = ProcessInfo.processInfo.environment["WHO_FIXTURES_DIR"] else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expanded + "/who_speech_golden.json") ? expanded : nil
    }

    /// `WHO_FIXTURES_DIR` again: the join golden and its longer WAV.
    static var joinFixtures: String? {
        guard let path = ProcessInfo.processInfo.environment["WHO_FIXTURES_DIR"] else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expanded + "/who_join_golden.json") ? expanded : nil
    }

    static var hasModel: Bool { modelDirectory != nil }

    /// Whether the model on disk is this architecture's artifact: the pieced graphs, metadata schema 2.
    static var hasSchema2: Bool {
        guard let data = sidecar(WhoModel.meta),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["schema"] as? Int == 2
    }
    static var downloadEnabled: Bool { ProcessInfo.processInfo.environment["WHO_TEST_DOWNLOAD"] == "1" }

    static func who(variant: ModelVariant = .default) throws -> Who {
        guard let directory = modelDirectory else { throw WhoError.modelNotFound }
        return Who(directory: directory, variant: variant)
    }
}


/// The formula signals the goldens were made from, in double precision, rounded to Float at the end.
enum Signals {
    /// Three steady sines.
    static func tones(seconds: Double = 30, sampleRate: Int = 16000) -> [Float] {
        (0..<Int(seconds * Double(sampleRate))).map { (n: Int) -> Float in
            let t = Double(n) / Double(sampleRate)
            let low: Double = 0.5 * sin(2 * Double.pi * 440.0 * t)
            let high: Double = 0.25 * sin(2 * Double.pi * 1234.5 * t)
            let hum: Double = 0.05 * sin(2 * Double.pi * 97.0 * t)
            return Float(low + high + hum)
        }
    }

    /// Two harmonic voices taking three-second turns with half a second between, period 7 s, under a 4 Hz envelope.
    static func turns(seconds: Double = 100, sampleRate: Int = 16000) -> [Float] {
        let voices: [(Double, [Double])] = [(120.0, [0.5, 0.25, 0.125, 0.06]), (210.0, [0.5, 0.25, 0.125, 0.06])]
        let slots: [(Double, Double)] = [(0.0, 3.0), (3.5, 6.5)]
        return (0..<Int(seconds * Double(sampleRate))).map { (n: Int) -> Float in
            let t = Double(n) / Double(sampleRate)
            let phase = t.truncatingRemainder(dividingBy: 7.0)
            let envelope: Double = 0.5 + 0.5 * sin(2 * Double.pi * 4.0 * t)
            var x: Double = 0
            for (voice, slot) in zip(voices, slots) where phase >= slot.0 && phase < slot.1 {
                var tone: Double = 0
                for (k, a) in voice.1.enumerated() {
                    let frequency: Double = voice.0 * Double(k + 1)
                    tone += a * sin(2 * Double.pi * frequency * t)
                }
                x += envelope * tone
            }
            return Float(x)
        }
    }
}

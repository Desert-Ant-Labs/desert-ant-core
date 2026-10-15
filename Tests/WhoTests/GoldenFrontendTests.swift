import Foundation
import Testing

@testable import Who

/// The filterbank against the reference implementation on a formula signal, with the shipped bank table.
@Suite(.enabled(if: WhoFixtures.hasModel, "no who_mel_banks.f32: set WHO_MODEL_DIR"))
struct GoldenFrontendTests {
    struct Golden: Decodable {
        struct Spot: Decodable { let mel: Int; let frame: Int; let value: Float }
        let mels: Int
        let frames: Int
        let rowMeans: [Float]
        let spots: [Spot]
        let min: Float
        let max: Float
    }

    static func golden() throws -> Golden {
        let url = try #require(Bundle.module.url(forResource: "who_frontend_golden", withExtension: "json"))
        return try JSONDecoder().decode(Golden.self, from: try Data(contentsOf: url))
    }

    /// The shipped bank table, with the mel count the golden was written at.
    static func frontend(mels: Int) throws -> Frontend {
        let table = try #require(WhoFixtures.sidecar(WhoModel.melBanks))
        var geometry = FrontendTests.geometry
        geometry = Frontend.Geometry(
            sampleRate: geometry.sampleRate, frame: geometry.frame, shift: geometry.shift, nFFT: geometry.nFFT,
            mels: mels, preemphasis: geometry.preemphasis, scale: geometry.scale, logFloor: geometry.logFloor)
        return try Frontend(geometry: geometry, banksTable: [UInt8](table))
    }

    @Test func matchesThePythonFilterbankOnTheFormulaSignal() throws {
        let golden = try Self.golden()
        let mels = golden.mels
        let frontend = try Self.frontend(mels: mels)
        let (values, frames) = frontend.features(Signals.tones())
        #expect(frames == golden.frames)

        var worstMean: Float = 0
        for m in 0..<mels {
            var sum: Float = 0
            for f in 0..<frames { sum += values[f * mels + m] }
            worstMean = max(worstMean, abs(sum / Float(frames) - golden.rowMeans[m]))
        }
        #expect(worstMean < 2e-4, "row means differ by up to \(worstMean)")

        var worstSpot: Float = 0
        for spot in golden.spots {
            worstSpot = max(worstSpot, abs(values[spot.frame * mels + spot.mel] - spot.value))
        }
        #expect(worstSpot < 1e-3, "spots differ by up to \(worstSpot)")

        #expect(abs(values.min()! - golden.min) < 1e-3)
        #expect(abs(values.max()! - golden.max) < 1e-3)
    }
}

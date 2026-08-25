import Foundation
import Testing

@testable import Ear

/// The Swift frontend against the Python one the detector was exported with.
///
/// This is the test that matters. If the two disagree the detector is fed
/// features it has never seen, and nothing reports an error: the logits stay
/// plausible, the language is wrong, and every other test still passes. Shapes
/// and window placement can be checked with a synthetic filterbank; only this
/// can check the numbers.
///
/// The signal is generated from a formula rather than shipped as audio so both
/// sides produce it exactly.
@Suite(.enabled(if: EarFixtures.hasFilterbank,
                "no mel_filters.f32: set EAR_MODEL_DIR"))
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

    static func signal() -> [Float] {
        let count = 3000 * 160
        return (0..<count).map { n in
            let t = Double(n) / 16000.0
            let value = 0.5 * sin(2 * .pi * 440 * t)
                + 0.25 * sin(2 * .pi * 1234.5 * t)
                + 0.05 * sin(2 * .pi * 97 * t)
            return Float(value)
        }
    }

    static func golden() throws -> Golden {
        let url = Bundle.module.url(forResource: "ear_frontend_golden", withExtension: "json")
        let data = try Data(contentsOf: try #require(url))
        return try JSONDecoder().decode(Golden.self, from: data)
    }

    /// The real filterbank, read from the same sidecar the SDK ships.
    static func frontend(mels: Int) throws -> Frontend? {
        guard let table = EarFixtures.filterbank else { return nil }
        return try Frontend(
            geometry: Frontend.Geometry(
                sampleRate: 16000, nFFT: 400, hop: 160, mels: mels, frames: 3000,
                clampMin: 1e-10, floorDecades: 8, affineAdd: 4, affineDivide: 4),
            filterTable: table)
    }

    // The golden vectors are a SwiftPM resource, and `Bundle.module` has no WASI
    // backing, so this comparison is off-wasm. The frontend's shape, window
    // placement and floor are checked on every platform in FrontendTests; this
    // is the one test that needs a file.
#if !os(WASI)
    @Test func matchesTheReferenceFrontend() throws {
        let golden = try Self.golden()
        let frontend = try #require(try Self.frontend(mels: golden.mels))
        let features = frontend.features(Self.signal())
        #expect(features.count == golden.mels * golden.frames)

        // Spot values catch ordering, scaling and the floor. Row means catch a
        // drift too small to show in five samples.
        for spot in golden.spots {
            let got = features[spot.mel * golden.frames + spot.frame]
            #expect(abs(got - spot.value) < 2e-3,
                    "mel \(spot.mel) frame \(spot.frame): \(got) vs \(spot.value)")
        }
        for mel in 0..<golden.mels {
            let row = features[(mel * golden.frames)..<((mel + 1) * golden.frames)]
            let mean = row.reduce(0, +) / Float(golden.frames)
            #expect(abs(mean - golden.rowMeans[mel]) < 2e-3, "row \(mel) mean")
        }
        #expect(abs((features.min() ?? 0) - golden.min) < 2e-3)
        #expect(abs((features.max() ?? 0) - golden.max) < 2e-3)
    }
#endif
}

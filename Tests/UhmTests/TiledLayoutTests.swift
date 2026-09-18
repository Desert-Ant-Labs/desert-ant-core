// The detector reads its input layout off the artifact, so these pin the two
// things that would silently produce garbage if they drifted: which layout is
// inferred from a declared input width, and whether a tile lands on the samples
// the whole-window model would have seen at the same frames.
import Testing
import DesertAnt
@testable import Uhm

/// A session that only answers shape questions: layout selection happens at
/// init, before anything runs.
private struct ShapeOnlySession: InferenceSession {
    let width: Int?
    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor] {
        []
    }
    func inputWidth(_ name: String) -> Int? { width }
}

struct TiledLayoutTests {

    private func detector(width: Int?) -> FillerDetector {
        FillerDetector(session: ShapeOnlySession(width: width))
    }

    @Test func fullWindowArtifactStaysOnTheWindowPath() {
        #expect(detector(width: 480_000).layout == .window)
        // A runtime that cannot report shapes must not be guessed at.
        #expect(detector(width: nil).layout == .window)
    }

    @Test func tiledArtifactDerivesItsGeometry() {
        // 16080 = 50 frames x 320 samples + the 80-sample halo.
        guard case let .tiles(count, samples, stride) = detector(width: 16_080).layout else {
            Issue.record("expected a tiled layout")
            return
        }
        #expect(samples == 16_080)
        #expect(stride == 16_000)
        #expect(count == 30)                       // 30 x 50 frames covers 1499
    }

    @Test func tilesCoverTheWindowWithTheRightOverlap() {
        let config = FillerDetector.Config.default
        let maxSamples = Int(config.maxWindowSec * config.sampleRate)
        // A ramp makes every sample identify its own index.
        let window = (0..<maxSamples).map { Float($0) }
        let layout = detector(width: 16_080).layout
        let tensor = FillerDetector.tensor(for: window, layout: layout, maxSamples: maxSamples)

        #expect(tensor.shape == [30, 1, 1, 16_080])
        let values = tensor.float32Values!

        // Tile k starts one stride later, and its halo repeats the next tile's
        // opening samples - which is what makes the tiled frames identical to
        // the whole-window ones rather than merely similar.
        for tile in [0, 1, 17, 29] {
            let base = tile * 16_080
            #expect(values[base] == Float(tile * 16_000))
            if tile < 29 {
                #expect(values[base + 16_000] == values[(tile + 1) * 16_080])
            }
        }
        // The last tile reads past the window, and that tail is zero-padded.
        let lastTileStart = 29 * 16_000
        let overrun = lastTileStart + 16_080 - maxSamples
        #expect(overrun == 80)
        #expect(values[29 * 16_080 + 16_080 - 1] == 0)
    }

    @Test func fillerProbabilityReadsBothOutputLayouts() {
        // (1, T, C) with C = 6: class 0 is not-filler.
        let planar = Tensor(float32: [0.9, 0.1, 0, 0, 0, 0,
                                      0.2, 0.8, 0, 0, 0, 0], shape: [1, 2, 6])
        // (1, C, 1, T): class 0 occupies the first T values.
        let bc1s = Tensor(float32: [0.9, 0.2,
                                    0.1, 0.8,
                                    0, 0, 0, 0, 0, 0, 0, 0], shape: [1, 6, 1, 2])
        let fromPlanar = FillerDetector.fillerProbs(planar)
        let fromBC1S = FillerDetector.fillerProbs(bc1s)
        #expect(fromPlanar.count == 2)
        #expect(fromBC1S.count == 2)
        for (a, b) in zip(fromPlanar, fromBC1S) {
            #expect(abs(a - b) < 1e-6)
        }
        #expect(abs(fromPlanar[0] - 0.1) < 1e-6)
        #expect(abs(fromPlanar[1] - 0.8) < 1e-6)
    }
}

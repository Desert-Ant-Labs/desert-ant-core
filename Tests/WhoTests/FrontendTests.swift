import Foundation
import Testing

@testable import Who

struct FrontendTests {
    /// Kaldi's 25 ms frames every 10 ms at 16 kHz, 80 mels over a 512-point spectrum.
    static let geometry = Frontend.Geometry(
        sampleRate: 16000, frame: 400, shift: 160, nFFT: 512, mels: 80, preemphasis: 0.97, scale: 32768, logFloor: 1.1920929e-07)

    /// A bank table in the sidecar's format: `[mels, bins]` then the rows.
    static func table(mels: Int, bins: Int, value: (Int, Int) -> Float = { m, b in b == m * 3 + 1 ? 1 : 0 }) -> [UInt8] {
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
        try Frontend(geometry: geometry, banksTable: table(mels: 80, bins: 257))
    }

    @Test func countsOnlyTheFramesThatFitCompletely() throws {
        let frontend = try Self.make()
        #expect(frontend.frames(for: 399) == 0)
        #expect(frontend.frames(for: 400) == 1)
        #expect(frontend.frames(for: 16000) == 98)                                       // 1 + (16000 - 400) / 160
        #expect(frontend.frames(for: 480_000) == 2998)
    }

    @Test func producesOneRowPerFrameAndCentresEveryMel() throws {
        let frontend = try Self.make()
        let (values, frames) = frontend.features(Signals.tones(seconds: 2))
        #expect(frames == 198 && values.count == 198 * 80)
        for m in 0..<80 {
            var sum: Float = 0
            for f in 0..<frames { sum += values[f * 80 + m] }
            #expect(abs(sum / Float(frames)) < 1e-4, "mel \(m) is not centred")
        }
    }

    @Test func silenceGivesTheFloorBeforeCentring() throws {
        let frontend = try Self.make()
        let (values, frames) = frontend.features([Float](repeating: 0, count: 16000))
        #expect(frames == 98)
        let quiet = values.allSatisfy { abs($0) < 1e-6 }
        #expect(quiet)
    }

    @Test func sharedSpectrumMeansAreEachFrontendsOwnToTheBit() async throws {
        let wide = try Self.make()
        let narrow = try Frontend(geometry: Frontend.Geometry(sampleRate: 16000, frame: 400, shift: 160, nFFT: 512, mels: 23, preemphasis: 0.97,
                                                              scale: 32768, logFloor: 1.1920929e-07),
                                  banksTable: Self.table(mels: 23, bins: 257) { m, b in b >= m * 10 && b < m * 10 + 12 ? 0.5 : 0 })
        #expect(wide.sharesSpectrum(with: narrow))
        let samples = Signals.turns(seconds: 130)                                        // 12,998 frames: three chunks, the last short
        let (both, frames) = await Frontend.means([wide, narrow], samples: samples)
        #expect(frames == wide.frames(for: samples.count))
        for (shared, frontend) in zip(both, [wide, narrow]) {
            #expect(shared.map(\.bitPattern) == frontend.means(samples).means.map(\.bitPattern))
        }
        let serial = await Frontend.means([wide], samples: samples, workers: 1).means[0]
        #expect(serial.map(\.bitPattern) == both[0].map(\.bitPattern))
    }

    @Test func refusesABankTableOfTheWrongShape() {
        #expect(throws: WhoError.self) {
            try Frontend(geometry: Self.geometry, banksTable: Self.table(mels: 40, bins: 257))
        }
        #expect(throws: WhoError.self) {
            try Frontend(geometry: Self.geometry, banksTable: Self.table(mels: 80, bins: 201))
        }
    }

    @Test func parsesTheTableHeaderAndRows() throws {
        let (banks, mels, bins) = try Frontend.parseBanks(Self.table(mels: 3, bins: 5) { m, b in Float(m * 10 + b) })
        #expect(mels == 3 && bins == 5)
        let expected = (0..<15).map { (i: Int) -> Float in Float((i / 5) * 10 + i % 5) }
        #expect(banks == expected)
    }
}

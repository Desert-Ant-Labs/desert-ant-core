import XCTest
import Foundation
@testable import AudioDSP

final class AudioDSPTests: XCTestCase {
    // Signal-to-error ratio in dB between a reference and a reconstruction.
    private func snr(_ ref: [Float], _ rec: [Float]) -> Double {
        let n = min(ref.count, rec.count)
        var sig = 0.0, err = 0.0
        for i in 0..<n {
            sig += Double(ref[i]) * Double(ref[i])
            let e = Double(ref[i]) - Double(rec[i])
            err += e * e
        }
        return err > 0 ? 10 * log10(sig / err) : .infinity
    }

    private func tone(_ n: Int, freq: Double = 440, sr: Double = 16000) -> [Float] {
        (0..<n).map { Float(0.5 * sin(2 * .pi * freq * Double($0) / sr)) }
    }

    func testHannPeriodic() {
        let w = Window.hann(4, periodic: true)
        XCTAssertEqual(w[0], 0, accuracy: 1e-6)          // periodic Hann starts at 0
        XCTAssertEqual(w.max()!, 1, accuracy: 1e-6)      // and reaches 1
    }

    func testSTFTRoundTripReconstructsSignal() {
        let x = tone(8000)
        let stft = STFT(nFFT: 400, hop: 100)
        let spec = stft.forward(x)
        let y = stft.inverse(spec, length: x.count)
        XCTAssertEqual(y.count, x.count)
        // Windowed COLA + real-DFT identity should reconstruct near-perfectly.
        XCTAssertGreaterThan(snr(x, y), 60)
    }

    func testSTFTMagnitudePhaseRebuild() {
        let x = tone(4000, freq: 220)
        let stft = STFT(nFFT: 256, hop: 64)
        let spec = stft.forward(x)
        let mag = spec.magnitude(), pha = spec.phase()
        // Rebuild re/im from magnitude+phase and confirm the same reconstruction.
        var rebuilt = spec
        for i in 0..<mag.count {
            rebuilt.re[i] = mag[i] * cos(pha[i])
            rebuilt.im[i] = mag[i] * sin(pha[i])
        }
        let y = stft.inverse(rebuilt, length: x.count)
        XCTAssertGreaterThan(snr(x, y), 60)
    }

    func testEnergyNormalizeIsInvertible() {
        let x = tone(2000).map { $0 * 3 }
        let (norm, gain) = VectorOps.energyNormalize(x)
        let restored = VectorOps.scaled(norm, by: 1 / gain)
        XCTAssertGreaterThan(snr(x, restored), 100)   // float round-trip, not bit-exact
        // Unit average power after normalization.
        let power = VectorOps.energy(norm) / Float(norm.count)
        XCTAssertEqual(power, 1, accuracy: 1e-3)
    }

    func testStandardizeZeroMeanUnitStd() {
        let x: [Float] = (0..<1000).map { Float($0) }
        let z = VectorOps.standardize(x)
        let mean = z.reduce(0, +) / Float(z.count)
        XCTAssertEqual(mean, 0, accuracy: 1e-3)
    }

    func testMelSpectrogramShape() {
        let mel = MelSpectrogram(sampleRate: 16000, nFFT: 400, hop: 160, mels: 80)
        let (values, frames, mels) = mel.logMel(tone(16000))
        XCTAssertEqual(mels, 80)
        XCTAssertGreaterThan(frames, 90)              // ~1 s at hop 160
        XCTAssertEqual(values.count, frames * mels)
        XCTAssertTrue(values.allSatisfy { $0.isFinite })
    }

    func testFramingWindows() {
        let w = Framing.windows(count: 250, window: 100, hop: 80)
        XCTAssertEqual(w.first!.start, 0)
        XCTAssertEqual(w.last!.end, 250)              // final window clamps to count
        XCTAssertTrue(w.allSatisfy { $0.end <= 250 })
    }

    func testLoudnessNormalizeHitsTarget() {
        // 1 kHz tone at 48 kHz, ~3 s; normalize to -19 LUFS.
        let sr = 48_000.0
        let x = (0..<Int(3 * sr)).map { Float(0.1 * sin(2 * .pi * 1000 * Double($0) / sr)) }
        let before = Loudness.integratedLUFS(x, sampleRate: sr)
        XCTAssertNotNil(before)
        let (y, measured) = Loudness.normalize(x, sampleRate: sr, targetLUFS: -19, maxGainDB: 30, peakCeilingDBFS: -1)
        XCTAssertEqual(measured, before)
        let after = Loudness.integratedLUFS(y, sampleRate: sr)!
        XCTAssertEqual(after, -19, accuracy: 0.5)          // lands on target
        XCTAssertTrue(y.allSatisfy { abs($0) <= 1 })       // never clips
    }

    func testLoudnessSilenceIsNil() {
        XCTAssertNil(Loudness.integratedLUFS([Float](repeating: 0, count: 48_000), sampleRate: 48_000))
    }

    func testOverlapAccumulatorAverages() {
        var acc = OverlapAccumulator(length: 4)
        acc.add([1, 1], at: 0)
        acc.add([3, 3], at: 1)   // index 1 and 2 now overlap
        let avg = acc.average()
        XCTAssertEqual(avg, [1, 2, 3, 0])
    }
}

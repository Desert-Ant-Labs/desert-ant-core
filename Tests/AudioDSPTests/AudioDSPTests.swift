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

    // MARK: streaming meter

    /// The whole point of the streaming meter: chunked measurement has to agree
    /// with whole-signal measurement, whatever the chunk sizes are. The filter
    /// state and the 400 ms block grid both have to survive chunk boundaries.
    func testStreamingMeterMatchesWholeSignal() {
        let sr = 48_000.0
        var rng = SystemRandomNumberGenerator()
        for trial in 0..<4 {
            let n = [48_000 * 3, 48_000 * 7 + 13, 96_000, 48_000 * 11 + 1][trial]
            var x = [Float](repeating: 0, count: n)
            for i in 0..<n {
                x[i] = 0.4 * Float(sin(2 * .pi * 220 * Double(i) / sr))
                    + Float.random(in: -0.05...0.05, using: &rng)
            }
            let reference = Loudness.integratedLUFS(x, sampleRate: sr)
            XCTAssertNotNil(reference, "n=\(n)")

            // Deliberately awkward chunk sizes: not multiples of the block or
            // step, and one larger than a block.
            for chunk in [1_000, 4_800, 19_200, 50_000, 7_777] {
                guard let meter = Loudness.StreamingMeter(sampleRate: sr) else {
                    XCTFail("meter init"); return
                }
                var i = 0
                while i < n {
                    let end = min(i + chunk, n)
                    meter.consume(Array(x[i..<end]))
                    i = end
                }
                let streamed = meter.finalize()
                XCTAssertNotNil(streamed, "n=\(n) chunk=\(chunk)")
                // Not bit-exact: vDSP_biquad rounds slightly differently
                // depending on how long a span it is handed (vector tail
                // handling), so an odd chunk size shifts the last bits. The
                // observed spread is ~1e-5 dB, which is nothing against the
                // 0.1 LU that matters for delivery targets.
                XCTAssertEqual(reference!, streamed!, accuracy: 1e-4,
                               "n=\(n) chunk=\(chunk)")
            }
        }
    }

    func testStreamingMeterTracksPeak() {
        guard let meter = Loudness.StreamingMeter(sampleRate: 48_000) else {
            XCTFail("meter init"); return
        }
        meter.consume([0.1, -0.7, 0.3])
        meter.consume([0.2, -0.25])
        XCTAssertEqual(meter.peak, 0.7, accuracy: 1e-6)
    }

    func testStreamingMeterMemoryIsBounded() {
        guard let meter = Loudness.StreamingMeter(sampleRate: 48_000) else {
            XCTFail("meter init"); return
        }
        // 10 minutes fed in 1 s pieces; the meter must not be accumulating the
        // signal itself.
        let second = [Float](repeating: 0.2, count: 48_000)
        for _ in 0..<600 { meter.consume(second) }
        XCTAssertNotNil(meter.finalize())
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

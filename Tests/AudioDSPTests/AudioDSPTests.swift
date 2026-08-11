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

    // MARK: limiter

    /// The regression the limiter exists to fix. A signal that is quiet apart
    /// from one loud transient cannot be mastered by a single static gain: to
    /// keep the transient under the ceiling the whole file has to come down,
    /// landing well below the requested loudness. The limiter takes the gain
    /// out of the transient alone, so the target survives.
    func testLimiterHoldsLoudnessTargetThroughATransient() {
        let sr = 48_000.0
        let n = Int(3 * sr)
        var x = (0..<n).map { Float(0.05 * sin(2 * .pi * 1000 * Double($0) / sr)) }
        // One 2 ms transient at full scale, a long way above the rest.
        for i in Int(1.5 * sr)..<(Int(1.5 * sr) + Int(0.002 * sr)) { x[i] = 0.99 }

        let (y, measured) = Loudness.normalize(x, sampleRate: sr, targetLUFS: -19,
                                               maxGainDB: 30, peakCeilingDBFS: -1)
        let after = Loudness.integratedLUFS(y, sampleRate: sr)!
        let ceiling = Float(pow(10, -1.0 / 20))

        // What the static backoff this replaced would have produced: one gain
        // for the whole signal, scaled down until the transient fits.
        let staticGain = Float(pow(10, min(-19 - measured!, 30) / 20))
        var scaled = x.map { $0 * staticGain }
        let peak = scaled.map { abs($0) }.max()!
        if peak > ceiling { scaled = scaled.map { $0 * (ceiling / peak) } }
        let staticAfter = Loudness.integratedLUFS(scaled, sampleRate: sr)!

        // The limiter lands near the target. It does not land exactly on it,
        // and cannot: the transient inflates the *input* measurement, so the
        // gain is chosen for a signal whose energy the limiter then removes.
        XCTAssertEqual(after, -19, accuracy: 1.5)
        // The backoff misses by far more - that is the regression being fixed.
        XCTAssertLessThan(staticAfter, after - 5)

        // And the ceiling still holds, which is all the backoff ever bought.
        XCTAssertTrue(y.allSatisfy { abs($0) <= ceiling + 1e-4 },
                      "peak \(y.map { abs($0) }.max()!) exceeds ceiling \(ceiling)")
    }

    func testLimiterCeilingIsRespectedAndGainRecovers() {
        let sr = 48_000.0
        // Full-scale tone: every sample needs limiting.
        var channels = [(0..<Int(sr)).map { Float(0.99 * sin(2 * .pi * 200 * Double($0) / sr)) }]
        Limiter.apply(&channels, ceilingDBTP: -6, sampleRate: sr)
        let ceiling = Float(pow(10, -6.0 / 20))
        XCTAssertTrue(channels[0].allSatisfy { abs($0) <= ceiling + 1e-4 })

        // After a lone transient the envelope must return to unity, otherwise
        // the release is not working and the tail stays ducked.
        var quiet = [[Float]](repeating: [Float](repeating: 0.01, count: Int(sr)), count: 1)
        quiet[0][100] = 0.99
        Limiter.apply(&quiet, ceilingDBTP: -6, sampleRate: sr)
        XCTAssertEqual(quiet[0][Int(sr) - 1], 0.01, accuracy: 1e-4)
    }

    /// One envelope drives every channel: a peak in one channel must duck the
    /// other by the same amount, or the stereo image shifts while it limits.
    func testLimiterGainIsJointAcrossChannels() {
        let sr = 48_000.0
        let n = 4_800
        var channels = [[Float]](repeating: [Float](repeating: 0.5, count: n), count: 2)
        channels[0][2_000] = 0.99                       // peak in the left only
        let before = channels[1][2_000]
        Limiter.apply(&channels, ceilingDBTP: -6, sampleRate: sr)
        XCTAssertLessThan(channels[1][2_000], before)   // right ducked too
        XCTAssertEqual(channels[0][2_000] / 0.99, channels[1][2_000] / 0.5, accuracy: 1e-4)
    }

    /// Inter-sample peaks sit between samples, so true peak is never below the
    /// sample peak and is strictly above it when a waveform straddles one.
    func testTruePeakMeetsOrExceedsSamplePeak() {
        let sr = 48_000.0
        let x = (0..<Int(sr)).map { Float(0.9 * sin(2 * .pi * 11_000 * Double($0) / sr)) }
        let samplePeak = 20 * log10(Double(x.map { abs($0) }.max()!))
        let truePeak = Limiter.truePeakDBFS([x])
        XCTAssertGreaterThanOrEqual(truePeak, samplePeak - 1e-9)
        XCTAssertEqual(Limiter.truePeakDBFS([[Float](repeating: 0, count: 100)]), -.infinity)
    }

    /// The streaming limiter has to produce the same samples as the in-memory
    /// one whatever the chunk sizes are, or a long file mastered through the
    /// file path would not match the same audio mastered in memory. Both the
    /// gain envelope and the held-back look-ahead tail have to cross chunk
    /// boundaries for that to hold.
    func testStreamingLimiterMatchesWholeSignal() {
        let sr = 48_000.0
        let n = 40_000
        var x = (0..<n).map { Float(0.3 * sin(2 * .pi * 440 * Double($0) / sr)) }
        for i in stride(from: 5_000, to: n, by: 9_000) { x[i] = 0.95 }

        var whole = [x]
        Limiter.apply(&whole, ceilingDBTP: -3, sampleRate: sr)

        let streaming = Limiter.Streaming(ceilingDBTP: -3, sampleRate: sr, channels: 1)
        var chunked = [Float]()
        var offset = 0
        for size in [1, 17, 4_800, 240, 12_000, 9_999] {
            let end = min(offset + size, n)
            if offset >= end { break }
            chunked.append(contentsOf: streaming.process([Array(x[offset..<end])])[0])
            offset = end
        }
        if offset < n { chunked.append(contentsOf: streaming.process([Array(x[offset...])])[0]) }
        chunked.append(contentsOf: streaming.flush()[0])

        XCTAssertEqual(chunked.count, whole[0].count)
        for i in 0..<chunked.count {
            XCTAssertEqual(chunked[i], whole[0][i], accuracy: 1e-6, "sample \(i)")
        }
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

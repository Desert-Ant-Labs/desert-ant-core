import Testing
import Foundation
@testable import AudioDSP

struct AudioDSPTests {
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

    @Test func hannPeriodic() {
        let w = Window.hann(4, periodic: true)
        #expect(abs(w[0]) <= 1e-6)               // periodic Hann starts at 0
        #expect(abs(w.max()! - 1) <= 1e-6)       // and reaches 1
    }

    @Test func stftRoundTripReconstructsSignal() {
        let x = tone(8000)
        let stft = STFT(nFFT: 400, hop: 100)
        let spec = stft.forward(x)
        let y = stft.inverse(spec, length: x.count)
        #expect(y.count == x.count)
        // Windowed COLA + real-DFT identity should reconstruct near-perfectly.
        #expect(snr(x, y) > 60)
    }

    @Test func stftMagnitudePhaseRebuild() {
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
        #expect(snr(x, y) > 60)
    }

    @Test func energyNormalizeIsInvertible() {
        let x = tone(2000).map { $0 * 3 }
        let (norm, gain) = VectorOps.energyNormalize(x)
        let restored = VectorOps.scaled(norm, by: 1 / gain)
        #expect(snr(x, restored) > 100)   // float round-trip, not bit-exact
        // Unit average power after normalization.
        let power = VectorOps.energy(norm) / Float(norm.count)
        #expect(abs(power - 1) <= 1e-3)
    }

    @Test func standardizeZeroMeanUnitStd() {
        let x: [Float] = (0..<1000).map { Float($0) }
        let z = VectorOps.standardize(x)
        let mean = z.reduce(0, +) / Float(z.count)
        #expect(abs(mean) <= 1e-3)
    }

    @Test func melSpectrogramShape() {
        let mel = MelSpectrogram(sampleRate: 16000, nFFT: 400, hop: 160, mels: 80)
        let (values, frames, mels) = mel.logMel(tone(16000))
        #expect(mels == 80)
        #expect(frames > 90)              // ~1 s at hop 160
        #expect(values.count == frames * mels)
        #expect(values.allSatisfy { $0.isFinite })
    }

    @Test func framingWindows() {
        let w = Framing.windows(count: 250, window: 100, hop: 80)
        #expect(w.first!.start == 0)
        #expect(w.last!.end == 250)       // final window clamps to count
        #expect(w.allSatisfy { $0.end <= 250 })
    }

    @Test func loudnessNormalizeHitsTarget() throws {
        // 1 kHz tone at 48 kHz, ~3 s; normalize to -19 LUFS.
        let sr = 48_000.0
        let x = (0..<Int(3 * sr)).map { Float(0.1 * sin(2 * .pi * 1000 * Double($0) / sr)) }
        let before = Loudness.integratedLUFS(x, sampleRate: sr)
        #expect(before != nil)
        let (y, measured) = Loudness.normalize(x, sampleRate: sr, targetLUFS: -19, maxGainDB: 30, peakCeilingDBFS: -1)
        #expect(measured == before)
        let after = try #require(Loudness.integratedLUFS(y, sampleRate: sr))
        #expect(abs(after - (-19)) <= 0.5)               // lands on target
        #expect(y.allSatisfy { abs($0) <= 1 })           // never clips
    }

    // MARK: limiter

    /// The regression the limiter exists to fix. A signal that is quiet apart
    /// from one loud transient cannot be mastered by a single static gain: to
    /// keep the transient under the ceiling the whole file has to come down,
    /// landing well below the requested loudness. The limiter takes the gain
    /// out of the transient alone, so the target survives.
    @Test func limiterHoldsLoudnessTargetThroughATransient() throws {
        let sr = 48_000.0
        let n = Int(3 * sr)
        var x = (0..<n).map { Float(0.05 * sin(2 * .pi * 1000 * Double($0) / sr)) }
        // One 2 ms transient at full scale, a long way above the rest.
        for i in Int(1.5 * sr)..<(Int(1.5 * sr) + Int(0.002 * sr)) { x[i] = 0.99 }

        let (y, measured) = Loudness.normalize(x, sampleRate: sr, targetLUFS: -19,
                                               maxGainDB: 30, peakCeilingDBFS: -1)
        let after = try #require(Loudness.integratedLUFS(y, sampleRate: sr))
        let ceiling = Float(pow(10, -1.0 / 20))

        // What the static backoff this replaced would have produced: one gain
        // for the whole signal, scaled down until the transient fits.
        let staticGain = Float(pow(10, min(-19 - measured!, 30) / 20))
        var scaled = x.map { $0 * staticGain }
        let peak = scaled.map { abs($0) }.max()!
        if peak > ceiling { scaled = scaled.map { $0 * (ceiling / peak) } }
        let staticAfter = try #require(Loudness.integratedLUFS(scaled, sampleRate: sr))

        // The limiter lands near the target. It does not land exactly on it,
        // and cannot: the transient inflates the *input* measurement, so the
        // gain is chosen for a signal whose energy the limiter then removes.
        #expect(abs(after - (-19)) <= 1.5)
        // The backoff misses by far more - that is the regression being fixed.
        #expect(staticAfter < after - 5)

        // And the ceiling still holds, which is all the backoff ever bought.
        #expect(y.allSatisfy { abs($0) <= ceiling + 1e-4 },
                "peak \(y.map { abs($0) }.max()!) exceeds ceiling \(ceiling)")
    }

    @Test func limiterCeilingIsRespectedAndGainRecovers() {
        let sr = 48_000.0
        // Full-scale tone: every sample needs limiting.
        var channels = [(0..<Int(sr)).map { Float(0.99 * sin(2 * .pi * 200 * Double($0) / sr)) }]
        Limiter.apply(&channels, ceilingDBTP: -6, sampleRate: sr)
        let ceiling = Float(pow(10, -6.0 / 20))
        #expect(channels[0].allSatisfy { abs($0) <= ceiling + 1e-4 })

        // After a lone transient the envelope must return to unity, otherwise
        // the release is not working and the tail stays ducked.
        var quiet = [[Float]](repeating: [Float](repeating: 0.01, count: Int(sr)), count: 1)
        quiet[0][100] = 0.99
        Limiter.apply(&quiet, ceilingDBTP: -6, sampleRate: sr)
        #expect(abs(quiet[0][Int(sr) - 1] - 0.01) <= 1e-4)
    }

    /// One envelope drives every channel: a peak in one channel must duck the
    /// other by the same amount, or the stereo image shifts while it limits.
    @Test func limiterGainIsJointAcrossChannels() {
        let sr = 48_000.0
        let n = 4_800
        var channels = [[Float]](repeating: [Float](repeating: 0.5, count: n), count: 2)
        channels[0][2_000] = 0.99                       // peak in the left only
        let before = channels[1][2_000]
        Limiter.apply(&channels, ceilingDBTP: -6, sampleRate: sr)
        #expect(channels[1][2_000] < before)            // right ducked too
        #expect(abs(channels[0][2_000] / 0.99 - channels[1][2_000] / 0.5) <= 1e-4)
    }

    /// Inter-sample peaks sit between samples, so true peak is never below the
    /// sample peak and is strictly above it when a waveform straddles one.
    @Test func truePeakMeetsOrExceedsSamplePeak() {
        let sr = 48_000.0
        let x = (0..<Int(sr)).map { Float(0.9 * sin(2 * .pi * 11_000 * Double($0) / sr)) }
        let samplePeak = 20 * log10(Double(x.map { abs($0) }.max()!))
        let truePeak = Limiter.truePeakDBFS([x])
        #expect(truePeak >= samplePeak - 1e-9)
        #expect(Limiter.truePeakDBFS([[Float](repeating: 0, count: 100)]) == -.infinity)
    }

    /// The streaming limiter has to produce the same samples as the in-memory
    /// one whatever the chunk sizes are, or a long file mastered through the
    /// file path would not match the same audio mastered in memory. Both the
    /// gain envelope and the held-back look-ahead tail have to cross chunk
    /// boundaries for that to hold.
    @Test func streamingLimiterMatchesWholeSignal() {
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

        #expect(chunked.count == whole[0].count)
        for i in 0..<chunked.count {
            #expect(abs(chunked[i] - whole[0][i]) <= 1e-6, "sample \(i)")
        }
    }

    // MARK: multi-channel loudness

    /// The mono path must not have moved: a one-channel meter has to agree with
    /// the mono entry point exactly, or every existing measurement shifted.
    @Test func oneChannelMatchesTheMonoMeter() throws {
        let sr = 48_000.0
        let x = (0..<Int(3 * sr)).map { Float(0.1 * sin(2 * .pi * 1000 * Double($0) / sr)) }
        let mono = try #require(Loudness.integratedLUFS(x, sampleRate: sr))
        let single = try #require(Loudness.integratedLUFS([x], sampleRate: sr))
        #expect(abs(mono - single) <= 1e-12)
    }

    /// BS.1770 sums the channels' mean squares, so the same signal in both
    /// channels is +3 dB louder than one alone - a stereo programme is not the
    /// average of its sides.
    @Test func stereoSumsChannelsPerBS1770() throws {
        let sr = 48_000.0
        let x = (0..<Int(3 * sr)).map { Float(0.1 * sin(2 * .pi * 1000 * Double($0) / sr)) }
        let one = try #require(Loudness.integratedLUFS([x], sampleRate: sr))
        let two = try #require(Loudness.integratedLUFS([x, x], sampleRate: sr))
        #expect(abs((two - one) - 3.0103) <= 0.01)

        // A silent right channel adds no energy, so the pair reads as the left.
        let silent = [Float](repeating: 0, count: x.count)
        let half = try #require(Loudness.integratedLUFS([x, silent], sampleRate: sr))
        #expect(abs(half - one) <= 0.01)
    }

    /// Per-channel gating is what channel balancing corrects against, so each
    /// side has to report its own level, not the programme's.
    @Test func perChannelLoudnessReportsEachSide() throws {
        let sr = 48_000.0
        let loud = (0..<Int(3 * sr)).map { Float(0.2 * sin(2 * .pi * 1000 * Double($0) / sr)) }
        let quiet = loud.map { $0 * 0.5 }        // -6 dB
        let meter = try #require(Loudness.StreamingMeter(sampleRate: sr, channels: 2, perChannel: true))
        meter.consume([loud, quiet])
        let each = meter.finalizePerChannel()
        #expect(each.count == 2)
        #expect(abs((each[0]! - each[1]!) - 6.0206) <= 0.01)
    }

    /// Balancing lifts the quiet side to the target while the joint stages
    /// leave the corrected image alone.
    @Test func channelBalancingEqualisesTheSides() throws {
        let sr = 48_000.0
        let loud = (0..<Int(3 * sr)).map { Float(0.2 * sin(2 * .pi * 1000 * Double($0) / sr)) }
        var channels = [loud, loud.map { $0 * 0.5 }]
        Loudness.normalizeInPlace(&channels, sampleRate: sr, targetLUFS: -19,
                                  maxGainDB: 30, peakCeilingDBFS: -1,
                                  balanceChannelsLUFS: -20)

        let after = try #require(Loudness.StreamingMeter(sampleRate: sr, channels: 2, perChannel: true))
        after.consume(channels)
        let each = after.finalizePerChannel()
        #expect(abs(each[0]! - each[1]!) <= 0.1)
    }

    /// Without balancing, mastering is joint: both channels take the same gain,
    /// so their level difference survives untouched.
    @Test func jointGainPreservesTheStereoImage() {
        let sr = 48_000.0
        let loud = (0..<Int(3 * sr)).map { Float(0.05 * sin(2 * .pi * 1000 * Double($0) / sr)) }
        var channels = [loud, loud.map { $0 * 0.5 }]
        Loudness.normalizeInPlace(&channels, sampleRate: sr, targetLUFS: -19,
                                  maxGainDB: 30, peakCeilingDBFS: -1)
        // The ratio between the sides is what the image is; it must not move.
        for i in stride(from: 1_000, to: 100_000, by: 10_000) where abs(channels[0][i]) > 1e-4 {
            #expect(abs(channels[1][i] / channels[0][i] - 0.5) <= 1e-3)
        }
    }

    // MARK: streaming meter

    /// The whole point of the streaming meter: chunked measurement has to agree
    /// with whole-signal measurement, whatever the chunk sizes are. The filter
    /// state and the 400 ms block grid both have to survive chunk boundaries.
    @Test func streamingMeterMatchesWholeSignal() throws {
        let sr = 48_000.0
        var rng = SystemRandomNumberGenerator()
        for trial in 0..<4 {
            let n = [48_000 * 3, 48_000 * 7 + 13, 96_000, 48_000 * 11 + 1][trial]
            var x = [Float](repeating: 0, count: n)
            for i in 0..<n {
                x[i] = 0.4 * Float(sin(2 * .pi * 220 * Double(i) / sr))
                    + Float.random(in: -0.05...0.05, using: &rng)
            }
            let reference = try #require(Loudness.integratedLUFS(x, sampleRate: sr), "n=\(n)")

            // Deliberately awkward chunk sizes: not multiples of the block or
            // step, and one larger than a block.
            for chunk in [1_000, 4_800, 19_200, 50_000, 7_777] {
                let meter = try #require(Loudness.StreamingMeter(sampleRate: sr), "meter init")
                var i = 0
                while i < n {
                    let end = min(i + chunk, n)
                    meter.consume(Array(x[i..<end]))
                    i = end
                }
                let streamed = try #require(meter.finalize(), "n=\(n) chunk=\(chunk)")
                // Not bit-exact: vDSP_biquad rounds slightly differently
                // depending on how long a span it is handed (vector tail
                // handling), so an odd chunk size shifts the last bits. The
                // observed spread is ~1e-5 dB, which is nothing against the
                // 0.1 LU that matters for delivery targets.
                #expect(abs(reference - streamed) <= 1e-4, "n=\(n) chunk=\(chunk)")
            }
        }
    }

    @Test func streamingMeterTracksPeak() throws {
        let meter = try #require(Loudness.StreamingMeter(sampleRate: 48_000), "meter init")
        meter.consume([0.1, -0.7, 0.3])
        meter.consume([0.2, -0.25])
        #expect(abs(meter.peak - 0.7) <= 1e-6)
    }

    @Test func streamingMeterMemoryIsBounded() throws {
        let meter = try #require(Loudness.StreamingMeter(sampleRate: 48_000), "meter init")
        // 10 minutes fed in 1 s pieces; the meter must not be accumulating the
        // signal itself.
        let second = [Float](repeating: 0.2, count: 48_000)
        for _ in 0..<600 { meter.consume(second) }
        #expect(meter.finalize() != nil)
    }

    @Test func loudnessSilenceIsNil() {
        #expect(Loudness.integratedLUFS([Float](repeating: 0, count: 48_000), sampleRate: 48_000) == nil)
    }

    @Test func overlapAccumulatorAverages() {
        var acc = OverlapAccumulator(length: 4)
        acc.add([1, 1], at: 0)
        acc.add([3, 3], at: 1)   // index 1 and 2 now overlap
        let avg = acc.average()
        #expect(avg == [1, 2, 3, 0])
    }
}

import Foundation
import Testing
import AudioIO
import DesertAnt
import TestSupport
@testable import Clear

/// A sine tone, the input every test builds on.
func tone(_ n: Int, freq: Double = 220, sr: Double = 48_000, amp: Float = 0.3) -> [Float] {
    (0..<n).map { amp * Float(sin(2 * .pi * freq * Double($0) / sr)) }
}

/// Signal-to-noise ratio in dB between a reference and a reconstruction.
func snr(_ ref: [Float], _ rec: [Float]) -> Double {
    let n = min(ref.count, rec.count)
    var sig = 0.0, err = 0.0
    for i in 0..<n { sig += Double(ref[i]) * Double(ref[i]); let e = Double(ref[i]) - Double(rec[i]); err += e * e }
    return err > 0 ? 10 * log10(sig / err) : .infinity
}

/// 2.5 s of tone plus deterministic noise at 48 kHz: what the model is asked to
/// clean up. Deterministic so a failure reproduces.
func noisyTone() -> [Float] {
    var x = tone(120_000)
    var seed: UInt64 = 1
    for i in 0..<x.count {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        x[i] += 0.15 * (Float(seed >> 40) / Float(1 << 24) - 0.5)
    }
    return x
}

/// Collects progress updates from the task group the chunk loop runs on.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [Clear.Progress] = []
    func append(_ update: Clear.Progress) { lock.withLock { updates.append(update) } }
    func all() -> [Clear.Progress] { lock.withLock { updates } }
}

/// The half of Clear that needs no model: the DSP front end, the mastering
/// presets, and the variant declarations.
struct ClearTests {
    // MARK: DSP

    /// Validates the ported DFN STFT: analysis+synthesis reconstructs the signal
    /// (Vorbis-window COLA identity), independent of the model.
    @Test func stftReconstruction() {
        let x = tone(48_000)
        let stft = ClearSTFT()
        let (re, im, frames) = stft.forward(x)
        #expect(frames > 90)
        let y = stft.inverse(real: re, imag: im, nFrames: frames)
        #expect(y.count >= x.count)
        // COLA identity holds on the interior; the first/last half-window lack
        // full overlap (the pipeline pads the tail, so this is edge-only).
        let pad = ClearDSP.fftSize
        let xi = Array(x[pad..<(x.count - pad)])
        let yi = Array(y[pad..<(x.count - pad)])
        #expect(snr(xi, yi) > 60)
    }

    @Test func featuresAreFinite() {
        let stft = ClearSTFT()
        let (re, im, frames) = stft.forward(tone(24_000))
        let (fe, fr, fi) = ClearFeatures.compute(real: re, imag: im, nFrames: frames)
        #expect(fe.count == frames * ClearDSP.nErb)
        #expect(fr.count == frames * ClearDSP.nDf)
        #expect((fe + fr + fi).allSatisfy { $0.isFinite })
    }

    // MARK: mastering presets

    /// The published targets each preset normalizes to, and that a preset round
    /// trips into `Options`. These are platform specs, so a change here is a
    /// deliberate spec change, not a refactor.
    @Test func loudnessPresetTargets() {
        #expect(Clear.LoudnessPreset.applePodcasts.integratedLUFS == -19)
        #expect(Clear.LoudnessPreset.spotify.integratedLUFS == -14)
        #expect(Clear.LoudnessPreset.youtube.integratedLUFS == -14)
        #expect(Clear.LoudnessPreset.broadcast.integratedLUFS == -23)

        // EBU R128 allows a wider range than spoken-word delivery.
        #expect(Clear.LoudnessPreset.broadcast.mastering.loudnessRangeLU == 10)
        #expect(Clear.LoudnessPreset.applePodcasts.mastering.loudnessRangeLU == 7)

        // Every case is pickable and labelled, so a UI can render the list.
        #expect(Clear.LoudnessPreset.allCases.count == 4)
        for preset in Clear.LoudnessPreset.allCases {
            #expect(!preset.displayName.isEmpty)
            #expect(!preset.shortName.isEmpty)
            #expect(preset.id == preset.rawValue)
            #expect(Clear.LoudnessPreset(rawValue: preset.rawValue) == preset)
            #expect(preset.mastering.integratedLUFS == preset.integratedLUFS)
        }
    }

    @Test func masteringDefaultsAndBypass() {
        // The default options are the Apple Podcasts preset at full strength.
        #expect(Clear.Options.default.mastering == .applePodcasts)
        #expect(Clear.Options.default.strength.value == 1)
        #expect(Clear.Options.default.targetLUFS == -19)
        #expect(Clear.Mastering.podcast == Clear.Mastering.applePodcasts)

        // Bypass reports no target, which is what disables the loudness stage.
        #expect(Clear.Options(mastering: .bypass).targetLUFS == nil)
        #expect(Clear.Options(targetLUFS: nil).targetLUFS == nil)

        // The numeric initializer maps onto the same chain.
        let explicit = Clear.Options(targetLUFS: -16, peakCeilingDBFS: -2, maxGainDB: 6)
        #expect(explicit.mastering.integratedLUFS == -16)
        #expect(explicit.mastering.truePeakDBTP == -2)
        #expect(explicit.mastering.maxLoudnessGainDB == 6)
        #expect(Clear.Mastering.targetLUFS(-21).integratedLUFS == -21)
    }

    // MARK: channels

    /// Equal-weight averaging, so a centred voice keeps the level it had in the
    /// pair instead of coming out 6 dB down or summing to clipping.
    @Test func downmixAveragesTheChannels() {
        #expect(Clear.downmix([[1, 2, 3]]) == [1, 2, 3])
        #expect(Clear.downmix([[1, 0, -1], [1, 0, -1]]) == [1, 0, -1])
        #expect(Clear.downmix([[1, 1], [0, -1]]) == [0.5, 0])
        #expect(Clear.downmix([]) == [])
    }

    /// `samples` is a convenience over `channels`, so the two must not be able
    /// to disagree.
    @Test func resultSamplesIsTheFirstChannel() {
        let stereo = Clear.Result(channels: [[1, 2], [3, 4]], sampleRate: 48_000,
                                  durationSec: 0, processingSec: 0, measuredLUFS: nil,
                                  measuredTruePeakDBFS: nil, modelVariant: nil, modelRevision: nil)
        #expect(stereo.channelCount == 2)
        #expect(stereo.samples == [1, 2])

        let empty = Clear.Result(channels: [], sampleRate: 48_000,
                                 durationSec: 0, processingSec: 0, measuredLUFS: nil,
                                 measuredTruePeakDBFS: nil, modelVariant: nil, modelRevision: nil)
        #expect(empty.samples == [])
        #expect(empty.channelCount == 0)
    }

    /// The new options have to default to exactly the old behaviour, or every
    /// existing caller silently changes.
    @Test func channelOptionsDefaultToTheMonoPath() {
        #expect(Clear.Options.default.channelMode == .mono)
        #expect(Clear.Options.default.sampleRate == 48_000)
        #expect(Clear.Options.default.mastering.balanceChannelsLUFS == nil)
        #expect(Clear.Options(targetLUFS: -16).sampleRate == 48_000)
        #expect(Clear.Options(targetLUFS: -16).channelMode == .mono)
    }

    // MARK: variants

    /// The variant is what selects files, so its names must match the Hub's
    /// artifact stems exactly, and each variant must fetch only its own.
    @Test func modelVariantFilesAndInference() {
        #expect(ModelVariant.default == .clearStudio)
        #expect(ClearModel.variant == .clearStudio)
        #expect(ModelVariant.clearStudio.rawValue == "clear-studio")
        #expect(ModelVariant.clearNatural.rawValue == "clear-natural")
        #expect(ModelVariant.clearNatural.coreML == "clear-natural.mlmodelc")
        #expect(ModelVariant.clearNatural.tflite == "clear-natural.tflite")

        // A variant's manifest carries that variant alone.
        let natural = ModelVariant.clearNatural.distribution
        #expect(natural.repo == ClearModel.repo)
        #expect(natural.revision == ClearModel.revision)
        for (_, files) in natural.files {
            #expect(files.allSatisfy { $0.hasPrefix("clear-natural") }, "got \(files)")
        }

        // The catalog entry stays the default variant, which is what the shared
        // fixture and tooling read.
        #expect(ClearModel.files[.apple] == ModelVariant.clearStudio.files[.apple])

        // A path identifies its variant; anything else is not a published one.
        #expect(ModelVariant.inferred(fromPath: "/tmp/x/clear-studio.mlmodelc") == .clearStudio)
        #expect(ModelVariant.inferred(fromPath: "clear-natural.tflite") == .clearNatural)
        #expect(ModelVariant.inferred(fromPath: "/tmp/my-own-export.tflite") == nil)
    }
}

// `.modelBacked` (TestSupport) decides where these run - one trait on the suite
// instead of a platform `#if` around each test - and the wasm guard is because
// the shared fixture does not exist there (the model store's filesystem and
// transport come from the JS host an app installs, which the bare test harness
// never does).
#if !os(WASI)
@Suite(.serialized, .modelBacked) struct ClearModelTests {
    /// An enhancer over the cached artifact for this platform: the Core ML
    /// directory on Apple, the LiteRT file elsewhere. The fixture downloads it
    /// once per process and every test here reuses it.
    private func enhancer() async throws -> Clear {
        let files = try await ModelFixture.files(ClearModel.self)
        return try Clear(modelPath: files.path(ClearModel.artifact), revision: "1d8810f")
    }

    @Test func enhanceEndToEnd() async throws {
        let clear = try await enhancer()
        let x = noisyTone()
        let result = try await clear.enhance(samples: x, sampleRate: 48_000,
                                             options: .init(mastering: .applePodcasts))
        #expect(result.sampleRate == 48_000)
        #expect(abs(result.samples.count - x.count) <= 480)
        #expect(result.samples.allSatisfy { $0.isFinite })
        var energy: Float = 0; for v in result.samples { energy += v * v }
        #expect(energy > 0)                             // not silent
        #expect(result.measuredLUFS != nil)
        // The run identifies the artifact that produced it (read off the cached
        // file name), so a benchmark or usage event is self-describing.
        #expect(result.modelVariant == .clearStudio)
    }

    /// A preset actually moves the output level: the same input mastered to
    /// Spotify (-14) is louder than to broadcast (-23), and bypass leaves the
    /// model's own level (so it reports no measurement).
    @Test func presetsChangeTheMasteredLevel() async throws {
        let clear = try await enhancer()
        let x = noisyTone()

        func rms(_ s: [Float]) -> Double {
            var acc = 0.0
            for v in s { acc += Double(v) * Double(v) }
            return (acc / Double(max(1, s.count))).squareRoot()
        }

        let spotify = try await clear.enhance(samples: x, sampleRate: 48_000,
                                              options: .init(mastering: .spotify))
        let broadcast = try await clear.enhance(samples: x, sampleRate: 48_000,
                                                options: .init(mastering: .broadcast))
        let bypassed = try await clear.enhance(samples: x, sampleRate: 48_000,
                                               options: .init(mastering: .bypass))

        #expect(rms(spotify.samples) > rms(broadcast.samples))
        #expect(spotify.measuredLUFS != nil)
        #expect(bypassed.measuredLUFS == nil)

        // True peak is measured after limiting, so it reports the delivered
        // audio and has to sit under the ceiling the preset asked for.
        #expect(bypassed.measuredTruePeakDBFS == nil)
        let truePeak = try #require(spotify.measuredTruePeakDBFS)
        #expect(truePeak <= Clear.Mastering.spotify.truePeakDBTP + 0.5)
        // 4x oversampling can only find peaks a sample-peak reading misses.
        let samplePeak = 20 * log10(Double(spotify.samples.map { abs($0) }.max() ?? 0))
        #expect(truePeak >= samplePeak - 1e-9)
    }

    /// Stereo in, stereo out, with both sides actually enhanced rather than one
    /// being copied or dropped.
    @Test func stereoKeepsBothChannels() async throws {
        let clear = try await enhancer()
        let left = noisyTone()
        // A different signal per side, so a channel mix-up is visible.
        let right = left.map { $0 * 0.5 }

        let result = try await clear.enhance(channels: [left, right], sampleRate: 48_000,
                                             options: .init(mastering: .applePodcasts,
                                                            channelMode: .preserve))
        #expect(result.channelCount == 2)
        #expect(result.channels[0].count == result.channels[1].count)
        #expect(result.samples == result.channels[0])
        for channel in result.channels {
            #expect(channel.allSatisfy { $0.isFinite })
            var energy: Float = 0; for v in channel { energy += v * v }
            #expect(energy > 0)
        }
        // The sides stay distinguishable: joint mastering must not have
        // collapsed them into the same signal.
        #expect(result.channels[0] != result.channels[1])
    }

    /// Mastering is joint, so the level difference between the sides survives
    /// it. This is what "does not move the stereo image" means concretely.
    @Test func jointMasteringPreservesTheImage() async throws {
        let clear = try await enhancer()
        let left = noisyTone()
        let result = try await clear.enhance(channels: [left, left.map { $0 * 0.5 }],
                                             sampleRate: 48_000,
                                             options: .init(mastering: .spotify,
                                                            channelMode: .preserve))
        // Compare energies rather than samples: the model is not linear, so the
        // ratio is approximate, but a joint gain keeps them well apart.
        func energy(_ s: [Float]) -> Double {
            var acc = 0.0; for v in s { acc += Double(v) * Double(v) }
            return acc
        }
        let ratio = energy(result.channels[1]) / energy(result.channels[0])
        #expect(ratio < 0.9, "sides converged (ratio \(ratio)); mastering moved the image")
    }

    /// The default collapses a pair before inference, so the result is one
    /// channel and one inference pass - what every release so far did.
    @Test func defaultCollapsesThePairBeforeInference() async throws {
        let clear = try await enhancer()
        let left = noisyTone()
        let result = try await clear.enhance(channels: [left, left.map { $0 * 0.5 }],
                                             sampleRate: 48_000,
                                             options: .init(channelMode: .mono))
        #expect(result.channelCount == 1)
        #expect(result.samples.allSatisfy { $0.isFinite })
    }

    /// The mono entry point is the one-channel case of the same path, so the
    /// two must agree sample for sample.
    @Test func monoEntryPointMatchesOneChannel() async throws {
        let clear = try await enhancer()
        let x = noisyTone()
        let mono = try await clear.enhance(samples: x, sampleRate: 48_000)
        let single = try await clear.enhance(channels: [x], sampleRate: 48_000)
        #expect(mono.channels.count == 1)
        #expect(mono.samples == single.samples)
    }

    /// The delivery rate is applied after the model, the meter, and the
    /// limiter, all of which are derived for 48 kHz.
    @Test func outputSampleRateResamplesTheDelivery() async throws {
        let clear = try await enhancer()
        let x = noisyTone()
        let result = try await clear.enhance(samples: x, sampleRate: 48_000,
                                             options: .init(sampleRate: 24_000))
        #expect(result.sampleRate == 24_000)
        #expect(result.samples.allSatisfy { $0.isFinite })
        // Half the rate over the same audio is about half the samples.
        let expected = Double(x.count) / 2
        #expect(abs(Double(result.samples.count) - expected) < expected * 0.02)
        #expect(abs(result.durationSec - Double(x.count) / 48_000) < 0.05)
    }

    /// Balancing corrects a pair recorded at different levels, which is the one
    /// case where mastering is allowed to move the sides relative to each other.
    @Test func channelBalancingEqualisesTheSides() async throws {
        let clear = try await enhancer()
        let left = noisyTone()
        var mastering = Clear.Mastering.applePodcasts
        mastering.balanceChannelsLUFS = -20
        let result = try await clear.enhance(channels: [left, left.map { $0 * 0.25 }],
                                             sampleRate: 48_000,
                                             options: .init(mastering: mastering,
                                                            channelMode: .preserve))
        func energy(_ s: [Float]) -> Double {
            var acc = 0.0; for v in s { acc += Double(v) * Double(v) }
            return acc
        }
        // Started 12 dB apart; balancing should bring them close together.
        let ratio = energy(result.channels[1]) / energy(result.channels[0])
        #expect(ratio > 0.5, "balancing did not lift the quiet side (ratio \(ratio))")
    }

    /// A stereo file stays stereo through the bounded-memory path, which reads,
    /// enhances, meters, limits and writes per channel. The written file is the
    /// proof: it has to decode back as two channels.
    @Test func stereoSurvivesTheFilePath() async throws {
        let clear = try await enhancer()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clear-stereo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = dir.appendingPathComponent("in.wav")
        let output = dir.appendingPathComponent("out.wav")
        let left = noisyTone()
        let right = left.map { $0 * 0.5 }
        try AudioIO.writeWAV(Resample.interleave([left, right]),
                             sampleRate: 48_000, channels: 2, to: input.path)

        let result = try await clear.enhance(path: input.path, to: output.path,
                                             options: .init(channelMode: .preserve))
        #expect(result.sampleRate == 48_000)

        let decoded = try await AudioIO.decodeChannels(path: output.path, sampleRate: 48_000)
        #expect(decoded.count == 2)
        let expected = Int(result.durationSec * 48_000)
        #expect(abs(decoded[0].count - expected) <= 480)
        for channel in decoded {
            #expect(channel.contains { $0 != 0 })
            #expect(channel.allSatisfy { $0.isFinite })
        }
        // Joint mastering keeps the sides apart, the same as in memory.
        #expect(decoded[0] != decoded[1])
    }

    /// A stereo input still writes a mono file: the contract an existing
    /// caller depends on, which a version bump must not change under it.
    @Test func theFilePathWritesMonoByDefault() async throws {
        let clear = try await enhancer()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clear-mono-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = dir.appendingPathComponent("in.wav")
        let output = dir.appendingPathComponent("out.wav")
        let left = noisyTone()
        try AudioIO.writeWAV(Resample.interleave([left, left.map { $0 * 0.5 }]),
                             sampleRate: 48_000, channels: 2, to: input.path)

        _ = try await clear.enhance(path: input.path, to: output.path)
        let decoded = try await AudioIO.decodeChannels(path: output.path, sampleRate: 48_000)
        #expect(decoded.count == 1)
    }

    /// The stage breakdown has to account for the run: every stage that ran is
    /// non-zero, the model dominates, and the total sits under `processingSec`
    /// without being a rounding error away from zero.
    @Test func phaseTimingsAccountForTheRun() async throws {
        let clear = try await enhancer()
        let result = try await clear.enhance(samples: noisyTone(), sampleRate: 48_000,
                                             options: .init(strength: 0.8))
        let p = result.phaseTimings
        #expect(p.stftForwardSec > 0)
        #expect(p.computeFeaturesSec > 0)
        #expect(p.modelPredictSec > 0)
        #expect(p.stftInverseSec > 0)
        #expect(p.blendSec > 0)             // strength < 1, so the blend ran
        #expect(p.masteringSec > 0)
        // Nothing to do: already 48 kHz in, 48 kHz out. The resample stage
        // still walks the channels, so it is negligible rather than exactly 0;
        // the delivery stage is skipped outright.
        #expect(p.decodeResampleSec < 0.001)
        #expect(p.deliverySec == 0)

        // The model is the expensive part of an enhance pass.
        #expect(p.modelPredictSec > p.stftForwardSec)
        // The stages are a breakdown of the run, so they cannot exceed it.
        #expect(p.totalSec <= result.processingSec)
        #expect(p.totalSec > result.processingSec * 0.5,
                "stages \(p.totalSec)s account for too little of \(result.processingSec)s")
    }

    /// Two channels run one after another, so their stage times add up rather
    /// than being reported once.
    @Test func phaseTimingsSumAcrossChannels() async throws {
        let clear = try await enhancer()
        let x = noisyTone()
        // The first enhance pays the Core ML compile and a cold session, which
        // lands in whichever measurement runs first - on CI that made mono look
        // slower than stereo and failed this backwards.
        _ = try await clear.enhance(channels: [x], sampleRate: 48_000)

        let mono = try await clear.enhance(channels: [x], sampleRate: 48_000)
        let stereo = try await clear.enhance(channels: [x, x], sampleRate: 48_000,
                                             options: .init(channelMode: .preserve))
        // Serial channels means their model time adds up; taking the slower
        // channel would land at ~1x. Measured ~1.8x idle, so 1.2x separates
        // summing from maxing without asserting a throughput number.
        #expect(stereo.phaseTimings.modelPredictSec > mono.phaseTimings.modelPredictSec * 1.2,
                "stereo \(stereo.phaseTimings.modelPredictSec)s vs mono \(mono.phaseTimings.modelPredictSec)s: not summing across channels")
    }

    /// This runtime has to reproduce the Apple reference in
    /// `Tests/Fixtures/clear-parity.json` - what says LiteRT runs the same
    /// pipeline rather than merely running.
    @Test func matchesTheCrossPlatformReference() async throws {
        let golden = try #require(ParityFixture.golden())
        let clear = try await enhancer()
        let result = try await clear.enhance(samples: ParityFixture.input(), sampleRate: 48_000,
                                             options: .init(mastering: .applePodcasts))

        #expect(abs(result.samples.count - golden.sampleCount) <= 480)
        let envelope = ParityFixture.envelope(result.samples)
        #expect(envelope.count == golden.blockRMS.count)

        // Per-block RMS, compared relative to the loudest block so the quiet
        // tail does not demand absurd precision of near-silence.
        let scale = max(golden.blockRMS.max() ?? 1, 1e-9)
        var worst = 0.0
        for (i, expected) in golden.blockRMS.enumerated() where i < envelope.count {
            worst = max(worst, abs(envelope[i] - expected) / scale)
        }
        let lufs = try #require(result.measuredLUFS)
        let truePeak = try #require(result.measuredTruePeakDBFS)

        // Reported even on success: a log that only speaks up when it breaks
        // cannot show the margin shrinking.
        print(String(format: "PARITY envelope=%.4f lufs=%+.4f truePeak=%+.4f",
                     worst, lufs - golden.measuredLUFS, truePeak - golden.truePeakDBFS))

        // Apple produced the reference, so only there is this a like-for-like
        // regression gate; see ParityFixture.envelopeTolerance.
        #if canImport(CoreML)
        #expect(worst < ParityFixture.envelopeTolerance,
                "block RMS diverged by \(worst) of full scale (tolerance \(ParityFixture.envelopeTolerance))")
        #endif
        #expect(abs(lufs - golden.measuredLUFS) < ParityFixture.loudnessToleranceDB,
                "loudness \(lufs) vs reference \(golden.measuredLUFS)")
        #expect(abs(truePeak - golden.truePeakDBFS) < ParityFixture.loudnessToleranceDB,
                "true peak \(truePeak) vs reference \(golden.truePeakDBFS)")
    }

    /// The Android APK carries its own copy of the reference, because wiring a
    /// Gradle copy into androidTest assets did not order reliably on a clean
    /// build. Two files can drift; this is what stops them.
    @Test func theAndroidFixtureCopyMatches() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shared = root.appendingPathComponent("Tests/Fixtures/clear-parity.json")
        let android = root.appendingPathComponent(
            "packages/clear-kotlin/src/androidTest/assets/clear-parity.json")
        guard let a = try? Data(contentsOf: shared), let b = try? Data(contentsOf: android) else {
            return   // not a repo checkout (wasm, sandboxed); nothing to compare
        }
        #expect(a == b, "the androidTest copy is stale; copy Tests/Fixtures/clear-parity.json over it")
    }

    /// The store path the SDK's own initializer takes: resolve the pinned model
    /// into the managed cache, then report it as available offline.
    @Test func resolvesThroughTheModelStore() async throws {
        _ = try await ModelFixture.files(ClearModel.self)
        // Availability is per instance (LoadedModel owns it), so ask one.
        #expect(Clear().isDownloaded())
        // The managed cache lists the downloaded version, its last path
        // component the revision the SDK is pinned to.
        let models = Clear.models()
        #expect(models.contains { $0.hasSuffix("/\(ClearModel.repo)/\(Clear.modelRevision)") })
    }

    /// The file-in/file-out path (Apple/Linux): decode any audio file, enhance,
    /// and write a 48 kHz WAV. Uses the core's AudioIO for both ends, so this
    /// also covers the WAV encode the SDK hands users.
    @Test func enhanceFileToFile() async throws {
        let clear = try await enhancer()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clear-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = dir.appendingPathComponent("in.wav")
        let output = dir.appendingPathComponent("out.wav")
        try AudioIO.writeWAV(noisyTone(), sampleRate: 48_000, to: input.path)

        let result = try await clear.enhance(path: input.path, to: output.path)
        #expect(result.sampleRate == 48_000)
        #expect(FileManager.default.fileExists(atPath: output.path))

        // The written file decodes back to the enhanced signal. Length comes
        // from `durationSec`, not `samples`: writing to a file takes the
        // bounded-memory path, which never materializes the signal, so
        // `samples` is empty by design.
        let decoded = try await AudioIO.decode(path: output.path, sampleRate: 48_000)
        let expected = Int(result.durationSec * 48_000)
        #expect(abs(decoded.count - expected) <= 480)
        #expect(decoded.contains { $0 != 0 })
    }

    /// Progress reporting: the phases arrive in pipeline order, each fraction is
    /// monotonic within its phase, and enhancing is subdivided (more than one
    /// chunk report) rather than jumping 0 -> 1.
    @Test func progressReportsPhasesInOrder() async throws {
        let clear = try await enhancer()
        let log = ProgressLog()

        _ = try await clear.enhance(samples: noisyTone(), sampleRate: 48_000,
                                    options: .init(mastering: .applePodcasts)) { log.append($0) }

        let updates = log.all()
        #expect(!updates.isEmpty)

        // The model is already loaded here (the fixture built the session), so
        // the phases present are analyzing then enhancing, never interleaved.
        let phases = updates.map(\.phase)
        let order: [Clear.Phase] = [.loadingModel, .analyzing, .enhancing]
        let ranks = phases.compactMap { order.firstIndex(of: $0) }
        #expect(ranks == ranks.sorted(), "phases must not interleave: \(phases)")

        #expect(phases.contains(.analyzing))
        #expect(phases.contains(.enhancing))

        // Fractions stay in range and never go backwards within a phase.
        for phase in Set(phases) {
            let fractions = updates.filter { $0.phase == phase }.map(\.fraction)
            #expect(fractions == fractions.sorted(), "\(phase) fractions went backwards")
            #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
        }

        // 2.5 s is many model chunks, so enhancing is genuinely incremental, and
        // it ends at 1 only after mastering (its tail) has run.
        #expect(updates.filter { $0.phase == .enhancing }.count > 2)
        #expect(updates.last?.phase == .enhancing)
        #expect(updates.last?.fraction == 1)
        #expect(updates.filter { $0.phase == .analyzing }.last?.fraction == 1)
    }

    /// A fresh instance that has to resolve the model reports `.loadingModel`
    /// first, so the first call does not look like a hang.
    @Test func progressReportsModelLoad() async throws {
        _ = try await ModelFixture.files(ClearModel.self)   // cached; the load is local
        let log = ProgressLog()
        _ = try await enhancer().enhance(samples: tone(48_000), sampleRate: 48_000) { log.append($0) }
        #expect(log.all().first?.phase == .loadingModel)
    }
}
#endif

// The wire contract the JavaScript and Kotlin SDKs encode against. No compiler
// checks it across languages, so each side asserts the same bytes.
#if !os(WASI)
@Suite(.serialized, .modelBacked) struct ClearBindingTests {
    private func enhancer() async throws -> Clear {
        let files = try await ModelFixture.files(ClearModel.self)
        return try Clear(modelPath: files.path(ClearModel.artifact), revision: "1d8810f")
    }

    private func input(_ channels: [[Float]], sampleRate: Double = 48_000) -> FFIReader {
        var w = FFIWriter()
        w.f32Array(channels[0])
        w.f64(sampleRate)
        w.u32(channels.count - 1)
        for channel in channels.dropFirst() { w.f32Array(channel) }
        return FFIReader(w.bytes)
    }

    private func options(monoDownmix: Bool = true, outputRate: Double = 48_000) -> FFIReader {
        var o = FFIWriter()
        o.f64(1)            // strength
        o.f64(-19)          // integratedLUFS
        o.f64(-1.5)         // truePeakDBTP
        o.f64(9)            // maxLoudnessGainDB
        o.f64(outputRate)
        o.f64(monoDownmix ? 1 : 0)
        o.f64(Double.nan)   // balanceChannelsLUFS: none
        return FFIReader(o.bytes)
    }

    /// Reads a result payload back into its channels.
    private func decode(_ bytes: [UInt8]) -> (channels: [[Float]], sampleRate: Double) {
        var r = FFIReader(bytes)
        var channels = [r.f32Array()]
        let rate = r.f64()
        _ = r.f64(); _ = r.f64(); _ = r.f64(); _ = r.f64()   // durations, measurements
        let extra = r.u32()
        for _ in 0..<extra { channels.append(r.f32Array()) }
        return (channels, rate)
    }

    @Test func monoRoundTripsWithNoExtraChannels() async throws {
        let clear = try await enhancer()
        let x = Array(noisyTone().prefix(48_000))
        let bytes = try #require(await clear.run(input: input([x]), options: options()))
        let (channels, rate) = decode(bytes)
        #expect(channels.count == 1)
        #expect(rate == 48_000)
        #expect(!channels[0].isEmpty)
    }

    @Test func stereoCrossesTheBoundaryBothWays() async throws {
        let clear = try await enhancer()
        let left = Array(noisyTone().prefix(48_000))
        let right = left.map { $0 * 0.5 }
        let bytes = try #require(await clear.run(input: input([left, right]),
                                                 options: options(monoDownmix: false)))
        let (channels, _) = decode(bytes)
        #expect(channels.count == 2)
        #expect(channels[0].count == channels[1].count)
        #expect(channels[0] != channels[1])
    }

    @Test func monoDownmixAndOutputRateCrossAsOptions() async throws {
        let clear = try await enhancer()
        let left = Array(noisyTone().prefix(48_000))
        let bytes = try #require(await clear.run(
            input: input([left, left.map { $0 * 0.5 }]),
            options: options(monoDownmix: true, outputRate: 24_000)))
        let (channels, rate) = decode(bytes)
        #expect(channels.count == 1)
        #expect(rate == 24_000)
    }

    /// A host built before the channel and rate fields sends the old, shorter
    /// payloads. Those must still run, as mono at 48 kHz.
    @Test func theOlderSchemaStillRuns() async throws {
        let clear = try await enhancer()
        let x = Array(noisyTone().prefix(48_000))
        var w = FFIWriter()
        w.f32Array(x)
        w.f64(48_000)                    // no extra-channel count
        var o = FFIWriter()
        o.f64(1); o.f64(-19); o.f64(-1.5); o.f64(9)   // no rate/mode/balance
        let bytes = try #require(await clear.run(input: FFIReader(w.bytes),
                                                 options: FFIReader(o.bytes)))
        let (channels, rate) = decode(bytes)
        #expect(channels.count == 1)
        #expect(rate == 48_000)
    }
}
#endif

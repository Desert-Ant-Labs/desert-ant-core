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
        return try Clear(modelPath: files.path(ClearModel.artifact))
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
    }

    /// The store path the SDK's own initializer takes: resolve the pinned model
    /// into the managed cache, then report it as available offline.
    @Test func resolvesThroughTheModelStore() async throws {
        _ = try await ModelFixture.files(ClearModel.self)
        // Availability is per instance (LoadedModel owns it), so ask one.
        #expect(Clear().isDownloaded())
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
        _ = try await Clear().enhance(samples: tone(48_000), sampleRate: 48_000) { log.append($0) }
        #expect(log.all().first?.phase == .loadingModel)
    }
}
#endif

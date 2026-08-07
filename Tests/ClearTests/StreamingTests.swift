import Foundation
import Darwin
import Testing
import AudioIO
import AudioDSP
import TestSupport
@testable import Clear

/// The bounded-memory file path: it must agree with the in-memory pipeline, and
/// its peak must not grow with the length of the file.
/// Thread-safe max, because progress arrives from the worker pool.
private final class PeakTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    init(start: Double) { value = start }
    func observe(_ v: Double) { lock.lock(); value = max(value, v); lock.unlock() }
    var peak: Double { lock.lock(); defer { lock.unlock() }; return value }
}

private enum TempFootprint {
    static func current() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1024 / 1024 : -1
    }
}

@Suite(.serialized)
struct ClearStreamingTests {
    private func enhancer() async throws -> Clear {
        let files = try await ModelFixture.files(ClearModel.self)
        return try Clear(modelPath: files.path(ClearModel.artifact))
    }

    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1024 / 1024 : -1
    }

    private func speechish(_ seconds: Double) -> [Float] {
        // Something with structure the model will actually act on, plus noise,
        // and an amplitude envelope so the loudness gate has quiet and loud
        // stretches to work with.
        let n = Int(seconds * 48_000)
        var x = [Float](repeating: 0, count: n)
        var seed: UInt64 = 0x5EED
        func rnd() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
        }
        for i in 0..<n {
            let t = Double(i) / 48_000
            let env = 0.35 * (0.6 + 0.4 * sin(2 * .pi * 0.25 * t))
            let voiced = sin(2 * .pi * 140 * t) + 0.5 * sin(2 * .pi * 280 * t) + 0.25 * sin(2 * .pi * 560 * t)
            x[i] = Float(env) * (Float(voiced) / 1.75 + 0.08 * rnd())
        }
        return x
    }

    /// Windowed output is not bit-identical to whole-file output (the feature
    /// EMA is reconverged per window rather than threaded across the seam), so
    /// this asserts they agree to within a healthy SNR instead.
    @Test(.modelBacked) func streamingMatchesInMemory() async throws {
        let clear = try await enhancer()
        let x = speechish(50)   // more than two 20 s windows, so seams are exercised

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clear-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.wav")
        let output = dir.appendingPathComponent("out.wav")
        try AudioIO.writeWAV(x, sampleRate: 48_000, to: input.path)

        // Bounded-memory path (writes a file).
        let streamed = try await clear.enhance(path: input.path, to: output.path,
                                               options: .init(mastering: .bypass))
        let streamedSamples = try await AudioIO.decode(path: output.path, sampleRate: 48_000)

        // In-memory path over the same input.
        let reference = try await clear.enhance(samples: x, sampleRate: 48_000,
                                                options: .init(mastering: .bypass))

        #expect(abs(streamedSamples.count - reference.samples.count) <= 480)
        #expect(abs(streamed.durationSec - reference.durationSec) < 0.05)

        // 16-bit WAV quantization alone caps this around 90 dB; the seams are
        // what we are really measuring.
        // ~43 dB in practice. The floor guards the grid alignment described in
        // Streaming.swift: a window or warmup that is not a whole number of
        // 200-frame model chunks drops this to ~12 dB.
        let agreement = snr(reference.samples, streamedSamples)
        #expect(agreement > 35, "streaming vs in-memory SNR was \(agreement) dB")
    }

    /// Mastering has to land on the same target as the in-memory path, which is
    /// the part the scratch-file round trip exists to preserve.
    @Test(.modelBacked) func streamingMasteringMatches() async throws {
        let clear = try await enhancer()
        let x = speechish(45)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clear-master-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.wav")
        let output = dir.appendingPathComponent("out.wav")
        try AudioIO.writeWAV(x, sampleRate: 48_000, to: input.path)

        let streamed = try await clear.enhance(path: input.path, to: output.path,
                                               options: .init(mastering: .applePodcasts))
        let written = try await AudioIO.decode(path: output.path, sampleRate: 48_000)
        let achieved = Loudness.integratedLUFS(written, sampleRate: 48_000)

        #expect(streamed.measuredLUFS != nil)
        if let achieved {
            // Landed on the preset target (-19 LUFS), give or take the gain cap
            // and quantization.
            #expect(abs(achieved - (-19)) < 1.5, "mastered to \(achieved) LUFS")
        }
    }

    /// The acceptance criterion for the whole exercise: doubling the input must
    /// not double the peak.
    @Test(.modelBacked) func peakDoesNotGrowWithDuration() async throws {
        let clear = try await enhancer()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clear-peak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var peaks: [Double] = []
        for seconds in [60.0, 240.0] {
            let input = dir.appendingPathComponent("in-\(Int(seconds)).wav")
            let output = dir.appendingPathComponent("out-\(Int(seconds)).wav")
            try AudioIO.writeWAV(speechish(seconds), sampleRate: 48_000, to: input.path)

            let before = footprintMB()
            let tracker = PeakTracker(start: before)
            _ = try await clear.enhance(path: input.path, to: output.path,
                                        options: .init(mastering: .applePodcasts)) { [tracker] _ in
                tracker.observe(TempFootprint.current())
            }
            let peak = tracker.peak
            peaks.append(peak - before)
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
            print(String(format: ">>> %.0fs: peak +%.0f MB", seconds, peak - before))
        }

        // 4x the audio. Whole-file processing would be ~4x the memory; windowed
        // processing should be roughly flat, so allow generous slack and still
        // catch a regression to linear growth.
        #expect(peaks[1] < peaks[0] + 150,
                "peak grew from \(peaks[0]) MB to \(peaks[1]) MB with 4x the audio")
    }
}

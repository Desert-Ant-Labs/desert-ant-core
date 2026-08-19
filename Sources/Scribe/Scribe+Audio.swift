#if canImport(CoreML)
import AudioIO
import CoreML
import Foundation

public extension Scribe {
    /// Transcribe an audio file. Any format `AudioIO` can decode is accepted and
    /// is downmixed and resampled to the rate the model expects.
    func transcribe(
        path: String,
        progress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Result {
        let samples = try await AudioIO.decode(path: path, sampleRate: sampleRate)
        guard !samples.isEmpty else {
            throw ScribeError.invalidAudio("\(path) decoded to no audio")
        }
        return try transcribe(samples: samples, progress: progress)
    }

    /// Transcribe an audio file at `url`.
    func transcribe(
        _ url: URL,
        progress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Result {
        try await transcribe(path: url.path, progress: progress)
    }

    /// Transcribe already-decoded audio at an arbitrary rate.
    func transcribe(
        samples: [Float],
        sampleRate rate: Double,
        progress: @Sendable (Progress) -> Void = { _ in }
    ) throws -> Result {
        let converted = rate == sampleRate
            ? samples
            : Resample.linear(samples, from: rate, to: sampleRate)
        return try transcribe(samples: converted, progress: progress)
    }
}
#endif

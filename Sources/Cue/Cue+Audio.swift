#if canImport(CoreML)
import AudioIO
import CoreML
import Foundation

public extension Cue {
    /// Detect speech in an audio file. Any format `AudioIO` can decode is
    /// accepted, and is downmixed and resampled to the rate the model expects.
    func detect(path: String,
                options: Options = .default,
                progress: @Sendable (Double) -> Void = { _ in }) async throws -> Result {
        let samples = try await AudioIO.decode(path: path, sampleRate: sampleRate)
        guard !samples.isEmpty else {
            throw CueError.invalidAudio("\(path) decoded to no audio")
        }
        return try detect(samples: samples, options: options, progress: progress)
    }

    /// Detect speech in the audio file at `url`.
    func detect(_ url: URL,
                options: Options = .default,
                progress: @Sendable (Double) -> Void = { _ in }) async throws -> Result {
        try await detect(path: url.path, options: options, progress: progress)
    }

    /// Detect speech in already-decoded audio at an arbitrary rate.
    func detect(samples: [Float],
                sampleRate rate: Double,
                options: Options = .default,
                progress: @Sendable (Double) -> Void = { _ in }) throws -> Result {
        let converted = rate == sampleRate
            ? samples
            : Resample.linear(samples, from: rate, to: sampleRate)
        return try detect(samples: converted, options: options, progress: progress)
    }
}
#endif

#if canImport(CoreML)
import AudioIO
import CoreML
import Foundation

public extension Voz {
    /// Transcribe an audio file. Any format `AudioIO` can decode is accepted and
    /// is downmixed and resampled to the rate the model expects.
    func transcribe(
        path: String,
        progress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Result {
        #if canImport(AVFoundation)
        // Read and convert as we go. Decoding the file up front costs 230 MB of
        // `Float` per hour of audio before the model has allocated anything.
        var stream = try FileAudioStream(url: URL(fileURLWithPath: path),
                                         sampleRate: sampleRate)
        let duration = Double(stream.totalSamples ?? 0) / sampleRate
        return try transcribe(stream: &stream, duration: duration, progress: progress)
        #else
        let samples = try await AudioIO.decode(path: path, sampleRate: sampleRate)
        guard !samples.isEmpty else {
            throw VozError.invalidAudio("\(path) decoded to no audio")
        }
        return try transcribe(samples: samples, progress: progress)
        #endif
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

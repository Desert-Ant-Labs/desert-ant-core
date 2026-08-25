import AudioIO
import DesertAnt
import Foundation

public extension Ear {
    /// Identify the language of an audio file.
    ///
    /// Any format `AudioIO` can decode is accepted, and is downmixed and
    /// resampled to the rate the model expects.
    ///
    /// ```swift
    /// let detection = try await Ear().identify(contentsOf: url)
    /// detection.language     // "pt"
    /// ```
    func identify(contentsOf url: URL, windows: Int = Ear.defaultWindows) async throws -> Detection {
        try await identify(path: url.path, windows: windows)
    }

    /// Identify the language of the audio file at `path`.
    func identify(path: String, windows: Int = Ear.defaultWindows) async throws -> Detection {
        let rate = try await modelSampleRate()
        let samples = try await AudioIO.decode(path: path, sampleRate: rate)
        guard !samples.isEmpty else { throw EarError.invalidAudio("\(path) decoded to no audio") }
        return try await identify(samples: samples, sampleRate: rate, windows: windows)
    }
}

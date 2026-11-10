import AudioIO
import DesertAnt
import Foundation

public extension Who {
    /// Who spoke when, from an audio file: any format `AudioIO` decodes, downmixed and resampled to the model's rate.
    func diarize(contentsOf url: URL, options: Options = Options()) async throws -> Diarization {
        try await diarize(path: url.path, options: options)
    }

    /// Who spoke when, from the audio file at `path`.
    func diarize(path: String, options: Options = Options()) async throws -> Diarization {
        let rate = try await modelSampleRate()
        let samples = try await AudioIO.decode(path: path, sampleRate: rate)
        guard !samples.isEmpty else { throw WhoError.invalidAudio("\(path) decoded to no audio") }
        return try await diarize(samples: samples, sampleRate: rate, options: options)
    }
}

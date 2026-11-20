import AudioIO
import DesertAnt
#if os(Android)
// Do not import Foundation on Android: it pulls in the full ICU payload.
// Use FoundationEssentials to keep ICU out of the SDK.
import FoundationEssentials
#else
import Foundation
#endif

public extension Who {
    /// Who spoke when, from an audio file: any format `AudioIO` decodes, downmixed and resampled to the model's rate.
    func diarize(contentsOf url: URL) async throws -> Diarization {
        try await diarize(path: url.path)
    }

    /// Who spoke when, from the audio file at `path`.
    func diarize(path: String) async throws -> Diarization {
        let rate = try await modelSampleRate()
        let samples = try await AudioIO.decode(path: path, sampleRate: rate)
        guard !samples.isEmpty else { throw WhoError.invalidAudio("\(path) decoded to no audio") }
        return try await diarize(samples: samples, sampleRate: rate)
    }
}

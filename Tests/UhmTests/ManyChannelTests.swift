import Testing
import AudioIO
import TestSupport
@testable import Uhm

/// A real 14-channel field-recorder capture crashed `analyze(audioPath:)`
/// (std::overflow_error out of the whole-file convert) and, decoded, carried
/// only channel 0. Both fixed in AudioIO's Apple backend (chunked convert,
/// explicit many-channel mixdown); this pins the contract at Uhm's level: a
/// many-channel file is analyzable audio like any other, not a crash.
#if canImport(CoreML)
@Suite(.serialized, .modelBacked)
struct ManyChannelTests {
    @Test func analyzesFourteenChannelAudio() async throws {
        // One second of near-silence across 14 channels: decode must survive
        // the layout, and near-silence must yield zero fillers rather than an
        // error or a truncated duration.
        let sr = 16000
        let channels = 14
        var interleaved = [Float](repeating: 0, count: sr * channels)
        for f in 0..<sr {
            for c in 0..<channels {
                interleaved[f * channels + c] = 0.001 * Float(f % 7)
            }
        }
        let wav = WAV.encode(interleaved, sampleRate: sr, channels: channels)
        let result = try await Uhm().analyze(bytes: wav)
        #expect(abs(result.audioDuration - 1.0) < 0.05,
                "14 channels of 1 s decoded to \(result.audioDuration) s")
        #expect(result.fillers.isEmpty, "near-silence has no fillers")
    }
}
#endif

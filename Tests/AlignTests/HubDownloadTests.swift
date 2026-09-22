#if !os(WASI)
import Foundation
import Testing
import TestSupport
@testable import Align

@Suite(.hubIntegration)
struct HubDownloadTests {
    @Test func downloadThenRefine() async throws {
        try await HubDownloadScenario.run(
            AlignModel.self,
            make: { Align(directory: $0) },
            isDownloaded: { $0.isDownloaded() },
            download: { try await $0.download(progress: $1) }
        ) { refiner, cached in
            let sr = 16_000
            let phase = 2 * Double.pi * 200 / Double(sr)
            let audio = (0..<(sr * 3)).map { i in 0.3 * Float(sin(phase * Double(i))) }
            let words = [WordTiming(text: "hola", start: 0.4, end: 0.71),
                         WordTiming(text: "mundo", start: 0.8, end: 1.3)]
            let out = try await refiner.refine(words, audio: audio, sampleRate: Double(sr), languageCode: "es")
            #expect(out.count == 2)
            #expect(out[0].start < out[0].end)
            // The second refiner reads the same directory with no network.
            let again = try await cached.refine(words, audio: audio, sampleRate: Double(sr), languageCode: "es")
            #expect(again.map(\.start) == out.map(\.start))
        }
    }
}
#endif

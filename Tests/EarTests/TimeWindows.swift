import Foundation
@testable import Ear
import Testing

struct WindowSelectionCost {
    @Test func rankingATenMinuteFileIsCheap() throws {
        let frontend = try FrontendTests.make()
        var audio = [Float](repeating: 0, count: 16000 * 600)
        for i in audio.indices { audio[i] = Float.random(in: -0.3...0.3) }
        let began = Date()
        _ = frontend.windowOffsets(audio, count: 3)
        let ms = Date().timeIntervalSince(began) * 1000
        print("  windowOffsets on 10 minutes: \(Int(ms)) ms")
        // 1 ms optimized, about 250 ms unoptimized. Detection itself is roughly
        // 45 ms of Neural Engine time, so selection has to stay well under that
        // in the build that ships; the debug bound is loose on purpose, because
        // a test that fails only in debug teaches people to ignore it.
        #if DEBUG
        #expect(ms < 2000)
        #else
        #expect(ms < 20)
        #endif
    }
}

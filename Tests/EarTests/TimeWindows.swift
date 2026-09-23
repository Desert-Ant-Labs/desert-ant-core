import Foundation
@testable import Ear
import Testing

// Wall-clock bounds flake on CI: runners have ~3 slow, shared cores, test:ios
// runs suites inside parallel simulator clones, and Swift Testing runs tests
// concurrently, so wall clock measures the scheduler. This measures thread CPU
// time (CLOCK_THREAD_CPUTIME_ID) instead, which is immune to contention and
// still catches selection going accidentally quadratic. That clock does not
// exist on Windows or wasm32-wasi, hence the #if.
//
// Disabled until it has a quiet stretch of manual runs behind it. Run it
// locally with:
//   swift test -c release --filter WindowSelectionCost
#if !os(Windows) && !os(WASI)
struct WindowSelectionCost {
    @Test(.disabled("timing bound under observation, see the header comment"))
    func rankingATenMinuteFileIsCheap() throws {
        let frontend = try FrontendTests.make()
        var audio = [Float](repeating: 0, count: 16000 * 600)
        for i in audio.indices { audio[i] = Float.random(in: -0.3...0.3) }
        // Thread CPU time, not wall clock; see the header.
        var begin = timespec(), end = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &begin)
        _ = frontend.windowOffsets(audio, count: 3)
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &end)
        let ms = (Double(end.tv_sec - begin.tv_sec) * 1_000
            + Double(end.tv_nsec - begin.tv_nsec) / 1_000_000)
        print("  windowOffsets on 10 minutes: \(Int(ms)) ms of thread CPU")
        // 1 ms optimized, about 250 ms unoptimized. Detection itself is roughly
        // 45 ms of Neural Engine time, so selection has to stay well under that
        // in the build that ships; the debug bound is loose on purpose, because
        // a test that fails only in debug teaches people to ignore it.
        #if DEBUG
        #expect(ms < 2000)
        #else
        #expect(ms < 100)
        #endif
    }
}
#endif

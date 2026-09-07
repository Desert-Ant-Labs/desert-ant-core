import Foundation
@testable import Ear
import Testing

// Disabled, with the full history, because this test burned four CI runs in
// one day and each fix taught us something worth keeping:
//
// - For most of its life CI only built debug, where the meaningful release
//   bound (20 ms) was dead code and the loose debug bound (2000 ms) was the
//   only thing running: a performance test that never measured the build that
//   ships.
// - When the pipeline moved to release, the 20 ms wall-clock bound flaked
//   immediately: CI runners have ~3 slow, shared cores.
// - Widening to 100 ms flaked again, because test:ios runs suites inside
//   parallel simulator clones and Swift Testing runs tests concurrently in
//   the same process, so wall clock measures the scheduler, not this code.
// - The rewrite below uses thread CPU time (CLOCK_THREAD_CPUTIME_ID), which
//   is immune to contention and concurrency and still catches the regression
//   this test guards, selection going accidentally quadratic. But that clock
//   does not exist on Windows or wasm32-wasi, where the suite also runs,
//   hence the #if that drops the file from those builds.
//
// The thread-CPU version is believed sound but has no CI history, and the
// branch it landed on is about CI stability, so it stays disabled until it
// has a quiet stretch of manual runs behind it. Run it locally with:
//   swift test -c release --filter WindowSelectionCost
#if !os(Windows) && !os(WASI)
struct WindowSelectionCost {
    @Test(.disabled("timing bound under observation, see the header comment"))
    func rankingATenMinuteFileIsCheap() throws {
        let frontend = try FrontendTests.make()
        var audio = [Float](repeating: 0, count: 16000 * 600)
        for i in audio.indices { audio[i] = Float.random(in: -0.3...0.3) }
        // Thread CPU time, not wall clock: CI runs this on contended shared
        // runners, inside parallel simulator clones, concurrently with other
        // suites in the same process. Wall-clock bounds there measure the
        // scheduler (a 100 ms bound flaked at both 20 ms and 100 ms), while
        // the regression this test guards, selection going accidentally
        // quadratic, is a CPU-time property of this thread alone.
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

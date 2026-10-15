#if os(macOS)
import Darwin
import Foundation

/// The process's physical footprint while a stretch of work runs, sampled every few milliseconds on its own thread.
/// The process's lifetime peak would do, but it never resets, so a second measurement would repeat the first's.
final class FootprintWatch: @unchecked Sendable {
    let baseline: Int
    private let lock = NSLock()
    private var peak: Int
    private var running = true

    init(every interval: TimeInterval = 0.005) {
        baseline = FootprintWatch.footprint()
        peak = baseline
        let thread = Thread { [self] in
            while true {
                lock.lock()
                let go = running
                lock.unlock()
                if !go { break }
                let now = FootprintWatch.footprint()
                lock.lock()
                peak = max(peak, now)
                lock.unlock()
                Thread.sleep(forTimeInterval: interval)
            }
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Stops sampling and returns the peak footprint seen, in bytes.
    func stop() -> Int {
        lock.lock()
        defer { lock.unlock() }
        running = false
        peak = max(peak, FootprintWatch.footprint())
        return peak
    }

    static func footprint() -> Int {
        var info = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, rebound)
            }
        }
        return ok == 0 ? Int(info.ri_phys_footprint) : 0
    }

    static func text(_ bytes: Int) -> String {
        String(format: "%.2f GB", Double(bytes) / Double(1 << 30))
    }
}
#endif

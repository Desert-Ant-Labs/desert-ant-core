// Progress accounting for concurrent file downloads. A lock rather than an
// actor because `ModelTransport.download` reports bytes from a synchronous
// callback (URLSession's delegate, the Android host's C callback), which cannot
// suspend to `await` an actor.

#if os(WASI)
/// wasm is single-threaded, so there is nothing to guard.
private struct CounterLock {
    func lock() {}
    func unlock() {}
}
#else
#if os(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Raw pthread rather than `NSLock`, to keep this module Foundation-free.
private final class CounterLock {
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    init() { pthread_mutex_init(mutex, nil) }
    deinit { pthread_mutex_destroy(mutex); mutex.deallocate() }
    func lock() { pthread_mutex_lock(mutex) }
    func unlock() { pthread_mutex_unlock(mutex) }
}
#endif

/// Sums per-file byte counts into one whole-model ``DownloadProgress``.
///
/// Each file reports its own cumulative bytes, so the sum is monotonic no
/// matter what order concurrent downloads make progress in.
final class DownloadProgressCounter: @unchecked Sendable {
    private let lock = CounterLock()
    private let totalBytes: Int64
    private let report: @Sendable (DownloadProgress) -> Void
    private var perFile: [Int64]

    init(fileCount: Int, totalBytes: Int64, report: @escaping @Sendable (DownloadProgress) -> Void) {
        self.totalBytes = totalBytes
        self.report = report
        perFile = [Int64](repeating: 0, count: fileCount)
    }

    /// Record `bytes` as the cumulative total downloaded for file `index`, and
    /// report the new whole-model total. Reporting happens outside the lock so
    /// a slow consumer never blocks another file's transfer.
    func record(file index: Int, bytes: Int64) {
        lock.lock()
        perFile[index] = bytes
        var completed: Int64 = 0
        for value in perFile { completed += value }
        lock.unlock()
        report(DownloadProgress(completedBytes: completed, totalBytes: totalBytes))
    }
}

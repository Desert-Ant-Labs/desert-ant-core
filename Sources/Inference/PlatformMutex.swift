// A minimal mutual-exclusion lock for the threaded platforms: pthread on
// POSIX (Apple/Linux/Android), SRWLOCK on Windows (which has no pthread).
// WASI is single-threaded and never allocates one (callers gate on os(WASI)).
#if !os(WASI)

#if os(Windows)
import WinSDK
#elseif os(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// A heap-allocated mutex with stable storage, safe to share across threads.
/// `lock`/`unlock` mirror the pthread call shape so call sites stay unchanged.
final class PlatformMutex: @unchecked Sendable {
    #if os(Windows)
    private var mutex = SRWLOCK()
    init() { InitializeSRWLock(&mutex) }
    func lock() { AcquireSRWLockExclusive(&mutex) }
    func unlock() { ReleaseSRWLockExclusive(&mutex) }
    #else
    private var mutex = pthread_mutex_t()
    init() { pthread_mutex_init(&mutex, nil) }
    deinit { pthread_mutex_destroy(&mutex) }
    func lock() { pthread_mutex_lock(&mutex) }
    func unlock() { pthread_mutex_unlock(&mutex) }
    #endif
}
#endif

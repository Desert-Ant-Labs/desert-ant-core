// Process-wide SDK configuration set by the host app in code, for platforms
// where an environment variable is not a natural fit (an iOS or Android app
// has no launch environment of its own).

#if !os(WASI)
import Dispatch
#endif

/// Process-wide Desert Ant configuration.
///
/// Set once at launch, before the first model session is created:
///
/// ```swift
/// DesertAnt.apiKey = "pk_live_..."
/// ```
///
/// The key is read when a usage client is built (lazily, on a session's first
/// run), so a value set after that does not retroactively re-attribute clients
/// already built. When unset, resolution falls back to the `DAL_API_KEY`
/// environment variable (`__dalApiKey` on JS hosts), and with neither present
/// attribution uses the app identity instead. See `hostProvidedApiKey()`.
public enum DesertAnt {
    /// The publishable API key used for usage attribution, shared by every
    /// model SDK in the process. `nil` (the default) means "not set in code";
    /// an empty string is treated as unset.
    public static var apiKey: String? {
        get { withLock { storedApiKey } }
        set { withLock { storedApiKey = newValue } }
    }

    /// Whether usage events carry the device `context` (OS, model, locale and
    /// the like; see `DeviceContext`). `true` by default. Setting it to `false`
    /// sends usage without context, the in-code form of the
    /// `DAL_USAGE_CONTEXT_DISABLED` flag. Read per event, so it applies from
    /// the next send on. An Android app, which has no Swift of its own, sets
    /// `HostBridge.sendsDeviceContext = false` in Kotlin instead.
    public static var sendsDeviceContext: Bool {
        get { withLock { storedSendsDeviceContext } }
        set { withLock { storedSendsDeviceContext = newValue } }
    }

    // A launch-time write and per-client reads make contention irrelevant, but
    // the accessors still have to be data-race free under Swift 6, and the
    // package floor (iOS 17) predates Synchronization.Mutex.
    private nonisolated(unsafe) static var storedApiKey: String?
    private nonisolated(unsafe) static var storedSendsDeviceContext = true

#if os(WASI)
    // Single-threaded host, nothing to lock.
    private static func withLock<T>(_ body: () -> T) -> T { body() }
#else
    private static let lock = DispatchSemaphore(value: 1)

    private static func withLock<T>(_ body: () -> T) -> T {
        lock.wait()
        defer { lock.signal() }
        return body()
    }
#endif
}

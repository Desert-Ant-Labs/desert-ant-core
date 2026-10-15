// Process-wide SDK configuration set by the host app in code, for platforms
// where an environment variable is not a natural fit (an iOS or Android app
// has no launch environment of its own).

#if !os(WASI)
import Dispatch
#endif

/// Process-wide Desert Ant configuration.
///
/// Set once at launch, before the first model loads:
///
/// ```swift
/// DesertAnt.apiKey = "pk_live_..."
/// ```
///
/// The key is read on each model load, when the SDK requests or activates that
/// model's license. When unset, resolution falls back to the `DAL_API_KEY`
/// environment variable (`__dalApiKey` on JS hosts), and with neither present
/// the license is activated without a key. See `hostProvidedApiKey()`.
public enum DesertAnt {
    /// The publishable API key sent with license grants and activations, shared by every
    /// model SDK in the process. `nil` (the default) means "not set in code";
    /// an empty string is treated as unset.
    public static var apiKey: String? {
        get { withLock { storedApiKey } }
        set { withLock { storedApiKey = newValue } }
    }

    @available(*, deprecated, message: "Has no effect. The SDK sends no device context.")
    public static var sendsDeviceContext: Bool {
        get { withLock { storedSendsDeviceContext } }
        set { withLock { storedSendsDeviceContext = newValue } }
    }

    /// Whether models compile faster for the Neural Engine on the M6 and A20 Pro.
    /// `true` by default. On an iPhone 18 Pro, Voz's first load takes 9.5s with
    /// this setting and 33.4s without it. Predictions and outputs are the same
    /// either way.
    ///
    /// This setting uses a private Core ML API. To use only public APIs, set it
    /// to `false` before the first model loads:
    ///
    /// ```swift
    /// DesertAnt.fasterNeuralEngineCompile = false
    /// ```
    ///
    /// Core ML caches each compiled model by its compiler options, so changing
    /// this setting makes each model compile again on its next load.
    public static var fasterNeuralEngineCompile: Bool {
        get { withLock { storedFasterNeuralEngineCompile } }
        set { withLock { storedFasterNeuralEngineCompile = newValue } }
    }

    // Rare writes and per-call reads make contention irrelevant, but
    // the accessors still have to be data-race free under Swift 6, and the
    // package floor (iOS 17) predates Synchronization.Mutex.
    private nonisolated(unsafe) static var storedApiKey: String?
    private nonisolated(unsafe) static var storedSendsDeviceContext = true
    private nonisolated(unsafe) static var storedFasterNeuralEngineCompile = true

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

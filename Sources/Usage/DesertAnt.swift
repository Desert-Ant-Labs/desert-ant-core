// Process-wide SDK configuration that the host app sets in code with DesertAnt.configure.

#if !os(WASI)
import Dispatch
#endif
import PlatformSupport

/// Process-wide Desert Ant configuration.
///
/// Call once at launch, before the first model loads:
///
/// ```swift
/// DesertAnt.configure(apiKey: "dal_...")
/// ```
public enum DesertAnt {
    /// Sets the API key, replacing an earlier one.
    public static func configure(apiKey: String) {
        withLock { storedApiKey = apiKey }
    }

    /// Sets the API key and the device id secret, for a process that serves many devices, such
    /// as a server. Do not use it in an app that ships to users: a secret in an app is public.
    ///
    /// The secret is 32 or more random bytes as text, kept on the server and never changed. The
    /// SDK uses it to turn each call's device id into the install id it sends. The device id
    /// never leaves the server, and only the holder of the secret can link the two.
    public static func configure(apiKey: String, deviceIdSecret: String) {
        if trimmedKey(deviceIdSecret) == nil {
            Log.warning("DesertAnt.configure was given a blank deviceIdSecret, so device ids are hashed without a secret.")
        }
        withLock {
            storedApiKey = apiKey
            storedDeviceIdSecret = deviceIdSecret
        }
    }

    package static var configuredApiKey: String? { withLock { storedApiKey } }

    package static var configuredDeviceIdSecret: String? { trimmedKey(withLock { storedDeviceIdSecret }) }

    // For the JavaScript bindings, which pass the key and the secret with one call each, and for tests.
    /// Sends the license requests that wait, before a process exits. False when device licenses are left.
    @discardableResult
    public static func flushLicenses() async -> Bool {
        await LicenseFlush.shared.flushAndWait()
    }

    package static func configure(deviceIdSecret: String?) {
        withLock { storedDeviceIdSecret = deviceIdSecret }
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

    /// The least severe level the SDK writes: `.debug`, `.info`, `.warning`,
    /// `.error` or `.off`. `.warning` unless `DAL_LOG_LEVEL` says otherwise.
    /// Set it at any time.
    public static var logLevel: LogLevel {
        get { Log.level }
        set { Log.level = newValue }
    }

    /// Where every message the SDK and its runtimes write goes, as
    /// `(level, source, message)`, instead of the platform's log. `nil` (the
    /// default) is the platform's log.
    ///
    /// ```swift
    /// DesertAnt.logger = { level, source, message in myLogger.log("\(source): \(message)") }
    /// ```
    public static var logger: LogHandler? {
        get { Log.handler }
        set { Log.handler = newValue }
    }

    // Rare writes and per-call reads make contention irrelevant, but
    // the accessors still have to be data-race free under Swift 6, and the
    // package floor (iOS 17) predates Synchronization.Mutex.
    private nonisolated(unsafe) static var storedApiKey: String?
    private nonisolated(unsafe) static var storedDeviceIdSecret: String?
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

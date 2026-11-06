// Every message the SDK writes, and every message a runtime it drives writes,
// goes through here: the SDK's own notes, LiteRT's setup lines on Linux and
// Windows, ONNX Runtime's messages on Windows, the HTTP client's traces. One
// level gates them all and one handler receives them all, so a host decides
// once where SDK output goes and how much of it there is, on every platform
// and for every runtime.
//
// The platform's own log is the default sink: the unified log on Apple
// platforms (Xcode's console and Console.app show it), standard error on Linux
// and Windows, logcat on Android, the console in a browser and in Node's wasm
// path. A host that wants the messages somewhere else installs a handler and
// the default sink is not used.
//
// The default level is `warning`. `DAL_LOG_LEVEL` sets another one before the
// first message, and `DesertAnt.logLevel` at any time, on every platform.

import CStrings

#if os(Android)
import Android
import CHostBridge
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#elseif os(Windows)
import CRT
#endif
#if os(WASI)
import JavaScriptKit
#else
import Dispatch
#endif
#if canImport(os)
import os
#endif

/// How much the SDK says, from the most talkative to silent.
public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    /// Nothing, from the SDK or from a runtime it drives.
    case off = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The level a setting names: `debug`, `info`, `warning`, `error` or
    /// `off`, in any case. `warn`, `verbose`, `silent` and `none` are read as
    /// the level they mean, so a value copied from another tool's setting works.
    public init?(name: String) {
        switch name.lowercased() {
        case "debug", "verbose": self = .debug
        case "info": self = .info
        case "warning", "warn": self = .warning
        case "error": self = .error
        case "off", "silent", "none": self = .off
        default: return nil
        }
    }

    /// The name a setting uses for this level, upper-cased on the default sink.
    public var name: String {
        switch self {
        case .debug: return "debug"
        case .info: return "info"
        case .warning: return "warning"
        case .error: return "error"
        case .off: return "off"
        }
    }
}

/// What a host installs to receive every message instead of the platform's
/// log. `source` names what wrote it: `core`, `http`, `litert`, `onnxruntime`,
/// or a model's id. Called on whatever thread logged, which may be a runtime's
/// worker.
public typealias LogHandler = @Sendable (_ level: LogLevel, _ source: String, _ message: String) -> Void

/// The SDK's log. See the file comment for what goes through it and where it
/// ends up. A host sets the level and the handler through `DesertAnt.logLevel`
/// and `DesertAnt.logger`; they are these two properties.
public enum Log {
    /// The least severe level that is written. `warning` unless `DAL_LOG_LEVEL`
    /// (or a host SDK's setting) says otherwise.
    public static var level: LogLevel {
        get { withLock { resolvedLevel() } }
        set { withLock { storedLevel = newValue } }
    }

    /// Where messages go. `nil` (the default) is the platform's own log.
    public static var handler: LogHandler? {
        get { withLock { storedHandler } }
        set { withLock { storedHandler = newValue } }
    }

    public static func debug(_ message: @autoclosure () -> String, source: String = "core") {
        log(.debug, message(), source: source)
    }

    public static func info(_ message: @autoclosure () -> String, source: String = "core") {
        log(.info, message(), source: source)
    }

    public static func warning(_ message: @autoclosure () -> String, source: String = "core") {
        log(.warning, message(), source: source)
    }

    public static func error(_ message: @autoclosure () -> String, source: String = "core") {
        log(.error, message(), source: source)
    }

    /// Whether a message at `level` would be written, for a caller whose
    /// message is expensive to build.
    public static func isEnabled(_ level: LogLevel) -> Bool {
        level != .off && level >= self.level
    }

    public static func log(_ level: LogLevel, _ message: @autoclosure () -> String, source: String = "core") {
        guard isEnabled(level) else { return }
        let text = message()
        if let handler {
            handler(level, source, text)
        } else {
            platformLog(level, source: source, message: text)
        }
    }

    // Rare writes and a read per message. The accessors have to be data-race
    // free under Swift 6, and the package floor (iOS 17) predates
    // Synchronization.Mutex, so a semaphore guards them as in `DesertAnt`.
    private nonisolated(unsafe) static var storedLevel: LogLevel?
    private nonisolated(unsafe) static var storedHandler: LogHandler?

    private static func resolvedLevel() -> LogLevel {
        if let storedLevel { return storedLevel }
        let level = configuredLevel() ?? .warning
        storedLevel = level
        return level
    }

#if os(WASI)
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

// MARK: the configured level and the platform's log

#if os(WASI)

// `globalThis.__dalLogLevel`, a level name, like the other `__dal*` host settings.
private func configuredLevel() -> LogLevel? {
    JSObject.global.__dalLogLevel.string.flatMap(LogLevel.init(name:))
}

// `globalThis.__dalLog(level, source, message)` when the host set one, else the
// console at the matching severity.
private func platformLog(_ level: LogLevel, source: String, message: String) {
    if let handler = JSObject.global.__dalLog.function {
        _ = try? handler.throws(level.name.jsValue, source.jsValue, message.jsValue)
        return
    }
    guard let console = JSObject.global.console.object else { return }
    let method: String
    switch level {
    case .debug: method = "debug"
    case .info: method = "info"
    case .warning: method = "warn"
    case .error, .off: method = "error"
    }
    _ = console[dynamicMember: method].function?("[desert-ant] \(source): \(message)".jsValue)
}

#elseif os(Android)

// The level the Kotlin host set (`DesertAnt.logLevel`); -1 when it set none.
private func configuredLevel() -> LogLevel? {
    LogLevel(rawValue: Int(host_log_level()))
}

// The Kotlin host's logger when it installed one (`DesertAnt.logger`, or
// android.util.Log behind it), else logcat directly.
private func platformLog(_ level: LogLevel, source: String, message: String) {
    let delivered = source.withCString { source in
        message.withCString { message in
            host_log(Int32(level.rawValue), source, message)
        }
    }
    if delivered != 0 { return }
    let priority: Int32
    switch level {
    case .debug: priority = Int32(ANDROID_LOG_DEBUG.rawValue)
    case .info: priority = Int32(ANDROID_LOG_INFO.rawValue)
    case .warning: priority = Int32(ANDROID_LOG_WARN.rawValue)
    case .error, .off: priority = Int32(ANDROID_LOG_ERROR.rawValue)
    }
    _ = __android_log_write(priority, "DesertAnt", "\(source): \(message)")
}

#else

private func configuredLevel() -> LogLevel? {
    environmentVariable("DAL_LOG_LEVEL").flatMap(LogLevel.init(name:))
}

#if canImport(os)
// The unified log, subsystem `ai.desertant` with the source as the category, so
// Console.app and `log stream --predicate 'subsystem == "ai.desertant"'` filter
// on either. Public, as a log is for reading: the SDK never logs personal data.
// A tool run from a terminal would show nothing, so when standard error is one
// the line goes there too (under Xcode it is not, so nothing shows twice).
private func platformLog(_ level: LogLevel, source: String, message: String) {
    let logger = Logger(subsystem: "ai.desertant", category: source)
    switch level {
    case .debug: logger.debug("\(message, privacy: .public)")
    case .info: logger.info("\(message, privacy: .public)")
    case .warning: logger.notice("\(message, privacy: .public)")
    case .error, .off: logger.error("\(message, privacy: .public)")
    }
    if isatty(2) != 0 { writeLine(level, source: source, message: message) }
}
#else
private func platformLog(_ level: LogLevel, source: String, message: String) {
    writeLine(level, source: source, message: message)
}
#endif

// One line on standard error, which a terminal shows for a tool. The whole
// line in one write, straight to the descriptor: a message from a runtime's
// worker thread must not interleave with another thread's, and `stderr` the
// stream is shared mutable state to Swift 6.
private func writeLine(_ level: LogLevel, source: String, message: String) {
    let line = Array("[desert-ant] \(level.name.uppercased()) \(source): \(message)\n".utf8)
    line.withUnsafeBytes { bytes in
#if os(Windows)
        _ = _write(2, bytes.baseAddress, UInt32(bytes.count))
#else
        _ = write(2, bytes.baseAddress, bytes.count)
#endif
    }
}

#endif

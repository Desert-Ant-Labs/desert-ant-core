#if canImport(Foundation) && !os(Android) && !os(WASI)
import Foundation

/// Errors with one human-readable `message`. Where Foundation exists this is
/// also `LocalizedError` (so `localizedDescription` and alerts show the
/// message); on Foundation-free platforms (Android, wasm) it is plain `Error`.
/// Model SDK error types conform to this instead of writing a per-platform
/// `LocalizedError` extension.
public protocol MessageError: LocalizedError {
    var message: String { get }
}

public extension MessageError {
    var errorDescription: String? { message }
}
#else
public protocol MessageError: Error {
    var message: String { get }
}
#endif

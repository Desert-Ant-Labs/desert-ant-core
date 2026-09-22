import CStrings

#if os(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#elseif os(Windows)
import CRT
#endif

/// Read a process environment variable without importing Foundation or a
/// platform C module in model code.
public func environmentVariable(_ name: String) -> String? {
    name.withCString { key in
#if os(Windows)
        // The MSVC CRT deprecates getenv (every call site warns), and its
        // replacement returns a heap copy the caller owns. A missing variable
        // is a zero return with a nil buffer, not an error.
        var buffer: UnsafeMutablePointer<CChar>? = nil
        var length = 0
        guard _dupenv_s(&buffer, &length, key) == 0, let buffer else { return nil }
        defer { free(buffer) }
        return decodeCString(buffer)
#else
        return getenv(key).map { decodeCString($0) }
#endif
    }
}

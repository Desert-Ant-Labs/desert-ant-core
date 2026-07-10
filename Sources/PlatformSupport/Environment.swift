#if os(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Read a process environment variable without importing Foundation or a
/// platform C module in model code.
public func environmentVariable(_ name: String) -> String? {
    name.withCString { key in
        getenv(key).map { String(cString: $0) }
    }
}

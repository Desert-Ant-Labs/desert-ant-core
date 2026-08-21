// Foundation-free time and identity helpers, using the C runtime the same way
// PlatformSupport's Environment/HTTPClient do, so this target stays Embedded-safe.

#if canImport(Darwin)
import Darwin
#elseif os(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#elseif os(Windows)
import WinSDK
#endif

/// Wall-clock time in epoch milliseconds. Used as the client's `now`.
public func systemNowMs() -> Int64 {
    #if os(Windows)
    // FILETIME is 100 ns ticks since 1601-01-01; rebase to the Unix epoch.
    var ft = FILETIME()
    GetSystemTimeAsFileTime(&ft)
    let ticks = (Int64(ft.dwHighDateTime) << 32) | Int64(ft.dwLowDateTime)
    return (ticks - 116_444_736_000_000_000) / 10_000
    #else
    var tv = timeval()
    gettimeofday(&tv, nil)
    return Int64(tv.tv_sec) * 1000 + Int64(tv.tv_usec) / 1000
    #endif
}

/// Format epoch milliseconds as an ISO-8601 UTC timestamp, e.g.
/// `2024-01-02T03:04:05.678Z` (the shape the ingest endpoint expects).
public func iso8601(epochMs: Int64) -> String {
    #if os(Windows)
    let ticks = UInt64(epochMs) * 10_000 &+ 116_444_736_000_000_000
    var ft = FILETIME(dwLowDateTime: DWORD(truncatingIfNeeded: ticks),
                      dwHighDateTime: DWORD(truncatingIfNeeded: ticks >> 32))
    var st = SYSTEMTIME()
    FileTimeToSystemTime(&ft, &st)
    let millis = Int(((epochMs % 1000) + 1000) % 1000)
    return
        pad(Int(st.wYear), 4) + "-" + pad(Int(st.wMonth), 2) + "-" + pad(Int(st.wDay), 2) +
        "T" + pad(Int(st.wHour), 2) + ":" + pad(Int(st.wMinute), 2) +
        ":" + pad(Int(st.wSecond), 2) + "." + pad(millis, 3) + "Z"
    #else
    var seconds = time_t(epochMs / 1000)
    var parts = tm()
    gmtime_r(&seconds, &parts)
    let millis = Int(((epochMs % 1000) + 1000) % 1000)

    let year = Int(parts.tm_year) + 1900
    let month = Int(parts.tm_mon) + 1
    return
        pad(year, 4) + "-" + pad(month, 2) + "-" + pad(Int(parts.tm_mday), 2) +
        "T" + pad(Int(parts.tm_hour), 2) + ":" + pad(Int(parts.tm_min), 2) +
        ":" + pad(Int(parts.tm_sec), 2) + "." + pad(millis, 3) + "Z"
    #endif
}

/// A random RFC 4122 v4 UUID, using the Swift stdlib system RNG (no Foundation).
public func generateUUID() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
    bytes[6] = (bytes[6] & 0x0F) | 0x40 // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80 // variant 1

    let hex = Array("0123456789abcdef".unicodeScalars)
    var out = ""
    for (i, b) in bytes.enumerated() {
        if i == 4 || i == 6 || i == 8 || i == 10 { out.unicodeScalars.append("-") }
        out.unicodeScalars.append(hex[Int(b >> 4)])
        out.unicodeScalars.append(hex[Int(b & 0x0F)])
    }
    return out
}

private func pad(_ value: Int, _ width: Int) -> String {
    var s = String(value)
    while s.count < width { s = "0" + s }
    return s
}

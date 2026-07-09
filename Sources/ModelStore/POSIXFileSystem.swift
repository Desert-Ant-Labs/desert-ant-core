// A `FileSystem` over raw POSIX (open/read/write/rename/mkdir/stat/unlink), no
// Foundation. This is the Android filesystem backend; because POSIX is
// identical on Linux, the exact same code is exercised by the tests on the host.
#if os(Android) || canImport(Glibc) || canImport(Darwin)

#if os(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// File-scope wrappers so `read`/`write` resolve to the POSIX globals, not the
// FileSystem methods of the same name.
private func posixRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ n: Int) -> Int { read(fd, buf, n) }
private func posixWrite(_ fd: Int32, _ buf: UnsafeRawPointer?, _ n: Int) -> Int { write(fd, buf, n) }

public struct POSIXFileSystem: FileSystem {
    private let cacheRoot: String

    /// - Parameter cacheRoot: the default cache directory (on Android, the app's
    ///   cacheDir path supplied by the host).
    public init(cacheRoot: String) { self.cacheRoot = cacheRoot }

    public func defaultCacheRoot() -> String { cacheRoot }

    public func exists(_ path: String) -> Bool { access(path, F_OK) == 0 }

    public func size(_ path: String) -> Int64? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Int64(st.st_size)
    }

    public func read(_ path: String) throws -> [UInt8] {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw ModelStoreError.io("open(\(path))") }
        defer { close(fd) }
        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = buf.withUnsafeMutableBytes { posixRead(fd, $0.baseAddress, $0.count) }
            if n < 0 { throw ModelStoreError.io("read(\(path))") }
            if n == 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    public func write(_ path: String, _ bytes: [UInt8]) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw ModelStoreError.io("create(\(path))") }
        defer { close(fd) }
        var offset = 0
        try bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let n = posixWrite(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { throw ModelStoreError.io("write(\(path))") }
                offset += n
            }
        }
    }

    public func makeDirectory(_ path: String) throws {
        // mkdir -p: create each component, tolerating EEXIST.
        var partial = path.hasPrefix("/") ? "" : "."
        for comp in path.split(separator: "/") {
            partial += "/" + comp
            if mkdir(partial, 0o755) != 0 && errno != EEXIST {
                throw ModelStoreError.io("mkdir(\(partial))")
            }
        }
    }

    public func move(_ from: String, to: String) throws {
        unlink(to)  // rename onto an existing file is atomic, but be explicit
        if rename(from, to) != 0 { throw ModelStoreError.io("rename(\(from) -> \(to))") }
    }

    public func remove(_ path: String) { unlink(path) }
}
#endif

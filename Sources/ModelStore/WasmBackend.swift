// wasm backend: HTTP via JS `fetch`; filesystem via node's `fs` (whose *Sync
// methods match the synchronous FileSystem seam) on node, or an in-memory store
// in the browser (browser persistence is async - OPFS/Cache API - and would need
// its own backend; the browser HTTP cache covers refetch for now). The download
// and SHA-256 verification are the shared Swift ModelStore on every platform.
#if os(WASI)
import JavaScriptKit
import JavaScriptEventLoop

/// Whether we are running under node (vs a browser).
public func jsIsNode() -> Bool {
    JSObject.global.process.object?.versions.object?.node.string != nil
}

/// In-memory filesystem for the browser, where there is no synchronous disk.
/// A class so writes made by the transport are visible to the store and to the
/// caller that reads the files back after downloading.
public final class MemoryFileSystem: FileSystem, @unchecked Sendable {
    private let cacheRoot: String
    private var files: [String: [UInt8]] = [:]

    public init(cacheRoot: String) { self.cacheRoot = cacheRoot }
    public func defaultCacheRoot() -> String { cacheRoot }
    public func exists(_ path: String) -> Bool { files[path] != nil }
    public func size(_ path: String) -> Int64? { files[path].map { Int64($0.count) } }
    public func read(_ path: String) throws -> [UInt8] {
        guard let b = files[path] else { throw ModelStoreError.io("read(\(path))") }
        return b
    }
    public func write(_ path: String, _ bytes: [UInt8]) throws { files[path] = bytes }
    public func makeDirectory(_ path: String) throws {}
    public func move(_ from: String, to: String) throws {
        guard let b = files[from] else { throw ModelStoreError.io("move(\(from))") }
        files[to] = b; files[from] = nil
    }
    public func remove(_ path: String) { files[path] = nil }
}


/// node `fs` (sync) filesystem. The host injects node's `fs` as
/// `globalThis.__DalNodeFS` (a small object of the *Sync methods) - there is no
/// `require` under the WASI shim - so this is just the platform's file seam; the
/// download and verification logic stay in the shared Swift ModelStore.
public struct JSFileSystem: FileSystem {
    private let cacheRoot: String
    private var fs: JSObject { JSObject.global.__DalNodeFS.object! }

    public init(cacheRoot: String) { self.cacheRoot = cacheRoot }
    public func defaultCacheRoot() -> String { cacheRoot }

    public func exists(_ path: String) -> Bool { fs.existsSync!(path).boolean ?? false }

    public func size(_ path: String) -> Int64? {
        // statSync throws (a JS exception) on a missing path; guard with exists.
        guard exists(path), let st = fs.statSync?(path).object, let n = st.size.number else { return nil }
        return Int64(n)
    }

    public func read(_ path: String) throws -> [UInt8] {
        // readFileSync throws a JS exception on a missing path, which does not
        // surface as a catchable Swift error; convert it to one so the store's
        // `try? read(...)` (e.g. the manifest probe) works.
        guard exists(path) else { throw ModelStoreError.io("read(\(path)) missing") }
        guard let arr = JSTypedArray<UInt8>(from: fs.readFileSync!(path)) else {
            throw ModelStoreError.io("readFileSync(\(path))")
        }
        return arr.withUnsafeBytes { Array($0) }
    }

    public func write(_ path: String, _ bytes: [UInt8]) throws {
        _ = fs.writeFileSync!(path, JSTypedArray<UInt8>(bytes).jsValue)
    }

    public func makeDirectory(_ path: String) throws {
        let opts = JSObject.global.Object.function!.new()
        opts.recursive = true.jsValue
        _ = fs.mkdirSync!(path, opts.jsValue)
    }

    public func move(_ from: String, to: String) throws { _ = fs.renameSync!(from, to) }
    // unlinkSync throws (a JS exception) on a missing path; only unlink if present.
    public func remove(_ path: String) { if exists(path) { _ = fs.unlinkSync?(path) } }
}

// Opt-in verbose logging for the WASM model-download transport, enabled from JS
// by setting `globalThis.__dalHttpDebug = true`. Logs go to `console.log`.
private func jsTransportDebugEnabled() -> Bool {
    JSObject.global.__dalHttpDebug.boolean ?? false
}

private func jsTransportDebugLog(_ message: @autoclosure () -> String) {
    guard jsTransportDebugEnabled() else { return }
    _ = JSObject.global.console.object?.log?("[DAL HTTP] \(message())".jsValue)
}

/// JS `fetch` transport. Writes downloaded bytes through the store's filesystem
/// so the same code path caches to node's `fs` or the browser's memory store.
public struct JSTransport: ModelTransport {
    private let fileSystem: FileSystem
    public init(fileSystem: FileSystem) { self.fileSystem = fileSystem }

    public func tree(_ url: String) async throws -> [RemoteEntry] {
        jsTransportDebugLog("tree \(url)")
        let resp = try await fetch(url, .undefined)
        guard let jsonPromise = JSPromise(from: resp.json!()) else { throw ModelStoreError.io("json(\(url))") }
        let arr = try await jsonPromise.value
        let n = Int(arr.length.number ?? 0)
        var out: [RemoteEntry] = []
        for i in 0..<n {
            let e = arr[i]
            guard e.type.string == "file" else { continue }
            let sha = e.lfs.object?.oid.string
            out.append(RemoteEntry(path: e.path.string ?? "", size: Int64(e.size.number ?? 0), sha256: sha))
        }
        return out
    }

    public func download(_ url: String, to destinationPath: String, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        jsTransportDebugLog("download \(url) -> \(destinationPath)")
        let resp = try await fetch(url, .undefined)
        // Stream the body for fine-grained progress: read the ReadableStream
        // chunk by chunk, reporting cumulative bytes, then write the file.
        if let body = resp.body.object, let reader = body.getReader?().object {
            var all = [UInt8]()
            while true {
                guard let readPromise = JSPromise(from: reader.read!()) else { throw ModelStoreError.io("read(\(url))") }
                let result = try await readPromise.value
                if result.done.boolean == true { break }
                if let chunk = JSTypedArray<UInt8>(from: result.value) {
                    chunk.withUnsafeBytes { all.append(contentsOf: $0) }
                    onBytes(Int64(all.count))
                }
            }
            try fileSystem.write(destinationPath, all)
            return
        }
        // Fallback (no streaming body): whole-body arrayBuffer.
        guard let bufPromise = JSPromise(from: resp.arrayBuffer!()) else { throw ModelStoreError.io("arrayBuffer(\(url))") }
        let u8 = JSObject.global.Uint8Array.function!.new(try await bufPromise.value)
        guard let arr = JSTypedArray<UInt8>(from: u8) else { throw ModelStoreError.io("bytes(\(url))") }
        let bytes = arr.withUnsafeBytes { Array($0) }
        try fileSystem.write(destinationPath, bytes)
        onBytes(Int64(bytes.count))
    }

    private func fetch(_ url: String, _ opts: JSValue) async throws -> JSObject {
        jsTransportDebugLog("fetch \(url)")
        guard let promise = JSPromise(from: JSObject.global.fetch.function!(url, opts)) else {
            throw ModelStoreError.io("fetch(\(url))")
        }
        let value = try await promise.value
        let status = Int(value.object?.status.number ?? 0)
        jsTransportDebugLog("fetch \(url) -> status \(status)")
        guard let resp = value.object, (resp.ok.boolean ?? false) || (resp.status.number ?? 0) < 400 else {
            throw ModelStoreError.io("fetch(\(url)) not ok")
        }
        return resp
    }
}

public extension StoredModel {
    static func platformLocal(rootPath: String) throws -> StoredModel {
        guard jsIsNode() else {
            throw ModelStoreError.io("local model directories are only available under node")
        }
        return StoredModel(rootPath: rootPath, fileSystem: JSFileSystem(cacheRoot: rootPath))
    }

    /// Hand a model file to a JavaScript host session factory. Node receives
    /// the cached path (avoiding a large copy across the wasm boundary);
    /// browsers receive bytes because their store is in memory.
    func createJavaScriptSession(
        modelFile: String,
        hostGlobal: String,
        method: String = "createSession"
    ) async throws {
        guard let host = JSObject.global[hostGlobal].object,
              let createSession = host[method].object else {
            throw ModelStoreError.io("missing \(hostGlobal).\(method)")
        }
        let argument: JSValue = jsIsNode()
            ? .string(path(modelFile))
            : JSTypedArray<UInt8>(try read(modelFile)).jsValue
        guard let promise = createSession(argument).object.flatMap(JSPromise.init) else {
            throw ModelStoreError.io("\(hostGlobal).\(method) did not return a promise")
        }
        _ = try await promise.value
    }
}

public extension ModelStore {
    /// `cacheRoot` is the base for the managed nested layout (node `~/.cache`);
    /// empty in the browser (in-memory filesystem).
    static func platformDefault(cacheRoot: String?) throws -> ModelStore {
        ModelStore.js(cacheRoot: cacheRoot ?? "").0
    }

    /// Default wasm store: JS `fetch` + node `fs` (persistent) or, in the
    /// browser, an in-memory filesystem. Returns the filesystem too so the
    /// caller can read the downloaded files back from the same store.
    static func js(cacheRoot: String, endpoint: String = "https://huggingface.co") -> (ModelStore, FileSystem) {
        let fs: FileSystem = jsIsNode() ? JSFileSystem(cacheRoot: cacheRoot) : MemoryFileSystem(cacheRoot: cacheRoot)
        return (ModelStore(transport: JSTransport(fileSystem: fs), fileSystem: fs, endpoint: endpoint), fs)
    }
}
#endif

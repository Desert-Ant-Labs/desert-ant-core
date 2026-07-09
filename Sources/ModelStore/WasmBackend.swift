// wasm backend (node): HTTP via JS `fetch`, filesystem via node's `fs` (whose
// *Sync methods match the synchronous FileSystem seam). Browser storage is
// async and would need a different FileSystem (OPFS/Cache API); on the web the
// JS host currently owns caching, so this targets node (redact-node).
#if os(WASI)
import JavaScriptKit
import JavaScriptEventLoop


/// node `fs` (sync) filesystem.
public struct JSFileSystem: FileSystem {
    private let cacheRoot: String
    private var fs: JSObject { JSObject.global.require.function!("fs").object! }

    public init(cacheRoot: String) { self.cacheRoot = cacheRoot }
    public func defaultCacheRoot() -> String { cacheRoot }

    public func exists(_ path: String) -> Bool { fs.existsSync!(path).boolean ?? false }

    public func size(_ path: String) -> Int64? {
        guard let st = fs.statSync?(path).object, let n = st.size.number else { return nil }
        return Int64(n)
    }

    public func read(_ path: String) throws -> [UInt8] {
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
    public func remove(_ path: String) { _ = try? fs.unlinkSync?(path) }
}

/// JS `fetch` transport.
public struct JSTransport: ModelTransport {
    public init() {}

    public func tree(_ url: String) async throws -> [RemoteEntry] {
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
            try JSFileSystem(cacheRoot: "").write(destinationPath, all)
            return
        }
        // Fallback (no streaming body): whole-body arrayBuffer.
        guard let bufPromise = JSPromise(from: resp.arrayBuffer!()) else { throw ModelStoreError.io("arrayBuffer(\(url))") }
        let u8 = JSObject.global.Uint8Array.function!.new(try await bufPromise.value)
        guard let arr = JSTypedArray<UInt8>(from: u8) else { throw ModelStoreError.io("bytes(\(url))") }
        let bytes = arr.withUnsafeBytes { Array($0) }
        try JSFileSystem(cacheRoot: "").write(destinationPath, bytes)
        onBytes(Int64(bytes.count))
    }

    private func fetch(_ url: String, _ opts: JSValue) async throws -> JSObject {
        guard let promise = JSPromise(from: JSObject.global.fetch.function!(url, opts)) else {
            throw ModelStoreError.io("fetch(\(url))")
        }
        let value = try await promise.value
        guard let resp = value.object, (resp.ok.boolean ?? false) || (resp.status.number ?? 0) < 400 else {
            throw ModelStoreError.io("fetch(\(url)) not ok")
        }
        return resp
    }
}

public extension ModelStore {
    /// Default wasm/node store: JS `fetch` + node `fs`.
    init(cacheRoot: String, endpoint: String = "https://huggingface.co") {
        self.init(transport: JSTransport(), fileSystem: JSFileSystem(cacheRoot: cacheRoot), endpoint: endpoint)
    }
}
#endif

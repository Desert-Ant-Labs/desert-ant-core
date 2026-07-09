import Checksum

/// Progress across a model download.
public struct DownloadProgress: Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let completedFiles: Int
    public let totalFiles: Int
    /// 0...1, by bytes when a total is known, else by files.
    public var fraction: Double {
        if totalBytes > 0 { return min(1, Double(completedBytes) / Double(totalBytes)) }
        return totalFiles > 0 ? Double(completedFiles) / Double(totalFiles) : 0
    }
}

/// Downloads Hugging Face model files on demand, caches them, and verifies
/// integrity so a crash or corruption never yields a broken model. Everything
/// works offline once a model is downloaded; otherwise it downloads. All the
/// logic here is Foundation-free; the HTTP and filesystem seams
/// (`ModelTransport`, `FileSystem`) are the only platform-specific parts.
public struct ModelStore: Sendable {
    private let transport: ModelTransport
    private let fs: FileSystem
    /// The Hub endpoint; override for tests or a mirror.
    private let endpoint: String

    public init(transport: ModelTransport, fileSystem: FileSystem, endpoint: String = "https://huggingface.co") {
        self.transport = transport
        self.fs = fileSystem
        self.endpoint = endpoint
    }

    // MARK: paths

    /// The directory that holds a model's files (present or not). Consumers open
    /// artifacts under here, e.g. `location(of:) + "/redact.mlmodelc"`.
    public func location(of model: Model) -> String {
        let root = model.cacheDirectory ?? fs.defaultCacheRoot()
        return join(root, "desert-ant-labs", model.repo, model.revision)
    }

    private func metaDir(_ model: Model) -> String { join(location(of: model), ".dal-meta") }
    private func filePath(_ model: Model, _ file: String) -> String { join(location(of: model), file) }
    private func metaPath(_ model: Model, _ file: String) -> String { join(metaDir(model), file + ".meta") }
    private func resolveURL(_ model: Model, _ file: String) -> String {
        "\(endpoint)/\(model.repo)/resolve/\(model.revision)/\(file)"
    }

    // MARK: public API

    /// Whether every file of `model` is present and intact. Always re-hashes
    /// each file and checks it against the SHA-256 recorded at download time, so
    /// a truncated or corrupted file reports `false` (and re-downloads) rather
    /// than being used. Works fully offline (no network).
    public func isDownloaded(_ model: Model) -> Bool {
        model.files.allSatisfy { isFileValid(model, $0) }
    }

    /// Ensure every file of `model` is present and valid, downloading only what
    /// is missing. A no-op (no network) when already downloaded. Downloads go to
    /// a `.part` temp file, are verified, then atomically moved into place, so a
    /// crash mid-download never corrupts the cache.
    public func download(_ model: Model, progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }) async throws {
        try fs.makeDirectory(location(of: model))
        try fs.makeDirectory(metaDir(model))

        // Pre-size: known-present files count toward the total immediately.
        var completedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var pending: [String] = []
        for file in model.files {
            if isFileValid(model, file), let s = fs.size(filePath(model, file)) {
                completedBytes += s
                totalBytes += s
            } else {
                pending.append(file)
            }
        }
        let totalFiles = model.files.count
        var completedFiles = totalFiles - pending.count
        progress(DownloadProgress(completedBytes: completedBytes, totalBytes: totalBytes,
                                  completedFiles: completedFiles, totalFiles: totalFiles))

        for file in pending {
            let info = try await transport.head(resolveURL(model, file))
            if let s = info.size { totalBytes += s }
            let base = completedBytes
            try await fetch(model, file, info: info) { fileBytes in
                progress(DownloadProgress(completedBytes: base + fileBytes, totalBytes: totalBytes,
                                          completedFiles: completedFiles, totalFiles: totalFiles))
            }
            completedBytes += fs.size(filePath(model, file)) ?? info.size ?? 0
            completedFiles += 1
            progress(DownloadProgress(completedBytes: completedBytes, totalBytes: totalBytes,
                                      completedFiles: completedFiles, totalFiles: totalFiles))
        }
    }

    // MARK: internals

    /// A cached file is valid iff its bytes hash to the SHA-256 recorded in its
    /// `.meta` sidecar (catches truncation/corruption; needs no network).
    private func isFileValid(_ model: Model, _ file: String) -> Bool {
        guard let metaBytes = try? fs.read(metaPath(model, file)),
              let meta = FileMetadata.parse(metaBytes),
              let bytes = try? fs.read(filePath(model, file)),
              SHA256.hexDigest(bytes) == meta.sha256 else { return false }
        return true
    }

    private func fetch(_ model: Model, _ file: String, info: RemoteFileInfo,
                       onBytes: @Sendable @escaping (Int64) -> Void) async throws {
        let dest = filePath(model, file)
        let meta = metaPath(model, file)
        let part = meta + ".\(info.etag ?? "dl").part"
        try fs.makeDirectory(parentDir(dest))
        try fs.makeDirectory(parentDir(part))
        try fs.makeDirectory(parentDir(meta))
        fs.remove(part)  // discard any stale partial

        try await transport.download(resolveURL(model, file), to: part, onBytes: onBytes)

        // Verify before it is allowed into the cache.
        if let expected = info.size, let got = fs.size(part), got != expected {
            fs.remove(part)
            throw ModelStoreError.integrityCheckFailed("\(file): size \(got) != \(expected)")
        }
        let bytes = try fs.read(part)
        let sha = SHA256.hexDigest(bytes)
        if info.etagIsSHA256, let etag = info.etag, sha != etag {
            fs.remove(part)
            throw ModelStoreError.integrityCheckFailed("\(file): sha256 mismatch")
        }

        try fs.move(part, to: dest)  // atomic
        let record = FileMetadata(sha256: sha, size: Int64(bytes.count), etag: info.etag, commit: info.commit)
        try fs.write(meta, record.serialized())
    }

    // MARK: path helpers (POSIX-style, all target platforms use "/")

    private func join(_ parts: String...) -> String {
        var out = ""
        for p in parts where !p.isEmpty {
            if out.isEmpty { out = p }
            else { out += out.hasSuffix("/") ? p : "/" + p }
        }
        return out
    }

    private func parentDir(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        return String(path[..<slash])
    }
}

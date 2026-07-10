import Checksum

/// One total download progress across all of a model's files: bytes downloaded
/// out of the combined size of every file (not per file).
public struct DownloadProgress: Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64
    /// 0...1 = completedBytes / totalBytes.
    public var fraction: Double {
        if totalBytes > 0 { return min(1, Double(completedBytes) / Double(totalBytes)) }
        return completedBytes > 0 ? 1 : 0
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
    private let endpoint: String

    public init(transport: ModelTransport, fileSystem: FileSystem, endpoint: String = "https://huggingface.co") {
        self.transport = transport
        self.fs = fileSystem
        self.endpoint = endpoint
    }

    // MARK: paths / urls

    /// The directory holding a model's files (present or not). Consumers open
    /// artifacts under here, e.g. `location(of:) + "/redact.mlmodelc"`.
    public func location(of model: ModelSpec) -> String {
        join(model.cacheDirectory ?? fs.defaultCacheRoot(), "desert-ant-models", model.repo, model.revision)
    }

    /// Access files at this model's cache location using the store's platform
    /// filesystem. The files are only guaranteed to exist after `download` or
    /// when `isDownloaded` returns true.
    public func storedModel(for model: ModelSpec) -> StoredModel {
        StoredModel(rootPath: location(of: model), fileSystem: fs)
    }
    private func manifestPath(_ model: ModelSpec) -> String { join(location(of: model), ".dal-meta", "manifest") }
    private func filePath(_ model: ModelSpec, _ file: String) -> String { join(location(of: model), file) }
    private func fileURL(_ model: ModelSpec, _ file: String) -> String {
        "\(endpoint)/\(model.repo)/resolve/\(model.revision)/\(file)"
    }
    private func treeURL(_ model: ModelSpec) -> String {
        "\(endpoint)/api/models/\(model.repo)/tree/\(model.revision)?recursive=true"
    }

    // MARK: public API

    /// Whether the model is fully present and intact. Reads the resolved
    /// manifest written at download time (so it knows the exact files, folders
    /// already expanded) and re-hashes each against its recorded SHA-256. A
    /// truncated/corrupted file reports `false` and re-downloads. Fully offline.
    public func isDownloaded(_ model: ModelSpec) -> Bool {
        guard isValid(model),
              let bytes = try? fs.read(manifestPath(model)),
              let manifest = Manifest.parse(bytes),
              manifest.requested == model.files,
              !manifest.entries.isEmpty else { return false }
        for e in manifest.entries {
            guard isSafeRelativePath(e.path), e.size >= 0,
                  e.sha256.count == 64, e.sha256.allSatisfy({ $0.isHexDigit }),
                  let data = try? fs.read(filePath(model, e.path)),
                  Int64(data.count) == e.size,
                  SHA256.hexDigest(data) == e.sha256 else { return false }
        }
        return true
    }

    /// Ensure the model is present and valid, downloading only what is missing.
    /// A no-op (no network) when already downloaded. `files` may name exact
    /// files or folders (a trailing `/`), which the Hub tree call expands.
    /// Downloads go to a `.part` temp file, are size- and SHA256-verified, then
    /// atomically moved into place; the manifest is written last, so a crash
    /// mid-download never yields a "downloaded" but broken model.
    @discardableResult
    public func download(
        _ model: ModelSpec,
        progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws -> StoredModel {
        guard isValid(model) else { throw ModelStoreError.invalidSpec }
        try fs.makeDirectory(location(of: model))
        if isDownloaded(model) {
            if let bytes = try? fs.read(manifestPath(model)), let m = Manifest.parse(bytes) {
                let total = m.entries.reduce(0) { $0 + $1.size }
                progress(DownloadProgress(completedBytes: total, totalBytes: total))
            }
            return storedModel(for: model)
        }

        // One tree call resolves folders and gives size + LFS sha256 per file.
        let tree = try await transport.tree(treeURL(model))
        let resolved = try resolve(model.files, in: tree, repo: model.repo)

        let totalBytes = resolved.reduce(0) { $0 + $1.size }
        var completedBytes: Int64 = 0
        let report: @Sendable (Int64) -> Void = { done in
            progress(DownloadProgress(completedBytes: done, totalBytes: totalBytes))
        }
        report(0)

        var manifest: [Manifest.Entry] = []
        for e in resolved {
            let dest = filePath(model, e.path)
            // Skip a file already present and matching its LFS hash (resumes a
            // partial prior run without re-downloading verified LFS files).
            if let expected = e.sha256, fs.exists(dest), let data = try? fs.read(dest),
               SHA256.hexDigest(data) == expected {
                completedBytes += e.size
                manifest.append(.init(path: e.path, size: e.size, sha256: expected))
                report(completedBytes)
                continue
            }
            let base = completedBytes
            let sha = try await fetch(model, e) { fileBytes in report(base + fileBytes) }
            completedBytes += fs.size(dest) ?? e.size
            manifest.append(.init(path: e.path, size: e.size, sha256: sha))
            report(completedBytes)
        }

        try fs.makeDirectory(parentDir(manifestPath(model)))
        try fs.write(
            manifestPath(model),
            Manifest(requested: model.files, entries: manifest).serialized()
        )
        return storedModel(for: model)
    }

    // MARK: internals

    /// Expand the requested files/folders against the repo tree.
    private func resolve(_ requested: [String], in tree: [RemoteEntry], repo: String) throws -> [RemoteEntry] {
        var out: [RemoteEntry] = []
        var seen = Set<String>()
        func add(_ entry: RemoteEntry) throws {
            guard isSafeRelativePath(entry.path), entry.size >= 0 else {
                throw ModelStoreError.invalidResponse("unsafe tree entry: \(entry.path)")
            }
            if seen.insert(entry.path).inserted { out.append(entry) }
        }
        for req in requested {
            if req.hasSuffix("/") {
                let matches = tree.filter { $0.path == String(req.dropLast()) || $0.path.hasPrefix(req) }
                guard !matches.isEmpty else { throw ModelStoreError.notInRepo("\(repo)/\(req)") }
                try matches.forEach(add)
            } else {
                guard let e = tree.first(where: { $0.path == req }) else {
                    throw ModelStoreError.notInRepo("\(repo)/\(req)")
                }
                try add(e)
            }
        }
        return out
    }

    /// Download one file to a temp path, verify size + (LFS) SHA-256, atomically
    /// move into place, and return the content SHA-256.
    private func fetch(_ model: ModelSpec, _ e: RemoteEntry,
                       onBytes: @Sendable @escaping (Int64) -> Void) async throws -> String {
        let dest = filePath(model, e.path)
        let part = join(location(of: model), ".dal-meta", e.path + ".part")
        try fs.makeDirectory(parentDir(dest))
        try fs.makeDirectory(parentDir(part))
        fs.remove(part)

        try await transport.download(fileURL(model, e.path), to: part, onBytes: onBytes)

        guard let got = fs.size(part), got == e.size else {
            let actual = fs.size(part).map(String.init) ?? "missing"
            fs.remove(part)
            throw ModelStoreError.integrityCheckFailed("\(e.path): size \(actual) != \(e.size)")
        }
        let bytes = try fs.read(part)
        let sha = SHA256.hexDigest(bytes)
        if let expected = e.sha256, sha != expected {
            fs.remove(part)
            throw ModelStoreError.integrityCheckFailed("\(e.path): sha256 mismatch")
        }
        try fs.move(part, to: dest)
        return sha
    }

    private func isValid(_ model: ModelSpec) -> Bool {
        guard isSafeRelativePath(model.repo), isSafeRelativePath(model.revision),
              !model.files.isEmpty else { return false }
        return model.files.allSatisfy(isSafeRelativePath)
    }

    /// Reject absolute paths, traversal, control separators used by the
    /// manifest, and empty path components. This protects every filesystem and
    /// URL backend at the shared orchestration layer.
    private func isSafeRelativePath(_ path: String) -> Bool {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"),
              !trimmed.contains("\t"), !trimmed.contains("\n"), !trimmed.contains("\r") else { return false }
        return trimmed.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    // MARK: path helpers (POSIX-style, all target platforms use "/")

    private func join(_ parts: String...) -> String {
        var out = ""
        for p in parts where !p.isEmpty {
            if out.isEmpty { out = p } else { out += out.hasSuffix("/") ? p : "/" + p }
        }
        return out
    }
    private func parentDir(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        return String(path[..<slash])
    }
}

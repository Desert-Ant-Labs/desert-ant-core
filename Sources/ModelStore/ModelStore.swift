
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
    private let maxConcurrentDownloads: Int

    /// - Parameter maxConcurrentDownloads: how many of a model's files transfer
    ///   at once. A model repo is 10-25 files, and downloading them one after
    ///   another leaves most of the link idle; a small bound gets the
    ///   throughput without opening a socket per file on a phone.
    public init(transport: ModelTransport, fileSystem: FileSystem,
                endpoint: String = "https://huggingface.co",
                maxConcurrentDownloads: Int = 4) {
        self.transport = transport
        self.fs = fileSystem
        self.endpoint = endpoint
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
    }

    // MARK: paths / urls

    /// The directory holding a model's files (present or not). Consumers open
    /// artifacts under here, e.g. `location(of:) + "/redact.mlmodelc"`.
    ///
    /// A `cacheDirectory` is used directly as the model's directory, so you can
    /// point at a folder you already populated and it is reused as-is. With no
    /// `cacheDirectory`, a managed per-model/revision path under the platform
    /// cache is used (so multiple models never collide).
    public func location(of model: ModelSpec) -> String {
        if let directory = model.cacheDirectory { return directory }
        return join(fs.defaultCacheRoot(), "desert-ant-models", model.repo, model.revision)
    }

    /// Access files at this model's cache location using the store's platform
    /// filesystem. The files are only guaranteed to exist after `download` or
    /// when `isDownloaded` returns true.
    public func storedModel(for model: ModelSpec) -> StoredModel {
        StoredModel(rootPath: location(of: model), fileSystem: fs)
    }
    /// Directory holding the store's own bookkeeping (manifest, `.part` temps)
    /// inside a model's location. Its presence marks a location as download-
    /// managed rather than user-provided.
    static let metadataDirectory = ".dal-meta"

    private func manifestPath(_ model: ModelSpec) -> String { join(location(of: model), Self.metadataDirectory, "manifest") }
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
            let path = filePath(model, e.path)
            guard isSafeRelativePath(e.path), e.size >= 0,
                  e.sha256.count == 64, e.sha256.allSatisfy({ $0.isHexDigit }),
                  let d = try? fs.digest(path),
                  d.size == e.size,
                  d.sha256 == e.sha256 else { return false }
        }
        return true
    }

    /// Ensure the model is present and valid, downloading only what is missing.
    /// A no-op (no network) when already downloaded. `files` may name exact
    /// files or folders (a trailing `/`), which the Hub tree call expands.
    /// Downloads go to a `.part` temp file, are size- and SHA256-verified, then
    /// atomically moved into place; the manifest is written last, so a crash
    /// mid-download never yields a "downloaded" but broken model. Up to
    /// `maxConcurrentDownloads` files transfer at once, and `progress` reports
    /// one total across all of them.
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
        let counter = DownloadProgressCounter(fileCount: resolved.count, totalBytes: totalBytes, report: progress)
        progress(DownloadProgress(completedBytes: 0, totalBytes: totalBytes))

        // Files are independent (each has its own `.part` temp and its own
        // destination), so they transfer concurrently, bounded by
        // `maxConcurrentDownloads`. Results are placed back by index, so the
        // manifest records the resolved order whatever order they finish in.
        var slots = [Manifest.Entry?](repeating: nil, count: resolved.count)
        try await withThrowingTaskGroup(of: (Int, Manifest.Entry).self) { group in
            var next = 0
            let inFlight = min(maxConcurrentDownloads, resolved.count)
            while next < inFlight {
                let index = next
                group.addTask { (index, try await self.fetchOrReuse(model, resolved[index], index: index, counter: counter)) }
                next += 1
            }
            // Start the next file only as one finishes, so at most `inFlight`
            // transfers are ever open. A throw here exits the group, which
            // cancels the rest.
            while let (index, entry) = try await group.next() {
                slots[index] = entry
                guard next < resolved.count else { continue }
                let index = next
                group.addTask { (index, try await self.fetchOrReuse(model, resolved[index], index: index, counter: counter)) }
                next += 1
            }
        }
        let manifest = slots.compactMap { $0 }

        try fs.makeDirectory(parentDir(manifestPath(model)))
        try fs.write(
            manifestPath(model),
            Manifest(requested: model.files, entries: manifest).serialized()
        )
        return storedModel(for: model)
    }

    /// Directories of every revision of `repo` present in the managed cache,
    /// sorted by revision. Only completed downloads are listed (the store's
    /// manifest marks completion); an interrupted download is not. The last
    /// path component of each entry is the revision. Locations you populated
    /// yourself (an explicit `cacheDirectory`) are outside the managed layout
    /// and are not listed.
    public func downloadedModels(repo: String) -> [String] {
        let base = join(fs.defaultCacheRoot(), "desert-ant-models", repo)
        return downloadedRevisions(repo: repo).map { join(base, $0) }
    }

    /// The revisions of `repo` with a completed download in the managed cache,
    /// sorted. (`downloadedModels(repo:)` returns the same entries as paths.)
    public func downloadedRevisions(repo: String) -> [String] {
        let base = join(fs.defaultCacheRoot(), "desert-ant-models", repo)
        return fs.listDirectory(base)
            .filter { fs.exists(join(base, $0, Self.metadataDirectory, "manifest")) }
            .sorted()
    }

    /// Resolve a ``RevisionRequirement`` to a concrete revision for `repo`.
    /// `exact` needs nothing. A range asks the Hub for the repo's tags; when
    /// that fails (offline, or a transport without a refs call), it falls back
    /// to the newest *downloaded* revision in range, then to the range's `from`
    /// - so a device that downloaded once keeps working offline, and a fresh
    /// offline install still points at a valid revision to try.
    public func resolveRevision(_ requirement: RevisionRequirement, repo: String) async -> String {
        switch requirement {
        case .exact(let revision):
            return revision
        case .from(let from):
            if let tags = try? await transport.tags("\(endpoint)/api/models/\(repo)/refs"),
               let best = requirement.bestMatch(in: tags) {
                return best
            }
            return requirement.bestMatch(in: downloadedRevisions(repo: repo)) ?? from
        }
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

    /// One file's worth of work: reuse it if it is already present and intact,
    /// otherwise download it. Reports its own cumulative bytes to `counter`,
    /// and finishes on the file's full size so the total always reaches 100%
    /// even for a transport that reports progress coarsely.
    private func fetchOrReuse(_ model: ModelSpec, _ e: RemoteEntry, index: Int,
                              counter: DownloadProgressCounter) async throws -> Manifest.Entry {
        let dest = filePath(model, e.path)
        // Skip a file already present and matching its LFS hash (resumes a
        // partial prior run without re-downloading verified LFS files).
        if let expected = e.sha256, let d = try? fs.digest(dest),
           d.size == e.size, d.sha256 == expected {
            counter.record(file: index, bytes: e.size)
            return .init(path: e.path, size: e.size, sha256: expected)
        }
        let sha = try await fetch(model, e) { counter.record(file: index, bytes: $0) }
        counter.record(file: index, bytes: e.size)
        return .init(path: e.path, size: e.size, sha256: sha)
    }

    /// Download one file to a temp path, verify size + (LFS) SHA-256, atomically
    /// move into place, and return the content SHA-256.
    private func fetch(_ model: ModelSpec, _ e: RemoteEntry,
                       onBytes: @Sendable @escaping (Int64) -> Void) async throws -> String {
        let dest = filePath(model, e.path)
        let part = join(location(of: model), Self.metadataDirectory, e.path + ".part")
        try fs.makeDirectory(parentDir(dest))
        try fs.makeDirectory(parentDir(part))
        fs.remove(part)

        do {
            try await transport.download(fileURL(model, e.path), to: part, onBytes: onBytes)
        } catch {
            fs.remove(part)  // don't leave a half-written temp file behind
            throw error
        }

        guard let got = fs.size(part), got == e.size else {
            let actual = fs.size(part).map(String.init) ?? "missing"
            fs.remove(part)
            throw ModelStoreError.integrityCheckFailed("\(e.path): size \(actual) != \(e.size)")
        }
        let sha = try fs.digest(part).sha256
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

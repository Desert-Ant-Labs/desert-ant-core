// The shared shape of a model catalog entry.
//
// This file is the reusable half: identity, published coordinates, the
// per-platform file manifest, and everything derivable from them (the
// `ModelDistribution`, the current platform's runnable artifact, resolve /
// availability helpers). No model appears here.
//
// Each model contributes one folder next to this file — `Redact/Redact.swift`,
// `Emo/Emo.swift`, … — holding only that model's data. Adding a model is a new
// folder plus one line in `Catalog.swift`; nothing shared changes.

import ModelStore

/// One model in the Desert Ant Labs catalog: what it is, where its files come
/// from, and which of them each platform needs.
public protocol ModelDeclaration: Sendable {
    /// Canonical lowercase id: Hub repo suffix, npm/Maven coordinate, directory
    /// name, usage-event name. Everything else derives from it.
    static var id: String { get }
    /// Capitalized name: Swift products, native library names, docs.
    static var product: String { get }
    /// Pinned model revision the SDK is built against (a `v`-prefixed tag).
    static var revision: String { get }
    /// One line describing what the model does.
    static var summary: String { get }
    /// Repo-relative entries each platform needs. Directory artifacts (e.g. a
    /// Core ML `.mlmodelc`) end in `/`. A platform absent here is unsupported.
    static var files: [ModelPlatform: [String]] { get }
    /// The runnable artifact for `platform` — the file the inference session is
    /// built from, as opposed to the sidecars around it.
    static func artifact(for platform: ModelPlatform) -> String
}

public extension ModelDeclaration {
    /// Hugging Face repo id, e.g. `"desert-ant-labs/redact"`. Uniform across the
    /// catalog, so it is derived rather than declared per model.
    static var repo: String { "desert-ant-labs/\(id)" }

    /// This model's Hub declaration: repo, pinned revision, per-platform files.
    /// The single value an SDK needs to download, adopt, or verify its model.
    static var distribution: ModelDistribution {
        ModelDistribution(repo: repo, revision: revision, files: files)
    }

    /// The runnable artifact on the platform being built for.
    static var artifact: String { artifact(for: .current) }

    /// Whether this model ships anything for `platform`.
    static func supports(_ platform: ModelPlatform) -> Bool { files[platform] != nil }

    /// Resolve the model for `directory` (adopt files you placed there, else
    /// download to it); `nil` uses the managed platform cache.
    static func resolve(
        directory: String? = nil,
        cacheRoot: String? = nil,
        progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws -> StoredModel {
        try await distribution.resolve(cacheDirectory: directory, cacheRoot: cacheRoot, progress: progress)
    }

    /// Whether the model is usable offline for `directory`.
    static func isAvailable(directory: String? = nil, cacheRoot: String? = nil) -> Bool {
        distribution.isAvailable(cacheDirectory: directory, cacheRoot: cacheRoot)
    }
}

// The shared shape of a model catalog entry.
//
// This file is the reusable half: identity, published coordinates, the
// per-platform file manifest, and everything derivable from them (the
// `ModelDistribution`, the current platform's runnable artifact, resolve /
// availability helpers). No model appears here.
//
// Each model contributes its own module (`Sources/Emo`, `Sources/Redact`, ...)
// holding only that model's data, so adding a model changes nothing shared.

import ModelStore
import Usage

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
    /// The SDK's own released version, as published to npm and Maven. This is the
    /// single source: it is what usage attributes to, and `ModelCatalogTests`
    /// checks it against `packages/<id>-node/package.json` and
    /// `packages/<id>-kotlin/build.gradle.kts` so the three cannot drift.
    static var sdkVersion: String { get }
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

    /// This SDK's usage identity, attached to every emitted telemetry body's
    /// `sdk` field so usage attributes to this model rather than to the core it
    /// is built on. Derived, so a model cannot forget to pass one (which silently
    /// bills its inference to the default identity) or let the version go stale.
    static var sdkInfo: SDKInfo { SDKInfo(name: product, version: sdkVersion) }

    /// The JavaScript global the wasm build drives its inference session
    /// through (`__EmoHost`, `__RedactHost`, …). Derived, so the Swift side and
    /// the JS package cannot disagree about the name.
    static var hostGlobal: String { "__\(product)Host" }

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

// A model's declaration of what it needs, provided by each model SDK.
//
// Foundation-free on purpose: the orchestration (this file, ModelStore,
// FileMetadata) must build on Android and wasm, where Foundation is avoided.
// Platform I/O lives behind the `ModelTransport` and `FileSystem` seams; only
// their Apple/Linux backends touch Foundation.

/// What a model is and where its files come from.
///
/// `files` are repo-relative paths; a compiled artifact that is a directory on
/// the Hub (e.g. a Core ML `.mlmodelc`) is listed as its individual files
/// (`redact.mlmodelc/model.mil`, `redact.mlmodelc/weights/weight.bin`, …), so
/// the store fetches, verifies, and checks them per file with no special-casing.
public struct Model: Sendable, Equatable {
    /// Hugging Face repo id, e.g. `"desert-ant-labs/redact"`.
    public let repo: String
    /// Pinned revision: a tag, branch, or commit, e.g. `"v0.2.1"`.
    public let revision: String
    /// Repo-relative file paths that make up the model.
    public let files: [String]
    /// Optional override for the cache directory (a filesystem path). `nil`
    /// uses the `FileSystem`'s default cache root.
    public let cacheDirectory: String?

    public init(repo: String, revision: String, files: [String], cacheDirectory: String? = nil) {
        self.repo = repo
        self.revision = revision
        self.files = files
        self.cacheDirectory = cacheDirectory
    }
}

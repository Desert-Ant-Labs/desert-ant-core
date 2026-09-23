// A model's declaration of what it needs, provided by each model SDK.
//
// Foundation-free: the orchestration (this file and ModelStore) must build on
// Android and wasm, where Foundation is avoided.
// Platform I/O lives behind the `ModelTransport` and `FileSystem` seams; only
// their Apple/Linux backends touch Foundation.

/// What a model is and where its files come from.
///
/// `files` are repo-relative paths. A directory on the Hub (e.g. a Core ML
/// `.mlmodelc`) ends in `/`; the store expands it through the Hub tree and
/// fetches, verifies, and checks it per file.
public struct ModelSpec: Sendable, Equatable {
    /// Hugging Face repo id, e.g. `"desert-ant-labs/redact"`.
    public let repo: String
    /// Pinned revision: a tag, branch, or commit, e.g. `"v0.2.1"`.
    public let revision: String
    /// Repo-relative file paths that make up the model.
    public let files: [String]
    /// The model's directory (a filesystem path), used directly: a folder you
    /// already populated is reused, and downloads go here. `nil` uses a managed
    /// per-model/revision path under the platform cache.
    public let cacheDirectory: String?

    public init(repo: String, revision: String, files: [String], cacheDirectory: String? = nil) {
        self.repo = repo
        self.revision = revision
        self.files = files
        self.cacheDirectory = cacheDirectory
    }
}

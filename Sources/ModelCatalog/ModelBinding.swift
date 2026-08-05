// What a model has to provide to be reachable from another language.
//
// A model conforms in its own module and exports its entry points from a small
// native target, so its artifacts pull in no unrelated model or optional
// capability. NativeBindings owns the shared handle, download, blocking, and
// call-group implementation. Options and results cross as FFIBuffer payloads.

import FFIBuffer

/// One loaded model instance, behind the opaque handle the host holds.
public protocol BoundModel: AnyObject {
    /// Whether the model is usable with no network (cached, or files present).
    func isDownloaded() -> Bool

    /// Fetch and verify the model ahead of time, reporting the download
    /// fraction in `0...1`. Throws on failure. Hosts that cannot report progress
    /// (the C ABI) pass a closure that ignores it.
    func download(progress: @Sendable @escaping (Double) -> Void) async throws

    /// Run the model. `options` is the model's own payload, written by the host
    /// with the same field order the model reads here; an empty reader means
    /// "all defaults". The return value is an `FFIWriter` payload (no outer
    /// length prefix) that the host decodes with its own reader.
    ///
    /// Returning `nil` reports failure to the host as a NULL buffer.
    func run(text: String, options: FFIReader) async -> [UInt8]?

    /// Run the model over audio: mono `samples` at `sampleRate`, with the
    /// model's own `options` payload, returning its own result payload (see
    /// `run(text:options:)` for both conventions).
    ///
    /// A model implements the modality it has - text models (emo, redact) leave
    /// this alone, audio models (clear) leave `run(text:options:)` alone - and
    /// the default reports "not this model's input" to the host as a NULL
    /// buffer, exactly like a failed run.
    func run(audio: [Float], sampleRate: Double, options: FFIReader) async -> [UInt8]?
}

public extension BoundModel {
    func run(text: String, options: FFIReader) async -> [UInt8]? { nil }
    func run(audio: [Float], sampleRate: Double, options: FFIReader) async -> [UInt8]? { nil }
}

/// A model's binding: how to construct it. The instance methods live on
/// `BoundModel` so the generic ABI never names a concrete model type.
public protocol ModelBinding {
    /// The catalog id, which is how the host asks for this model.
    static var id: String { get }

    /// Lazy construction against the model store: `directory` is an explicit
    /// model home (adopt files there, else download into it), or nil for the
    /// managed layout under `cacheRoot`. No work happens until the first run.
    /// There is no from-files construction: a host that ships model files with
    /// its app passes their folder as `directory`, which is adopted as-is.
    static func make(cacheRoot: String?, directory: String?) -> any BoundModel
}

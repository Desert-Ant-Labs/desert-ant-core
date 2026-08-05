// What a model has to provide to be reachable from another language.
//
// There is one C ABI and one JNI layer for the whole SDK (Sources/Bindings), not
// one per model, because the exported symbol names are the only thing that
// genuinely cannot be shared: `@_cdecl` takes a string literal, and JNI derives
// its symbol from the Java class name. Everything else - handle boxing, lazy
// creation, download, the blocking bridge, call groups - is identical for every
// model, and the parts that do differ (which options a run takes, what a result
// looks like) cross as `FFIBuffer` payloads that the model decodes and encodes
// itself.
//
// So the model side of a binding is this file's two protocols, and adding a
// model means conforming to them in that model's folder plus one line in the
// bindings registry. No new exported symbol, no new native library, no change to
// the host languages' shared plumbing.

import FFIBuffer

/// One loaded model instance, behind the opaque handle the host holds.
public protocol BoundModel: AnyObject {
    /// Whether the model is usable with no network (cached, or files present).
    func isDownloaded() -> Bool

    /// Fetch and verify the model ahead of time. Throws on failure.
    func download() async throws

    /// Run the model. `options` is the model's own payload, written by the host
    /// with the same field order the model reads here; an empty reader means
    /// "all defaults". The return value is an `FFIWriter` payload (no outer
    /// length prefix) that the host decodes with its own reader.
    ///
    /// Returning `nil` reports failure to the host as a NULL buffer.
    func run(text: String, options: FFIReader) async -> [UInt8]?
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

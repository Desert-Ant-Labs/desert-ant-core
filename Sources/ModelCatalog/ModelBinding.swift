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

    /// Run the model.
    ///
    /// Both arguments are this model's own payloads, written by the host with the
    /// same field order the model reads here, and the return value is another one
    /// (an `FFIWriter` payload, no outer length prefix) that the host decodes with
    /// its own reader.
    ///
    /// `input` is whatever this model takes: a string for a text model, samples
    /// and a rate for an audio model, frames or a container for a video model.
    /// Nothing about the modality reaches the ABI, so a new kind of input is a
    /// new payload schema in this file's model and its host codec - not a new
    /// entry point in every language.
    ///
    /// `options` is separate because an empty payload means "all defaults", which
    /// is a contract every SDK relies on; the input is always written.
    ///
    /// Returning `nil` reports failure to the host as a NULL buffer.
    func run(input: FFIReader, options: FFIReader) async -> [UInt8]?
}

public extension BoundModel {
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

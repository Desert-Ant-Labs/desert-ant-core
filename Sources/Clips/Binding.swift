// Clips's side of the cross-language binding: construction, plus the payload
// schemas that are genuinely model-specific (the input a run takes, the options,
// and what a result looks like). The generic handle lifecycle and the exported
// symbols live in NativeBindings and ClipNative, so this file is only the
// model's adapter.

import DesertAnt

extension Clips: BoundModel {
    // `isDownloaded()` and `download(progress:)` are Clips's own public API and
    // witness the protocol as they stand.

    /// Input payload: `u32 count`, then that many length-prefixed UTF-8
    /// sentences, in spoken order. A transcript is a string array, which is a
    /// payload schema like any other - it adds no entry point to the ABI.
    ///
    /// Options payload: `u32 limit` (the most moments to return; `0` means all
    /// of them). An empty payload means the SDK defaults.
    ///
    /// Result payload: `u32 count`, then per moment a `u32` sentence count
    /// followed by that many `u32` transcript indices, a length-prefixed UTF-8
    /// text, and `f64 score`, `f64 percentile`, `f64 estimatedDurationSec`.
    public func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var input = input
        var options = options
        let transcript = input.strings()
        guard !transcript.isEmpty else { return nil }
        // An empty payload means the SDK defaults, so this must match the
        // default every SDK declares for `limit` (no limit), not a number of
        // its own.
        let limit = options.isEmpty ? 0 : options.u32()
        guard let moments = try? await clips(in: transcript, limit: limit > 0 ? limit : nil) else {
            return nil
        }
        var w = FFIWriter()
        w.u32(moments.count)
        for moment in moments {
            w.u32(moment.sentenceIDs.count)
            for id in moment.sentenceIDs { w.u32(id) }
            w.string(moment.text)
            w.f64(moment.score)
            w.f64(moment.percentile)
            w.f64(moment.estimatedDurationSec)
        }
        return w.bytes
    }
}

/// How the generic bindings construct Clips.
public enum ClipBinding: ModelBinding {
    public static let id = ClipModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        Clips(directory: directory, cacheRoot: cacheRoot)
    }
}

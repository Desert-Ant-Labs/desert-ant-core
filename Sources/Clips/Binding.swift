import DesertAnt

extension Clips: BoundModel {
    /// Input payload: `u32 count`, then that many length-prefixed UTF-8
    /// sentences, in spoken order.
    ///
    /// Options payload: `u32 limit` (the most moments to return; `0` lets the
    /// model decide from the duration). An empty payload means the SDK defaults.
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
        // default every host SDK declares for `limit`, not a number of its own.
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

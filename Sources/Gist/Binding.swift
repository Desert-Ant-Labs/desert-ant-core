// Gist's side of the cross-language binding: construction, plus the two payload
// schemas that are genuinely model-specific (the options a run takes, and what a
// result looks like). The generic handle lifecycle and the exported symbols live
// in NativeBindings and GistNative, so this file is only the model's adapter.

import DesertAnt

extension Gist: BoundModel {
    /// Input payload: `string text`.
    ///
    /// Options payload: empty. Unlike the other text models, a run takes no
    /// options: `topK` and `threshold` shape a ranking the host derives itself
    /// (see below), so passing them here would just move the same arithmetic
    /// across the ABI.
    ///
    /// Result payload: `f64 threshold`, `u32 count`, then per topic a
    /// length-prefixed UTF-8 slug, its display name, and an `f64` probability -
    /// the whole taxonomy, ordered by slug.
    ///
    /// The full distribution rather than a ranked top-N (which is what Emo
    /// returns) because two of gist's public APIs need it: `scores()` is the
    /// distribution itself, and `channelTopics()` rolls many posts' distributions
    /// up on the host with no model involved. Sending the tuned `threshold` and
    /// the display names along means the host derives `classify()` exactly as
    /// Swift does, and needs no bundled `taxonomy.json` or `gist_config.json` to
    /// do it - which is what lets the JS and Kotlin packages ship no model files.
    public func run(input: FFIReader, options _: FFIReader) async -> [UInt8]? {
        var input = input
        let text = input.string()
        guard let tagged = try? await tagged(text) else { return nil }

        var w = FFIWriter()
        w.f64(tagged.threshold)
        w.u32(tagged.scores.count)
        // Ordered by slug: the wire is then deterministic across platforms, which
        // is what the parity fixture compares.
        for (slug, score) in tagged.scores.sorted(by: { $0.key < $1.key }) {
            w.string(slug)
            w.string(tagged.names[slug] ?? slug)
            w.f64(score)
        }
        return w.bytes
    }
}

/// How the generic bindings construct Gist.
///
/// The default (multilingual) variant: `make` has no variant slot, matching
/// clear, whose studio/natural choice is likewise Swift-only. Selecting the
/// English build from Kotlin or JS needs a variant on the shared ABI, not a
/// change here.
public enum GistBinding: ModelBinding {
    public static let id = GistModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        Gist(directory: directory, cacheRoot: cacheRoot)
    }
}

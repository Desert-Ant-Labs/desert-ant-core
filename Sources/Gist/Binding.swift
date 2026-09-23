import DesertAnt

extension Gist: BoundModel {
    /// Input payload: `string text`.
    ///
    /// Options payload: empty. `topK` and `threshold` shape a ranking the host
    /// derives itself (see below).
    ///
    /// Result payload: `f64 threshold`, `u32 count`, then per topic a
    /// length-prefixed UTF-8 slug, its display name, and an `f64` probability:
    /// the whole taxonomy, ordered by slug.
    ///
    /// The full distribution rather than a top-N because `scores()` is the
    /// distribution itself and `channelTopics()` rolls many posts up on the host.
    /// Sending the tuned `threshold` and display names lets the host derive
    /// `classify()` exactly as Swift does, so the JS and Kotlin packages ship no
    /// `taxonomy.json` or `gist_config.json`.
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
/// Always the default (multilingual) variant: `make` has no variant slot.
/// Selecting the English build from Kotlin or JS needs a variant on the shared
/// ABI, not a change here.
public enum GistBinding: ModelBinding {
    public static let id = GistModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        Gist(directory: directory, cacheRoot: cacheRoot)
    }
}

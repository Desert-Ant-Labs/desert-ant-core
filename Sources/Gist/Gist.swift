import DesertAnt

/// A single predicted topic and its probability.
public struct Topic: Sendable, Identifiable, Equatable {
    public var id: String { slug }
    /// The taxonomy slug, e.g. `"technology"`.
    public let slug: String
    /// The human-readable name, e.g. `"Technology & Software"`.
    public let name: String
    /// The model's probability, `0...1`.
    public let score: Double
}

/// Errors thrown while loading or running the model. (`MessageError` is
/// `LocalizedError` wherever Foundation exists, so `localizedDescription`
/// shows `message`.)
public enum GistError: MessageError, Sendable {
    /// A model resource (model, tokenizer, embedding, or metadata) was missing.
    case modelNotFound
    /// On-device prediction failed or returned an unexpected output.
    case predictionFailed

    public var message: String {
        switch self {
        case .modelNotFound: "A Gist model resource was not found."
        case .predictionFailed: "On-device topic tagging failed."
        }
    }
}

/// On-device, multi-label content topic tagging.
///
/// `Gist` tags a post (title, or title + description) with topics from a fixed
/// 36-topic taxonomy across 101 languages, fully on device. A potion embedding
/// lookup and a hashed n-gram stream feed an MLP head that runs through the
/// shared inference session (Core ML on Apple, LiteRT elsewhere). Create one
/// once and reuse it.
///
/// ```swift
/// let gist = Gist()
/// let topics = try await gist.classify("How to start a podcast with your iPhone")
/// // [Topic(slug: "technology", name: "Technology & Software", score: 0.91), ...]
/// ```
public final class Gist: @unchecked Sendable {
    // Resolving the files, loading once, sharing that load, and reporting
    // availability are the same for every model, so they live in the core's
    // `LoadedModel`; Gist adds only how a resolved directory becomes its model.
    private let model: LoadedModel<Model>

    /// Creates a tagger. Construction does no work and starts no download; the
    /// model loads on the first ``classify(_:topK:threshold:)``, ``scores(of:)``
    /// or ``download(progress:)``, off your calling thread.
    ///
    /// `variant` selects the model: ``GistVariant/multilingual`` (the default,
    /// 101 languages) or ``GistVariant/english`` (the ~15 MB English-only build;
    /// English/Latin text only). Each variant downloads and caches only its own
    /// files.
    ///
    /// `directory` is where the model lives. If it already contains the model
    /// (you pre-downloaded or shipped it there) it is used offline; otherwise the
    /// model is downloaded into it and reused offline afterward. With no
    /// `directory` (the default), a managed cache location is used.
    ///
    /// Nothing is bundled with this package. To ship the model with your app,
    /// point `directory` at a folder you populated with the model files: it is
    /// used as-is, offline, and nothing is downloaded.
    public convenience init(variant: GistVariant = .default, directory: String? = nil) {
        self.init(variant: variant, directory: directory, cacheRoot: nil)
    }

    /// Binding entry point that also supplies the platform base cache root under
    /// which the managed layout lives (the app cache dir on Android, node
    /// `~/.cache` on the web). On Apple/Linux FileManager provides it, so the
    /// public `init(variant:directory:)` passes `nil`.
    @_spi(GistBindings)
    public init(variant: GistVariant = .default, directory: String?, cacheRoot: String?) {
        // The variant's own slice of the repo, not the catalog's default
        // manifest, so selecting English never downloads the 74 MB build.
        model = LoadedModel(variant.distribution, directory: directory, cacheRoot: cacheRoot) { files in
            try Model(assets: await .gist(files: files, variant: variant))
        }
    }

    /// Creates a tagger from explicitly provided assets (used by the Android/JNI
    /// and custom-deployment paths).
    @_spi(GistBindings)
    public init(assets: ModelAssets) {
        model = LoadedModel { try Model(assets: assets) }
    }

    /// Whether the model is available for this tagger with no network: cached
    /// (for the managed location) or already present in `directory`.
    public func isDownloaded() -> Bool { model.isDownloaded() }

    /// Download and load the model ahead of time, so the first classify is
    /// instant. Reports download progress `0...1`. Concurrent calls, and an
    /// implicit load from a classify, share one download. A no-op once loaded
    /// (see ``isDownloaded()``).
    public func download(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        try await model.download(progress: progress)
    }

    /// Await model readiness. The bindings use this to surface load errors
    /// eagerly; apps can just call ``classify(_:topK:threshold:)``.
    @_spi(GistBindings)
    public func waitUntilLoaded() async throws {
        _ = try await model.value()
    }

    /// The full 36-topic probability distribution for `text` (slug -> probability).
    /// Use these for channel roll-up (see ``channelTopics(_:options:)``).
    public func scores(of text: String) async throws -> [String: Double] {
        try await model.value().scores(text)
    }

    /// Everything the cross-language bindings send over the wire in one call:
    /// the distribution plus the tuned threshold and display names that let a
    /// host derive `classify` without shipping `gist_config.json` or
    /// `taxonomy.json`. The public API splits these across two calls and a
    /// loaded `Model`, neither of which crosses the ABI.
    func tagged(_ text: String) async throws -> (threshold: Double, names: [String: String], scores: [String: Double]) {
        let model = try await model.value()
        return (model.threshold, model.names, try await model.scores(text))
    }

    /// The ranked topics for `text` above the model's tuned threshold (the top
    /// topic is always returned). `topK` caps the list (default 3).
    public func classify(_ text: String, topK: Int = 3, threshold: Double? = nil) async throws -> [Topic] {
        let model = try await model.value()
        let thr = threshold ?? model.threshold
        let scores = try await model.scores(text)
        let ranked = scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        return ranked.prefix(topK).enumerated().compactMap { i, kv in
            (kv.value >= thr || i == 0)
                ? Topic(slug: kv.key, name: model.names[kv.key] ?? kv.key, score: kv.value)
                : nil
        }
    }
}

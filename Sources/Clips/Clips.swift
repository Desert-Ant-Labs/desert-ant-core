import DesertAnt
import Transcript

/// Errors thrown while loading or running the model. (`MessageError` is
/// `LocalizedError` wherever Foundation exists, so `localizedDescription`
/// shows `message`.)
public enum ClipError: MessageError, Sendable {
    /// A model resource (an export or the tokenizer) could not be found.
    case modelNotFound
    /// On-device selection failed or returned an unexpected output.
    case predictionFailed

    public var message: String {
        switch self {
        case .modelNotFound: "A Clips model resource was not found."
        case .predictionFailed: "On-device clip selection failed."
        }
    }
}

/// On-device clip selection: the moments in a transcript worth cutting.
///
/// `Clips` turns a transcript - one string per sentence, in order - into ranked,
/// non-overlapping runs of those sentences, fully on device. A per-sentence
/// selector proposes candidate spans, a span scorer rates them, and weighted
/// interval scheduling picks the best non-overlapping set. Both models run
/// through the shared inference session (Core ML on Apple, LiteRT elsewhere).
/// Create one once and reuse it.
///
/// ```swift
/// let clip = Clips()
/// let moments = try await clip.clips(in: transcript)
/// for moment in moments where moment.percentile > 0.8 {
///     print(moment.text)
/// }
/// ```
public final class Clips: @unchecked Sendable {
    /// How many moments a call returns unless the caller says otherwise.
    ///
    /// **10 is a PRODUCT CHOICE, not a measurement**, recorded as such so it is not later cited
    /// as one. What IS measured: the model finds a median of 30 disjoint moments on long-form
    /// (`clips-training/runs/e2e/preflight_uncapped_50.jsonl`), and 30 is the pipeline's own
    /// internal ceiling, so the true number is higher and unknown. The duration curve in
    /// `Pipeline.budget(for:)` — 8/11/13/14 — came from the teacher's median count, which is
    /// itself pinned by the teacher prompt's arbitrary "8 minimum, 15 maximum". None of those
    /// numbers is a statement about how many good moments a video contains.
    ///
    /// The ceiling is a latency decision as much as an editorial one, because the emitted count
    /// sets the candidate pool: on an M1 the same 633-sentence podcast takes 23.5 s at 14 clips.
    /// Measurements in `clips-training/runs/e2e/`.
    ///
    /// Pass `nil` to ``clips(in:limit:)`` to use the duration curve instead of this.
    public static let defaultClipLimit = 10

    // Resolving the files, loading once, sharing that load, and reporting
    // availability are the same for every model, so they live in the core's
    // `LoadedModel`; Clips adds only how a resolved directory becomes its model.
    private let model: LoadedModel<Model>

    /// Creates a selector. Construction does no work and starts no download; the
    /// model loads on the first ``clips(in:limit:)`` or ``download(progress:)``,
    /// off your calling thread.
    ///
    /// `directory` is where the model lives. If it already contains the model
    /// (you pre-downloaded or shipped it there) it is used offline; otherwise the
    /// model is downloaded into it and reused offline afterward. With no
    /// `directory` (the default), a managed cache location is used.
    ///
    /// Nothing is bundled with this package. To ship the model with your app,
    /// point `directory` at a folder you populated with the model files: it is
    /// used as-is, offline, and nothing is downloaded.
    public convenience init(directory: String? = nil) {
        self.init(directory: directory, cacheRoot: nil)
    }

    /// Binding entry point that also supplies the platform base cache root under
    /// which the managed layout lives (the app cache dir on Android, node
    /// `~/.cache` on the web). On Apple/Linux FileManager provides it, so the
    /// public `init(directory:)` passes `nil`.
    @_spi(ClipBindings)
    public init(directory: String?, cacheRoot: String?) {
        model = LoadedModel(ClipModel.self, directory: directory, cacheRoot: cacheRoot) { files in
            try Model(assets: await .clip(files: files))
        }
    }

    /// Creates a selector from explicitly provided assets (used by the
    /// Android/JNI and custom-deployment paths).
    @_spi(ClipBindings)
    public init(assets: ModelAssets) {
        model = LoadedModel { try Model(assets: assets) }
    }

    /// Whether the model is available for this selector with no network:
    /// cached (for the managed location) or already present in `directory`.
    public func isDownloaded() -> Bool { model.isDownloaded() }

    /// Download and load the model ahead of time, so the first
    /// ``clips(in:limit:)`` is instant. Reports download progress `0...1`.
    /// Concurrent calls, and an implicit load from a selection, share one
    /// download. A no-op once loaded (see ``isDownloaded()``).
    public func download(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        try await model.download(progress: progress)
    }

    /// Await model readiness. The bindings use this to surface load errors
    /// eagerly; apps can just call ``clips(in:limit:)``.
    @_spi(ClipBindings)
    public func waitUntilLoaded() async throws {
        _ = try await model.value()
    }

    /// Every worthwhile moment in `transcript`, ranked best first and
    /// non-overlapping.
    ///
    /// - Parameters:
    ///   - transcript: one sentence per element, in spoken order.
    ///   - limit: the most moments to return. Defaults to ``defaultClipLimit``.
    ///     Pass `nil` to let the model decide from the video's duration.
    /// - Returns: the moments, best first. A transcript under three sentences
    ///   returns `[]`.
    ///
    /// **The limit sizes the WORK, it does not trim the result.** It sets the selection budget,
    /// and the candidate pool is `budget * 4` anchors wide, so a smaller limit means fewer
    /// scorer passes — which is 60-85% of the runtime. This previously ran the whole pipeline at
    /// the full ceiling and then discarded the tail, so asking for fewer clips cost exactly as
    /// much as asking for all of them.
    ///
    /// One consequence worth knowing: the result at `limit: 10` is not generally the first ten
    /// of the result at `limit: 14`. Weighted interval scheduling returns the highest-total
    /// non-overlapping SET of at most k, and the best set of ten is not the best set of fourteen
    /// with four removed. Both are correct answers to different questions, and a bounded list
    /// wants "the best ten moments".
    public func clips(in transcript: [String],
                      limit: Int? = Clips.defaultClipLimit) async throws -> [Clip] {
        try await model.value().clips(in: transcript, limit: limit)
    }
}

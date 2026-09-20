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
    /// The loaded model cannot produce chapters: it is missing the chapter head, or its
    /// `select` graph does not emit the per-sentence `pooled` output chapters read.
    ///
    /// A distinct case rather than ``predictionFailed`` because the remedy is completely
    /// different: this one means "update the artifact", not "the input was bad".
    case chaptersUnsupported

    public var message: String {
        switch self {
        case .modelNotFound: "A Clips model resource was not found."
        case .predictionFailed: "On-device clip selection failed."
        case .chaptersUnsupported:
            "This Clips model does not support chapters. It needs a build whose `select` "
            + "function emits `pooled`, plus the `chapters.bin` head alongside it."
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
    ///
    /// `computeUnits` is which backends Core ML may prepare and run the graph
    /// on. It defaults to ``ComputeUnits/cpuAndNeuralEngine`` rather than
    /// ``ComputeUnits/all`` because this model is built for the ANE — the int8
    /// per-channel export in `Catalog.swift` was chosen on ANE latency — and
    /// preparing a GPU path it never profitably uses is paid on first load, once
    /// per function. `clips.mlmodelc` is multifunction, so `.all` compiles two
    /// graphs for three backends. Measured on an iPhone 17 Pro with the model
    /// already on disk: `.all` took 3-4 minutes to specialize, and
    /// `.cpuAndNeuralEngine` took ~41s, with selection latency unchanged
    /// (5.31s -> 4.92s on a 49-sentence transcript). Pass `.all` to restore the
    /// previous behaviour, or `.cpuOnly` to take the ANE out of the picture when
    /// diagnosing a partitioning problem.
    public convenience init(directory: String? = nil, computeUnits: ComputeUnits = .cpuAndNeuralEngine) {
        self.init(directory: directory, cacheRoot: nil, computeUnits: computeUnits)
    }

    /// Binding entry point that also supplies the platform base cache root under
    /// which the managed layout lives (the app cache dir on Android, node
    /// `~/.cache` on the web). On Apple/Linux FileManager provides it, so the
    /// public `init(directory:)` passes `nil`.
    @_spi(ClipBindings)
    public init(directory: String?, cacheRoot: String?, computeUnits: ComputeUnits = .cpuAndNeuralEngine) {
        model = LoadedModel(ClipModel.self, directory: directory, cacheRoot: cacheRoot) { files in
            try Model(assets: await .clip(files: files, computeUnits: computeUnits))
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

    /// Chapter markers for `transcript`: contiguous sections covering every sentence.
    ///
    /// - Parameter transcript: sentences in spoken order, WITH timings. The chapter length
    ///   prior is expressed in seconds, so real timings are worth having; see the `[String]`
    ///   overload for what it costs to go without them.
    /// - Returns: chapters in time order, tiling the transcript with no gaps and no overlaps.
    ///   `title` is always nil.
    ///
    /// **Chapters are not clips and the shape of the answer differs.** Clips are a ranked,
    /// sparse, non-overlapping SELECTION and the caller decides how many to keep. Chapters are
    /// an exhaustive PARTITION: every sentence belongs to exactly one, the count follows from
    /// the video's duration rather than from a caller's limit, and there is nothing to filter.
    ///
    /// **Cheap alongside ``clips(in:limit:)``, not free on its own.** Both read the same trunk
    /// pass, so a view that already asked for clips pays almost nothing more for chapters. A
    /// caller that only wants chapters still pays the trunk once (~2.4 s for a 30-minute
    /// video); the chapter head itself is ~16 ms at 800 sentences.
    ///
    /// **Titles come from the Title model.** ``Chapter/title`` is nil here and naming is text
    /// generation, which this module does not do. Pass each chapter's `text` to
    /// `Titles.describe(_:)`.
    ///
    /// Throws ``ClipError/chaptersUnsupported`` when the loaded artifact predates chapters.
    public func chapters(in transcript: [Sentence]) async throws -> [Chapter] {
        try await model.value().chapters(in: transcript)
    }

    /// Chapters from bare sentences, with durations ESTIMATED from word count.
    ///
    /// A convenience for callers holding what ``clips(in:limit:)`` takes. It estimates each
    /// sentence's duration at ``Pipeline/wordsPerSecond``, the same proxy the offline pipeline
    /// uses when a corpus has no timings.
    ///
    /// Prefer the `[Sentence]` overload wherever real timings exist. The chapter length prior
    /// is in SECONDS, so on a video whose speaking rate is far from the proxy this shifts how
    /// many chapters come back. It does not shift where the model thinks the topic changes:
    /// the boundary logits never see a timestamp.
    public func chapters(in transcript: [String]) async throws -> [Chapter] {
        var start = 0.0
        let sentences = transcript.enumerated().map { index, text -> Sentence in
            let words = max(1, text.split(separator: " ").count)
            let duration = Double(words) / Pipeline.wordsPerSecond
            defer { start += duration }
            return Sentence(id: index, text: text, start: start, end: start + duration)
        }
        return try await chapters(in: sentences)
    }
}

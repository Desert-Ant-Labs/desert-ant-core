import DesertAnt

/// A redaction: text with unique placeholders, plus the mapping needed to
/// inspect the detections and restore the originals after out-of-band
/// processing (e.g. an LLM).
///
/// ```swift
/// let r = try await redact.redaction(of: userText)
/// let reply = try await llm.rewrite(r.redactedText)   // sees only [EMAIL_1], [GIVEN_NAME_1], …
/// let final = r.restore(reply)                          // originals filled back in
/// ```
public struct Redaction: Sendable {
    /// A single detected entity and the placeholder that stands in for it.
    public struct Item: Sendable, Identifiable, Equatable {
        public var id: String { placeholder }
        /// The category of personal data.
        public let label: Label
        /// The original (sensitive) text that was matched.
        public let original: String
        /// The unique, restorable placeholder, e.g. `"[EMAIL_1]"`.
        public let placeholder: String
        /// The model's confidence, `0...1` (deterministic recognizers report `1.0`).
        public let confidence: Double
        /// The entity's range in the *original* text.
        public let range: Range<String.Index>
    }

    /// The text with each entity replaced by its unique placeholder.
    public let redactedText: String
    /// Every detected entity, in document order.
    public let items: [Item]

    /// Fill the originals back into `processed` (typically an LLM's output) by
    /// substituting each placeholder. Placeholders are bracket-delimited and
    /// numbered (`[EMAIL_1]`, `[EMAIL_2]`, …) so they are unique and never a
    /// prefix of one another, so restoration is order-independent and safe.
    public func restore(_ processed: String) -> String {
        var out = processed
        for item in items { out = out.replacing(item.placeholder, with: item.original) }
        return out
    }
}

/// Options controlling detection and redaction.
public struct Options: Sendable {
    /// Minimum confidence for neural detections. Structured recognizers
    /// (email, cards, IBANs, …) always apply. Default `0.6`.
    public var minimumConfidence: Double
    /// If set, only these categories are redacted. `nil` means
    /// ``Label/defaultEnabled`` — every category except ``Label/org``.
    public var labels: Set<Label>?

    public init(minimumConfidence: Double = 0.6, labels: Set<Label>? = nil) {
        self.minimumConfidence = minimumConfidence.isFinite
            ? min(1, max(0, minimumConfidence))
            : 0.6
        self.labels = labels
    }
}

/// Errors thrown while loading or running the model. (`MessageError` is
/// `LocalizedError` wherever Foundation exists, so `localizedDescription`
/// shows `message`.)
public enum RedactError: MessageError, Sendable {
    case resourceMissing
    case predictionFailed

    public var message: String {
        switch self {
        case .resourceMissing: "A Redact model resource was not found."
        case .predictionFailed: "On-device PII detection failed."
        }
    }
}

/// On-device, multilingual PII redaction.
///
/// `Redact` finds names, addresses, emails, phone numbers, cards, IBANs,
/// national IDs and more across the 24 official EU languages, fully on device.
/// Create one once and reuse it.
///
/// ```swift
/// let redact = Redact()
/// let r = try await redact.redaction(of: "Email Anna at anna@example.com.")
/// r.redactedText            // "Email [GIVEN_NAME_1] at [EMAIL_1]."
/// r.items.first?.original   // "Anna"
/// ```
public final class Redact: @unchecked Sendable {
    // Resolving the files, loading once, sharing that load, and reporting
    // availability are the same for every model, so they live in the core's
    // `LoadedModel`; Redact adds only how a resolved directory becomes its model.
    private let model: LoadedModel<Model>

    /// Creates a redactor. Construction does no work and starts no download; the
    /// model loads on the first ``redaction(of:options:)`` or ``download(progress:)``,
    /// off your calling thread.
    ///
    /// `directory` is where the model lives. If it already contains the model
    /// (you pre-downloaded or shipped it there) it is used offline; otherwise
    /// the model is downloaded into it and reused offline afterward. With no
    /// `directory` (the default), a managed cache location is used.
    ///
    /// ```swift
    /// let redact = Redact()                       // download to the managed cache
    /// let redact = Redact(directory: myModelDir)  // the model lives here (use or download)
    /// ```
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
    @_spi(RedactBindings)
    public init(directory: String?, cacheRoot: String?) {
        model = LoadedModel(RedactModel.self, directory: directory, cacheRoot: cacheRoot) { files in
            try Model(assets: await .redact(files: files))
        }
    }

    /// Creates a redactor from explicitly provided assets (used by the
    /// Android/JNI and custom-deployment paths).
    @_spi(RedactBindings)
    public init(assets: ModelAssets) {
        model = LoadedModel { try Model(assets: assets) }
    }

    /// Whether the model is available for this redactor with no network: cached
    /// (for the managed location) or already present in `directory`.
    public func isDownloaded() -> Bool { model.isDownloaded() }

    /// Download and load the model ahead of time, so the first
    /// ``redaction(of:options:)`` is instant. Reports download progress `0...1`.
    /// Concurrent calls, and an implicit load from a redaction, share one
    /// download. A no-op once loaded (see ``isDownloaded()``).
    public func download(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        try await model.download(progress: progress)
    }

    /// Await model readiness. The bindings use this to surface load errors
    /// eagerly; apps can just call ``redaction(of:options:)``.
    @_spi(RedactBindings)
    public func waitUntilLoaded() async throws {
        _ = try await model.value()
    }

    /// Detect and redact the PII in `text`.
    ///
    /// The result's ``Redaction/redactedText`` has each entity replaced by a
    /// unique placeholder (`[EMAIL_1]`, `[GIVEN_NAME_1]`, …); ``Redaction/items``
    /// lists every detection (label, original text, placeholder, confidence,
    /// range); and ``Redaction/restore(_:)`` fills the originals back in.
    public func redaction(of text: String, options: Options = .init()) async throws -> Redaction {
        let spans = try await spans(in: text, options: options)
        let units = Array(text.utf16)
        var counts: [Label: Int] = [:]
        var items: [Redaction.Item] = []
        var out: [UInt16] = []
        var last = 0
        for span in spans {
            guard let label = Label(rawValue: span.label) else { continue }
            let s = span.start, e = span.end
            guard s >= last, s < e, e <= units.count else { continue }   // in order, non-overlapping
            let n = (counts[label] ?? 0) + 1
            counts[label] = n
            let placeholder = "[\(label.rawValue)_\(n)]"
            let original = String(decoding: units[s..<e], as: UTF16.self)
            let range = String.Index(utf16Offset: s, in: text)..<String.Index(utf16Offset: e, in: text)
            items.append(.init(label: label, original: original, placeholder: placeholder,
                               confidence: span.score, range: range))
            out.append(contentsOf: units[last..<s])
            out.append(contentsOf: Array(placeholder.utf16))
            last = e
        }
        out.append(contentsOf: units[last...])
        return Redaction(redactedText: String(decoding: out, as: UTF16.self), items: items)
    }

    private func spans(in text: String, options: Options) async throws -> [Span] {
        let allowed = Set((options.labels ?? Label.defaultEnabled).map(\.rawValue))
        return try await model.value().detect(text, minScore: options.minimumConfidence)
            .filter { allowed.contains($0.label) }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
    }
}

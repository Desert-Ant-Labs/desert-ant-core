import DesertAnt

/// A single emoji suggestion returned by ``Emo/suggestions(for:limit:skinTone:)``.
public struct EmoSuggestion: Identifiable, Sendable, Equatable {
    init(emoji: String, confidence: Double) {
        id = emoji
        self.emoji = emoji
        self.confidence = confidence
    }

    /// A stable identifier for this suggestion. This is the same value as ``emoji``.
    public let id: String

    /// The suggested emoji.
    public let emoji: String

    /// The model's normalized confidence for this suggestion, from `0...1`.
    public let confidence: Double
}

/// Errors thrown while loading or running the model. (`MessageError` is
/// `LocalizedError` wherever Foundation exists, so `localizedDescription`
/// shows `message`.)
public enum EmoError: MessageError, Sendable {
    /// A model resource (model, tokenizer, or metadata) could not be found.
    case modelNotFound
    /// On-device prediction failed or returned an unexpected output.
    case predictionFailed

    public var message: String {
        switch self {
        case .modelNotFound: "An Emo model resource was not found."
        case .predictionFailed: "On-device emoji prediction failed."
        }
    }
}

/// On-device emoji suggestion for short tasks, calendar entries, or messages.
///
/// `Emo` turns a short phrase into ranked emoji suggestions, fully on device,
/// across 23 languages. A small hashed n-gram stream plus a transformer over a
/// pruned multilingual token sequence run through the shared inference session
/// (Core ML on Apple, LiteRT elsewhere). Create one once and reuse it.
///
/// ```swift
/// let emo = Emo()
/// let suggestions = try await emo.suggestions(for: "Pay my bills")
/// // ["💰", "💳", "🧾", ...]
/// let toned = try await emo.suggestions(for: "go for a run", limit: 1, skinTone: .medium)
/// // "🏃🏽"
/// ```
public final class Emo: @unchecked Sendable {
    // Resolving the files, loading once, sharing that load, and reporting
    // availability are the same for every model, so they live in the core's
    // `LoadedModel`; Emo adds only how a resolved directory becomes its model.
    private let model: LoadedModel<Model>

    /// Creates a suggester. Construction does no work and starts no download;
    /// the model loads on the first ``suggestions(for:limit:skinTone:)`` or
    /// ``download(progress:)``, off your calling thread.
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
    @_spi(EmoBindings)
    public init(directory: String?, cacheRoot: String?) {
        model = LoadedModel(EmoModel.self, directory: directory, cacheRoot: cacheRoot) { files in
            try Model(assets: await .emo(files: files))
        }
    }

    /// Creates a suggester from explicitly provided assets (used by the
    /// Android/JNI and custom-deployment paths).
    @_spi(EmoBindings)
    public init(assets: ModelAssets) {
        model = LoadedModel { try Model(assets: assets) }
    }

    /// Whether the model is available for this suggester with no network:
    /// cached (for the managed location) or already present in `directory`.
    public func isDownloaded() -> Bool { model.isDownloaded() }

    /// Download and load the model ahead of time, so the first
    /// ``suggestions(for:limit:skinTone:)`` is instant. Reports download
    /// progress `0...1`. Concurrent calls, and an implicit load from a
    /// suggestion, share one download. A no-op once loaded (see
    /// ``isDownloaded()``).
    public func download(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        try await model.download(progress: progress)
    }

    /// Await model readiness. The bindings use this to surface load errors
    /// eagerly; apps can just call ``suggestions(for:limit:skinTone:)``.
    @_spi(EmoBindings)
    public func waitUntilLoaded() async throws {
        _ = try await model.value()
    }

    /// Returns up to `limit` emoji suggestions for `text`, most likely first.
    ///
    /// - Parameters:
    ///   - text: A short task, calendar entry, note, or message draft.
    ///   - limit: The maximum number of suggestions. Pass `1` for only the best emoji.
    ///   - skinTone: Preferred skin tone for skin-tone-capable emoji.
    /// - Returns: Up to `limit` suggestions. Empty input returns `[]`.
    public func suggestions(for text: String, limit: Int = 3, skinTone: EmojiSkinTone = .default) async throws -> [EmoSuggestion] {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return [] }
        return try await model.value().suggestions(for: trimmed, limit: limit, skinTone: skinTone)
    }
}

private extension String {
    /// Trim ASCII/Unicode whitespace without Foundation (absent on Android).
    var trimmed: String {
        let scalars = unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, scalars[start].properties.isWhitespace { start = scalars.index(after: start) }
        while end > start {
            let prev = scalars.index(before: end)
            if scalars[prev].properties.isWhitespace { end = prev } else { break }
        }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }
}

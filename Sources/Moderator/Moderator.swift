import DesertAnt

/// Decoded RGB(A) pixels, row-major from the top-left, 8 bits per channel. The
/// portable input every platform funnels into: Apple builds one from a
/// `CGImage` or file, Android from a `Bitmap`, the web from `ImageData`.
/// Alpha is ignored.
public struct ImagePixels: Sendable {
    public let width: Int
    public let height: Int
    /// Bytes per pixel: 4 for RGBA, 3 for RGB.
    public let channels: Int
    public let bytes: [UInt8]

    /// Interleaved RGBA bytes, `width * height * 4` of them.
    public init(width: Int, height: Int, rgba: [UInt8]) throws {
        try self.init(width: width, height: height, channels: 4, bytes: rgba)
    }

    /// Interleaved RGB bytes, `width * height * 3` of them.
    public init(width: Int, height: Int, rgb: [UInt8]) throws {
        try self.init(width: width, height: height, channels: 3, bytes: rgb)
    }

    init(width: Int, height: Int, channels: Int, bytes: [UInt8]) throws {
        guard width > 0, height > 0, channels == 3 || channels == 4,
              bytes.count == width * height * channels else { throw ModeratorError.invalidImage }
        self.width = width
        self.height = height
        self.channels = channels
        self.bytes = bytes
    }
}

/// How many crops each image is scored on. More crops run proportionally
/// slower and recover recall; the image score is the max over crops.
public enum Quality: Int, Sendable, CaseIterable {
    /// One center square crop. Cheapest and the most precise per frame, so the
    /// right choice for video, where sampling across frames recovers recall.
    case fast = 0
    /// Four multiscale tiles: the whole image letterboxed, plus three center
    /// zoom-ins.
    case balanced = 1
    /// The four tiles and their mirror images, the test-time augmentation the
    /// model is evaluated with. Highest recall. The default.
    case accurate = 2
}

/// Which region heads count toward the single NSFW score.
public enum Policy: Int, Sendable, CaseIterable {
    /// Any nudity or sexual content, including a bare chest. The default.
    case standard = 0
    /// A bare chest alone does not flag; exposed genitals or buttocks, full
    /// nudity, and sexual activity still do.
    case allowTopless = 1
}

/// Options for one ``Moderator/analyze(_:options:)`` call.
public struct Options: Sendable {
    /// Score at or above which ``Moderation/isNSFW`` is `true`. Default `0.5`.
    public var threshold: Double
    /// Which heads count toward the score. Default ``Policy/standard``.
    public var policy: Policy
    /// Speed / recall dial. Default ``Quality/accurate``.
    public var quality: Quality

    public init(threshold: Double = 0.5, policy: Policy = .standard, quality: Quality = .accurate) {
        self.threshold = threshold.isFinite ? threshold : 0.5
        self.policy = policy
        self.quality = quality
    }
}

/// Per-region confidences in `0...1`, each the max over the scored crops.
/// Decision scores, not calibrated probabilities.
public struct Regions: Sendable, Hashable, Codable {
    /// Exposed nipples / bare chest.
    public let nipples: Double
    /// Exposed genitals.
    public let genitals: Double
    /// Bare buttocks.
    public let buttocks: Double
    /// Fully unclothed subject.
    public let nude: Double
    /// Sexual activity.
    public let sexAct: Double

    public init(nipples: Double, genitals: Double, buttocks: Double, nude: Double, sexAct: Double) {
        self.nipples = nipples
        self.genitals = genitals
        self.buttocks = buttocks
        self.nude = nude
        self.sexAct = sexAct
    }

    /// The NSFW score under `policy`: the max of the heads it counts.
    public func score(for policy: Policy) -> Double {
        switch policy {
        case .standard: max(nipples, genitals, buttocks, nude, sexAct)
        case .allowTopless: max(genitals, buttocks, nude, sexAct)
        }
    }
}

/// The result of analyzing one image.
public struct Moderation: Sendable, Hashable {
    /// The NSFW score in `0...1` under the requested policy.
    public let score: Double
    /// Whether ``score`` meets the requested threshold.
    public let isNSFW: Bool
    /// Per-region detail, for custom policies and UI.
    public let regions: Regions

    public init(regions: Regions, options: Options) {
        self.regions = regions
        score = regions.score(for: options.policy)
        isNSFW = score >= options.threshold
    }
}

/// Errors thrown while loading or running the model.
public enum ModeratorError: MessageError, Sendable {
    /// The model could not be found.
    case resourceMissing
    /// The image could not be decoded, or its pixel buffer does not match its size.
    case invalidImage
    /// On-device inference failed or returned an unexpected output.
    case predictionFailed

    public var message: String {
        switch self {
        case .resourceMissing: "A Moderator model resource was not found."
        case .invalidImage: "Moderator could not read the image."
        case .predictionFailed: "On-device NSFW detection failed."
        }
    }
}

/// On-device NSFW image detection.
///
/// Scores an image from `0` to `1` for nudity or sexual activity, tuned to pass
/// swimwear and lingerie while flagging nude and sexual content. Runs on Core ML
/// on Apple platforms and LiteRT everywhere else. Create one and reuse it.
///
/// ```swift
/// let moderator = Moderator()
/// let result = try await moderator.analyze(image)   // CGImage, file URL, or ImagePixels
/// if result.isNSFW { blur() }
/// ```
public final class Moderator: @unchecked Sendable {
    private let model: LoadedModel<Model>

    /// Creates a moderator. Construction does no work; the model loads on the
    /// first ``analyze(_:options:)`` or ``download(progress:)``.
    ///
    /// `directory` is where the model lives. If it already holds the model it is
    /// used offline; otherwise the model is downloaded into it. With no
    /// `directory`, a managed cache location is used.
    public convenience init(directory: String? = nil) {
        self.init(directory: directory, cacheRoot: nil)
    }

    /// Binding entry point that also supplies the platform base cache root.
    @_spi(ModeratorBindings)
    public init(directory: String?, cacheRoot: String?) {
        model = LoadedModel(ModeratorModel.self, directory: directory, cacheRoot: cacheRoot) { files in
            Model(assets: try await .moderator(files: files))
        }
    }

    /// Creates a moderator from explicitly provided assets (the wasm
    /// self-hosted and custom-deployment paths).
    @_spi(ModeratorBindings)
    public init(assets: ModelAssets) {
        model = LoadedModel { Model(assets: assets) }
    }

    /// Whether the model is available with no network.
    public func isDownloaded() -> Bool { model.isDownloaded() }

    /// Download and load the model ahead of time, reporting progress `0...1`.
    /// A no-op once loaded.
    public func download(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        try await model.download(progress: progress)
    }

    /// Await model readiness, so the bindings can surface load errors eagerly.
    @_spi(ModeratorBindings)
    public func waitUntilLoaded() async throws {
        _ = try await model.value()
    }

    /// Score an image.
    /// Throws `CancellationError` promptly if the calling task is cancelled.
    public func analyze(_ image: ImagePixels, options: Options = .init()) async throws -> Moderation {
        try Task.checkCancellation()
        let model = try await model.value()
        try Task.checkCancellation()
        // One image is one billed call, however many crops it runs.
        let regions = try await InferenceContext.withCallGroup {
            try await model.regions(for: image, quality: options.quality)
        }
        return Moderation(regions: regions, options: options)
    }
}

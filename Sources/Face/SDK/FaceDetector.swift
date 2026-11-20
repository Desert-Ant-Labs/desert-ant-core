import DesertAnt

/// On-device face detection: where the faces in a photo are, with five
/// landmarks each, and no faceprints. Downloads Face's detector alone, which
/// ``Face`` and Eye share, so an app that also uses them downloads it once. Use
/// it to crop to faces, blur them, or count them. Create one and reuse it.
///
/// ```swift
/// let detector = FaceDetector()
/// for face in try await detector.faces(contentsOf: url) {
///     blur(face.box)
/// }
/// ```
public final class FaceDetector: @unchecked Sendable {
    private let model: LoadedModel<FaceRuntime>

    /// Creates a face detector. Construction does no work; the detector loads on
    /// the first ``faces(in:options:)`` or ``download(progress:)``.
    ///
    /// `directory` is the folder for the detector's files, which can be the same
    /// folder as ``Face``'s. If the folder already holds them, the detector uses
    /// them offline; otherwise it downloads them into the folder. With no
    /// `directory`, it uses a managed cache.
    public convenience init(directory: String? = nil) {
        self.init(directory: directory, cacheRoot: nil)
    }

    @_spi(FaceBindings)
    public init(directory: String?, cacheRoot: String?) {
        model = LoadedModel([FaceModel.detectorFiles], directory: directory, cacheRoot: cacheRoot) { files in
            try await FaceRuntime.load(detector: files[0], embedder: nil)
        }
    }

    @_spi(FaceBindings)
    public init(detect: any InferenceSession) {
        model = LoadedModel { FaceRuntime(detector: detect, embedder: nil) }
    }

    /// Whether the detector is available with no network.
    public func isDownloaded() -> Bool { model.isDownloaded() }

    /// Download and load the detector ahead of time, reporting progress `0...1`.
    /// A no-op once loaded.
    public func download(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        try await model.download(progress: progress)
    }

    /// The faces in an image (upright, any size), most confident first. Throws
    /// `CancellationError` promptly if the task is cancelled.
    public func faces(in image: ImagePixels, options: Options = .init()) async throws -> [FaceDetection] {
        try Task.checkCancellation()
        let model = try await model.value()
        try Task.checkCancellation()
        return try await model.detect(image, minimumConfidence: options.minimumConfidence, minimumSize: options.minimumSize,
                                      maxFaces: options.maxFaces).map { $0.detection(width: image.width, height: image.height) }
    }

    /// Which faces to keep.
    public struct Options: Sendable, Hashable {
        /// Faces the detector scores lower are left out. Default 0.3: low enough to keep faces in dim light, on
        /// darker skin and in blur. ``Face`` defaults to 0.35 (``recognition``), which groups people better.
        public var minimumConfidence: Double
        /// Faces whose box is smaller than this many pixels on its shorter side are left out. Default 32, about the
        /// smallest face Face recognises.
        public var minimumSize: Int
        /// At most this many faces, the most confident first. Default 20.
        public var maxFaces: Int

        public init(minimumConfidence: Double = 0.3, minimumSize: Int = 32, maxFaces: Int = 20) {
            self.minimumConfidence = minimumConfidence
            self.minimumSize = minimumSize
            self.maxFaces = max(0, maxFaces)
        }

        /// ``Face``'s default: faces scoring 0.35 or more, so fewer statues, cartoons and animals reach
        /// ``FaceLibrary``.
        public static let recognition = Options(minimumConfidence: 0.35)
    }
}

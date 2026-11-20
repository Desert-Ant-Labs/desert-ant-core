import DesertAnt

/// On-device face matching: find the faces in a photo, and tell who is who
/// across a library or through a video. No face leaves the device.
///
/// ``faces(in:options:)`` finds the faces in a photo and gives each one a
/// ``Faceprint``. ``FaceLibrary`` groups faceprints into people, keeps the groups
/// right as photos come and go, and keeps every correction the user makes.
/// ``matches(for:in:level:)`` finds one person among faceprints you store
/// yourself, and ``Faceprint/isSamePerson(as:_:)`` compares two faceprints. The
/// library and the comparisons run without the model. For where the faces are
/// without faceprints, ``FaceDetector`` downloads the detector alone. On Apple
/// platforms Face runs on Core ML, every op on the Neural Engine; everywhere else
/// Face runs on LiteRT. Create one `Face` and reuse it.
///
/// ```swift
/// let face = Face()
/// var library = FaceLibrary()
/// library.add(try await face.faces(contentsOf: url), photo: url.path)
/// library.people()                                  // [Person], most photographed first
/// library.person(for: selfie.faceprint)?.name       // who is this
/// ```
public final class Face: @unchecked Sendable {
    private let model: LoadedModel<FaceRuntime>

    /// Which faces get a faceprint: the same options as ``FaceDetector``'s, with
    /// ``Options/recognition`` as the default.
    public typealias Options = FaceDetector.Options

    /// Creates a face model. Construction does no work; the model loads on the
    /// first ``faces(in:options:)`` or ``download(progress:)``.
    ///
    /// `directory` is the folder for the model's files. If the folder already
    /// holds the model, Face uses the files offline; otherwise Face downloads the
    /// model into the folder. With no `directory`, Face uses a managed cache,
    /// where ``FaceDetector`` and Eye find the same detector.
    public convenience init(directory: String? = nil) {
        self.init(directory: directory, cacheRoot: nil)
    }

    @_spi(FaceBindings)
    public init(directory: String?, cacheRoot: String?) {
        model = LoadedModel([FaceModel.detectorFiles, FaceModel.embedderFiles], directory: directory,
                            cacheRoot: cacheRoot) { files in
            try await FaceRuntime.load(detector: files[0], embedder: files[1])
        }
    }

    @_spi(FaceBindings)
    public init(detect: any InferenceSession, embed: any InferenceSession) {
        model = LoadedModel { FaceRuntime(detector: detect, embedder: embed) }
    }

    /// Whether the model is available with no network.
    public func isDownloaded() -> Bool { model.isDownloaded() }

    /// Download and load the model ahead of time, reporting progress `0...1`.
    /// A no-op once loaded.
    public func download(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        try await model.download(progress: progress)
    }

    /// The faces in an image (upright, any size), most confident first, each with
    /// its faceprint. Throws `CancellationError` promptly if the task is cancelled.
    public func faces(in image: ImagePixels, options: Options = .recognition) async throws -> [DetectedFace] {
        try Task.checkCancellation()
        let model = try await model.value()
        try Task.checkCancellation()
        return try await model.faces(image, minimumConfidence: options.minimumConfidence,
                                     minimumSize: options.minimumSize, maxFaces: options.maxFaces)
    }

    /// The published model repository.
    public static var modelRepo: String { FaceModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    public static var modelRevision: String { FaceModel.revision }
}

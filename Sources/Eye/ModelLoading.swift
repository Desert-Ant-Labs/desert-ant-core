import DesertAnt

/// The decoded sidecar and one ready session per function. The entry point for
/// custom deployments; the public Swift API loads assets itself.
@_spi(EyeBindings)
public struct ModelAssets: Sendable {
    let sessions: [String: any InferenceSession]
    let meta: Meta
    let faces: FaceRuntime

    /// Bindings entry point: build from already-constructed sessions (one per
    /// function in ``EyeModel``, e.g. the wasm host's), the sidecar bytes, and
    /// Face's detector and, for faceprints, its embedder.
    @_spi(EyeBindings)
    public init(sessions: [String: any InferenceSession], meta: [UInt8], faceDetector: any InferenceSession,
                faceEmbedder: (any InferenceSession)? = nil) throws {
        self.sessions = sessions
        self.meta = try Meta(json: meta)
        faces = FaceRuntime(detector: faceDetector, embedder: faceEmbedder)
    }

    /// Build from resolved files: Eye's (the sidecar, and this platform's session
    /// for each function of the one artifact), then Face's detector and, when
    /// given, its embedder. Every session is licensed as Eye's.
    static func eye(files: StoredModel, faceDetector: StoredModel, faceEmbedder: StoredModel?) async throws -> ModelAssets {
        let sessions = try await files.inferenceSessions(model: EyeModel.artifact, functions: EyeModel.functions,
                                                         sdk: EyeModel.sdkInfo)
        let faces = try await FaceRuntime.load(detector: faceDetector, embedder: faceEmbedder, sdk: EyeModel.sdkInfo)
        return ModelAssets(sessions: sessions, meta: try Meta(json: try files.read(EyeModel.meta)), faces: faces)
    }

    private init(sessions: [String: any InferenceSession], meta: Meta, faces: FaceRuntime) {
        self.sessions = sessions
        self.meta = meta
        self.faces = faces
    }
}

public extension Eye {
    /// The published model repository.
    static var modelRepo: String { EyeModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { EyeModel.revision }
}

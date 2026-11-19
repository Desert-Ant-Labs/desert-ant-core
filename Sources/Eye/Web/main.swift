#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(EyeBindings) import Eye

// Eye's WebAssembly entry point. The exported surface is the shared one in
// `WasmBindings`, with payloads from `Eye/Binding.swift`. The host compiles
// Eye's one model, which runs each function as a named signature, and Face's
// detector (and embedder, for the `faceprints` variant) under their file names.
let detector = FaceModel.detector(for: .web), embedder = FaceModel.embedder(for: .web)

func selfHosted(_ files: [String: [UInt8]], faceprints: Bool) throws -> Eye {
    guard let meta = files[EyeModel.meta] else { throw EyeError.resourceMissing }
    let sessions = Dictionary(uniqueKeysWithValues: EyeModel.functions.map {
        ($0, inferenceSession(signature: $0, sdk: EyeModel.sdkInfo))
    })
    return Eye(assets: try ModelAssets(
        sessions: sessions, meta: meta,
        faceDetector: inferenceSession(model: detector, sdk: EyeModel.sdkInfo),
        faceEmbedder: faceprints ? inferenceSession(model: embedder, sdk: EyeModel.sdkInfo) : nil))
}

installWasmModel(
    WasmModel(EyeModel.self, binding: EyeBinding.self, sidecars: [EyeModel.meta, detector],
              selfHosted: { files, _ in try selfHosted(files, faceprints: false) },
              selfHostedVariant: { variant, files, _ in
                  guard variant == "faceprints" else { throw EyeError.resourceMissing }
                  return try selfHosted(files, faceprints: true)
              }))
#endif

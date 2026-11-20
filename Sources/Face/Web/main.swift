#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(FaceBindings) import Face

// The page compiles the detector (the artifact) itself; the embedder is a
// sidecar it compiles under its file name.
installWasmModel(
    WasmModel(FaceModel.self, binding: FaceBinding.self, selfHosted: { _, detect in
        FaceBinding.make(detect: detect,
                         embed: inferenceSession(model: FaceModel.embedder(for: .web), sdk: FaceModel.sdkInfo))
    }, selfHostedVariant: { variant, _, detect in
        guard variant == "detector" else { throw FaceError.resourceMissing }
        return FaceBinding.make(detect: detect)
    }))
#endif

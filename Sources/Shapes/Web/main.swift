#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(ShapesBindings) import Shapes

// Shapes' WebAssembly entry point. The exported surface is the shared one in
// `WasmBindings`, with payloads from `Shapes/Binding.swift`. Only the self-hosted
// `modelBaseUrl` path is model-specific, because only Shapes knows its sidecar.
installWasmModel(
    WasmModel(ShapesModel.self, binding: ShapesBinding.self) { sidecars, session in
        guard let meta = sidecars[ShapesModel.meta] else {
            throw ShapesError.resourceMissing
        }
        return Shapes(assets: ModelAssets(
            metaJSON: String(decoding: meta, as: UTF8.self),
            session: session))
    })
#endif

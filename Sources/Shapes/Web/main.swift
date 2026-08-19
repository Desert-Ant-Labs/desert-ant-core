#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(ShapesBindings) import Shapes

// Shapes' WebAssembly entry point.
//
// The exported surface is the shared, model-agnostic one in `WasmBindings`
// (`Exports.swift`, generated into typed JS by BridgeJS), the wasm twin of the
// `dal_*` C ABI: options and results cross as the FFI payloads
// `Shapes/Binding.swift` already encodes, so nothing model-specific is repeated
// here. The one exception is the `modelBaseUrl` path, where the JS host fetched
// the files and compiled the model itself: only Shapes knows that its sidecar is
// the meta JSON.
//
// `packages/shapes-node` wraps that surface in the public typed API.
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

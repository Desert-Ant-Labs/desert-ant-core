#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(EarBindings) import Ear

// Ear's WebAssembly entry point.
//
// The exported surface is the shared, model-agnostic one in `WasmBindings`
// (`Exports.swift`, generated into typed JS by BridgeJS), the wasm twin of the
// `dal_*` C ABI: options and results cross as the FFI payloads
// `Ear/Binding.swift` already encodes, so nothing model-specific is repeated
// here. The one exception is the `modelBaseUrl` path, where the JS host fetched
// the files and compiled the model itself: only Ear knows that its sidecars are
// the language list, the geometry, and the mel filterbank.
//
// `packages/ear-node` wraps that surface in the public typed API.
installWasmModel(
    WasmModel(EarModel.self, binding: EarBinding.self) { sidecars, session in
        guard let languages = sidecars[EarModel.languages],
              let meta = sidecars[EarModel.meta],
              let filters = sidecars[EarModel.melFilters] else {
            throw EarError.modelNotFound
        }
        return try Ear(assets: ModelAssets(
            languagesJSON: String(decoding: languages, as: UTF8.self),
            metaJSON: String(decoding: meta, as: UTF8.self),
            melFilters: filters,
            session: session))
    })
#endif

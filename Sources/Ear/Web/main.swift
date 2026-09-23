#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(EarBindings) import Ear

// Ear's WebAssembly entry point. The exported surface is the shared one in
// `WasmBindings`, with payloads from `Ear/Binding.swift`. Only the self-hosted
// `modelBaseUrl` path is model-specific, because only Ear knows its sidecars.
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

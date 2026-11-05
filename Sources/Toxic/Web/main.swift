#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(ToxicBindings) import Toxic

// Toxic's WebAssembly entry point. The exported surface is the shared one in
// `WasmBindings`, with payloads from `Toxic/Binding.swift`. Only the self-hosted
// `modelBaseUrl` path is model-specific, because only Toxic knows its sidecars.
installWasmModel(
    WasmModel(ToxicModel.self, binding: ToxicBinding.self) { sidecars, session in
        guard let meta = sidecars[ToxicModel.meta(for: .web)],
              let tokenizer = sidecars[ToxicModel.tokenizer],
              let table = sidecars[ToxicModel.table] else {
            throw ToxicError.resourceMissing
        }
        return Toxic(assets: ModelAssets(
            metaJSON: String(decoding: meta, as: UTF8.self),
            tokenizer: tokenizer,
            table: table,
            session: session))
    })
#endif

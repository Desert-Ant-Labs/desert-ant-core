#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(EmoBindings) import Emo

// Emo's WebAssembly entry point. The exported surface is the shared one in
// `WasmBindings`, with payloads from `Emo/Binding.swift`. Only the self-hosted
// `modelBaseUrl` path is model-specific, because only Emo knows its sidecars.
installWasmModel(
    WasmModel(EmoModel.self, binding: EmoBinding.self) { sidecars, session in
        guard let meta = sidecars[EmoModel.meta], let tokenizer = sidecars[EmoModel.tokenizer] else {
            throw EmoError.modelNotFound
        }
        return Emo(assets: ModelAssets(
            metaJSON: String(decoding: meta, as: UTF8.self),
            tokenizer: tokenizer,
            session: session))
    })
#endif

#if os(WASI)
import DesertAnt
import WasmBindings
import Bindings
@_spi(EmoBindings) import Emo

// Emo's WebAssembly entry point.
//
// The exported surface is the shared, model-agnostic ABI in `WasmBindings`
// (`globalThis.__DesertAntExports.emo`), the wasm twin of the `dal_*` C ABI:
// options and results cross as the FFI payloads `Emo/Binding.swift` already
// encodes, so nothing model-specific is repeated here. The one exception is the
// `modelBaseUrl` path, where the JS host fetched the files and compiled the
// model itself: only Emo knows that its sidecars are the meta JSON and the
// tokenizer.
//
// `packages/emo-node` wraps this in the public typed API; nothing else should
// touch these globals.
installWasmExports([
    WasmModel(EmoModel.self, binding: EmoBinding.self) { sidecars, session in
        guard let meta = sidecars[EmoModel.meta], let tokenizer = sidecars[EmoModel.tokenizer] else {
            throw EmoError.modelNotFound
        }
        return Emo(assets: ModelAssets(
            metaJSON: String(decoding: meta, as: UTF8.self),
            tokenizer: tokenizer,
            session: session))
    },
])
#endif

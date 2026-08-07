#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(EmoBindings) import Emo

// Emo's WebAssembly entry point.
//
// The exported surface is the shared, model-agnostic one in `WasmBindings`
// (`Exports.swift`, generated into typed JS by BridgeJS), the wasm twin of the
// `dal_*` C ABI: options and results cross as the FFI payloads
// `Emo/Binding.swift` already encodes, so nothing model-specific is repeated
// here. The one exception is the `modelBaseUrl` path, where the JS
// host fetched the files and compiled the model itself: only Emo knows that its
// sidecars are the meta JSON and the tokenizer.
//
// `packages/emo-node` wraps that surface in the public typed API.
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

#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(RedactBindings) import Redact

// Redact's WebAssembly entry point.
//
// The exported surface is the shared, model-agnostic one in `WasmBindings`
// (`Exports.swift`, generated into typed JS by BridgeJS), the wasm twin of the
// `dal_*` C ABI: options and results cross as the FFI payloads
// `Redact/Binding.swift` already encodes, so nothing model-specific is repeated
// here. The one exception is the `modelBaseUrl` path, where the JS
// host fetched the files and compiled the model itself: only Redact knows that
// its sidecars are the tokenizer and the label map.
//
// `packages/redact-node` wraps that surface in the public typed API.
installWasmModel(
    WasmModel(RedactModel.self, binding: RedactBinding.self) { sidecars, session in
        guard let tokenizer = sidecars[RedactModel.tokenizer],
              let labels = sidecars[RedactModel.labels] else {
            throw RedactError.resourceMissing
        }
        return Redact(assets: ModelAssets(
            tokenizer: tokenizer,
            labelsJSON: String(decoding: labels, as: UTF8.self),
            session: session))
    })
#endif

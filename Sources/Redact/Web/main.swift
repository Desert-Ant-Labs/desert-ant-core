#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(RedactBindings) import Redact

// Redact's WebAssembly entry point.
//
// The exported surface is the shared, model-agnostic ABI in `WasmBindings`
// (`globalThis.__DesertAntExports.redact`), the wasm twin of the `dal_*` C ABI:
// options and results cross as the FFI payloads `Redact/Binding.swift` already
// encodes, so nothing model-specific is repeated here. The one exception is the
// `modelBaseUrl` path, where the JS host fetched the files and compiled the
// model itself: only Redact knows that its sidecars are the tokenizer and the
// label map.
//
// `packages/redact-node` wraps this in the public typed API; nothing else should
// touch these globals.
installWasmExports([
    WasmModel(RedactModel.self, binding: RedactBinding.self) { sidecars, session in
        guard let tokenizer = sidecars[RedactModel.tokenizer],
              let labels = sidecars[RedactModel.labels] else {
            throw RedactError.resourceMissing
        }
        return Redact(assets: ModelAssets(
            tokenizer: tokenizer,
            labelsJSON: String(decoding: labels, as: UTF8.self),
            session: session))
    },
])
#endif

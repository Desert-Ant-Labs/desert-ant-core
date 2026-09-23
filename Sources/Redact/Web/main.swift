#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(RedactBindings) import Redact

// Redact's WebAssembly entry point. The exported surface is the shared one in
// `WasmBindings`, with payloads from `Redact/Binding.swift`. Only the self-hosted
// `modelBaseUrl` path is model-specific, because only Redact knows its sidecars.
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

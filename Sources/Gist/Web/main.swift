#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(GistBindings) import Gist

// Gist's WebAssembly entry point.
//
// The exported surface is the shared, model-agnostic one in `WasmBindings`
// (`Exports.swift`, generated into typed JS by BridgeJS), the wasm twin of the
// `dal_*` C ABI: options and results cross as the FFI payloads
// `Gist/Binding.swift` already encodes, so nothing model-specific is repeated
// here. The one exception is the `modelBaseUrl` path, where the JS host fetched
// the files and compiled the model itself: only Gist knows that its sidecars are
// the tokenizer, the embedding table and its metadata, the config, and the
// taxonomy.
//
// `packages/gist-node` wraps that surface in the public typed API.
installWasmModel(
    WasmModel(GistModel.self, binding: GistBinding.self) { sidecars, session in
        guard let tokenizer = sidecars[GistModel.tokenizer],
              let embedding = sidecars[GistModel.embedding],
              let embeddingMeta = sidecars[GistModel.embeddingMeta],
              let config = sidecars[GistModel.config],
              let taxonomy = sidecars[GistModel.taxonomy] else {
            throw GistError.modelNotFound
        }
        return Gist(assets: ModelAssets(
            tokenizer: tokenizer,
            embedding: embedding,
            embeddingMetaJSON: String(decoding: embeddingMeta, as: UTF8.self),
            configJSON: String(decoding: config, as: UTF8.self),
            taxonomyJSON: String(decoding: taxonomy, as: UTF8.self),
            session: session))
    })
#endif

#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(GistBindings) import Gist

// Gist's WebAssembly entry point. The exported surface is the shared one in
// `WasmBindings`, with payloads from `Gist/Binding.swift`. Only the self-hosted
// `modelBaseUrl` path is model-specific, because only Gist knows its sidecars.
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

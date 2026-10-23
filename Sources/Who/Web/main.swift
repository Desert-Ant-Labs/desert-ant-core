#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(WhoBindings) import Who

// Who's WebAssembly entry point. The exported surface is the shared one in
// `WasmBindings`, with payloads from `Who/Binding.swift`. The host compiles the
// one LiteRT file; Who runs each of its five graphs as a named signature of it.
installWasmModel(
    WasmModel(WhoModel.self, binding: WhoBinding.self) { files, _ in
        let directory = WhoModel.variant.directory(for: .web)
        guard let meta = files["\(directory)/\(WhoModel.meta)"], let melBanks = files["\(directory)/\(WhoModel.melBanks)"],
              let voiceBanks = files["\(directory)/\(WhoModel.voiceBanks)"], let embedding = files["\(directory)/\(WhoModel.embedding)"]
        else { throw WhoError.modelNotFound }
        let sessions = Dictionary(uniqueKeysWithValues: ModelVariant.graphs.map {
            ($0, inferenceSession(signature: $0, sdk: WhoModel.sdkInfo))
        })
        return WhoBound(try Who(assets: ModelAssets(metaJSON: String(decoding: meta, as: UTF8.self), melBanks: melBanks,
                                                    voiceBanks: voiceBanks, embedding: embedding, sessions: sessions)))
    })
#endif

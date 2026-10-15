#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(EyeBindings) import Eye

// Eye's WebAssembly entry point. The exported surface is the shared one in
// `WasmBindings`, with payloads from `Eye/Binding.swift`. The host compiles the
// one model; Eye runs each of its functions as a named signature of it.
installWasmModel(
    WasmModel(EyeModel.self, binding: EyeBinding.self) { files, _ in
        guard let meta = files[EyeModel.meta] else { throw EyeError.resourceMissing }
        let sessions = Dictionary(uniqueKeysWithValues: EyeModel.functions.map {
            ($0, inferenceSession(signature: $0, sdk: EyeModel.sdkInfo))
        })
        return Eye(assets: try ModelAssets(sessions: sessions, meta: meta))
    })
#endif

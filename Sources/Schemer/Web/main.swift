#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(SchemerBindings) import Schemer

// Schemer's WebAssembly entry point.
//
// The exported surface is the shared, model-agnostic one in `WasmBindings`;
// the text, schema and result cross as the FFI payloads `Schemer/Binding.swift`
// encodes. The `modelBaseUrl` path is the one place Schemer differs: it runs
// three graphs where every other model runs one, so the host's compiled model
// is only the encoder, and the decode and label graphs arrive as sidecars that
// `ModelAssets.selfHosted` compiles on the host beside it.
// `packages/schemer-node` wraps this surface in the public typed API.
installWasmModel(
    WasmModel(SchemerModel.self, binding: SchemerBinding.self) { files, _ in
        Schemer(assets: try ModelAssets.selfHosted(files: files))
    })
#endif

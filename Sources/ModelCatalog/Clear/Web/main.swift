#if os(WASI)
import DesertAnt
import WasmBindings
import Bindings
@_spi(ClearBindings) import Clear

// Clear's WebAssembly entry point.
//
// The exported surface is the shared, model-agnostic ABI in `WasmBindings`
// (`globalThis.__DesertAntExports.clear`), the wasm twin of the `dal_*` C ABI:
// options and results cross as the FFI payloads `Clear/Binding.swift` already
// encodes, so nothing model-specific is repeated here. The one exception is the
// self-hosted path, where the JS host fetched the files and compiled the model
// itself - and Clear has no sidecars, so there is nothing to read from them.
//
// Audio in and out crosses as the model's own payload, so the host passes
// samples through the shared `run` entry like any other model's input.
installWasmExports([
    WasmModel(ClearModel.self, binding: ClearBinding.self) { _, session in
        Clear(assets: ModelAssets(session: session))
    },
])
#endif

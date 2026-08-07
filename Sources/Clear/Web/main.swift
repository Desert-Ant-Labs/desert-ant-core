#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(ClearBindings) import Clear

// Clear's WebAssembly entry point.
//
// The exported surface is the shared, model-agnostic one in `WasmBindings`
// (`Exports.swift`, generated into typed JS by BridgeJS), the wasm twin of the
// `dal_*` C ABI: options and results cross as the FFI payloads
// `Clear/Binding.swift` already encodes, so nothing model-specific is repeated
// here. Clear has no sidecars, so the self-hosted path
// (where the JS host fetched the files and compiled the model itself) has
// nothing to read from them, and audio in and out crosses as the model's own
// payload through the shared `run` entry like any other model's input.
//
// Clear ships no npm package yet, so this is a compile check today; the surface
// it exposes is the same one every model's package consumes.
installWasmModel(
    WasmModel(ClearModel.self, binding: ClearBinding.self) { _, session in
        Clear(assets: ModelAssets(session: session))
    })
#endif

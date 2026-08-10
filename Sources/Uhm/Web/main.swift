#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(UhmBindings) import Uhm

// Uhm's WebAssembly entry point.
//
// The exported surface is the shared, model-agnostic one in `WasmBindings`
// (`Exports.swift`, generated into typed JS by BridgeJS), the wasm twin of the
// `dal_*` C ABI: options and results cross as the FFI payloads
// `Uhm/Binding.swift` already encodes, so nothing model-specific is repeated
// here. Uhm has no sidecars, and audio in and out crosses as the model's own
// payload through the shared `run` entry like any other model's input.
//
// Uhm ships no npm package (and no published web artifact) yet, so this is a
// compile check today; the surface it exposes is the same one every model's
// package consumes.
installWasmModel(
    WasmModel(UhmModel.self, binding: UhmBinding.self) { _, session in
        Uhm(assets: ModelAssets(session: session))
    })
#endif

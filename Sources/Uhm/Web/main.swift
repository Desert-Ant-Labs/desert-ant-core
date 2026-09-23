#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(UhmBindings) import Uhm

// Uhm's WebAssembly entry point, a compile check only: Uhm ships no npm package
// or web artifact. The exported surface is the shared one in `WasmBindings`, with
// payloads from `Uhm/Binding.swift`.
installWasmModel(
    WasmModel(UhmModel.self, binding: UhmBinding.self) { _, session in
        Uhm(assets: ModelAssets(session: session))
    })
#endif

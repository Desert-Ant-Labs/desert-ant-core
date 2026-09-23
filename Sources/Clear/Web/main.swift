#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(ClearBindings) import Clear

// Clear's WebAssembly entry point. The exported surface is the shared one in
// `WasmBindings`, with payloads from `Clear/Binding.swift`. Clear has no sidecars,
// so the self-hosted path needs nothing but the session.
installWasmModel(
    WasmModel(ClearModel.self, binding: ClearBinding.self) { _, session in
        Clear(assets: ModelAssets(session: session))
    })
#endif

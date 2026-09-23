#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(ModeratorBindings) import Moderator

// Moderator's WebAssembly entry point. The exported surface is the shared one in
// `WasmBindings`, with payloads from `Moderator/Binding.swift`. Moderator has no
// sidecars, so the self-hosted path needs nothing but the session.
installWasmModel(
    WasmModel(ModeratorModel.self, binding: ModeratorBinding.self) { _, session in
        Moderator(assets: ModelAssets(session: session))
    })
#endif

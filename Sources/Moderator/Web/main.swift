#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(ModeratorBindings) import Moderator

// Moderator's WebAssembly entry point.
//
// The exported surface is the shared, model-agnostic one in `WasmBindings`;
// images, options, and results cross as the FFI payloads `Moderator/Binding.swift`
// encodes. Moderator has no sidecars, so the self-hosted `modelBaseUrl` path
// needs nothing but the session. `packages/moderator-node` wraps this surface
// in the public typed API.
installWasmModel(
    WasmModel(ModeratorModel.self, binding: ModeratorBinding.self) { _, session in
        Moderator(assets: ModelAssets(session: session))
    })
#endif

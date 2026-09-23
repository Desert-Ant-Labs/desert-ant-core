#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(ClipBindings) import Clips

// Clips's WebAssembly entry point, a compile check only. The wasm host holds one
// compiled model per module (`docs/development.md`) and selection needs two, so
// the self-hosted path refuses rather than scoring every span against the wrong
// graph. Lifting this is a host-contract change, not a patch to this file.
installWasmModel(
    WasmModel(ClipModel.self, binding: ClipBinding.self) { _, _ in
        throw ClipError.modelNotFound
    })
#endif

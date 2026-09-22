#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(AlignBindings) import Align

// No web platform: the wasm host holds one model per module and the cascade is two.
installWasmModel(
    WasmModel(AlignModel.self, binding: AlignBinding.self) { _, _ in
        throw InferenceError.sessionUnavailable("align needs two sessions; the wasm host holds one")
    })
#endif

#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(UhmBindings) import Uhm

// The WebAssembly entry point of @desert-ant-labs/uhm's browser build.
installWasmModel(
    WasmModel(UhmModel.self, binding: UhmBinding.self) { _, session in
        Uhm(assets: ModelAssets(session: session))
    })
#endif

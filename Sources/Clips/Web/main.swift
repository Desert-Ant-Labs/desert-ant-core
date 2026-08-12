#if os(WASI)
import DesertAnt
import WasmBindings
@_spi(ClipBindings) import Clips

// Clips's WebAssembly entry point.
//
// The exported surface is the shared, model-agnostic one in `WasmBindings`
// (`Exports.swift`, generated into typed JS by BridgeJS), the wasm twin of the
// `dal_*` C ABI: the transcript, the options and the result cross as the FFI
// payloads `Clips/Binding.swift` already encodes, so nothing model-specific is
// repeated here.
//
// Clips ships no npm package, so this is a compile check today - and it is the
// honest state of the model on the web rather than an oversight. The wasm host
// contract holds ONE compiled model per module (`docs/development.md`), and
// selection needs two sessions in the same module: a per-sentence selector and
// a per-span scorer, two separate exports with different inputs. So
// `ClipModel.files` declares no `.web` manifest, and the self-hosted path -
// where the JS host fetched the files and compiled the model itself - has only
// one of the two sessions to hand over and says so rather than half-building a
// model that would score every span against the wrong graph.
//
// Lifting this is the same cross-language decision `docs/development.md`
// already frames for Clear: it is a host-contract change (more than one
// compiled model per module), not a patch to this file.
installWasmModel(
    WasmModel(ClipModel.self, binding: ClipBinding.self) { _, _ in
        throw ClipError.modelNotFound
    })
#endif

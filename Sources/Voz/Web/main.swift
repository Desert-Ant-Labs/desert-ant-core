#if os(WASI)
import Foundation
import JavaScriptEventLoop
import JavaScriptKit

// Voz's WebAssembly entry point.
//
// The same `Pipeline` the Neural Engine runs: windowing, the boundary search,
// the lane-batched decode and the splice are Swift on both platforms, and the
// only thing that differs is the engine underneath (`Engine+Wasm.swift`), which
// calls back into JavaScript to run the three models.
//
// Not the shared surface in `WasmBindings`, which every other model exports.
// That one is model-agnostic because options and results cross as a model's own
// `FFIBuffer` payload through one `run`, and it is built on the single-session
// `dalModelHost` seam. Voz has neither: it runs three models, and its result is
// a transcript with a word list rather than a byte payload. So it exports its
// own `@JS` surface, which is still BridgeJS-generated (`dist/bridge-js.d.ts`
// carries these types) rather than globals a consumer has to know the names of.
//
// The exported surface itself lives in `Bridge.swift`: BridgeJS does not scan
// a `main.swift`, so an `@JS` declaration in this file generates nothing.

JavaScriptEventLoop.installGlobalExecutor()
#endif

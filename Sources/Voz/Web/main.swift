#if os(WASI)
import Foundation
import JavaScriptEventLoop
import JavaScriptKit

// Voz's WebAssembly entry point: the same `Pipeline` the Neural Engine runs,
// over an engine (`Engine+Wasm.swift`) that calls back into JavaScript.
//
// Not the shared surface in `WasmBindings`, which assumes a single session and a
// byte payload through one `run`. Voz runs three models and returns a transcript
// with a word list, so it exports its own BridgeJS-generated `@JS` surface.
// That surface lives in `Bridge.swift`.

JavaScriptEventLoop.installGlobalExecutor()
#endif

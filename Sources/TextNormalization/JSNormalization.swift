// NFKC via the JS host's String.prototype.normalize on WebAssembly, keeping ICU
// out of the wasm payload.
#if os(WASI)
import JavaScriptKit

// `nonisolated(unsafe)` because `JSObject` is not Sendable: a JS reference belongs
// to the context that made it, and this module only ever runs on wasm, which is
// single-threaded. Same basis as every other wasm-only unchecked global here.
private nonisolated(unsafe) let jsNormalize: JSObject =
    JSObject.global.Function.function!.new("s", "return s.normalize('NFKC')")

func nfkcNormalize(_ s: String) -> String { jsNormalize(s).string ?? s }
#endif
